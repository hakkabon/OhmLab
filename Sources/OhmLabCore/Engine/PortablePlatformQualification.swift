import Foundation

/// Executable release evidence for portable-simulation protocol v1.
public enum PortablePlatformQualification {
    public static let currentContractVersion = 1
    public static let minimumCaseCount = 8

    public struct CaseResult: Codable, Equatable, Sendable {
        public let identifier: String
        public let passed: Bool
        public let detail: String
    }

    public struct Report: Codable, Equatable, Sendable {
        public let contractVersion: Int
        public let productVersion: String
        public let protocolVersion: Int
        public let requiredBackends: [String]
        public let cases: [CaseResult]
        public let issues: [String]
        public let ready: Bool
    }

    public static func evaluate() -> Report {
        var cases: [CaseResult] = []
        do {
            let divider = try CircuitIRCompiler.compile(netlist: """
            V1 in 0 DC 5 AC 1
            R1 in out 1k
            R2 out 0 1k
            .end
            """)
            let plan = PortableSimulationPlatform.AnalysisPlan(
                dcOperatingPoint: true,
                ac: .init(type: .lin, startFrequency: 1_000, stopFrequency: 1_001, points: 2)
            )
            for backend in ["native-mna", "numeric-core"] {
                let request = PortableSimulationPlatform.Request(
                    requestID: "qualification-\(backend)", backend: backend,
                    circuit: divider, analysis: plan
                )
                cases.append(roundTripCase(identifier: "\(backend)-round-trip", request: request) { response in
                    guard let voltage = response.result?.dc?.nodes.first(where: { $0.name == "out" })?.value,
                          abs(voltage - 2.5) <= 1e-9,
                          response.result?.ac?.frequencies.count == 2 else { return false }
                    return true
                })
            }

            let diode = try CircuitIRCompiler.compile(netlist: """
            V1 in 0 5
            R1 in out 1k
            D1 out 0 DM
            .model DM D(IS=1e-14 N=1)
            .end
            """)
            let nonlinear = PortableSimulationPlatform.Request(
                requestID: "qualification-nonlinear", backend: "numeric-core",
                circuit: diode, analysis: .init(dcOperatingPoint: true)
            )
            cases.append(roundTripCase(identifier: "numeric-core-nonlinear", request: nonlinear) { response in
                guard let voltage = response.result?.dc?.nodes.first(where: { $0.name == "out" })?.value else {
                    return false
                }
                return voltage > 0.6 && voltage < 0.8
            })

            let future = PortableSimulationPlatform.Request(
                protocolVersion: PortableSimulationPlatform.currentContractVersion + 1,
                requestID: "qualification-future", circuit: divider, analysis: plan
            )
            let futureResponse = PortableSimulationPlatform.execute(future)
            cases.append(.init(
                identifier: "future-protocol-fails-closed",
                passed: futureResponse.error?.code == .unsupportedProtocol,
                detail: futureResponse.error?.message ?? "future protocol unexpectedly succeeded"
            ))

            let unknown = PortableSimulationPlatform.Request(
                requestID: "qualification-unknown", backend: "not-a-backend",
                circuit: divider, analysis: plan
            )
            let unknownResponse = PortableSimulationPlatform.execute(unknown)
            cases.append(.init(
                identifier: "unknown-backend-fails-closed",
                passed: unknownResponse.error?.code == .unknownBackend,
                detail: unknownResponse.error?.message ?? "unknown backend unexpectedly succeeded"
            ))

            let malformed = PortableSimulationPlatform.execute(Data("not-json".utf8))
            cases.append(.init(
                identifier: "malformed-json-fails-closed",
                passed: malformed.error?.code == .invalidRequest && malformed.requestID.isEmpty,
                detail: malformed.error?.message ?? "malformed JSON unexpectedly succeeded"
            ))

            let amplified = PortableSimulationPlatform.Request(
                requestID: "qualification-amplified", circuit: divider,
                analysis: .init(
                    dcOperatingPoint: false,
                    transient: .init(step: 1e-12, stop: 1)
                )
            )
            let amplifiedResponse = PortableSimulationPlatform.execute(amplified)
            cases.append(.init(
                identifier: "amplified-workload-fails-closed",
                passed: amplifiedResponse.error?.code == .invalidRequest,
                detail: amplifiedResponse.error?.message ?? "amplified workload unexpectedly succeeded"
            ))

            let provenanceRequest = PortableSimulationPlatform.Request(
                requestID: "qualification-provenance", circuit: divider,
                analysis: .init(dcOperatingPoint: true)
            )
            let first = PortableSimulationPlatform.execute(provenanceRequest)
            let second = PortableSimulationPlatform.execute(provenanceRequest)
            let digest = first.provenance?.requestSHA256 ?? ""
            cases.append(.init(
                identifier: "deterministic-provenance",
                passed: first.succeeded && digest.count == 64 && digest == second.provenance?.requestSHA256
                    && first.provenance?.modelSource == "embedded-circuit-ir",
                detail: digest.isEmpty ? "successful response omitted provenance" : digest
            ))
        } catch {
            cases.append(.init(identifier: "corpus-construction", passed: false, detail: error.localizedDescription))
        }

        var issues: [String] = []
        if cases.count < minimumCaseCount { issues.append("portable qualification contains only \(cases.count) cases") }
        let failures = cases.filter { !$0.passed }.map(\.identifier)
        if !failures.isEmpty { issues.append("portable qualification failed: \(failures.joined(separator: ", "))") }
        let identifiers = PortableSimulationPlatform.manifest.backends.map(\.identifier)
        if identifiers != ["native-mna", "numeric-core"] {
            issues.append("portable manifest must expose native-mna and numeric-core")
        }
        return Report(
            contractVersion: currentContractVersion,
            productVersion: OhmLabRelease.version,
            protocolVersion: PortableSimulationPlatform.currentContractVersion,
            requiredBackends: ["native-mna", "numeric-core"],
            cases: cases,
            issues: issues.sorted(),
            ready: issues.isEmpty
        )
    }
}

private extension PortablePlatformQualification {
    static func roundTripCase(
        identifier: String,
        request: PortableSimulationPlatform.Request,
        validate: (PortableSimulationPlatform.Response) -> Bool
    ) -> CaseResult {
        do {
            let encoded = try PortableSimulationPlatform.encode(request)
            let decoded = try PortableSimulationPlatform.decodeRequest(encoded)
            guard decoded == request else {
                return .init(identifier: identifier, passed: false, detail: "request round trip changed payload")
            }
            let response = PortableSimulationPlatform.execute(decoded)
            let first = try PortableSimulationPlatform.encode(response)
            let second = try PortableSimulationPlatform.encode(response)
            let passed = response.succeeded && validate(response) && first == second
            return .init(
                identifier: identifier,
                passed: passed,
                detail: passed ? "deterministic request/response round trip" : (response.error?.message ?? "unexpected result")
            )
        } catch {
            return .init(identifier: identifier, passed: false, detail: error.localizedDescription)
        }
    }
}
