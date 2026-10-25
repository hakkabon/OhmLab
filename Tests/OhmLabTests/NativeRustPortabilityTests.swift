import Testing
@testable import OhmLabCore
import OhmLabSimulationProtocol

@Suite("OhmLab 2.3 NumericCore feature completion")
struct NativeRustPortabilityTests {
    @Test func frozenContractPublishesTheDirectRustScope() {
        #expect(NativeRustPortabilityContract.currentVersion == 2)
        #expect(NativeRustPortabilityContract.backendIdentifier == "rust-numeric-core")
        #expect(NativeRustPortabilityContract.implementationVersion ==
                "rust-numeric-core-0.34.0-native.2")
        #expect(NativeRustPortabilityContract.rustNumericCoreVersion == "0.34.0")
        #expect(NativeRustPortabilityContract.supportedAnalyses ==
                ["dc-operating-point", "ac-small-signal", "transient", "dc-sweep"])
        #expect(NumericCoreFeatureCompletionContract.currentVersion == 1)
    }

    @Test func numericCoreCompletesThePortableAnalysisPlan() throws {
        let circuit = try CircuitIRCompiler.compile(netlist: """
        V1 in 0 DC 0
        R1 in out 1k
        R2 out 0 1k
        .end
        """)
        let request = PortableSimulationPlatform.Request(
            requestID: "numeric-core-sweep",
            backend: "numeric-core",
            circuit: circuit,
            analysis: .init(
                dcOperatingPoint: false,
                dcSweep: .init(source: "V1", start: 0, stop: 5, step: 2.5)
            )
        )
        let response = PortableSimulationPlatform.execute(
            try PortableSimulationPlatform.encode(request)
        )
        let sweep = try #require(response.result?.sweep)
        #expect(sweep.axes.first?.values == [0, 2.5, 5])
        #expect(sweep.points.count == 3)
        #expect(abs((sweep.points.last?.nodes.first { $0.name == "out" }?.value ?? .nan) - 2.5) < 1e-12)
        #expect(NumericCoreEngineBackend().capabilities.supports(.dcSweep))
    }
}
