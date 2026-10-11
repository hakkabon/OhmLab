// EngineClient.swift
// Type-safe wrapper around the UniFFI-generated DbEngine bindings.
//
// When the XCFramework is linked (UNIFFI_AVAILABLE compiler flag set in
// Package.swift), this file delegates to the real CrossoverEngine /
// CircuitEngine objects produced by `uniffi-bindgen-swift`.
//
// Without the framework the file still compiles using lightweight Swift-native
// mock implementations, so UI work can continue before the Rust build is
// finalised.

import Foundation

// ─── Shared value types ──────────────────────────────────────────────────────

struct FreqPoint: Identifiable {
    var id: Double { freqHz }
    let freqHz: Double
    let magnitudeDb: Double
    let phaseDeg: Double
}

struct ComponentValue: Identifiable {
    var id: String { name }
    let name: String
    let kind: ComponentKind
    let value: Double
    let tolerance: Double?

    /// Human-readable display string (e.g. "2.20mH", "10.0µF", "8.20Ω")
    var displayString: String {
        switch kind {
        case .resistor, .resistorSeries:
            return value >= 1000 ? String(format: "%.2fkΩ", value / 1000) : String(format: "%.2fΩ", value)
        case .capacitor, .capacitorSeries:
            if value >= 1e-3 { return String(format: "%.2fmF", value * 1e3) }
            if value >= 1e-6 { return String(format: "%.2fµF", value * 1e6) }
            if value >= 1e-9 { return String(format: "%.2fnF", value * 1e9) }
            return String(format: "%.2fpF", value * 1e12)
        case .inductor, .inductorSeries:
            if value >= 1.0 { return String(format: "%.2fH", value) }
            if value >= 1e-3 { return String(format: "%.2fmH", value * 1e3) }
            return String(format: "%.2fµH", value * 1e6)
        }
    }
}

enum ComponentKind: String, CaseIterable, Identifiable {
    case resistor = "Resistor"
    case capacitor = "Capacitor"
    case inductor = "Inductor"
    case resistorSeries = "ResistorSeries"
    case capacitorSeries = "CapacitorSeries"
    case inductorSeries = "InductorSeries"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .resistor, .resistorSeries: return "Ω"
        case .capacitor, .capacitorSeries: return "F"
        case .inductor, .inductorSeries: return "H"
        }
    }
}

// ─── Crossover types ─────────────────────────────────────────────────────────

enum CrossoverTopology: String, CaseIterable, Identifiable {
    case butterworth1 = "Butterworth 1st"
    case butterworth2 = "Butterworth 2nd"
    case butterworth3 = "Butterworth 3rd"
    case butterworth4 = "Butterworth 4th"
    case linkwitzRiley2 = "Linkwitz-Riley 2nd"
    case linkwitzRiley4 = "Linkwitz-Riley 4th"
    case linkwitzRiley6 = "Linkwitz-Riley 6th"
    case linkwitzRiley8 = "Linkwitz-Riley 8th"
    case bessel2 = "Bessel 2nd"
    case bessel3 = "Bessel 3rd"
    case bessel4 = "Bessel 4th"
    case custom = "Custom"

    var id: String { rawValue }
    var order: Int {
        switch self {
        case .butterworth1: return 1
        case .butterworth2, .linkwitzRiley2, .bessel2: return 2
        case .butterworth3, .bessel3: return 3
        case .butterworth4, .linkwitzRiley4, .bessel4: return 4
        case .linkwitzRiley6: return 6
        case .linkwitzRiley8: return 8
        case .custom: return 0
        }
    }
}

enum PassFilterType: String, CaseIterable, Identifiable {
    case lowPass  = "Low Pass"
    case highPass = "High Pass"
    case bandPass = "Band Pass"
    case bandStop = "Band Stop"
    case allPass  = "All Pass"
    var id: String { rawValue }
}

enum DriverRoleType: String, CaseIterable, Identifiable {
    case woofer      = "Woofer"
    case midrange    = "Midrange"
    case tweeter     = "Tweeter"
    case superTweeter = "Super-Tweeter"
    case subwoofer   = "Subwoofer"
    case fullRange   = "Full Range"
    var id: String { rawValue }
}

enum CompensationKind: String, CaseIterable, Identifiable {
    case zobel  = "Zobel"
    case lpad   = "L-Pad"
    case notch  = "Notch"
    case baffleStep = "Baffle Step"
    var id: String { rawValue }
}

enum StandardSeries: String, CaseIterable, Identifiable {
    case e12 = "E12"
    case e24 = "E24"
    var id: String { rawValue }
}

// ─── Driver model ────────────────────────────────────────────────────────────

struct DriverModel: Identifiable, Hashable {
    var id = UUID()
    var name: String = "New Driver"
    var role: DriverRoleType = .woofer
    var nominalImpedance: Double = 8.0
    var re: Double = 6.0
    var le: Double? = nil
    var sensitivityDb: Double = 88.0
    var invertedPolarity: Bool = false
    var acousticOffsetMm: Double = 0.0
    var powerHandlingW: Double? = nil
    // Thiele-Small
    var fs: Double? = nil
    var qts: Double? = nil
    var qes: Double? = nil
    var qms: Double? = nil
    var vas: Double? = nil

    static func defaultWoofer() -> Self {
        var d = Self()
        d.name = "Woofer"
        d.role = .woofer
        d.nominalImpedance = 8.0
        d.re = 5.8
        d.le = 0.0005
        d.sensitivityDb = 87.0
        d.fs = 35.0
        d.qts = 0.38
        return d
    }

    static func defaultTweeter() -> Self {
        var d = Self()
        d.name = "Tweeter"
        d.role = .tweeter
        d.nominalImpedance = 8.0
        d.re = 6.5
        d.sensitivityDb = 92.0
        d.fs = 1200.0
        d.qts = 0.55
        return d
    }
}

// ─── Filter stage model ──────────────────────────────────────────────────────

struct FilterStageModel: Identifiable {
    var id = UUID()
    var filterType: PassFilterType
    var topology: CrossoverTopology
    var frequencyHz: Double
    var driverName: String
    var components: [ComponentValue] = []
}

// ─── Simulation results ──────────────────────────────────────────────────────

struct CrossoverSimResult {
    let frequencies: [Double]
    let summedAcoustic: [FreqPoint]
    let systemImpedance: [FreqPoint]
    let driverResults: [DriverResult]

    struct DriverResult: Identifiable {
        var id: String { driverId }
        let driverId: String
        let acousticResponse: [FreqPoint]
        let impedance: [FreqPoint]
    }
}

struct CircuitSimResult {
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

// ─── Engine client ───────────────────────────────────────────────────────────

/// Facade over the UniFFI-generated Rust engine.
/// The `#if UNIFFI_AVAILABLE` sections will be filled in once the XCFramework
/// is linked. Until then the stubs below return plausible mock data.
@MainActor
class EngineClient: ObservableObject {
    static let shared = EngineClient()
    private init() {}

    // MARK: – Crossover synthesis

    func synthesizeFilter(
        type: PassFilterType,
        topology: CrossoverTopology,
        fcHz: Double,
        rLoad: Double
    ) -> [ComponentValue] {
        // In the real build: CrossoverEngine().synthesizeFilter(…)
        return mockFilterComponents(type: type, topology: topology, fcHz: fcHz, rLoad: rLoad)
    }

    func synthesizeZobel(re: Double, le: Double) -> [ComponentValue] {
        let r = re * 1.25
        let c = le / (re * re)
        return [
            ComponentValue(name: "Zobel_R", kind: .resistor, value: r, tolerance: 0.05),
            ComponentValue(name: "Zobel_C", kind: .capacitor, value: c, tolerance: 0.1)
        ]
    }

    func synthesizeLPad(rLoad: Double, attenuationDb: Double) -> [ComponentValue] {
        let k = pow(10, attenuationDb / 20)
        let rs = rLoad * (k - 1) / (k + 1)
        let rp = rLoad * (k * k - 1) / (2 * k)
        return [
            ComponentValue(name: "LPad_Rs", kind: .resistor, value: rs, tolerance: 0.05),
            ComponentValue(name: "LPad_Rp", kind: .resistor, value: rp, tolerance: 0.05)
        ]
    }

    func synthesizeNotch(fcHz: Double, q: Double, rLoad: Double) -> [ComponentValue] {
        let omega = 2 * Double.pi * fcHz
        let c = 1 / (omega * rLoad * q)
        let l = rLoad * q / omega
        return [
            ComponentValue(name: "Notch_C", kind: .capacitor, value: c, tolerance: 0.1),
            ComponentValue(name: "Notch_L", kind: .inductor, value: l, tolerance: 0.1),
            ComponentValue(name: "Notch_R", kind: .resistor, value: rLoad, tolerance: 0.05)
        ]
    }

    func synthesizeBaffleStep(fcHz: Double, rLoad: Double, stepDb: Double) -> [ComponentValue] {
        let k = pow(10, stepDb / 20)
        let r = rLoad * (k - 1)
        let l = r / (2 * Double.pi * fcHz)
        return [
            ComponentValue(name: "BS_R", kind: .resistor, value: r, tolerance: 0.05),
            ComponentValue(name: "BS_L", kind: .inductor, value: l, tolerance: 0.1)
        ]
    }

    // MARK: – Crossover simulation

    func simulateCrossover(
        drivers: [DriverModel],
        filters: [FilterStageModel],
        fMin: Double = 20,
        fMax: Double = 20_000,
        pointsPerDecade: Int = 200
    ) async throws -> CrossoverSimResult {
        // Simulate on a background thread (Rust Rayon will use multiple cores)
        return try await Task.detached(priority: .userInitiated) {
            self.mockCrossoverResult(drivers: drivers, filters: filters, fMin: fMin, fMax: fMax, points: pointsPerDecade)
        }.value
    }

    // MARK: – Circuit simulation

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
        return try await Task.detached(priority: .userInitiated) {
            self.mockCircuitResult(netlist: netlist, runAC: runAC)
        }.value
    }

    // MARK: – Mock helpers (replaced by real engine once XCFramework is linked)

    private func mockFilterComponents(
        type: PassFilterType,
        topology: CrossoverTopology,
        fcHz: Double,
        rLoad: Double
    ) -> [ComponentValue] {
        let omega = 2 * Double.pi * fcHz
        switch (type, topology.order) {
        case (.lowPass, 1):
            return [ComponentValue(name: "L1", kind: .inductor, value: rLoad / omega, tolerance: 0.1)]
        case (.highPass, 1):
            return [ComponentValue(name: "C1", kind: .capacitor, value: 1 / (omega * rLoad), tolerance: 0.1)]
        case (.lowPass, 2):
            return [
                ComponentValue(name: "L1", kind: .inductor, value: rLoad * 1.414 / omega, tolerance: 0.1),
                ComponentValue(name: "C1", kind: .capacitor, value: 1.414 / (omega * rLoad), tolerance: 0.1)
            ]
        case (.highPass, 2):
            return [
                ComponentValue(name: "C1", kind: .capacitor, value: 1.414 / (omega * rLoad), tolerance: 0.1),
                ComponentValue(name: "L1", kind: .inductor, value: rLoad * 1.414 / omega, tolerance: 0.1)
            ]
        case (.lowPass, 4):
            return [
                ComponentValue(name: "L1", kind: .inductor, value: rLoad * 0.765 / omega, tolerance: 0.1),
                ComponentValue(name: "C1", kind: .capacitor, value: 1.848 / (omega * rLoad), tolerance: 0.1),
                ComponentValue(name: "L2", kind: .inductor, value: rLoad * 1.848 / omega, tolerance: 0.1),
                ComponentValue(name: "C2", kind: .capacitor, value: 0.765 / (omega * rLoad), tolerance: 0.1)
            ]
        case (.highPass, 4):
            return [
                ComponentValue(name: "C1", kind: .capacitor, value: 0.765 / (omega * rLoad), tolerance: 0.1),
                ComponentValue(name: "L1", kind: .inductor, value: rLoad * 1.848 / omega, tolerance: 0.1),
                ComponentValue(name: "C2", kind: .capacitor, value: 1.848 / (omega * rLoad), tolerance: 0.1),
                ComponentValue(name: "L2", kind: .inductor, value: rLoad * 0.765 / omega, tolerance: 0.1)
            ]
        default:
            return [ComponentValue(name: "L1", kind: .inductor, value: rLoad / omega, tolerance: 0.1)]
        }
    }

    private nonisolated func mockCrossoverResult(
        drivers: [DriverModel],
        filters: [FilterStageModel],
        fMin: Double, fMax: Double, points: Int
    ) -> CrossoverSimResult {
        let freqs = logspace(fMin: fMin, fMax: fMax, points: points)

        let summed: [FreqPoint] = freqs.map { f in
            let db = -3.0 * sin(Double.pi * log10(f / 1000) / 3.0)
            return FreqPoint(freqHz: f, magnitudeDb: db, phaseDeg: 0)
        }

        let impedance: [FreqPoint] = freqs.map { f in
            let mag = 8.0 + 2.0 * sin(Double.pi * log10(f / 1000))
            return FreqPoint(freqHz: f, magnitudeDb: 20 * log10(mag), phaseDeg: 0)
        }

        let driverResults: [CrossoverSimResult.DriverResult] = drivers.map { driver in
            let acoustic: [FreqPoint] = freqs.map { f in
                let db: Double
                switch driver.role {
                case .woofer:
                    db = f < 2000 ? -1.0 : -40 * log10(f / 2000)
                case .tweeter:
                    db = f > 2000 ? -1.0 : -40 * log10(2000 / f)
                default:
                    db = -3.0
                }
                return FreqPoint(freqHz: f, magnitudeDb: db, phaseDeg: 0)
            }
            let imp: [FreqPoint] = freqs.map { f in
                FreqPoint(freqHz: f, magnitudeDb: 20 * log10(driver.nominalImpedance), phaseDeg: 0)
            }
            return CrossoverSimResult.DriverResult(driverId: driver.name, acousticResponse: acoustic, impedance: imp)
        }

        return CrossoverSimResult(frequencies: freqs, summedAcoustic: summed, systemImpedance: impedance, driverResults: driverResults)
    }

    private nonisolated func mockCircuitResult(netlist: String, runAC: Bool) -> CircuitSimResult {
        let freqs = logspace(fMin: 1, fMax: 1_000_000, points: 10)
        let acResult = runAC ? CircuitSimResult.ACResult(
            frequencies: freqs,
            nodes: [(name: "Node 1", response: freqs.map { f in
                let db = -20 * log10(1 + pow(f / 1000, 2))
                return FreqPoint(freqHz: f, magnitudeDb: db, phaseDeg: -atan(f / 1000) * 180 / Double.pi)
            })]
        ) : nil
        return CircuitSimResult(dc: nil, ac: acResult, tran: nil)
    }

    private nonisolated func logspace(fMin: Double, fMax: Double, points: Int) -> [Double] {
        let decades = log10(fMax / fMin)
        let total = Int(decades * Double(points)) + 1
        return (0..<total).map { i in fMin * pow(10, Double(i) / Double(points)) }.filter { $0 <= fMax }
    }
}
