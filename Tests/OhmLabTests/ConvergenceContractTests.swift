import Foundation
import Testing
@testable import OhmLabCore

@Suite("OhmLab 0.8 convergence contract")
struct ConvergenceContractTests {
    private static let fixtureDirectory = Bundle.module.resourceURL!
        .appendingPathComponent("Fixtures/Convergence", isDirectory: true)

    struct Corpus: Decodable {
        var contractVersion: Int
        var fixtures: [Fixture]
    }

    struct Fixture: Decodable, Sendable {
        struct ACSweep: Decodable, Sendable {
            var type: FrequencySweepType
            var start: Double
            var stop: Double
            var count: Int
        }
        var id: String
        var file: String
        var analyses: [String]
        var acSweep: ACSweep?
        var absoluteTolerance: Double

        var settings: AnalysisSettings {
            var result = AnalysisSettings.default
            result.runDC = analyses.contains("dc")
            result.runAC = analyses.contains("ac")
            result.runTransient = false
            result.runDCSweep = false
            if let acSweep {
                result.acSweepType = acSweep.type
                result.acStartFrequency = acSweep.start
                result.acStopFrequency = acSweep.stop
                result.acPointsPerDecade = acSweep.count
            }
            return result
        }
    }

    static let corpus: Corpus = {
        let url = fixtureDirectory.appendingPathComponent("corpus.json")
        return try! JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }()

    static let fixtures = corpus.fixtures

    @Test func capabilityMatrixIsExplicitAndNativeRemainsDefault() throws {
        SimulationEngine.resetToDefaultBackend()
        #expect(SimulationEngine.backendIdentifier == "native-mna")
        #expect(SimulationEngine.backendCapabilities.supports(.circuitIRInput))

        let matrix = EngineBackends.capabilityMatrix
        let native = try #require(matrix.first { $0.backendIdentifier == "native-mna" })
        let numeric = try #require(matrix.first { $0.backendIdentifier == "numeric-core" })
        #expect(native.analyses == SimulationAnalysisKind.allCases.sorted())
        #expect(native.devices == CircuitIR.DeviceKind.allCases.sorted())
        #expect(numeric.analyses == [.acSmallSignal, .dcOperatingPoint, .dcSweep, .transient])
        #expect(numeric.devices == [.capacitor, .currentSource, .diode, .inductor, .mosfet, .resistor, .voltageSource])
        #expect(numeric.supports(.transient))
        #expect(numeric.supports(.circuitIRInput))
        #expect(numeric.supports(.initialConditions))
        #expect(!numeric.supports(.temperature))

    }

    @Test("Circuit IR round-trips and both engines agree", arguments: fixtures)
    func differentialFixture(fixture: Fixture) throws {
        #expect(Self.corpus.contractVersion == CircuitIR.currentSchemaVersion)
        let netlist = try String(
            contentsOf: Self.fixtureDirectory.appendingPathComponent(fixture.file),
            encoding: .utf8
        )
        let ir = try CircuitIRCompiler.compile(netlist: netlist)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(ir)
        let decoded = try JSONDecoder().decode(CircuitIR.self, from: encoded)
        #expect(decoded == ir, "\(fixture.id): Circuit IR JSON round-trip changed the model")

        let native = try NativeMNAEngine().solve(circuit: decoded, settings: fixture.settings)
        let numeric = try NumericCoreEngineBackend().solve(circuit: decoded, settings: fixture.settings)
        try compare(native, numeric, tolerance: fixture.absoluteTolerance, fixture: fixture.id)
    }


    @Test func circuitIRDecoderRejectsUnknownSchema() throws {
        let source = "V1 in 0 1\nR1 in 0 1k\n.end"
        let ir = try CircuitIRCompiler.compile(netlist: source)
        let data = try JSONEncoder().encode(ir)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = CircuitIR.currentSchemaVersion + 1
        let future = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: CircuitIRError.self) {
            _ = try JSONDecoder().decode(CircuitIR.self, from: future)
        }
    }

    @Test func circuitIRPreservesNonlinearModelsAndWaveforms() throws {
        let netlist = """
        V1 in 0 DC 0 PULSE(0 5 0 1u 1u 1m 2m)
        R1 in out 1k
        D1 out 0 DMOD
        .model DMOD D(IS=2e-14 N=1.2)
        .end
        """
        let ir = try CircuitIRCompiler.compile(netlist: netlist)
        #expect(ir.devices.first { $0.name == "V1" }?.source?.transient?.kind == .pulse)
        #expect(ir.devices.first { $0.name == "D1" }?.diode?.emissionCoefficient == 1.2)

        let decoded = try JSONDecoder().decode(CircuitIR.self, from: JSONEncoder().encode(ir))
        var settings = AnalysisSettings.default
        settings.runDC = false
        settings.runAC = false
        settings.runTransient = true
        settings.tranStep = 50e-6
        settings.tranStop = 2e-3

        let fromIR = try NativeMNAEngine().solve(circuit: decoded, settings: settings)
        let fromNetlist = try NativeMNAEngine().solve(netlist: netlist, settings: settings, libraries: [])
        let lhs = try #require(fromIR.transient?.nodes.first { $0.name == "out" }?.values)
        let rhs = try #require(fromNetlist.transient?.nodes.first { $0.name == "out" }?.values)
        #expect(lhs.count == rhs.count)
        for (a, b) in zip(lhs, rhs) { #expect(abs(a - b) < 1e-12) }
    }

    @Test func resultContractRejectsMalformedBackendOutput() {
        let malformed = CircuitSimResult(
            dc: .init(
                nodes: [("out", .nan)], components: [], sources: [], converged: true
            ),
            ac: nil, transient: nil, sweep: nil, fourier: [], warnings: []
        )
        #expect(throws: SimulationContractError.self) {
            try SimulationResultContract.validate(malformed)
        }
    }

    @Test func linearTransientParityAndInitialConditions() throws {
        let netlist = """
        V1 in 0 PULSE(0 1 100u 0 0 10m 20m)
        R1 in out 1k
        C1 out 0 1u
        .ic V(out)=0.25
        .tran 100u 2m
        .end
        """
        let ir = try CircuitIRCompiler.compile(netlist: netlist)
        var settings = AnalysisSettings.default
        settings.runDC = false
        settings.runAC = false
        settings.runTransient = true
        settings.tranStep = 100e-6
        settings.tranStop = 2e-3

        let native = try NativeMNAEngine().solve(circuit: ir, settings: settings)
        let numeric = try NumericCoreEngineBackend().solve(circuit: ir, settings: settings)
        let nativeTransient = try #require(native.transient)
        let numericTransient = try #require(numeric.transient)
        #expect(nativeTransient.times == numericTransient.times)
        let nativeOutput = try #require(nativeTransient.nodes.first { $0.name == "out" }?.values)
        let numericOutput = try #require(numericTransient.nodes.first { $0.name == "out" }?.values)
        #expect(abs(nativeOutput[0] - 0.25) < 1e-12)
        #expect(abs(numericOutput[0] - 0.25) < 1e-12)
        #expect(nativeOutput.count == numericOutput.count)
        for (lhs, rhs) in zip(nativeOutput, numericOutput) {
            // NumericCore uses adaptive DAE integration while the native
            // reference intentionally uses a fixed backward-Euler grid.
            #expect(abs(lhs - rhs) < 1e-1)
        }

    }

    private func compare(
        _ lhs: CircuitSimResult,
        _ rhs: CircuitSimResult,
        tolerance: Double,
        fixture: String
    ) throws {
        try SimulationResultContract.validate(lhs)
        try SimulationResultContract.validate(rhs)
        #expect(lhs.contractVersion == rhs.contractVersion)

        if let left = lhs.dc {
            let right = try #require(rhs.dc, "\(fixture): NumericCore returned no DC result")
            #expect(left.nodes.map(\.name) == right.nodes.map(\.name))
            #expect(left.components.map(\.name) == right.components.map(\.name))
            for (a, b) in zip(left.nodes, right.nodes) {
                #expect(abs(a.voltage - b.voltage) <= tolerance, "\(fixture): DC node \(a.name)")
            }
            for (a, b) in zip(left.components, right.components) {
                #expect(abs(a.voltage - b.voltage) <= tolerance, "\(fixture): DC voltage \(a.name)")
                #expect(abs(a.current - b.current) <= tolerance, "\(fixture): DC current \(a.name)")
            }
        } else {
            #expect(rhs.dc == nil)
        }

        if let left = lhs.ac {
            let right = try #require(rhs.ac, "\(fixture): NumericCore returned no AC result")
            #expect(left.frequencies == right.frequencies)
            #expect(left.nodes.map(\.name) == right.nodes.map(\.name))
            #expect(left.components.map(\.name) == right.components.map(\.name))
            for (a, b) in zip(left.nodes, right.nodes) {
                for (x, y) in zip(a.response, b.response) {
                    #expect(abs(x.magnitudeDb - y.magnitudeDb) <= tolerance, "\(fixture): AC magnitude \(a.name)")
                    #expect(abs(x.phaseDeg - y.phaseDeg) <= tolerance, "\(fixture): AC phase \(a.name)")
                }
            }
            for (a, b) in zip(left.components, right.components) {
                for (x, y) in zip(a.response, b.response) {
                    #expect(abs(x.magnitudeDb - y.magnitudeDb) <= tolerance, "\(fixture): AC current magnitude \(a.name)")
                    #expect(abs(x.phaseDeg - y.phaseDeg) <= tolerance, "\(fixture): AC current phase \(a.name)")
                }
            }
        } else {
            #expect(rhs.ac == nil)
        }
    }
}
