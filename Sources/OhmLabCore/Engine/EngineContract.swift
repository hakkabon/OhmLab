import Foundation

/// Analysis identifiers in the version-one simulation backend contract.
public enum SimulationAnalysisKind: String, Codable, Sendable, CaseIterable, Comparable {
    case dcOperatingPoint = "dc-operating-point"
    case acSmallSignal = "ac-small-signal"
    case transient
    case dcSweep = "dc-sweep"
    case parameterSweep = "parameter-sweep"
    case fourier

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Input and execution features that are separate from device/analysis support.
public enum SimulationBackendFeature: String, Codable, Sendable, CaseIterable, Comparable {
    case schematicInput = "schematic-input"
    case spiceNetlistInput = "spice-netlist-input"
    case circuitIRInput = "circuit-ir-input"
    case modelLibraries = "model-libraries"
    case sourceWaveforms = "source-waveforms"
    case initialConditions = "initial-conditions"
    case temperature
    case cooperativeCancellation = "cooperative-cancellation"

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Machine-readable capabilities for a simulation backend.
///
/// Arrays are normalized into deterministic order so their JSON representation
/// can be compared across releases and, eventually, across the Swift/Rust FFI.
public struct SimulationBackendCapabilities: Codable, Equatable, Sendable {
    public static let currentContractVersion = 1

    public let contractVersion: Int
    public let backendIdentifier: String
    public let analyses: [SimulationAnalysisKind]
    public let devices: [CircuitIR.DeviceKind]
    public let features: [SimulationBackendFeature]

    public init(
        backendIdentifier: String,
        analyses: [SimulationAnalysisKind],
        devices: [CircuitIR.DeviceKind],
        features: [SimulationBackendFeature],
        contractVersion: Int = currentContractVersion
    ) {
        self.contractVersion = contractVersion
        self.backendIdentifier = backendIdentifier
        self.analyses = Array(Set(analyses)).sorted()
        self.devices = Array(Set(devices)).sorted()
        self.features = Array(Set(features)).sorted()
    }

    public func supports(_ analysis: SimulationAnalysisKind) -> Bool {
        analyses.contains(analysis)
    }

    public func supports(_ device: CircuitIR.DeviceKind) -> Bool {
        devices.contains(device)
    }

    public func supports(_ feature: SimulationBackendFeature) -> Bool {
        features.contains(feature)
    }

    public static func unspecified(backendIdentifier: String) -> Self {
        .init(backendIdentifier: backendIdentifier, analyses: [], devices: [], features: [])
    }
}

/// Frozen units and sign conventions for `CircuitSimResult` contract version 1.
public enum SimulationResultContract {
    public static let currentVersion = 1
    public static let voltageUnit = "V"
    public static let currentUnit = "A"
    public static let timeUnit = "s"
    public static let frequencyUnit = "Hz"
    public static let phaseUnit = "deg"

    /// Validates structural invariants that every backend must honor.
    public static func validate(_ result: CircuitSimResult) throws {
        guard result.contractVersion == currentVersion else {
            throw SimulationContractError.unsupportedResultVersion(result.contractVersion)
        }
        if let dc = result.dc {
            try unique(dc.nodes.map(\.name), category: "DC node")
            try unique(dc.components.map(\.name), category: "DC component")
            try unique(dc.sources.map(\.name), category: "DC source")
            guard dc.nodes.allSatisfy({ $0.voltage.isFinite }),
                  dc.components.allSatisfy({ $0.voltage.isFinite && $0.current.isFinite }),
                  dc.sources.allSatisfy({ $0.current.isFinite }) else {
                throw SimulationContractError.nonFiniteValue("DC result")
            }
        }
        if let ac = result.ac {
            guard orderedFinite(ac.frequencies, allowZero: true) else {
                throw SimulationContractError.invalidAxis("AC frequency")
            }
            try unique(ac.nodes.map(\.name), category: "AC node")
            try unique(ac.components.map(\.name), category: "AC component")
            let series = ac.nodes.map(\.response) + ac.components.map(\.response)
            guard series.allSatisfy({ response in
                      response.count == ac.frequencies.count
                          && zip(response, ac.frequencies).allSatisfy({ $0.0.freqHz == $0.1 })
                  }),
                  series.flatMap({ $0 }).allSatisfy({
                      $0.freqHz.isFinite && $0.magnitudeDb.isFinite && $0.phaseDeg.isFinite
                  }) else {
                throw SimulationContractError.invalidSeries("AC result")
            }
        }
        if let transient = result.transient {
            guard orderedFinite(transient.times, allowZero: true) else {
                throw SimulationContractError.invalidAxis("transient time")
            }
            try unique(transient.nodes.map(\.name), category: "transient node")
            try unique(transient.components.map(\.name), category: "transient component")
            let series = transient.nodes.map(\.values) + transient.components.map(\.values)
            guard series.allSatisfy({ $0.count == transient.times.count }),
                  series.flatMap({ $0 }).allSatisfy(\.isFinite) else {
                throw SimulationContractError.invalidSeries("transient result")
            }
        }
        if let sweep = result.sweep {
            try unique(sweep.axes.map(\.name), category: "sweep axis")
            guard sweep.axes.allSatisfy({ !$0.values.isEmpty && $0.values.allSatisfy(\.isFinite) }),
                  sweep.points.allSatisfy({ point in
                      point.coordinates.count == sweep.axes.count
                          && zip(point.coordinates, sweep.axes).allSatisfy({
                              $0.0.name.caseInsensitiveCompare($0.1.name) == .orderedSame
                          })
                          && point.coordinates.allSatisfy({ $0.value.isFinite })
                          && point.nodes.allSatisfy({ $0.voltage.isFinite })
                          && point.components.allSatisfy({ $0.voltage.isFinite && $0.current.isFinite })
                  }) else {
                throw SimulationContractError.invalidSeries("DC sweep result")
            }
        }
        for entry in result.fourier {
            let spectrum = entry.spectrum
            guard !entry.variable.isEmpty, entry.fundamentalFrequency.isFinite,
                  entry.fundamentalFrequency > 0, spectrum.dcComponent.isFinite,
                  spectrum.totalHarmonicDistortion.isFinite,
                  spectrum.harmonics.allSatisfy({ harmonic in
                      harmonic.number > 0 && harmonic.frequency.isFinite
                          && harmonic.magnitude.isFinite && harmonic.phaseDegrees.isFinite
                          && harmonic.normalizedMagnitude.isFinite
                          && harmonic.normalizedPhaseDegrees.isFinite
                  }) else {
                throw SimulationContractError.invalidSeries("Fourier result")
            }
        }
    }

    private static func unique(_ names: [String], category: String) throws {
        let normalized = names.map { $0.lowercased() }
        guard names.allSatisfy({ !$0.isEmpty }), Set(normalized).count == names.count else {
            throw SimulationContractError.duplicateOrEmptyName(category)
        }
    }

    private static func orderedFinite(_ values: [Double], allowZero: Bool) -> Bool {
        guard !values.isEmpty, values.allSatisfy({ $0.isFinite && (allowZero ? $0 >= 0 : $0 > 0) }) else {
            return false
        }
        return zip(values, values.dropFirst()).allSatisfy { $0.0 < $0.1 }
    }
}

public enum SimulationContractError: LocalizedError, Equatable {
    case unsupportedResultVersion(Int)
    case duplicateOrEmptyName(String)
    case nonFiniteValue(String)
    case invalidAxis(String)
    case invalidSeries(String)
    case backendDoesNotAcceptCircuitIR(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedResultVersion(let version):
            return "Simulation result contract version \(version) is not supported."
        case .duplicateOrEmptyName(let category):
            return "The backend returned duplicate or empty \(category) names."
        case .nonFiniteValue(let category):
            return "The backend returned a non-finite value in the \(category)."
        case .invalidAxis(let axis):
            return "The backend returned an invalid or unordered \(axis) axis."
        case .invalidSeries(let series):
            return "The backend returned malformed \(series) series."
        case .backendDoesNotAcceptCircuitIR(let identifier):
            return "Backend \(identifier) does not accept OhmLab Circuit IR input."
        }
    }
}
