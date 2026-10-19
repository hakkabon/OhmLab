// RustEngineBackend.swift
// Optional bridge to the Rust simulation core (`ohm-core`).
//
// This file is compiled only when the `CCOhmCore` system-library module is
// available — i.e. after you have built the static library with
// `scripts/build-rust-core.sh` and enabled the `CCOhmCore` target + dependency
// in Package.swift (see README.md, "Rust core"). By default nothing here is
// compiled and the native Swift engine is the sole backend.
//
// The bridge marshals a netlist to the C entry point `ohm_solve`, which returns
// a JSON document, and decodes it into the same `CircuitSimResult` the native
// engine produces. No generated bindings are required.

#if canImport(CCOhmCore)
import CCOhmCore
import Foundation

/// A `SimulationEngineBackend` backed by the Rust `ohm-core` MNA engine.
///
/// Scope note: the Rust core implements DC operating points and AC sweeps for
/// linear R/C/L/V/I circuits. Unsupported analyses (transient, DC sweeps, model
/// libraries, nonlinear devices) are reported as warnings rather than silently
/// dropped; use the native engine for the full feature set.
struct RustEngineBackend: SimulationEngineBackend {
    let identifier = "ohm-core"

    /// The Rust core version reported by the library, e.g. `"ohm-core 0.1.0"`.
    var engineVersion: String {
        guard let ptr = ohm_engine_version() else { return "ohm-core" }
        return String(cString: ptr)
    }

    // The schematic path uses the protocol's default implementation
    // (snapshot → netlist → solve(netlist:)).

    func solve(
        netlist: String,
        settings: AnalysisSettings,
        libraries: [SpiceModelLibrary]
    ) throws -> CircuitSimResult {
        var warnings: [String] = []
        if !libraries.isEmpty {
            warnings.append("ohm-core: model libraries are ignored by the Rust core; only R/C/L/V/I are modeled.")
        }
        if settings.runTransient {
            warnings.append("ohm-core: transient analysis is not supported; only DC and AC were run.")
        }
        if settings.runDCSweep {
            warnings.append("ohm-core: DC sweeps are not supported by the Rust core.")
        }

        var text = netlist
        if settings.runAC {
            // The core reads the standard `.ac` directive; synthesize one from
            // the UI settings.
            text += "\n.ac \(settings.acSweepType.rawValue) \(settings.acPointsPerDecade) "
            text += "\(settings.acStartFrequency) \(settings.acStopFrequency)\n"
        }

        let payload = try run(text)
        warnings.insert(contentsOf: payload.warnings, at: 0)
        return payload.makeResult(runDC: settings.runDC, runAC: settings.runAC, extraWarnings: warnings)
    }

    // MARK: - FFI

    private func run(_ netlist: String) throws -> Payload {
        var outPointer: UnsafeMutablePointer<CChar>?
        let status = netlist.withCString { cString in
            ohm_solve(cString, &outPointer)
        }
        guard status == 0, let raw = outPointer else {
            throw RustEngineError.solveFailed(status: Int(status))
        }
        defer { ohm_free_string(raw) }
        let json = String(cString: raw)
        guard let data = json.data(using: .utf8) else {
            throw RustEngineError.invalidPayload
        }
        return try JSONDecoder().decode(Payload.self, from: data)
    }

    // MARK: - Wire format

    /// The JSON document returned by `ohm_solve`.
    private struct Payload: Decodable {
        let engine: String
        let warnings: [String]
        let dc: DCDTO?
        let ac: ACDTO?

        func makeResult(runDC: Bool, runAC: Bool, extraWarnings: [String]) -> CircuitSimResult {
            let dcResult = (runDC ? dc : nil).map { dto in
                CircuitSimResult.DCResult(
                    nodes: dto.nodes.map { ($0.name, $0.voltage) },
                    components: dto.components.map { ($0.name, $0.voltage, $0.current) },
                    sources: dto.sources.map { ($0.name, $0.current) },
                    converged: dto.converged
                )
            }
            let acResult = (runAC ? ac : nil).map { dto in
                CircuitSimResult.ACResult(
                    frequencies: dto.frequencies,
                    nodes: dto.nodes.map { ($0.name, $0.response.map(\.freqPoint)) },
                    components: dto.components.map { ($0.name, $0.response.map(\.freqPoint)) }
                )
            }
            return CircuitSimResult(
                dc: dcResult,
                ac: acResult,
                transient: nil,
                sweep: nil,
                fourier: [],
                warnings: extraWarnings
            )
        }
    }

    private struct NamedVoltage: Decodable {
        let name: String
        let voltage: Double
    }

    private struct ComponentDTO: Decodable {
        let name: String
        let voltage: Double
        let current: Double
    }

    private struct SourceDTO: Decodable {
        let name: String
        let current: Double
    }

    private struct DCDTO: Decodable {
        let converged: Bool
        let nodes: [NamedVoltage]
        let components: [ComponentDTO]
        let sources: [SourceDTO]
    }

    private struct FreqDTO: Decodable {
        let freqHz: Double
        let magnitudeDb: Double
        let phaseDeg: Double
        var freqPoint: FreqPoint {
            FreqPoint(freqHz: freqHz, magnitudeDb: magnitudeDb, phaseDeg: phaseDeg)
        }
    }

    private struct ResponseDTO: Decodable {
        let name: String
        let response: [FreqDTO]
    }

    private struct ACDTO: Decodable {
        let frequencies: [Double]
        let nodes: [ResponseDTO]
        let components: [ResponseDTO]
    }

    private enum RustEngineError: LocalizedError {
        case solveFailed(status: Int)
        case invalidPayload

        var errorDescription: String? {
            switch self {
            case .solveFailed(let status):
                return "The Rust engine (ohm-core) failed with status \(status)."
            case .invalidPayload:
                return "The Rust engine returned a result that could not be decoded."
            }
        }
    }
}
#endif
