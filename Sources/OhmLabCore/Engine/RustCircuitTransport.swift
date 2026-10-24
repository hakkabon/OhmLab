import Foundation

/// Stable JSON envelope used to move Circuit IR v1 across the Swift/Rust ABI.
/// The transport version evolves independently from both Circuit IR and the
/// simulation-result contract, so either side can reject incompatible peers.
public enum RustCircuitTransport {
    public static let currentVersion = 1

    public struct Request: Codable, Equatable, Sendable {
        public var transportVersion: Int
        public var circuit: CircuitIR
        public var analysis: Analysis

        public init(circuit: CircuitIR, settings: AnalysisSettings) throws {
            try circuit.validate()
            if settings.runTransient {
                throw RustCircuitTransportError.unsupportedAnalysis("transient analysis")
            }
            if settings.runDCSweep {
                throw RustCircuitTransportError.unsupportedAnalysis("DC or parameter sweeps")
            }
            let supported: Set<CircuitIR.DeviceKind> = [
                .resistor, .capacitor, .inductor, .voltageSource, .currentSource,
            ]
            if let device = circuit.devices.first(where: { !supported.contains($0.kind) }) {
                throw RustCircuitTransportError.unsupportedDevice(device.name)
            }
            guard settings.runDC || settings.runAC else {
                throw CircuitSimulationError.noAnalysisSelected
            }
            let ac: ACSweep?
            if settings.runAC {
                let count = FrequencySweep.pointCount(
                    from: settings.acStartFrequency,
                    to: settings.acStopFrequency,
                    count: settings.acPointsPerDecade,
                    type: settings.acSweepType
                )
                guard count > 0, count <= FrequencySweep.maxPointCount else {
                    throw CircuitSimulationError.invalidACSettings
                }
                ac = ACSweep(
                    sweepType: settings.acSweepType,
                    startFrequency: settings.acStartFrequency,
                    stopFrequency: settings.acStopFrequency,
                    pointCount: settings.acPointsPerDecade
                )
            } else {
                ac = nil
            }
            transportVersion = RustCircuitTransport.currentVersion
            self.circuit = circuit
            analysis = Analysis(runDC: settings.runDC, ac: ac)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let version = try container.decode(Int.self, forKey: .transportVersion)
            guard version == RustCircuitTransport.currentVersion else {
                throw RustCircuitTransportError.unsupportedTransportVersion(version)
            }
            transportVersion = version
            circuit = try container.decode(CircuitIR.self, forKey: .circuit)
            analysis = try container.decode(Analysis.self, forKey: .analysis)
        }

        private enum CodingKeys: String, CodingKey {
            case transportVersion, circuit, analysis
        }
    }

    public struct Analysis: Codable, Equatable, Sendable {
        public var runDC: Bool
        public var ac: ACSweep?
    }

    public struct ACSweep: Codable, Equatable, Sendable {
        public var sweepType: FrequencySweepType
        public var startFrequency: Double
        public var stopFrequency: Double
        /// Points per decade/octave, or total points for a linear sweep.
        public var pointCount: Int
    }
}

public enum RustCircuitTransportError: LocalizedError, Equatable {
    case unsupportedTransportVersion(Int)
    case unsupportedAnalysis(String)
    case unsupportedDevice(String)
    case rejected([String])
    case incompatibleResult(expectedTransport: Int, actualTransport: Int?)

    public var errorDescription: String? {
        switch self {
        case .unsupportedTransportVersion(let version):
            return "Rust circuit transport version \(version) is not supported."
        case .unsupportedAnalysis(let analysis):
            return "The Rust circuit transport does not support \(analysis)."
        case .unsupportedDevice(let name):
            return "The Rust circuit transport does not support device \(name)."
        case .rejected(let errors):
            return "The Rust circuit engine rejected the request: \(errors.joined(separator: "; "))"
        case .incompatibleResult(let expected, let actual):
            return "The Rust circuit engine returned transport version \(actual.map(String.init) ?? "missing"); expected \(expected)."
        }
    }
}
