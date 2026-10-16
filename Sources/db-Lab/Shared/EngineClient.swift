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
        let sources: [(name: String, current: Double)]
        let converged: Bool
    }

    struct ACResult: Sendable {
        let frequencies: [Double]
        let nodes: [(name: String, response: [FreqPoint])]
    }
}

enum CircuitSimulationError: LocalizedError {
    case emptyNetlist
    case noAnalysisSelected
    case invalidACSettings
    case tooManySamples
    case missingGround

    var errorDescription: String? {
        switch self {
        case .emptyNetlist:
            return "Enter a SPICE netlist before running the simulation."
        case .noAnalysisSelected:
            return "Select at least one analysis type (DC or AC)."
        case .invalidACSettings:
            return "AC start frequency, stop frequency, and points per decade must define a valid positive sweep."
        case .tooManySamples:
            return "The requested analysis exceeds the 200,000-sample limit."
        case .missingGround:
            return "The circuit has no ground reference."
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
                effective.acPointsPerDecade = parsed.analysis.pointsPerDecade
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
            dcResult = CircuitSimResult.DCResult(
                nodes: (1..<circuit.nodeCount).map { node in
                    (circuit.nodeNames[node], solution.nodeVoltages[node].re)
                },
                sources: solution.sourceCurrents.map { ($0.name, $0.current.re) },
                converged: true
            )
        }

        var acResult: CircuitSimResult.ACResult?
        if settings.runAC {
            guard settings.acStartFrequency.isFinite,
                  settings.acStopFrequency.isFinite,
                  settings.acStartFrequency > 0,
                  settings.acStopFrequency > settings.acStartFrequency,
                  settings.acPointsPerDecade > 0 else {
                throw CircuitSimulationError.invalidACSettings
            }
            let frequencies = logspace(
                from: settings.acStartFrequency,
                to: settings.acStopFrequency,
                pointsPerDecade: settings.acPointsPerDecade
            )
            guard frequencies.count <= 200_000 else { throw CircuitSimulationError.tooManySamples }

            var nodeResponses: [(name: String, response: [FreqPoint])] = []
            for node in 1..<circuit.nodeCount {
                var points: [FreqPoint] = []
                points.reserveCapacity(frequencies.count)
                for frequency in frequencies {
                    let solution = try circuit.solveAC(frequencyHz: frequency)
                    let voltage = solution.nodeVoltages[node]
                    points.append(FreqPoint(
                        freqHz: frequency,
                        magnitudeDb: voltage.magnitudeDecibels,
                        phaseDeg: voltage.phaseDegrees
                    ))
                }
                nodeResponses.append((circuit.nodeNames[node], points))
            }
            acResult = CircuitSimResult.ACResult(frequencies: frequencies, nodes: nodeResponses)
        }

        return CircuitSimResult(dc: dcResult, ac: acResult, warnings: warnings)
    }

    static func logspace(from start: Double, to stop: Double, pointsPerDecade: Int) -> [Double] {
        guard start > 0, stop > start, pointsPerDecade > 0 else { return [] }
        let decades = log10(stop / start)
        let intervals = Int(ceil(decades * Double(pointsPerDecade)))
        var frequencies = (0...intervals).map { index in
            min(start * pow(10, Double(index) / Double(pointsPerDecade)), stop)
        }
        if frequencies.last != stop { frequencies.append(stop) }
        return frequencies
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
