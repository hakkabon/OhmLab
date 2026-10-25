import Foundation
import Testing
@testable import OhmLabCore

@Suite("OhmLab 2.0 portable simulation platform")
struct PortableSimulationPlatformTests {
    private func divider() throws -> CircuitIR {
        try CircuitIRCompiler.compile(netlist: """
        V1 in 0 DC 5 AC 1
        R1 in out 1k
        R2 out 0 1k
        .end
        """)
    }

    @Test func manifestPublishesStableBoundaryAndQualifiedBackends() {
        let manifest = PortableSimulationPlatform.manifest
        #expect(manifest.productVersion == "2.0.0")
        #expect(manifest.protocolVersion == 1)
        #expect(manifest.circuitIRVersion == 1)
        #expect(manifest.simulationResultVersion == 1)
        #expect(manifest.mediaType.contains("version=1"))
        #expect(manifest.backends.map(\.identifier) == ["native-mna", "numeric-core"])
        #expect(manifest.limits.maximumRequestBytes == 16 * 1_024 * 1_024)
    }

    @Test func requestRoundTripsAndProducesDeterministicJSON() throws {
        let request = PortableSimulationPlatform.Request(
            requestID: "portable-divider",
            backend: "numeric-core",
            circuit: try divider(),
            analysis: .init(
                dcOperatingPoint: true,
                ac: .init(type: .lin, startFrequency: 1_000, stopFrequency: 1_001, points: 2)
            )
        )
        let data = try PortableSimulationPlatform.encode(request)
        #expect(try PortableSimulationPlatform.decodeRequest(data) == request)
        let response = PortableSimulationPlatform.execute(data)
        #expect(response.succeeded)
        #expect(response.requestID == request.requestID)
        #expect(response.backend == "numeric-core")
        #expect(response.result?.dc?.nodes.first { $0.name == "out" }?.value == 2.5)
        #expect(response.result?.ac?.frequencies.count == 2)
        #expect(try PortableSimulationPlatform.encode(response) == PortableSimulationPlatform.encode(response))
    }

    @Test func executionDoesNotMutateTheApplicationBackend() throws {
        SimulationEngine.resetToDefaultBackend()
        let request = PortableSimulationPlatform.Request(
            requestID: "isolated", backend: "numeric-core", circuit: try divider(),
            analysis: .init(dcOperatingPoint: true)
        )
        #expect(PortableSimulationPlatform.execute(request).succeeded)
        #expect(SimulationEngine.backendIdentifier == "native-mna")
    }

    @Test func protocolAndCapabilitiesFailClosed() throws {
        let circuit = try divider()
        let future = PortableSimulationPlatform.Request(
            protocolVersion: 2, requestID: "future", circuit: circuit,
            analysis: .init(dcOperatingPoint: true)
        )
        #expect(PortableSimulationPlatform.execute(future).error?.code == .unsupportedProtocol)

        let unknown = PortableSimulationPlatform.Request(
            requestID: "unknown", backend: "missing", circuit: circuit,
            analysis: .init(dcOperatingPoint: true)
        )
        #expect(PortableSimulationPlatform.execute(unknown).error?.code == .unknownBackend)

        let sweep = PortableSimulationPlatform.Request(
            requestID: "unsupported", backend: "numeric-core", circuit: circuit,
            analysis: .init(dcOperatingPoint: false, dcSweep: .init(source: "V1", start: 0, stop: 5, step: 1))
        )
        #expect(PortableSimulationPlatform.execute(sweep).error?.code == .unsupportedCapability)

        let malformed = PortableSimulationPlatform.execute(Data("not-json".utf8))
        #expect(malformed.error?.code == .invalidRequest)
        #expect(malformed.requestID.isEmpty)

        let oversized = PortableSimulationPlatform.execute(Data(
            repeating: 0,
            count: PortableSimulationPlatform.limits.maximumRequestBytes + 1
        ))
        #expect(oversized.error?.code == .invalidRequest)

        let wrongDirection = PortableSimulationPlatform.Request(
            requestID: "wrong-direction", circuit: circuit,
            analysis: .init(dcOperatingPoint: false, dcSweep: .init(source: "V1", start: 0, stop: 5, step: -1))
        )
        #expect(PortableSimulationPlatform.execute(wrongDirection).error?.code == .invalidRequest)
    }

    @Test func executableQualificationPasses() {
        let report = PortablePlatformQualification.evaluate()
        #expect(report.contractVersion == 1)
        #expect(report.productVersion == "2.0.0")
        #expect(report.cases.count == 5)
        #expect(report.cases.allSatisfy { $0.passed })
        #expect(report.issues.isEmpty)
        #expect(report.ready)
    }
}
