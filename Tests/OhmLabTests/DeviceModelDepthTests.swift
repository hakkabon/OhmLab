import Foundation
import Testing
@testable import OhmLabCore

@Suite("Device model depth and analysis depth")
struct DeviceModelDepthTests {
    // MARK: - Parsing

    @Test func diodeModelParsesReactiveParameters() throws {
        let parsed = try SpiceNetlistParser.parse("""
        V1 in 0 DC 1
        D1 in 0 DM
        .model DM D(IS=2e-14 N=1.1 CJO=3p VJ=0.7 M=0.4 TT=5n)
        .end
        """)
        let diode = try #require(parsed.circuit.elements.first { $0.kind == .diode }?.diode)
        #expect(abs(diode.junctionCapacitance - 3e-12) < 1e-24)
        #expect(abs(diode.junctionPotential - 0.7) < 1e-12)
        #expect(abs(diode.gradingCoefficient - 0.4) < 1e-12)
        #expect(abs(diode.transitTime - 5e-9) < 1e-21)
        #expect(parsed.warnings.isEmpty)
    }

    @Test func bjtModelParsesEarlyAndCapacitanceParameters() throws {
        let parsed = try SpiceNetlistParser.parse("""
        V1 c 0 DC 1
        Q1 c b 0 QM
        V2 b 0 DC 0.7
        .model QM NPN(IS=1e-15 BF=120 VAF=50 VAR=8 CJE=2p CJC=3p VJE=0.8 VJC=0.7 MJE=0.4 MJC=0.3 TF=1n TR=2n)
        .end
        """)
        let bjt = try #require(parsed.circuit.elements.first { $0.kind == .bjt }?.bjt)
        #expect(abs(bjt.forwardEarlyVoltage - 50) < 1e-12)
        #expect(abs(bjt.reverseEarlyVoltage - 8) < 1e-12)
        #expect(abs(bjt.baseEmitterCapacitance - 2e-12) < 1e-24)
        #expect(abs(bjt.baseCollectorCapacitance - 3e-12) < 1e-24)
        #expect(abs(bjt.baseEmitterPotential - 0.8) < 1e-12)
        #expect(abs(bjt.baseCollectorPotential - 0.7) < 1e-12)
        #expect(abs(bjt.baseEmitterGrading - 0.4) < 1e-12)
        #expect(abs(bjt.baseCollectorGrading - 0.3) < 1e-12)
        #expect(abs(bjt.forwardTransitTime - 1e-9) < 1e-21)
        #expect(abs(bjt.reverseTransitTime - 2e-9) < 1e-21)
    }

    @Test func mosfetAndJFETModelsParseCapacitances() throws {
        let mosfet = try SpiceNetlistParser.parse("""
        V1 d 0 DC 1
        M1 d g 0 0 MM
        V2 g 0 DC 2
        .model MM NMOS(VTO=1 KP=1m CGSO=2p CGDO=3p CGBO=1p CBD=4p CBS=5p)
        .end
        """)
        let mos = try #require(mosfet.circuit.elements.first { $0.kind == .mosfet }?.mosfet)
        #expect(abs(mos.gateSourceOverlapCapacitance - 2e-12) < 1e-24)
        #expect(abs(mos.gateDrainOverlapCapacitance - 3e-12) < 1e-24)
        #expect(abs(mos.gateBulkOverlapCapacitance - 1e-12) < 1e-24)
        #expect(abs(mos.bulkDrainCapacitance - 4e-12) < 1e-24)
        #expect(abs(mos.bulkSourceCapacitance - 5e-12) < 1e-24)

        let jfet = try SpiceNetlistParser.parse("""
        V1 d 0 DC 1
        J1 d g 0 JM
        V2 g 0 DC -1
        .model JM NJF(VTO=-2 BETA=1m CGS=2p CGD=3p)
        .end
        """)
        let jf = try #require(jfet.circuit.elements.first { $0.kind == .jfet }?.jfet)
        #expect(abs(jf.gateSourceCapacitance - 2e-12) < 1e-24)
        #expect(abs(jf.gateDrainCapacitance - 3e-12) < 1e-24)
    }

    // MARK: - AC response

    @Test func diodeJunctionCapacitanceChangesACResponse() throws {
        func magnitude(cjo: String) throws -> Double {
            let netlist = """
            V1 in 0 DC -1 AC 1
            R1 in out 1k
            D1 out 0 DM
            .model DM D(IS=1e-14 N=1 \(cjo))
            .end
            """
            let result = try NativeMNAEngine().solve(
                netlist: netlist,
                settings: Self.acSettings,
                libraries: []
            )
            return try Self.magnitude(at: 1e6, node: "out", in: #require(result.ac))
        }

        let withoutCapacitance = try magnitude(cjo: "")
        let withCapacitance = try magnitude(cjo: "CJO=1n VJ=0.7 M=0.5")
        #expect(withoutCapacitance > 0.9)
        #expect(withCapacitance < 0.5)
        #expect(withCapacitance < withoutCapacitance)
    }

    @Test func bjtCollectorCapacitanceRollsOffACGain() throws {
        func gain(cjc: String) throws -> Double {
            let netlist = """
            Vcc vcc 0 DC 5 AC 0
            Vin in 0 DC 0.65 AC 1
            Rc vcc c 2k
            Q1 c in 0 QM
            .model QM NPN(IS=1e-15 BF=100 \(cjc))
            .end
            """
            let result = try NativeMNAEngine().solve(
                netlist: netlist,
                settings: Self.acSettings,
                libraries: []
            )
            return try Self.magnitude(at: 1e6, node: "c", in: #require(result.ac))
        }

        let withoutCapacitance = try gain(cjc: "")
        let withCapacitance = try gain(cjc: "CJC=20p VJC=0.7 MJC=0.33")
        #expect(withCapacitance < withoutCapacitance)
        #expect(withoutCapacitance - withCapacitance > 1e-3)
    }

    @Test func mosfetAndJFETGateCapacitancesLoadTheACResponse() throws {
        let mosfetWithout = try Self.magnitude(
            at: 1e6,
            node: "d",
            in: #require(NativeMNAEngine().solve(netlist: """
            Vdd vdd 0 DC 5 AC 0
            Vin g 0 DC 2 AC 1
            Rd vdd d 2k
            M1 d g 0 0 MM
            .model MM NMOS(VTO=1 KP=1m)
            .end
            """, settings: Self.acSettings, libraries: []).ac)
        )
        let mosfetWith = try Self.magnitude(
            at: 1e6,
            node: "d",
            in: #require(NativeMNAEngine().solve(netlist: """
            Vdd vdd 0 DC 5 AC 0
            Vin g 0 DC 2 AC 1
            Rd vdd d 2k
            M1 d g 0 0 MM
            .model MM NMOS(VTO=1 KP=1m CGDO=20p CGSO=20p)
            .end
            """, settings: Self.acSettings, libraries: []).ac)
        )
        #expect(mosfetWithout != mosfetWith)

        let jfetWithout = try Self.magnitude(
            at: 1e6,
            node: "d",
            in: #require(NativeMNAEngine().solve(netlist: """
            Vdd vdd 0 DC 5 AC 0
            Vin g 0 DC 0 AC 1
            Rd vdd d 2k
            J1 d g 0 JM
            .model JM NJF(VTO=-2 BETA=1m)
            .end
            """, settings: Self.acSettings, libraries: []).ac)
        )
        let jfetWith = try Self.magnitude(
            at: 1e6,
            node: "d",
            in: #require(NativeMNAEngine().solve(netlist: """
            Vdd vdd 0 DC 5 AC 0
            Vin g 0 DC 0 AC 1
            Rd vdd d 2k
            J1 d g 0 JM
            .model JM NJF(VTO=-2 BETA=1m CGS=20p CGD=20p)
            .end
            """, settings: Self.acSettings, libraries: []).ac)
        )
        #expect(jfetWithout != jfetWith)
    }

    // MARK: - DC Early effect

    @Test func bjtEarlyVoltageRaisesCollectorCurrentAtHigherVce() throws {
        func collectorCurrent(vce: Double, vaf: String) throws -> Double {
            let netlist = """
            Vb b 0 DC 0.7
            Vc c 0 DC \(vce)
            Q1 c b 0 QM
            .model QM NPN(IS=1e-15 BF=100 \(vaf))
            .end
            """
            let result = try NativeMNAEngine().solve(
                netlist: netlist,
                settings: Self.dcOnlySettings,
                libraries: []
            )
            let dc = try #require(result.dc)
            let component = try #require(dc.components.first { $0.name == "Q1" })
            return abs(component.current)
        }

        let withoutEarly = try collectorCurrent(vce: 10, vaf: "")
        let lowVce = try collectorCurrent(vce: 2, vaf: "VAF=50")
        let highVce = try collectorCurrent(vce: 10, vaf: "VAF=50")
        #expect(abs(lowVce - withoutEarly) > 1e-9)
        #expect(highVce > lowVce)
        // Early factor ratio: (1 + 9.3/50) / (1 + 1.3/50) ≈ 1.156.
        #expect(highVce / lowVce > 1.10)
        #expect(highVce / lowVce < 1.22)
    }

    // MARK: - Transient response

    @Test func diodeJunctionCapacitanceSlowsTheTransientFall() throws {
        func finalVoltage(cjo: String) throws -> Double {
            let netlist = """
            V1 in 0 PULSE(5 0 1u 10n 10n 10u 20u)
            R1 in out 1k
            D1 out 0 DM
            .model DM D(IS=1e-14 N=1 \(cjo))
            .end
            """
            let parsed = try SpiceNetlistParser.parse(netlist)
            let solver = TransientSolver(circuit: parsed.circuit, timestep: 20e-9)
            let result = try solver.run(startTime: 0, stopTime: 2e-6, maxSteps: 200_000)
            let index = try #require(result.times.firstIndex { $0 >= 1.2e-6 })
            let out = try #require(parsed.circuit.nodeNames.firstIndex(of: "out"))
            return result.nodeSeries[out][index]
        }

        let withoutCapacitance = try finalVoltage(cjo: "")
        let withCapacitance = try finalVoltage(cjo: "CJO=1n VJ=0.7 M=0.5")
        #expect(withCapacitance > withoutCapacitance + 0.05)
    }

    // MARK: - Nodeset and IR round-trip

    @Test func nodesetSurvivesCircuitIRRoundTrip() throws {
        let parsed = try SpiceNetlistParser.parse("""
        V1 in 0 DC 5
        R1 in out 1k
        D1 out 0 DM
        .model DM D(IS=1e-14 N=1)
        .nodeset v(out)=0.6
        .end
        """)
        let data = try JSONEncoder().encode(
            CircuitIR(linearCircuit: parsed.circuit, initialConditions: parsed.initialConditions)
        )
        let decoded = try JSONDecoder().decode(CircuitIR.self, from: data)
        let rebuilt = try decoded.makeLinearCircuit()
        #expect(rebuilt.nodeSet["out"] == 0.6)
        #expect(parsed.warnings.isEmpty)
    }

    @Test func circuitIRRoundTripPreservesReactiveModelParameters() throws {
        let parsed = try SpiceNetlistParser.parse("""
        V1 in 0 DC 1
        R1 in out 1k
        D1 out 0 DM
        Q1 c b 0 QM
        V2 c 0 DC 2
        V3 b 0 DC 0.7
        M1 d g 0 0 MM
        V4 d 0 DC 2
        V5 g 0 DC 2
        J1 jd jg 0 JM
        V6 jd 0 DC 2
        V7 jg 0 DC -1
        .model DM D(IS=1e-14 CJO=2p VJ=0.7 M=0.4 TT=3n)
        .model QM NPN(VAF=50 VAR=8 CJE=2p CJC=3p TF=1n TR=2n)
        .model MM NMOS(VTO=1 KP=1m CGSO=1p CGDO=2p CGBO=3p CBD=4p CBS=5p)
        .model JM NJF(VTO=-2 BETA=1m CGS=6p CGD=7p)
        .end
        """)
        let encoded = try JSONEncoder().encode(
            CircuitIR(linearCircuit: parsed.circuit, initialConditions: parsed.initialConditions)
        )
        let rebuilt = try JSONDecoder().decode(CircuitIR.self, from: encoded).makeLinearCircuit()

        let diode = try #require(rebuilt.elements.first { $0.kind == .diode }?.diode)
        #expect(diode.junctionCapacitance == 2e-12)
        #expect(diode.junctionPotential == 0.7)
        #expect(diode.gradingCoefficient == 0.4)
        #expect(abs(diode.transitTime - 3e-9) < 1e-21)

        let bjt = try #require(rebuilt.elements.first { $0.kind == .bjt }?.bjt)
        #expect(bjt.forwardEarlyVoltage == 50)
        #expect(bjt.reverseEarlyVoltage == 8)
        #expect(bjt.baseEmitterCapacitance == 2e-12)
        #expect(bjt.baseCollectorCapacitance == 3e-12)
        #expect(bjt.forwardTransitTime == 1e-9)
        #expect(bjt.reverseTransitTime == 2e-9)

        let mosfet = try #require(rebuilt.elements.first { $0.kind == .mosfet }?.mosfet)
        #expect(mosfet.gateSourceOverlapCapacitance == 1e-12)
        #expect(mosfet.gateDrainOverlapCapacitance == 2e-12)
        #expect(mosfet.gateBulkOverlapCapacitance == 3e-12)
        #expect(mosfet.bulkDrainCapacitance == 4e-12)
        #expect(mosfet.bulkSourceCapacitance == 5e-12)

        let jfet = try #require(rebuilt.elements.first { $0.kind == .jfet }?.jfet)
        #expect(jfet.gateSourceCapacitance == 6e-12)
        #expect(jfet.gateDrainCapacitance == 7e-12)
    }

    @Test func circuitIRRejectsInvalidReactiveParameters() throws {
        let parsed = try SpiceNetlistParser.parse("""
        V1 in 0 DC 1
        R1 in out 1k
        D1 out 0 DM
        .model DM D(IS=1e-14 N=1)
        .end
        """)
        let ir = try CircuitIR(linearCircuit: parsed.circuit)

        var negativeCapacitance = ir
        negativeCapacitance.devices[2].diode?.junctionCapacitance = -1
        #expect(throws: CircuitIRError.self) {
            try negativeCapacitance.makeLinearCircuit()
        }

        var zeroPotential = ir
        zeroPotential.devices[2].diode?.junctionPotential = 0
        #expect(throws: CircuitIRError.self) {
            try zeroPotential.makeLinearCircuit()
        }

        var nonFiniteNodeSet = ir
        nonFiniteNodeSet.nodeSet = ["out": .nan]
        #expect(throws: CircuitIRError.self) {
            try nonFiniteNodeSet.makeLinearCircuit()
        }
    }

    @Test func devicesWithoutReactiveParametersKeepTheCircuitIRShapeStable() throws {
        let parsed = try SpiceNetlistParser.parse("""
        V1 in 0 DC 1
        R1 in out 1k
        D1 out 0 DM
        .model DM D(IS=1e-14 N=1)
        .end
        """)
        let encoded = try JSONEncoder().encode(CircuitIR(linearCircuit: parsed.circuit))
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(!text.contains("junctionCapacitance"))
        #expect(!text.contains("nodeSet"))
        #expect(!text.contains("forwardEarlyVoltage"))
    }

    @Test func repeatedCapacitiveSolvesAreDeterministic() throws {
        let netlist = """
        V1 in 0 DC -1 AC 1
        R1 in out 1k
        D1 out 0 DM
        .model DM D(IS=1e-14 N=1 CJO=1n VJ=0.7 M=0.5 TT=2n)
        .end
        """
        let first = try NativeMNAEngine().solve(netlist: netlist, settings: Self.acSettings, libraries: [])
        let second = try NativeMNAEngine().solve(netlist: netlist, settings: Self.acSettings, libraries: [])
        let lhs = try #require(first.ac)
        let rhs = try #require(second.ac)
        #expect(lhs.frequencies == rhs.frequencies)
        for (left, right) in zip(lhs.nodes, rhs.nodes) {
            #expect(left.name == right.name)
            #expect(left.response.map(\.magnitudeDb) == right.response.map(\.magnitudeDb))
            #expect(left.response.map(\.phaseDeg) == right.response.map(\.phaseDeg))
        }
    }

    // MARK: - Helpers

    private static var dcOnlySettings: AnalysisSettings {
        AnalysisSettings(
            runDC: true,
            runAC: false,
            runTransient: false,
            acStartFrequency: 1,
            acStopFrequency: 1_000,
            acPointsPerDecade: 1
        )
    }

    private static var acSettings: AnalysisSettings {
        AnalysisSettings(
            runDC: true,
            runAC: true,
            runTransient: false,
            acStartFrequency: 1_000,
            acStopFrequency: 1_000_000,
            acPointsPerDecade: 1
        )
    }

    private static func magnitude(
        at frequency: Double,
        node: String,
        in result: CircuitSimResult.ACResult
    ) throws -> Double {
        let response = try #require(result.nodes.first { $0.name == node })
        let point = try #require(response.response.min { abs($0.freqHz - frequency) < abs($1.freqHz - frequency) })
        return pow(10, point.magnitudeDb / 20)
    }
}
