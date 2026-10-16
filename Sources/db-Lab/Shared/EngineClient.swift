// Type-safe wrapper around the UniFFI-generated DbEngine circuit bindings.
//
// Without the framework, this file compiles with a lightweight Swift mock so
// UI work can continue before the Rust build is finalized.

import Foundation

struct FreqPoint: Identifiable {
    var id: Double { freqHz }
    let freqHz: Double
    let magnitudeDb: Double
    let phaseDeg: Double
}

struct CircuitSimResult {
    let isMock: Bool
    let dc: DCResult?
    let ac: ACResult?
    let tran: TRANResult?

    struct DCResult {
        let nodes: [(name: String, voltage: Double)]
        let sources: [(name: String, current: Double)]
        let converged: Bool
    }

    struct ACResult {
        let frequencies: [Double]
        let nodes: [(name: String, response: [FreqPoint])]
    }

    struct TRANResult {
        let timePoints: [Double]
        let nodes: [(name: String, waveform: [Double])]
    }
}

enum CircuitSimulationError: LocalizedError {
    case emptyNetlist
    case noAnalysisSelected
    case invalidACSettings
    case invalidTransientSettings
    case tooManySamples

    var errorDescription: String? {
        switch self {
        case .emptyNetlist:
            return "Enter a SPICE netlist before running the simulation."
        case .noAnalysisSelected:
            return "Select at least one analysis type."
        case .invalidACSettings:
            return "AC start frequency, stop frequency, and points per decade must define a valid positive sweep."
        case .invalidTransientSettings:
            return "Transient stop time and step must be positive finite values."
        case .tooManySamples:
            return "The requested analysis exceeds the 100,000-sample limit."
        }
    }
}

@MainActor
class EngineClient: ObservableObject {
    static let shared = EngineClient()
    private init() {}

    func simulateSpice(
        netlist: String,
        runDC: Bool = true,
        runAC: Bool = true,
        acFStart: Double = 1,
        acFStop: Double = 1e6,
        acPointsPerDecade: Int = 10,
        runTRAN: Bool = false,
        tranTStop: Double = 1e-3,
        tranTStep: Double = 1e-6
    ) async throws -> CircuitSimResult {
        guard !netlist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CircuitSimulationError.emptyNetlist
        }
        guard runDC || runAC || runTRAN else {
            throw CircuitSimulationError.noAnalysisSelected
        }
        if runAC {
            guard acFStart.isFinite, acFStop.isFinite, acFStart > 0,
                  acFStop > acFStart, acPointsPerDecade > 0 else {
                throw CircuitSimulationError.invalidACSettings
            }
            let sampleCount = log10(acFStop / acFStart) * Double(acPointsPerDecade)
            guard sampleCount.isFinite else { throw CircuitSimulationError.tooManySamples }
            guard ceil(sampleCount) < 100_000 else { throw CircuitSimulationError.tooManySamples }
        }
        if runTRAN {
            guard tranTStop.isFinite, tranTStep.isFinite, tranTStop > 0, tranTStep > 0 else {
                throw CircuitSimulationError.invalidTransientSettings
            }
            let sampleCount = tranTStop / tranTStep
            guard sampleCount.isFinite else { throw CircuitSimulationError.tooManySamples }
            guard ceil(sampleCount) < 100_000 else { throw CircuitSimulationError.tooManySamples }
        }

        return await Task.detached(priority: .userInitiated) {
            self.mockCircuitResult(
                runDC: runDC,
                runAC: runAC,
                acFStart: acFStart,
                acFStop: acFStop,
                acPointsPerDecade: acPointsPerDecade,
                runTRAN: runTRAN,
                tranTStop: tranTStop,
                tranTStep: tranTStep
            )
        }.value
    }

    private nonisolated func mockCircuitResult(
        runDC: Bool,
        runAC: Bool,
        acFStart: Double,
        acFStop: Double,
        acPointsPerDecade: Int,
        runTRAN: Bool,
        tranTStop: Double,
        tranTStep: Double
    ) -> CircuitSimResult {
        let dcResult = runDC ? CircuitSimResult.DCResult(
            nodes: [("Node 1", 1.0), ("Node 2", 1.0)],
            sources: [("V1", 0.0)],
            converged: true
        ) : nil

        let frequencies = runAC
            ? logspace(fMin: acFStart, fMax: acFStop, points: acPointsPerDecade)
            : []
        let acResult = runAC ? CircuitSimResult.ACResult(
            frequencies: frequencies,
            nodes: [
                (name: "Node 1", response: frequencies.map {
                    FreqPoint(freqHz: $0, magnitudeDb: 0, phaseDeg: 0)
                }),
                (name: "Node 2", response: frequencies.map { frequency in
                    let ratio = frequency / 159.15
                    return FreqPoint(
                        freqHz: frequency,
                        magnitudeDb: -10 * log10(1 + ratio * ratio),
                        phaseDeg: -atan(ratio) * 180 / Double.pi
                    )
                })
            ]
        ) : nil

        let transientResult: CircuitSimResult.TRANResult? = runTRAN ? {
            let count = Int(ceil(tranTStop / tranTStep))
            let times = (0...count).map { min(Double($0) * tranTStep, tranTStop) }
            let tau = 1e-3
            return CircuitSimResult.TRANResult(
                timePoints: times,
                nodes: [
                    (name: "Node 1", waveform: times.map { _ in 1.0 }),
                    (name: "Node 2", waveform: times.map { 1 - exp(-$0 / tau) })
                ]
            )
        }() : nil

        return CircuitSimResult(isMock: true, dc: dcResult, ac: acResult, tran: transientResult)
    }

    private nonisolated func logspace(fMin: Double, fMax: Double, points: Int) -> [Double] {
        let decades = log10(fMax / fMin)
        let intervals = Int(ceil(decades * Double(points)))
        var frequencies = (0...intervals).map { index in
            min(fMin * pow(10, Double(index) / Double(points)), fMax)
        }
        if frequencies.last != fMax {
            frequencies.append(fMax)
        }
        return frequencies
    }
}
