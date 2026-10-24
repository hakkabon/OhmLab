// RustEngineBackend.swift
// Optional bridge to the Rust simulation core (`ohm-core`).
//
// This file is compiled only when the `CCOhmCore` system-library module is
// available: run `scripts/build-rust-core.sh`, then set `OHMLAB_RUST_CORE=1`
// for the Swift build. By default nothing here is compiled and the native Swift
// engine is the sole backend.
//
// The bridge marshals Circuit IR v1 through `ohm_solve_circuit_ir`, which
// returns a versioned JSON result. The older netlist ABI remains available to
// external callers but is no longer the backend's internal solver boundary.

#if canImport(CCOhmCore)
import CCOhmCore
import Foundation

/// A `SimulationEngineBackend` backed by the Rust `ohm-core` MNA engine.
///
/// Scope note: the Rust core implements DC, AC, and transient analysis for
/// linear R/C/L/V/I circuits. Unsupported analyses and devices fail before the
/// FFI call; use the native engine for the full feature set.
struct RustEngineBackend: SimulationEngineBackend {
    let identifier = "ohm-core"

    let capabilities = SimulationBackendCapabilities(
        backendIdentifier: "ohm-core",
        analyses: [.dcOperatingPoint, .acSmallSignal, .transient],
        devices: [.resistor, .capacitor, .inductor, .voltageSource, .currentSource],
        features: [
            .spiceNetlistInput, .circuitIRInput, .modelLibraries,
            .sourceWaveforms, .initialConditions,
        ]
    )

    /// The Rust core version reported by the library, e.g. `"ohm-core 0.3.0"`.
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
        guard !netlist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CircuitSimulationError.emptyNetlist
        }
        let include = SpiceLibraryManager(libraries: libraries).includeResolver()
        let parsed = try SpiceNetlistParser.parse(netlist, include: include, libraries: libraries)
        var effective = settings
        if parsed.analysis.hasAC {
            effective.runAC = true
            if settings.acStartFrequency == AnalysisSettings.default.acStartFrequency,
               settings.acStopFrequency == AnalysisSettings.default.acStopFrequency {
                effective.acSweepType = parsed.analysis.sweep
                effective.acStartFrequency = parsed.analysis.startFrequency
                effective.acStopFrequency = parsed.analysis.stopFrequency
                effective.acPointsPerDecade = parsed.analysis.points
            }
        }
        if parsed.analysis.hasTransient {
            effective.runTransient = true
            if settings.tranStep == AnalysisSettings.default.tranStep,
               settings.tranStop == AnalysisSettings.default.tranStop {
                effective.tranStep = parsed.analysis.tranStep
                effective.tranStop = parsed.analysis.tranStop
                effective.tranStart = parsed.analysis.tranStart
            }
        }
        if effective.runDCSweep || !parsed.analysis.dcSweep.isEmpty || parsed.analysis.step != nil {
            throw RustCircuitTransportError.unsupportedAnalysis("DC or parameter sweeps")
        }
        if !parsed.analysis.fourier.isEmpty {
            throw RustCircuitTransportError.unsupportedAnalysis("Fourier analysis")
        }
        let ir = try CircuitIR(
            linearCircuit: parsed.circuit,
            initialConditions: parsed.initialConditions
        )
        var result = try solve(circuit: ir, settings: effective)
        result.warnings.insert(contentsOf: parsed.warnings, at: 0)
        return result
    }

    func solve(circuit: CircuitIR, settings: AnalysisSettings) throws -> CircuitSimResult {
        let request = try RustCircuitTransport.Request(circuit: circuit, settings: settings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let requestData = try encoder.encode(request)
        guard let requestJSON = String(data: requestData, encoding: .utf8) else {
            throw RustEngineError.invalidPayload
        }
        let payload = try runCircuitIR(requestJSON)
        guard payload.transportVersion == RustCircuitTransport.currentVersion else {
            throw RustCircuitTransportError.incompatibleResult(
                expectedTransport: RustCircuitTransport.currentVersion,
                actualTransport: payload.transportVersion
            )
        }
        guard payload.contractVersion == SimulationResultContract.currentVersion else {
            throw SimulationContractError.unsupportedResultVersion(payload.contractVersion)
        }
        if !payload.errors.isEmpty { throw RustCircuitTransportError.rejected(payload.errors) }
        let result = payload.makeResult(
            runDC: settings.runDC,
            runAC: settings.runAC,
            runTransient: settings.runTransient,
            extraWarnings: payload.warnings
        )
        try SimulationResultContract.validate(result)
        return result
    }

    // MARK: - FFI

    private func runCircuitIR(_ request: String) throws -> Payload {
        var outPointer: UnsafeMutablePointer<CChar>?
        let status = request.withCString { cString in
            ohm_solve_circuit_ir(cString, &outPointer)
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

    /// The JSON document returned by `ohm_solve_circuit_ir`.
    private struct Payload: Decodable {
        let engine: String
        let contractVersion: Int
        let transportVersion: Int?
        let errors: [String]
        let warnings: [String]
        let dc: DCDTO?
        let ac: ACDTO?
        let transient: TransientDTO?

        func makeResult(
            runDC: Bool,
            runAC: Bool,
            runTransient: Bool,
            extraWarnings: [String]
        ) -> CircuitSimResult {
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
            let transientResult = (runTransient ? transient : nil).map { dto in
                CircuitSimResult.TransientResult(
                    times: dto.times,
                    nodes: dto.nodes.map { ($0.name, $0.values) },
                    components: dto.components.map { ($0.name, $0.values) }
                )
            }
            return CircuitSimResult(
                contractVersion: contractVersion,
                dc: dcResult,
                ac: acResult,
                transient: transientResult,
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

    private struct TimeSeriesDTO: Decodable {
        let name: String
        let values: [Double]
    }

    private struct TransientDTO: Decodable {
        let times: [Double]
        let nodes: [TimeSeriesDTO]
        let components: [TimeSeriesDTO]
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
