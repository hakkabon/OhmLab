// EngineClient.swift
// The Swift-side circuit engine.
//
// The first milestone requires that displayed plots come from an analysis of
// the actual schematic, so this is a real solver: the schematic (or a parsed
// netlist) is projected into a linear MNA circuit and solved for AC and DC.
// There is no demonstration data on this path.

import Foundation

struct FreqPoint: Identifiable, Sendable {
    var id: Double { freqHz }
    let freqHz: Double
    let magnitudeDb: Double
    let phaseDeg: Double
}

struct CircuitSimResult: Sendable {
    let dc: DCResult?
    let ac: ACResult?
    let warnings: [String]

    struct DCResult: Sendable {
        let nodes: [(name: String, voltage: Double)]
        /// Per-element operating point: voltage drop (nodeA - nodeB) and current
        /// flowing from nodeA to nodeB.
        let components: [(name: String, voltage: Double, current: Double)]
        let sources: [(name: String, current: Double)]
        let converged: Bool
    }

    struct ACResult: Sendable {
        let frequencies: [Double]
        let nodes: [(name: String, response: [FreqPoint])]
        /// Per-element current sweep, in the same units as the element.
        let components: [(name: String, response: [FreqPoint])]
    }
}

enum CircuitSimulationError: LocalizedError {
    case emptyNetlist
    case noAnalysisSelected
    case invalidACSettings
    case tooManySamples
    case missingGround
    case acSolveFailed(frequency: Double, reason: String)
    case unstableResult

    var errorDescription: String? {
        switch self {
        case .emptyNetlist:
            return "Enter a SPICE netlist before running the simulation."
        case .noAnalysisSelected:
            return "Select at least one analysis type (DC or AC)."
        case .invalidACSettings:
            return "AC start frequency, stop frequency, and sweep points must define a valid positive sweep."
        case .tooManySamples:
            return "The requested analysis exceeds the 200,000-sample limit."
        case .missingGround:
            return "The circuit has no ground reference."
        case .acSolveFailed(let frequency, let reason):
            return "AC solve failed at \(String(format: "%.6g", frequency)) Hz: \(reason)"
        case .unstableResult:
            return "The solution is not numerically stable. Check for floating nodes or short circuits."
        }
    }
}

enum SimulationEngine {
    // MARK: - Schematic path

    static func solve(
        snapshot: SchematicSnapshot,
        settings: AnalysisSettings
    ) throws -> CircuitSimResult {
        let circuit = try CircuitCompiler.compile(
            symbols: snapshot.symbols,
            wires: snapshot.wires,
            labels: snapshot.netLabels
        )
        return try solve(circuit: circuit, settings: settings)
    }

    // MARK: - Netlist path

    static func solve(
        netlist: String,
        settings: AnalysisSettings
    ) throws -> CircuitSimResult {
        guard !netlist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CircuitSimulationError.emptyNetlist
        }
        let parsed = try SpiceNetlistParser.parse(netlist)

        // Prefer analysis settings entered in the UI; fall back to the `.ac`
        // card when the UI settings are left at their defaults and none supplied.
        var effective = settings
        if parsed.analysis.hasAC {
            effective.runAC = settings.runAC || parsed.analysis.hasAC
            if settings.acStartFrequency == AnalysisSettings.default.acStartFrequency,
               settings.acStopFrequency == AnalysisSettings.default.acStopFrequency {
                effective.acStartFrequency = parsed.analysis.startFrequency
                effective.acStopFrequency = parsed.analysis.stopFrequency
                effective.acPointsPerDecade = parsed.analysis.points
                effective.acSweepType = parsed.analysis.sweep
            }
        }
        return try solve(circuit: parsed.circuit, settings: effective)
    }

    // MARK: - Common solve

    private static func solve(circuit: LinearCircuit, settings: AnalysisSettings) throws -> CircuitSimResult {
        guard settings.runDC || settings.runAC else {
            throw CircuitSimulationError.noAnalysisSelected
        }

        var warnings: [String] = []
        let hasSource = circuit.elements.contains {
            $0.kind == .voltageSource || $0.kind == .currentSource
        }
        if !hasSource {
            warnings.append("The circuit has no independent source, so the results are all zero.")
        }

        var dcResult: CircuitSimResult.DCResult?
        if settings.runDC {
            let solution = try circuit.solveDC()
            try assertFinite(solution)
            dcResult = CircuitSimResult.DCResult(
                nodes: (1..<circuit.nodeCount).map { node in
                    (circuit.nodeNames[node], solution.nodeVoltages[node].re)
                },
                components: circuit.elements.enumerated().map { index, element in
                    let voltage = solution.nodeVoltages[element.nodeA] - solution.nodeVoltages[element.nodeB]
                    return (element.name, voltage.re, solution.elementCurrents[index].re)
                },
                sources: solution.sourceCurrents.map { ($0.name, $0.current.re) },
                converged: true
            )
        }

        var acResult: CircuitSimResult.ACResult?
        if settings.runAC {
            let frequencies = try makeFrequencies(settings)
            // Solve once per frequency and read every node and element current
            // from that solution, rather than re-solving for each signal.
            var nodePoints = [[FreqPoint]](repeating: [], count: circuit.nodeCount)
            var elementPoints = [[FreqPoint]](repeating: [], count: circuit.elements.count)
            var maxMagnitude = 0.0
            for frequency in frequencies {
                let solution: LinearCircuit.Solution
                do {
                    solution = try circuit.solveAC(frequencyHz: frequency)
                } catch {
                    throw CircuitSimulationError.acSolveFailed(
                        frequency: frequency,
                        reason: error.localizedDescription
                    )
                }
                try assertFinite(solution)
                for node in 1..<circuit.nodeCount {
                    let voltage = solution.nodeVoltages[node]
                    maxMagnitude = max(maxMagnitude, voltage.magnitude)
                    nodePoints[node].append(FreqPoint(
                        freqHz: frequency,
                        magnitudeDb: voltage.magnitudeDecibels,
                        phaseDeg: voltage.phaseDegrees
                    ))
                }
                for index in circuit.elements.indices {
                    let current = solution.elementCurrents[index]
                    elementPoints[index].append(FreqPoint(
                        freqHz: frequency,
                        magnitudeDb: current.magnitudeDecibels,
                        phaseDeg: current.phaseDegrees
                    ))
                }
            }
            if maxMagnitude > 1e15 {
                warnings.append(
                    "Voltage magnitude reached \(String(format: "%.3g", maxMagnitude)); "
                    + "the circuit may be near-singular (floating node or short)."
                )
            }
            let nodeResponses = (1..<circuit.nodeCount).map { node in
                (circuit.nodeNames[node], nodePoints[node])
            }
            let componentResponses = circuit.elements.enumerated().map { index, element in
                (element.name, elementPoints[index])
            }
            acResult = CircuitSimResult.ACResult(
                frequencies: frequencies,
                nodes: nodeResponses,
                components: componentResponses
            )
        }

        return CircuitSimResult(dc: dcResult, ac: acResult, warnings: warnings)
    }

    private static func makeFrequencies(_ settings: AnalysisSettings) throws -> [Double] {
        let type = settings.acSweepType
        let estimated = FrequencySweep.pointCount(
            from: settings.acStartFrequency,
            to: settings.acStopFrequency,
            count: settings.acPointsPerDecade,
            type: type
        )
        guard estimated > 0 else { throw CircuitSimulationError.invalidACSettings }
        guard estimated <= FrequencySweep.maxPointCount else { throw CircuitSimulationError.tooManySamples }
        let frequencies = FrequencySweep.points(
            from: settings.acStartFrequency,
            to: settings.acStopFrequency,
            count: settings.acPointsPerDecade,
            type: type
        )
        guard !frequencies.isEmpty else { throw CircuitSimulationError.invalidACSettings }
        return frequencies
    }

    private static func assertFinite(_ solution: LinearCircuit.Solution) throws {
        for voltage in solution.nodeVoltages where !voltage.re.isFinite || !voltage.im.isFinite {
            throw CircuitSimulationError.unstableResult
        }
    }
}

@MainActor
final class EngineClient: ObservableObject {
    static let shared = EngineClient()
    private init() {}

    func simulate(
        snapshot: SchematicSnapshot,
        settings: AnalysisSettings
    ) async throws -> CircuitSimResult {
        try await Task.detached(priority: .userInitiated) {
            try SimulationEngine.solve(snapshot: snapshot, settings: settings)
        }.value
    }

    func simulate(
        netlist: String,
        settings: AnalysisSettings
    ) async throws -> CircuitSimResult {
        try await Task.detached(priority: .userInitiated) {
            try SimulationEngine.solve(netlist: netlist, settings: settings)
        }.value
    }
}
