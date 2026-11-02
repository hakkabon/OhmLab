import Foundation
import Testing
@testable import OhmLabCore
@testable import OhmLabSimulationHost
@testable import OhmLabSimulationProtocol

@Suite("OhmLab 2.1 platform extraction")
struct PlatformExtractionTests {
    private func request(id: String = "extracted-host", backend: String = "native-mna") throws
        -> PortableSimulationPlatform.Request {
        let circuit = try CircuitIRCompiler.compile(netlist: """
        V1 in 0 5
        R1 in out 1k
        R2 out 0 1k
        .end
        """)
        return .init(
            requestID: id, backend: backend, circuit: circuit,
            analysis: .init(dcOperatingPoint: true)
        )
    }

    @Test func protocolPolicyAndCodecRequireNoHostTypes() throws {
        let policy = SimulationExecutionPolicy(
            timeoutMilliseconds: 1_000,
            maximumRequestBytes: 1_024,
            maximumResultBytes: 2_048,
            maximumNodes: 10,
            maximumDevices: 20,
            maximumParallelism: 2
        )
        try policy.validate()
        let data = try SimulationHostContract.encode(policy)
        #expect(try SimulationHostContract.decode(SimulationExecutionPolicy.self, from: data) == policy)
        #expect(throws: SimulationHostContractError.self) {
            try SimulationExecutionPolicy(maximumParallelism: 0).validate()
        }
    }

    @Test func extractedHostExecutesAndEnforcesBudgets() async throws {
        let request = try request()
        let success = await OhmLabSimulationHost.execute(request)
        #expect(success.succeeded)
        #expect(abs((success.result?.dc?.nodes.first { $0.name == "out" }?.value ?? 0) - 2.5) < 1e-12)

        let tooFewNodes = await OhmLabSimulationHost.execute(
            request,
            policy: .init(maximumNodes: 1)
        )
        #expect(tooFewNodes.error?.code == .resourceLimit)

        let tinyResultBudget = await OhmLabSimulationHost.execute(
            request,
            policy: .init(maximumResultBytes: 1)
        )
        #expect(tinyResultBudget.error?.code == .resourceLimit)
        #expect(tinyResultBudget.error?.message == "result exceeds host byte budget")
    }

    @Test func extractedHostEnforcesDeadlineOnRealWork() async throws {
        let circuit = try CircuitIRCompiler.compile(netlist: """
        V1 in 0 5
        R1 in out 1k
        R2 out 0 1k
        .end
        """)
        // The NumericCore divider sweep takes roughly a minute to complete.
        // The 30-second bound tolerates scheduling delays on a busy test
        // machine while still proving the solver was interrupted rather than
        // allowed to finish and labelled afterwards.
        let request = PortableSimulationPlatform.Request(
            requestID: "deadline",
            backend: "numeric-core",
            circuit: circuit,
            analysis: .init(
                dcOperatingPoint: false,
                dcSweep: .init(source: "V1", start: 0, stop: 100, step: 0.0011)
            )
        )
        let clock = ContinuousClock()
        let started = clock.now
        let response = await OhmLabSimulationHost.execute(
            request,
            policy: .init(timeoutMilliseconds: 1)
        )
        let elapsed = started.duration(to: clock.now)

        #expect(response.error?.code == .timeout)
        #expect(elapsed < .seconds(30))
    }

    @Test func deadlineContextIsInheritedBySolverTasks() async {
        // A deadline in the past makes the checkpoint deterministic: the child
        // task must inherit the task-local and stop on its first check. No
        // wall-clock measurement is needed, so a busy scheduler cannot make
        // this test flaky.
        let deadline = ContinuousClock().now.advanced(by: .milliseconds(-1))
        let stopped = await SimulationExecutionDeadline.$instant.withValue(deadline) {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for _ in 0..<10_000_000 {
                        do { try SimulationExecutionDeadline.check() }
                        catch { return true }
                    }
                    return false
                }
                return await group.next() ?? false
            }
        }
        #expect(stopped)
    }

    @Test func manifestPublishesPerBackendLimits() {
        let manifest = OhmLabSimulationHost.manifest
        #expect(manifest.backendLimits.map(\.identifier).sorted()
            == manifest.backends.map(\.identifier).sorted())
        #expect(manifest.backendLimits.allSatisfy {
            $0.maximumDenseUnknowns == PortableSimulationPlatform.maximumDenseUnknowns
        })
    }

    @Test func extractedHostHonorsCancellation() async throws {
        let token = SimulationCancellationToken()
        token.cancel()
        let response = await OhmLabSimulationHost.execute(try request(), cancellationToken: token)
        #expect(response.error?.message == "simulation cancelled")
        #expect(!response.succeeded)
    }

    @Test func batchIsOrderedAndFailFastIsExplicit() async throws {
        let first = try request(id: "first")
        let second = try request(id: "second", backend: "numeric-core")
        let batch = PortableSimulationBatchRequest(batchID: "ordered", requests: [first, second])
        let response = await OhmLabSimulationHost.executeBatch(
            batch, policy: .init(maximumParallelism: 2)
        )
        #expect(response.items.map(\.index) == [0, 1])
        #expect(response.items.compactMap(\.response).allSatisfy { $0.succeeded })

        let unknown = try request(id: "bad", backend: "unknown")
        let failFast = PortableSimulationBatchRequest(
            batchID: "fail-fast", failFast: true, requests: [unknown, first]
        )
        let stopped = await OhmLabSimulationHost.executeBatch(failFast)
        #expect(stopped.items[0].response?.error?.code == .unknownBackend)
        #expect(stopped.items[1].state == .skipped)
        #expect(stopped.items[1].response == nil)
    }

    @Test func executableExtractionQualificationPasses() async {
        let report = await PlatformExtractionQualification.evaluate()
        #expect(report.contractVersion == 1)
        #expect(report.cases.count == 9)
        #expect(report.cases.allSatisfy { $0.passed })
        #expect(report.ready)
        #expect(EngineBackends.descriptorMatrix.first { $0.identifier == "numeric-core" }?
            .implementationVersion == "swift-numeric-core-1.1.0+rust-numeric-core-0.34.0")
    }
}
