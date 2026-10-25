import Foundation
import Testing
@testable import OhmLabCore
import OhmLabSimulationProtocol

@Suite("OhmLab 2.0 portable simulation platform")
struct PortableSimulationPlatformTests {
    private struct MalformedEntry: Decodable {
        let identifier: String
        let payload: String
    }

    private func fixture(_ path: String, extension fileExtension: String) throws -> Data {
        let components = path.split(separator: "/").map(String.init)
        let name = components.last!
        let subdirectory = components.dropLast().joined(separator: "/")
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: fileExtension,
            subdirectory: "Fixtures/\(subdirectory)"
        ))
        return try Data(contentsOf: url)
    }

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
        #expect(manifest.productVersion == "2.3.0")
        #expect(manifest.protocolVersion == 1)
        #expect(manifest.circuitIRVersion == 1)
        #expect(manifest.simulationResultVersion == 1)
        #expect(manifest.mediaType.contains("version=1"))
        #expect(manifest.requestSchemaID == PortableSimulationPlatform.requestSchemaID)
        #expect(manifest.responseSchemaID == PortableSimulationPlatform.responseSchemaID)
        #expect(manifest.batchSchemaID == SimulationHostContract.batchSchemaID)
        #expect(manifest.batchResponseSchemaID == SimulationHostContract.batchResponseSchemaID)
        #expect(manifest.hostContractVersion == 1)
        #expect(manifest.canonicalEncoding == "json-sorted-keys-utf8")
        #expect(manifest.provenanceDigest == "sha-256")
        #expect(manifest.backends.map(\.identifier) == ["native-mna", "numeric-core"])
        #expect(manifest.limits.maximumRequestBytes == 16 * 1_024 * 1_024)
        #expect(manifest.limits.maximumAnalysisSamples == 100_000)
        #expect(manifest.limits.maximumWaveformPoints == 100_000)
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
        #expect(response.provenance?.productVersion == "2.3.0")
        #expect(response.provenance?.modelSource == "embedded-circuit-ir")
        #expect(response.provenance?.requestSHA256.count == 64)
        #expect(try PortableSimulationPlatform.encode(response) == PortableSimulationPlatform.encode(response))
    }

    @Test func canonicalRequestFixtureIsByteStable() throws {
        let fixtureData = try fixture("Portable/request-native-divider", extension: "json")
        let fixtureWithoutNewline = Data(fixtureData.dropLast(fixtureData.last == 0x0a ? 1 : 0))
        let request = try PortableSimulationPlatform.decodeRequest(fixtureWithoutNewline)
        #expect(request.circuit == (try divider()))
        #expect(try PortableSimulationPlatform.encode(request) == fixtureWithoutNewline)

        var object = try #require(JSONSerialization.jsonObject(with: fixtureData) as? [String: Any])
        var circuit = try #require(object["circuit"] as? [String: Any])
        var solver = try #require(circuit["solver"] as? [String: Any])
        solver["maximumInterations"] = 100
        circuit["solver"] = solver
        object["circuit"] = circuit
        let misspelled = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            try PortableSimulationPlatform.decodeRequest(misspelled)
        }
    }

    @Test func canonicalResponseFixtureIsByteStable() throws {
        let requestData = try fixture("Portable/request-native-divider", extension: "json")
        let responseData = try fixture("Portable/response-native-divider", extension: "json")
        let request = try PortableSimulationPlatform.decodeRequest(requestData)
        let actual = try PortableSimulationPlatform.encode(PortableSimulationPlatform.execute(request))
        let expected = Data(responseData.dropLast(responseData.last == 0x0a ? 1 : 0))
        #expect(actual == expected)
    }

    @Test func malformedCorpusAlwaysReturnsTheStableFailureEnvelope() throws {
        let entries = try JSONDecoder().decode(
            [MalformedEntry].self,
            from: fixture("Portable/malformed-corpus", extension: "json")
        )
        #expect(entries.count >= 8)
        for entry in entries {
            let response = PortableSimulationPlatform.execute(Data(entry.payload.utf8))
            #expect(response.status == .failure, "\(entry.identifier) succeeded")
            #expect(response.error?.code == .invalidRequest, "\(entry.identifier) had the wrong error")
            #expect(response.requestID.isEmpty)
            #expect(response.result == nil)
            #expect(response.provenance == nil)
        }
    }

    @Test func deterministicDecoderMutationFuzzingAlwaysReturnsAnEnvelope() throws {
        let original = Array(try fixture("Portable/request-native-divider", extension: "json"))
        var state: UInt64 = 0x4f686d4c61623230
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
        for _ in 0..<256 {
            var mutation = original
            let editCount = Int(next() % 4) + 1
            for _ in 0..<editCount {
                let index = Int(next() % UInt64(mutation.count))
                mutation[index] = UInt8(truncatingIfNeeded: next())
            }
            let response = PortableSimulationPlatform.execute(Data(mutation))
            #expect((response.status == .success) != (response.status == .failure))
            #expect(response.succeeded || (response.result == nil && response.error != nil))
            #expect((try? PortableSimulationPlatform.encode(response)) != nil)
        }
    }

    @Test func amplifiedWorkloadsAreRejectedBeforeExecution() throws {
        let circuit = try divider()
        let tooManyACPoints = PortableSimulationPlatform.Request(
            requestID: "too-many-ac", circuit: circuit,
            analysis: .init(
                dcOperatingPoint: false,
                ac: .init(type: .lin, startFrequency: 1, stopFrequency: 2,
                          points: PortableSimulationPlatform.limits.maximumAnalysisSamples + 1)
            )
        )
        #expect(PortableSimulationPlatform.execute(tooManyACPoints).error?.code == .invalidRequest)

        let tinyTransientStep = PortableSimulationPlatform.Request(
            requestID: "tiny-step", circuit: circuit,
            analysis: .init(dcOperatingPoint: false, transient: .init(step: 1e-12, stop: 1))
        )
        #expect(PortableSimulationPlatform.execute(tinyTransientStep).error?.code == .invalidRequest)

        var excessiveIterations = circuit
        excessiveIterations.solver.maximumIterations = PortableSimulationPlatform.limits.maximumSolverIterations + 1
        let excessiveSolver = PortableSimulationPlatform.Request(
            requestID: "too-many-iterations", circuit: excessiveIterations,
            analysis: .init(dcOperatingPoint: true)
        )
        #expect(PortableSimulationPlatform.execute(excessiveSolver).error?.code == .invalidRequest)
    }

    @Test func provenanceDigestUsesCanonicalSHA256() throws {
        #expect(StableSHA256.hexDigest(Data("abc".utf8)) ==
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let request = PortableSimulationPlatform.Request(
            requestID: "digest", circuit: try divider(), analysis: .init(dcOperatingPoint: true)
        )
        let expected = StableSHA256.hexDigest(try PortableSimulationPlatform.encode(request))
        #expect(PortableSimulationPlatform.execute(request).provenance?.requestSHA256 == expected)
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
            requestID: "numeric-core-sweep", backend: "numeric-core", circuit: circuit,
            analysis: .init(dcOperatingPoint: false, dcSweep: .init(source: "V1", start: 0, stop: 5, step: 1))
        )
        let sweepResponse = PortableSimulationPlatform.execute(sweep)
        #expect(sweepResponse.succeeded)
        #expect(sweepResponse.result?.sweep?.points.count == 6)

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
        #expect(report.productVersion == "2.3.0")
        #expect(report.cases.count == 8)
        #expect(report.cases.allSatisfy { $0.passed })
        #expect(report.issues.isEmpty)
        #expect(report.ready)
    }
}
