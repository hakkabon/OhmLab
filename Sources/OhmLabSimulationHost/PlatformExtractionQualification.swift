import Foundation
import OhmLabCore
import OhmLabSimulationProtocol

/// Executable evidence for the 2.1 protocol/host module boundary.
public enum PlatformExtractionQualification {
    public static let currentContractVersion = 1
    public static let minimumCaseCount = 9

    public struct CaseResult: Codable, Equatable, Sendable {
        public let identifier: String
        public let passed: Bool
        public let detail: String
    }

    public struct Report: Codable, Equatable, Sendable {
        public let contractVersion: Int
        public let productVersion: String
        public let protocolModule: String
        public let hostModule: String
        public let cases: [CaseResult]
        public let issues: [String]
        public let ready: Bool
    }

    public static func evaluate() async -> Report {
        var cases: [CaseResult] = []
        do {
            let circuit = try CircuitIRCompiler.compile(netlist: """
            V1 in 0 5
            R1 in out 1k
            R2 out 0 1k
            .end
            """)
            let request = PortableSimulationPlatform.Request(
                requestID: "host-qualification", circuit: circuit,
                analysis: .init(dcOperatingPoint: true)
            )

            let policy = SimulationExecutionPolicy(maximumParallelism: 2)
            cases.append(.init(
                identifier: "foundation-protocol-contract",
                passed: (try? policy.validate()) != nil
                    && SimulationHostContract.currentVersion == 1,
                detail: "Foundation-only execution and batch contracts"
            ))

            let manifest = OhmLabSimulationHost.manifest
            let backendIdentifiers = manifest.backends.map(\.identifier).sorted()
            let limitIdentifiers = manifest.backendLimits.map(\.identifier).sorted()
            cases.append(.init(
                identifier: "per-backend-limits-published",
                passed: limitIdentifiers == backendIdentifiers
                    && manifest.backendLimits.allSatisfy {
                        $0.maximumDenseUnknowns > 0
                            && $0.maximumNodes >= $0.maximumDenseUnknowns
                            && $0.maximumDevices > 0
                    },
                detail: "manifest publishes an executable dense envelope per backend"
            ))

            let response = await OhmLabSimulationHost.execute(request, policy: policy)
            cases.append(.init(
                identifier: "isolated-host-execution",
                passed: response.succeeded
                    && abs((response.result?.dc?.nodes.first(where: { $0.name == "out" })?.value ?? 0) - 2.5) < 1e-12,
                detail: response.error?.message ?? "host returned the expected divider result"
            ))

            let token = SimulationCancellationToken()
            token.cancel()
            let cancelled = await OhmLabSimulationHost.execute(request, cancellationToken: token)
            cases.append(.init(
                identifier: "preflight-cancellation",
                passed: cancelled.error?.message == "simulation cancelled",
                detail: cancelled.error?.message ?? "cancelled request unexpectedly succeeded"
            ))

            let budgeted = await OhmLabSimulationHost.execute(
                request,
                policy: .init(maximumResultBytes: 1)
            )
            cases.append(.init(
                identifier: "result-budget",
                passed: budgeted.error?.code == .resourceLimit
                    && budgeted.error?.message == "result exceeds host byte budget",
                detail: budgeted.error?.message ?? "result budget was not enforced"
            ))

            let denseBudget = await OhmLabSimulationHost.execute(
                request,
                policy: .init(maximumNodes: 1)
            )
            cases.append(.init(
                identifier: "resource-limit-code",
                passed: denseBudget.error?.code == .resourceLimit,
                detail: denseBudget.error?.message ?? "resource budget was not reported as a resource limit"
            ))

            // The NumericCore divider sweep takes roughly a minute to run to
            // completion but only milliseconds to reach its first deadline
            // checkpoint. The 30-second bound is deliberately loose so that a
            // busy test machine cannot fail the case by delaying scheduling;
            // it still separates an interrupted run from a completed one.
            let longSweep = PortableSimulationPlatform.Request(
                requestID: "host-qualification-deadline",
                backend: "numeric-core",
                circuit: circuit,
                analysis: .init(
                    dcOperatingPoint: false,
                    dcSweep: .init(source: "V1", start: 0, stop: 100, step: 0.0011)
                )
            )
            let clock = ContinuousClock()
            let started = clock.now
            let timedOut = await OhmLabSimulationHost.execute(
                longSweep,
                policy: .init(timeoutMilliseconds: 1)
            )
            let elapsed = started.duration(to: clock.now)
            cases.append(.init(
                identifier: "deadline-enforced",
                passed: timedOut.error?.code == .timeout && elapsed < .seconds(30),
                detail: timedOut.error?.code == .timeout
                    ? "deadline stopped a long sweep in \(elapsed)"
                    : (timedOut.error?.message ?? "long sweep unexpectedly succeeded")
            ))

            let second = PortableSimulationPlatform.Request(
                requestID: "host-qualification-2", backend: "numeric-core", circuit: circuit,
                analysis: .init(dcOperatingPoint: true)
            )
            let batch = PortableSimulationBatchRequest(
                batchID: "qualification-batch", requests: [request, second]
            )
            let batchResponse = await OhmLabSimulationHost.executeBatch(batch, policy: policy)
            cases.append(.init(
                identifier: "ordered-parallel-batch",
                passed: batchResponse.items.map(\.index) == [0, 1]
                    && batchResponse.items.allSatisfy { $0.response?.succeeded == true },
                detail: "two backends completed in deterministic request order"
            ))

            let unknown = PortableSimulationPlatform.Request(
                requestID: "host-qualification-failure", backend: "missing", circuit: circuit,
                analysis: .init(dcOperatingPoint: true)
            )
            let failFast = PortableSimulationBatchRequest(
                batchID: "qualification-fail-fast", failFast: true,
                requests: [unknown, request]
            )
            let failFastResponse = await OhmLabSimulationHost.executeBatch(failFast, policy: policy)
            cases.append(.init(
                identifier: "fail-fast-batch",
                passed: failFastResponse.items.count == 2
                    && failFastResponse.items[0].response?.error?.code == .unknownBackend
                    && failFastResponse.items[1].state == .skipped,
                detail: "remaining requests are represented explicitly as skipped"
            ))
        } catch {
            cases.append(.init(identifier: "qualification-setup", passed: false, detail: error.localizedDescription))
        }

        var issues: [String] = []
        if cases.count < minimumCaseCount { issues.append("platform extraction qualification is incomplete") }
        let failures = cases.filter { !$0.passed }.map(\.identifier)
        if !failures.isEmpty { issues.append("platform extraction failed: \(failures.joined(separator: ", "))") }
        return .init(
            contractVersion: currentContractVersion,
            productVersion: OhmLabRelease.version,
            protocolModule: "OhmLabSimulationProtocol",
            hostModule: "OhmLabSimulationHost",
            cases: cases,
            issues: issues,
            ready: issues.isEmpty
        )
    }
}
