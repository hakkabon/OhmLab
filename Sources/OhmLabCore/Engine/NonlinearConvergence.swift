import Foundation

/// Executable differential contract for the nonlinear surface introduced over
/// OhmLab 1.3–1.5. Native MNA is the reference; NumericCore must independently
/// agree for every qualified diode and body-tied Level-1 NMOS case.
public enum NonlinearConvergence {
    public static let currentContractVersion = 1
    public static let minimumCaseCount = 7

    public struct Measurement: Codable, Equatable, Sendable {
        public let name: String
        public let expected: Double
        public let actual: Double?
        public let absoluteError: Double?
        public let tolerance: Double
        public let passed: Bool
    }

    public struct CaseResult: Codable, Equatable, Sendable {
        public let identifier: String
        public let category: String
        public let measurements: [Measurement]
        public let error: String?
        public let passed: Bool
    }

    public struct Report: Codable, Equatable, Sendable {
        public let contractVersion: Int
        public let productVersion: String
        public let referenceBackend: String
        public let backend: String
        public let implementationVersion: String?
        public let scope: NonlinearBackendScope?
        public let cases: [CaseResult]
        public let issues: [String]
        public let ready: Bool
    }

    public static func evaluate() -> Report {
        let reference = NativeMNAEngine()
        let backend = NumericCoreEngineBackend()
        let descriptor = ProductionBoundary.descriptor(for: backend)
        let definitions: [CaseDefinition]
        do {
            definitions = try makeCases()
        } catch {
            return Report(
                contractVersion: currentContractVersion,
                productVersion: OhmLabRelease.version,
                referenceBackend: reference.identifier,
                backend: backend.identifier,
                implementationVersion: backend.implementationVersion,
                scope: backend.nonlinearScope,
                cases: [],
                issues: ["could not construct nonlinear corpus: \(error.localizedDescription)"],
                ready: false
            )
        }

        let results = definitions.map { definition -> CaseResult in
            do {
                let expected = try reference.solve(
                    circuit: definition.circuit,
                    settings: definition.settings
                )
                let actual = try backend.solve(
                    circuit: definition.circuit,
                    settings: definition.settings
                )
                try SimulationResultContract.validate(expected)
                try SimulationResultContract.validate(actual)
                let measurements = try definition.metrics.map { metric in
                    try measurement(metric, expected: expected, actual: actual)
                }
                return CaseResult(
                    identifier: definition.identifier,
                    category: definition.category,
                    measurements: measurements,
                    error: nil,
                    passed: !measurements.isEmpty && measurements.allSatisfy(\.passed)
                )
            } catch {
                return CaseResult(
                    identifier: definition.identifier,
                    category: definition.category,
                    measurements: [],
                    error: error.localizedDescription,
                    passed: false
                )
            }
        }

        var issues: [String] = []
        if !descriptor.isNonlinearProductionReady {
            issues.append("numeric-core does not have a valid nonlinear-production declaration")
        }
        if definitions.count < minimumCaseCount {
            issues.append("nonlinear corpus contains only \(definitions.count) cases")
        }
        let failures = results.filter { !$0.passed }.map(\.identifier)
        if !failures.isEmpty {
            issues.append("numeric-core failed nonlinear cases: \(failures.joined(separator: ", "))")
        }
        return Report(
            contractVersion: currentContractVersion,
            productVersion: OhmLabRelease.version,
            referenceBackend: reference.identifier,
            backend: backend.identifier,
            implementationVersion: backend.implementationVersion,
            scope: backend.nonlinearScope,
            cases: results,
            issues: issues.sorted(),
            ready: issues.isEmpty
        )
    }
}

private extension NonlinearConvergence {
    enum Metric {
        case dcNode(String, tolerance: Double)
        case dcCurrent(String, tolerance: Double)
        case acMagnitude(String, tolerance: Double)
        case acPhase(String, tolerance: Double)
        case transientLast(String, tolerance: Double)

        var name: String {
            switch self {
            case .dcNode(let name, _): "dc.v(\(name))"
            case .dcCurrent(let name, _): "dc.i(\(name))"
            case .acMagnitude(let name, _): "ac.v(\(name)).magnitude-db"
            case .acPhase(let name, _): "ac.v(\(name)).phase-deg"
            case .transientLast(let name, _): "tran.v(\(name)).last"
            }
        }

        var tolerance: Double {
            switch self {
            case .dcNode(_, let tolerance), .dcCurrent(_, let tolerance),
                 .acMagnitude(_, let tolerance), .acPhase(_, let tolerance),
                 .transientLast(_, let tolerance): tolerance
            }
        }
    }

    struct CaseDefinition {
        let identifier: String
        let category: String
        let circuit: CircuitIR
        let settings: AnalysisSettings
        let metrics: [Metric]
    }

    static func makeCases() throws -> [CaseDefinition] {
        var dc = AnalysisSettings.default
        dc.runDC = true
        dc.runAC = false
        dc.runTransient = false

        var ac = dc
        ac.runAC = true
        ac.acSweepType = .lin
        ac.acStartFrequency = 1_000
        ac.acStopFrequency = 1_001
        ac.acPointsPerDecade = 2

        var transient = dc
        transient.runDC = false
        transient.runTransient = true
        transient.tranStep = 10e-6
        transient.tranStop = 500e-6

        let diodeForward = "V1 in 0 5\nR1 in out 1k\nD1 out 0 DM\n.model DM D(IS=1e-14 N=1)\n.end"
        let diodeReverse = "V1 in 0 -5\nR1 in out 1k\nD1 out 0 DM\n.model DM D(IS=1e-14 N=1)\n.end"
        let diodeAC = "V1 in 0 DC 1 AC 1\nR1 in out 1k\nD1 out 0 DM\n.model DM D(IS=1e-14 N=1)\n.end"
        let diodeTransient = "V1 in 0 PULSE(0 5 0 1u 1u 1m 2m)\nR1 in out 1k\nD1 out 0 DM\n.model DM D(IS=1e-14 N=1)\n.end"
        let nmosDC = "VDD vdd 0 5\nVG gate 0 3\nRD vdd drain 1k\nM1 drain gate 0 0 NM\n.model NM NMOS(VTO=1 KP=1m LAMBDA=0.02 GAMMA=0)\n.end"
        let nmosAC = "VDD vdd 0 5\nVG gate 0 DC 3 AC 1\nRD vdd drain 1k\nM1 drain gate 0 0 NM\n.model NM NMOS(VTO=1 KP=1m LAMBDA=0.02 GAMMA=0)\n.end"
        let nmosTransient = "VDD vdd 0 5\nVG gate 0 PULSE(0 3 0 1u 1u 1m 2m)\nRD vdd drain 1k\nM1 drain gate 0 0 NM\n.model NM NMOS(VTO=1 KP=1m LAMBDA=0.02 GAMMA=0)\n.end"

        return [
            .init(identifier: "diode-forward-dc", category: "diode-dc", circuit: try CircuitIRCompiler.compile(netlist: diodeForward), settings: dc, metrics: [.dcNode("out", tolerance: 5e-3), .dcCurrent("D1", tolerance: 5e-6)]),
            .init(identifier: "diode-reverse-dc", category: "diode-dc", circuit: try CircuitIRCompiler.compile(netlist: diodeReverse), settings: dc, metrics: [.dcNode("out", tolerance: 5e-6), .dcCurrent("D1", tolerance: 5e-9)]),
            .init(identifier: "diode-small-signal-ac", category: "diode-ac", circuit: try CircuitIRCompiler.compile(netlist: diodeAC), settings: ac, metrics: [.acMagnitude("out", tolerance: 0.05), .acPhase("out", tolerance: 0.05)]),
            .init(identifier: "diode-pulse-transient", category: "diode-transient", circuit: try CircuitIRCompiler.compile(netlist: diodeTransient), settings: transient, metrics: [.transientLast("out", tolerance: 0.05)]),
            .init(identifier: "nmos-bias-dc", category: "nmos-dc", circuit: try CircuitIRCompiler.compile(netlist: nmosDC), settings: dc, metrics: [.dcNode("drain", tolerance: 5e-3), .dcCurrent("M1", tolerance: 5e-6)]),
            .init(identifier: "nmos-small-signal-ac", category: "nmos-ac", circuit: try CircuitIRCompiler.compile(netlist: nmosAC), settings: ac, metrics: [.acMagnitude("drain", tolerance: 0.05), .acPhase("drain", tolerance: 0.05)]),
            .init(identifier: "nmos-pulse-transient", category: "nmos-transient", circuit: try CircuitIRCompiler.compile(netlist: nmosTransient), settings: transient, metrics: [.transientLast("drain", tolerance: 0.05)]),
        ]
    }

    static func measurement(
        _ metric: Metric,
        expected: CircuitSimResult,
        actual: CircuitSimResult
    ) throws -> Measurement {
        let expectedValue = try value(metric, in: expected)
        let actualValue = try? value(metric, in: actual)
        let error = actualValue.map { candidate in
            switch metric {
            case .acPhase:
                let wrapped = (candidate - expectedValue).truncatingRemainder(dividingBy: 360)
                return min(abs(wrapped), abs(abs(wrapped) - 360))
            default:
                return abs(candidate - expectedValue)
            }
        }
        return Measurement(
            name: metric.name,
            expected: expectedValue,
            actual: actualValue,
            absoluteError: error,
            tolerance: metric.tolerance,
            passed: error.map { $0 <= metric.tolerance } ?? false
        )
    }

    static func value(_ metric: Metric, in result: CircuitSimResult) throws -> Double {
        switch metric {
        case .dcNode(let name, _):
            guard let value = result.dc?.nodes.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.voltage else { throw NumericCoreAdapterError.unsupportedAnalysis(metric.name) }
            return value
        case .dcCurrent(let name, _):
            guard let value = result.dc?.components.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.current else { throw NumericCoreAdapterError.unsupportedAnalysis(metric.name) }
            return value
        case .acMagnitude(let name, _):
            guard let value = result.ac?.nodes.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.response.first?.magnitudeDb else { throw NumericCoreAdapterError.unsupportedAnalysis(metric.name) }
            return value
        case .acPhase(let name, _):
            guard let value = result.ac?.nodes.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.response.first?.phaseDeg else { throw NumericCoreAdapterError.unsupportedAnalysis(metric.name) }
            return value
        case .transientLast(let name, _):
            guard let value = result.transient?.nodes.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.values.last else { throw NumericCoreAdapterError.unsupportedAnalysis(metric.name) }
            return value
        }
    }
}
