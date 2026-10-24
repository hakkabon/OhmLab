// EngineClient.swift
// The Swift-side circuit engine.
//
// The first milestone requires that displayed plots come from an analysis of
// the actual schematic, so this is a real solver: the schematic (or a parsed
// netlist) is projected into a linear MNA circuit and solved for AC and DC.
// There is no demonstration data on this path.

import Foundation

public struct FreqPoint: Identifiable, Sendable {
    public var id: Double { freqHz }
    public let freqHz: Double
    public let magnitudeDb: Double
    public let phaseDeg: Double

    public init(freqHz: Double, magnitudeDb: Double, phaseDeg: Double) {
        self.freqHz = freqHz
        self.magnitudeDb = magnitudeDb
        self.phaseDeg = phaseDeg
    }
}

public struct CircuitSimResult: Sendable {
    /// Version of the units, naming, and sign convention contract obeyed by
    /// this result. Backends must emit the current version.
    public let contractVersion: Int
    public let dc: DCResult?
    public let ac: ACResult?
    public let transient: TransientResult?
    /// A DC sweep (from a `.dc` card, a `.step param`, or the sweep settings),
    /// with one operating point per swept combination.
    public var sweep: SweepResult?
    /// Fourier components of a transient waveform, from a `.four` card.
    public var fourier: [FourierResult]
    public var warnings: [String]

    public init(
        contractVersion: Int = SimulationResultContract.currentVersion,
        dc: DCResult?,
        ac: ACResult?,
        transient: TransientResult?,
        sweep: SweepResult?,
        fourier: [FourierResult],
        warnings: [String]
    ) {
        self.contractVersion = contractVersion
        self.dc = dc
        self.ac = ac
        self.transient = transient
        self.sweep = sweep
        self.fourier = fourier
        self.warnings = warnings
    }

    /// The Fourier spectrum of one transient signal for a `.four` request.
    public struct FourierResult: Sendable {
        public let variable: String
        public let fundamentalFrequency: Double
        public let spectrum: FourierAnalysis.Result

        public init(variable: String, fundamentalFrequency: Double, spectrum: FourierAnalysis.Result) {
            self.variable = variable
            self.fundamentalFrequency = fundamentalFrequency
            self.spectrum = spectrum
        }
    }

    public struct DCResult: Sendable {
        public let nodes: [(name: String, voltage: Double)]
        /// Per-element operating point: voltage drop (nodeA - nodeB) and current
        /// flowing from nodeA to nodeB.
        public let components: [(name: String, voltage: Double, current: Double)]
        public let sources: [(name: String, current: Double)]
        public let converged: Bool

        public init(
            nodes: [(name: String, voltage: Double)],
            components: [(name: String, voltage: Double, current: Double)],
            sources: [(name: String, current: Double)],
            converged: Bool
        ) {
            self.nodes = nodes
            self.components = components
            self.sources = sources
            self.converged = converged
        }
    }

    /// One independent axis of a DC sweep and its sampled values.
    public struct SweepAxis: Sendable {
        public let name: String
        public let values: [Double]

        public init(name: String, values: [Double]) {
            self.name = name
            self.values = values
        }
    }

    /// A single operating point within a sweep. `coordinates` holds one value
    /// per axis, ordered the same as `SweepResult.axes`.
    public struct SweepPoint: Sendable {
        public let coordinates: [(name: String, value: Double)]
        public let nodes: [(name: String, voltage: Double)]
        public let components: [(name: String, voltage: Double, current: Double)]

        public init(
            coordinates: [(name: String, value: Double)],
            nodes: [(name: String, voltage: Double)],
            components: [(name: String, voltage: Double, current: Double)]
        ) {
            self.coordinates = coordinates
            self.nodes = nodes
            self.components = components
        }
    }

    public struct SweepResult: Sendable {
        /// Sweep dimensions, outermost first. The last axis is the innermost and
        /// forms the plot's X axis; the others select the curves.
        public let axes: [SweepAxis]
        public let points: [SweepPoint]

        public init(axes: [SweepAxis], points: [SweepPoint]) {
            self.axes = axes
            self.points = points
        }
    }

    public struct ACResult: Sendable {
        public let frequencies: [Double]
        public let nodes: [(name: String, response: [FreqPoint])]
        /// Per-element current sweep, in the same units as the element.
        public let components: [(name: String, response: [FreqPoint])]

        public init(
            frequencies: [Double],
            nodes: [(name: String, response: [FreqPoint])],
            components: [(name: String, response: [FreqPoint])]
        ) {
            self.frequencies = frequencies
            self.nodes = nodes
            self.components = components
        }
    }

    public struct TransientResult: Sendable {
        public let times: [Double]
        /// Node voltage waveform, sharing the `times` axis.
        public let nodes: [(name: String, values: [Double])]
        /// Per-element current waveform, sharing the `times` axis.
        public let components: [(name: String, values: [Double])]

        public init(
            times: [Double],
            nodes: [(name: String, values: [Double])],
            components: [(name: String, values: [Double])]
        ) {
            self.times = times
            self.nodes = nodes
            self.components = components
        }
    }
}

public enum CircuitSimulationError: LocalizedError {
    case emptyNetlist
    case noAnalysisSelected
    case invalidACSettings
    case invalidTransientSettings
    case invalidDCSweepSettings
    case unknownSweepSource(String)
    case tooManySamples
    case missingGround
    case acSolveFailed(frequency: Double, reason: String)
    case unstableResult

    public var errorDescription: String? {
        switch self {
        case .emptyNetlist:
            return "Enter a SPICE netlist before running the simulation."
        case .noAnalysisSelected:
            return "Select at least one analysis type (DC, AC, transient, or a DC sweep)."
        case .invalidACSettings:
            return "AC start frequency, stop frequency, and sweep points must define a valid positive sweep."
        case .invalidTransientSettings:
            return "Transient step, stop time, and start time must define a valid, sufficiently small run."
        case .invalidDCSweepSettings:
            return "The DC sweep start, stop, and step must define a valid range."
        case .unknownSweepSource(let name):
            return "The DC sweep targets \"\(name)\", but no source with that name exists."
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

// MARK: - Engine backend façade

/// A pluggable circuit-simulation backend. The built-in `NativeMNAEngine` is the
/// default; alternative cores (for example the Rust `audio-spice-core` linked
/// via the `CCOhmCore` module) can be registered at launch and swapped in
/// without touching any call site.
public protocol SimulationEngineBackend: Sendable {
    /// A stable, human-readable identifier (surfaced in diagnostics and the CLI).
    var identifier: String { get }

    /// Release status at the stable product boundary. Full-production and
    /// linear-production are separate promises.
    var maturity: SimulationBackendMaturity { get }

    /// Whether this backend is supported or retained only for migration.
    var lifecycle: SimulationBackendLifecycle { get }
    var deprecationMessage: String? { get }
    var removalVersion: String? { get }

    /// Backend implementation version, independent of the wire contracts.
    var implementationVersion: String? { get }

    /// Machine-readable support declaration. The default is deliberately
    /// empty so existing third-party backends fail closed until they declare
    /// their contract.
    var capabilities: SimulationBackendCapabilities { get }

    /// Solves a schematic snapshot.
    func solve(snapshot: SchematicSnapshot, settings: AnalysisSettings) throws -> CircuitSimResult

    /// Solves a SPICE netlist, optionally seeding model libraries.
    func solve(netlist: String, settings: AnalysisSettings, libraries: [SpiceModelLibrary]) throws -> CircuitSimResult

    /// Solves a normalized Circuit IR v1 request without reparsing SPICE.
    func solve(circuit: CircuitIR, settings: AnalysisSettings) throws -> CircuitSimResult
}

public extension SimulationEngineBackend {
    var maturity: SimulationBackendMaturity { .external }
    var lifecycle: SimulationBackendLifecycle { .supported }
    var deprecationMessage: String? { nil }
    var removalVersion: String? { nil }
    var implementationVersion: String? { nil }

    var capabilities: SimulationBackendCapabilities {
        .unspecified(backendIdentifier: identifier)
    }

    /// Default schematic path for foreign backends: project the schematic to a
    /// netlist and hand that to the netlist entry point. The built-in engine
    /// overrides this with a direct MNA compile.
    func solve(snapshot: SchematicSnapshot, settings: AnalysisSettings) throws -> CircuitSimResult {
        let netlist = try SpiceNetlistBuilder.build(snapshot: snapshot)
        return try solve(netlist: netlist, settings: settings, libraries: [])
    }

    func solve(circuit: CircuitIR, settings: AnalysisSettings) throws -> CircuitSimResult {
        throw SimulationContractError.backendDoesNotAcceptCircuitIR(identifier)
    }
}

/// Process-wide registry holding the active engine backend.
final class EngineBackendRegistry: @unchecked Sendable {
    static let shared = EngineBackendRegistry()

    private let lock = NSLock()
    private var overrideBackend: (any SimulationEngineBackend)?
    private let defaultBackend: any SimulationEngineBackend = NativeMNAEngine()

    private init() {}

    var active: any SimulationEngineBackend {
        lock.lock(); defer { lock.unlock() }
        return overrideBackend ?? defaultBackend
    }

    func register(_ backend: any SimulationEngineBackend, makeDefault: Bool) {
        lock.lock(); defer { lock.unlock() }
        if makeDefault { overrideBackend = backend }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        overrideBackend = nil
    }
}

/// The engine façade. Call sites stay the same — `SimulationEngine.solve(…)`
/// dispatches to whichever backend is registered (the native Swift MNA engine by
/// default).
public enum SimulationEngine {
    public static let defaultBackendIdentifier = "native-mna"

    /// The identifier of the backend currently in use.
    public static var backendIdentifier: String { EngineBackendRegistry.shared.active.identifier }

    /// Capabilities declared by the backend currently receiving solves.
    public static var backendCapabilities: SimulationBackendCapabilities {
        EngineBackendRegistry.shared.active.capabilities
    }

    /// Registers `backend`; pass `makeDefault: true` to route all solves to it.
    public static func register(_ backend: any SimulationEngineBackend, makeDefault: Bool = false) {
        EngineBackendRegistry.shared.register(backend, makeDefault: makeDefault)
    }

    /// Registers a backend only after validating its production-boundary
    /// declaration. Front ends should prefer this over unchecked registration.
    public static func registerValidated(
        _ backend: any SimulationEngineBackend,
        makeDefault: Bool = false
    ) throws {
        try ProductionBoundary.requireValid(backend)
        EngineBackendRegistry.shared.register(backend, makeDefault: makeDefault)
    }

    /// Restores the built-in native engine as the active backend.
    public static func resetToDefaultBackend() {
        EngineBackendRegistry.shared.reset()
    }

    public static func solve(
        snapshot: SchematicSnapshot,
        settings: AnalysisSettings
    ) throws -> CircuitSimResult {
        let backend = EngineBackendRegistry.shared.active
        try ProductionBoundary.requireValid(backend)
        let raw = try backend.solve(snapshot: snapshot, settings: settings)
        let processed = PluginManager.shared.processResult(
            raw,
            context: SimulationPostContext(source: "schematic", engine: backend.identifier)
        )
        try ProductionBoundary.validate(raw: raw, processed: processed)
        return processed
    }

    public static func solve(
        netlist: String,
        settings: AnalysisSettings,
        libraries: [SpiceModelLibrary] = []
    ) throws -> CircuitSimResult {
        // Netlist processors run before the backend sees the text, so a plugin
        // can macro-expand custom devices into supported primitives.
        let processed = try PluginManager.shared.processNetlist(netlist)
        let backend = EngineBackendRegistry.shared.active
        try ProductionBoundary.requireValid(backend)
        let raw = try backend.solve(
            netlist: processed,
            settings: settings,
            libraries: libraries
        )
        let result = PluginManager.shared.processResult(
            raw,
            context: SimulationPostContext(source: "netlist", engine: backend.identifier)
        )
        try ProductionBoundary.validate(raw: raw, processed: result)
        return result
    }


    public static func solve(
        circuit: CircuitIR,
        settings: AnalysisSettings
    ) throws -> CircuitSimResult {
        try circuit.validate()
        let backend = EngineBackendRegistry.shared.active
        try ProductionBoundary.requireValid(backend)
        let raw = try backend.solve(circuit: circuit, settings: settings)
        let processed = PluginManager.shared.processResult(
            raw,
            context: SimulationPostContext(source: "circuit-ir", engine: backend.identifier)
        )
        try ProductionBoundary.validate(raw: raw, processed: processed)
        return processed
    }
}

/// The built-in, pure-Swift modified-nodal-analysis engine — the default backend
/// and the reference implementation.
struct NativeMNAEngine: SimulationEngineBackend {
    let identifier = "native-mna"
    let maturity: SimulationBackendMaturity = .production
    let implementationVersion: String? = OhmLabRelease.version

    let capabilities = SimulationBackendCapabilities(
        backendIdentifier: "native-mna",
        analyses: SimulationAnalysisKind.allCases,
        devices: CircuitIR.DeviceKind.allCases,
        features: SimulationBackendFeature.allCases
    )

    // MARK: - Schematic path

    func solve(
        snapshot: SchematicSnapshot,
        settings: AnalysisSettings
    ) throws -> CircuitSimResult {
        let circuit = try CircuitCompiler.compile(snapshot: snapshot)
        let axes = try Self.sweepAxes(from: settings)
        return try Self.solve(circuit: circuit, settings: settings, sweepAxes: axes)
    }

    func solve(circuit ir: CircuitIR, settings: AnalysisSettings) throws -> CircuitSimResult {
        let circuit = try ir.makeLinearCircuit()
        let axes = try Self.sweepAxes(from: settings)
        return try Self.solve(
            circuit: circuit,
            settings: settings,
            initialConditions: ir.nativeInitialConditions,
            sweepAxes: axes
        )
    }

    // MARK: - Netlist path

    func solve(
        netlist: String,
        settings: AnalysisSettings,
        libraries: [SpiceModelLibrary] = []
    ) throws -> CircuitSimResult {
        guard !netlist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CircuitSimulationError.emptyNetlist
        }
        let include = SpiceLibraryManager(libraries: libraries).includeResolver()
        let parsed = try SpiceNetlistParser.parse(netlist, include: include, libraries: libraries)

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
        if parsed.analysis.hasTransient {
            effective.runTransient = settings.runTransient || parsed.analysis.hasTransient
            if settings.tranStep == AnalysisSettings.default.tranStep,
               settings.tranStop == AnalysisSettings.default.tranStop {
                effective.tranStep = parsed.analysis.tranStep
                effective.tranStop = parsed.analysis.tranStop
                effective.tranStart = parsed.analysis.tranStart
            }
        }

        // Sweep axes: a `.dc` card wins; otherwise the UI settings may request
        // one. A `.step param` is handled separately by re-parsing per value.
        var axes = parsed.analysis.dcSweep
        if axes.isEmpty {
            axes = try Self.sweepAxes(from: settings)
        }
        if let step = parsed.analysis.step {
            // The stepped parameter is exposed by re-parsing; run the base
            // analyses without a sweep so the step runner owns the result.
            var result = try Self.solve(
                circuit: parsed.circuit,
                settings: effective,
                initialConditions: parsed.initialConditions,
                fourierSpecs: parsed.analysis.fourier
            )
            result.sweep = try Self.runParameterStep(
                netlist: netlist,
                step: step,
                axes: axes,
                settings: effective,
                libraries: libraries
            )
            if effective.runAC || effective.runTransient {
                result.warnings.append(
                    "STEP applies only to DC analyses here; AC and transient were run once at the un-stepped value."
                )
            }
            result.warnings.insert(contentsOf: parsed.warnings, at: 0)
            return result
        }

        var result = try Self.solve(
            circuit: parsed.circuit,
            settings: effective,
            initialConditions: parsed.initialConditions,
            sweepAxes: axes,
            fourierSpecs: parsed.analysis.fourier
        )
        result.warnings.insert(contentsOf: parsed.warnings, at: 0)
        return result
    }

    /// Builds the DC sweep axes requested through `AnalysisSettings`.
    private static func sweepAxes(from settings: AnalysisSettings) throws -> [SpiceSweepAxis] {
        guard settings.runDCSweep, !settings.dcSweepSource.isEmpty else { return [] }
        let values = SpiceNetlistParser.linearSweep(
            from: settings.dcSweepStart,
            to: settings.dcSweepStop,
            step: settings.dcSweepStep
        )
        guard !values.isEmpty else { throw CircuitSimulationError.invalidDCSweepSettings }
        return [SpiceSweepAxis(name: settings.dcSweepSource, values: values)]
    }

    // MARK: - Common solve

    private static func solve(
        circuit: LinearCircuit,
        settings: AnalysisSettings,
        initialConditions: InitialConditions = InitialConditions(),
        sweepAxes: [SpiceSweepAxis] = [],
        fourierSpecs: [SpiceFourierSpec] = []
    ) throws -> CircuitSimResult {
        guard settings.runDC || settings.runAC || settings.runTransient || !sweepAxes.isEmpty else {
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
                try Task.checkCancellation()
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

        var transientResult: CircuitSimResult.TransientResult?
        if settings.runTransient {
            guard settings.tranStep > 0,
                  settings.tranStep.isFinite,
                  settings.tranStop > settings.tranStart,
                  settings.tranStart >= 0 else {
                throw CircuitSimulationError.invalidTransientSettings
            }
            let solver = TransientSolver(circuit: circuit, timestep: settings.tranStep)
            let raw: TransientSolver.Result
            do {
                raw = try solver.run(
                    startTime: settings.tranStart,
                    stopTime: settings.tranStop,
                    maxSteps: FrequencySweep.maxPointCount,
                    initialConditions: initialConditions
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw CircuitSimulationError.invalidTransientSettings
            }
            for series in raw.nodeSeries {
                for value in series where !value.isFinite {
                    throw CircuitSimulationError.unstableResult
                }
            }
            transientResult = CircuitSimResult.TransientResult(
                times: raw.times,
                nodes: (1..<circuit.nodeCount).map { node in
                    (circuit.nodeNames[node], raw.nodeSeries[node])
                },
                components: circuit.elements.enumerated().map { index, element in
                    (element.name, raw.componentSeries[index])
                }
            )
        }

        var sweepResult: CircuitSimResult.SweepResult?
        if !sweepAxes.isEmpty {
            let totalPoints = sweepAxes.reduce(1) { $0 * $1.values.count }
            guard totalPoints > 0, totalPoints <= FrequencySweep.maxPointCount else {
                throw CircuitSimulationError.tooManySamples
            }
            sweepResult = try runDCSweep(circuit: circuit, axes: sweepAxes)
        }

        var fourierResults: [CircuitSimResult.FourierResult] = []
        if !fourierSpecs.isEmpty {
            if let transient = transientResult {
                for spec in fourierSpecs {
                    for variable in spec.variables {
                        try Task.checkCancellation()
                        guard let values = fourierSeries(
                            variable,
                            transient: transient
                        ) else {
                            warnings.append(
                                "Fourier: \"\(variable)\" is not a known node or element."
                            )
                            continue
                        }
                        guard let spectrum = FourierAnalysis.analyze(
                            times: transient.times,
                            values: values,
                            fundamentalFrequency: spec.frequency
                        ) else {
                            warnings.append(
                                "Fourier: not enough transient data to analyze "
                                + "\"\(variable)\" at \(String(format: "%.6g", spec.frequency)) Hz."
                            )
                            continue
                        }
                        fourierResults.append(CircuitSimResult.FourierResult(
                            variable: variable,
                            fundamentalFrequency: spec.frequency,
                            spectrum: spectrum
                        ))
                    }
                }
            } else {
                warnings.append("Fourier: a `.four` card needs a transient analysis (`.tran`) to run.")
            }
        }

        return CircuitSimResult(
            dc: dcResult,
            ac: acResult,
            transient: transientResult,
            sweep: sweepResult,
            fourier: fourierResults,
            warnings: warnings
        )
    }

    /// Resolves a `.four` variable (`v(node)`, `i(element)`, or a bare node name)
    /// to the matching transient waveform.
    private static func fourierSeries(
        _ variable: String,
        transient: CircuitSimResult.TransientResult
    ) -> [Double]? {
        let trimmed = variable.trimmingCharacters(in: .whitespaces)
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("v("), lowered.hasSuffix(")") {
            let name = String(trimmed.dropFirst(2).dropLast())
            return transient.nodes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.values
        }
        if lowered.hasPrefix("i("), lowered.hasSuffix(")") {
            let name = String(trimmed.dropFirst(2).dropLast())
            return transient.components.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.values
        }
        return transient.nodes.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }?.values
    }

    // MARK: - DC sweep

    /// Runs a (possibly nested) DC sweep, returning one operating point per
    /// combination of axis values. The first axis varies slowest.
    private static func runDCSweep(
        circuit: LinearCircuit,
        axes: [SpiceSweepAxis]
    ) throws -> CircuitSimResult.SweepResult {
        let sources = Set(circuit.sourceNames.map { $0.uppercased() })
        // `.dc` axes must name an existing source; step axes are parameters and
        // are resolved by re-parsing, so they contribute no override here.
        for axis in axes where !sources.contains(axis.name.uppercased()) {
            // Only complain when this looks like a `.dc` source sweep: a step
            // parameter is passed in with a name that is not a source either, so
            // callers distinguish them by only including `.dc` axes here.
            throw CircuitSimulationError.unknownSweepSource(axis.name)
        }
        var combinations: [[Double]] = [[]]
        for axis in axes {
            combinations = combinations.flatMap { prefix in
                axis.values.map { prefix + [$0] }
            }
        }
        var points: [CircuitSimResult.SweepPoint] = []
        for combination in combinations {
            try Task.checkCancellation()
            var overrides: [String: Double] = [:]
            for (axis, value) in zip(axes, combination) {
                overrides[axis.name] = value
            }
            let solution = try circuit.solveDC(sourceOverrides: overrides)
            try assertFinite(solution)
            points.append(makeSweepPoint(
                circuit: circuit,
                axes: axes,
                coordinates: combination,
                solution: solution
            ))
        }
        return CircuitSimResult.SweepResult(
            axes: axes.map { CircuitSimResult.SweepAxis(name: $0.name, values: $0.values) },
            points: points
        )
    }

    /// Runs a `.step param` sweep, re-parsing the netlist once per value so the
    /// parameter reaches element values as well as sources. Any `.dc` axes are
    /// nested inside each step value.
    private static func runParameterStep(
        netlist: String,
        step: SpiceStepSpec,
        axes: [SpiceSweepAxis],
        settings: AnalysisSettings,
        libraries: [SpiceModelLibrary]
    ) throws -> CircuitSimResult.SweepResult {
        var points: [CircuitSimResult.SweepPoint] = []
        let stepAxis = SpiceSweepAxis(name: step.parameter, values: step.values)
        let allAxes = [stepAxis] + axes
        let totalPoints = allAxes.reduce(1) { $0 * $1.values.count }
        guard totalPoints > 0, totalPoints <= FrequencySweep.maxPointCount else {
            throw CircuitSimulationError.tooManySamples
        }
        var innerCombinations: [[Double]] = [[]]
        for axis in axes {
            innerCombinations = innerCombinations.flatMap { prefix in
                axis.values.map { prefix + [$0] }
            }
        }
        for stepValue in step.values {
            try Task.checkCancellation()
            let parsed = try SpiceNetlistParser.parse(
                netlist,
                parameterOverrides: step.isTemperature ? [:] : [step.parameter: stepValue],
                libraries: libraries
            )
            var circuit = parsed.circuit
            if step.isTemperature {
                circuit.solverOptions.temperatureCelsius = stepValue
            }
            let sources = Set(circuit.sourceNames.map { $0.uppercased() })
            for axis in axes where !sources.contains(axis.name.uppercased()) {
                throw CircuitSimulationError.unknownSweepSource(axis.name)
            }
            for inner in innerCombinations {
                try Task.checkCancellation()
                var overrides: [String: Double] = [:]
                for (axis, value) in zip(axes, inner) {
                    overrides[axis.name] = value
                }
                let solution = try circuit.solveDC(sourceOverrides: overrides)
                try assertFinite(solution)
                points.append(makeSweepPoint(
                    circuit: circuit,
                    axes: allAxes,
                    coordinates: [stepValue] + inner,
                    solution: solution
                ))
            }
        }
        return CircuitSimResult.SweepResult(
            axes: allAxes.map { CircuitSimResult.SweepAxis(name: $0.name, values: $0.values) },
            points: points
        )
    }

    private static func makeSweepPoint(
        circuit: LinearCircuit,
        axes: [SpiceSweepAxis],
        coordinates: [Double],
        solution: LinearCircuit.Solution
    ) -> CircuitSimResult.SweepPoint {
        let labels = zip(axes, coordinates).map { (name: $0.name, value: $1) }
        let nodes = (1..<circuit.nodeCount).map { node in
            (circuit.nodeNames[node], solution.nodeVoltages[node].re)
        }
        let components = circuit.elements.enumerated().map { index, element in
            let voltage = solution.nodeVoltages[element.nodeA] - solution.nodeVoltages[element.nodeB]
            return (element.name, voltage.re, solution.elementCurrents[index].re)
        }
        return CircuitSimResult.SweepPoint(
            coordinates: labels,
            nodes: nodes,
            components: components
        )
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
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try SimulationEngine.solve(snapshot: snapshot, settings: settings)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    func simulate(
        netlist: String,
        settings: AnalysisSettings,
        libraries: [SpiceModelLibrary] = []
    ) async throws -> CircuitSimResult {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try SimulationEngine.solve(netlist: netlist, settings: settings, libraries: libraries)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
