import Foundation
import NumericCoreOptimization

public enum NumericCoreAdapterError: LocalizedError, Equatable {
    case unsupportedAnalysis(String)
    case unsupportedElement(String)
    case missingBranch(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedAnalysis(let analysis):
            return "The NumericCore adapter does not support \(analysis) yet."
        case .unsupportedElement(let element):
            return "The NumericCore adapter does not support element \(element) yet."
        case .missingBranch(let element):
            return "NumericCore returned no branch current for \(element)."
        }
    }
}

/// Transitional backend over NumericCore's provisional circuit-analysis API.
///
/// The native engine remains the product default while nonlinear-device,
/// waveform, and advanced-analysis parity are completed. This adapter
/// deliberately fails closed for unsupported features instead of silently
/// returning a partial simulation.
public struct NumericCoreEngineBackend: SimulationEngineBackend {
    public let identifier = "numeric-core"

    public let capabilities = SimulationBackendCapabilities(
        backendIdentifier: "numeric-core",
        analyses: [.dcOperatingPoint, .acSmallSignal, .transient],
        devices: [.resistor, .capacitor, .inductor, .voltageSource, .currentSource],
        features: [.spiceNetlistInput, .circuitIRInput, .modelLibraries, .initialConditions]
    )

    public init() {}

    public func solve(
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
                effective.acStartFrequency = parsed.analysis.startFrequency
                effective.acStopFrequency = parsed.analysis.stopFrequency
                effective.acPointsPerDecade = parsed.analysis.points
                effective.acSweepType = parsed.analysis.sweep
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
            throw NumericCoreAdapterError.unsupportedAnalysis("DC or parameter sweeps")
        }
        if !parsed.analysis.fourier.isEmpty {
            throw NumericCoreAdapterError.unsupportedAnalysis("Fourier analysis")
        }
        guard effective.runDC || effective.runAC else {
            throw CircuitSimulationError.noAnalysisSelected
        }

        let ir = try CircuitIR(linearCircuit: parsed.circuit, initialConditions: parsed.initialConditions)
        var result = try solve(circuit: ir, settings: effective)
        result.warnings.insert(contentsOf: parsed.warnings, at: 0)
        return result
    }

    public func solve(
        circuit ir: CircuitIR,
        settings: AnalysisSettings
    ) throws -> CircuitSimResult {
        if settings.runDCSweep {
            throw NumericCoreAdapterError.unsupportedAnalysis("DC or parameter sweeps")
        }
        guard settings.runDC || settings.runAC || settings.runTransient else {
            throw CircuitSimulationError.noAnalysisSelected
        }

        let unsupported = ir.devices.first { !capabilities.supports($0.kind) }
        if let unsupported { throw NumericCoreAdapterError.unsupportedElement(unsupported.name) }
        let bridge = try Bridge(ir: ir)
        let operating = try bridge.model.dcOperatingPointContinuation()
        let dc = settings.runDC ? try bridge.dcResult(operating) : nil
        let ac = settings.runAC ? try bridge.acResult(operating, settings: settings) : nil
        let transient = settings.runTransient
            ? try bridge.transientResult(operating, settings: settings)
            : nil
        return CircuitSimResult(
            dc: dc,
            ac: ac,
            transient: transient,
            sweep: nil,
            fourier: [],
            warnings: []
        )
    }
}

private extension NumericCoreEngineBackend {
    struct Bridge {
        let circuit: LinearCircuit
        let model: CircuitModel
        let devices: [CircuitDevice]
        let initialConditions: CircuitIR.Conditions

        init(ir: CircuitIR) throws {
            let circuit = try ir.makeLinearCircuit()
            self.circuit = circuit
            initialConditions = ir.initialConditions
            let initialVoltages = Dictionary(
                uniqueKeysWithValues: ir.initialConditions.nodeVoltages.map {
                    ($0.key.lowercased(), $0.value)
                }
            )
            let nodes = circuit.nodeNames.map {
                CircuitNode(name: $0, initialVoltage: initialVoltages[$0.lowercased()] ?? 0)
            }
            let initialCurrents = Dictionary(
                uniqueKeysWithValues: ir.initialConditions.elementCurrents.map {
                    ($0.key.lowercased(), $0.value)
                }
            )
            var mapped: [CircuitDevice] = []
            mapped.reserveCapacity(circuit.elements.count)
            for element in circuit.elements {
                switch element.kind {
                case .resistor:
                    mapped.append(.resistor(
                        name: element.name, positive: element.nodeA,
                        negative: element.nodeB, resistance: element.value
                    ))
                case .capacitor:
                    mapped.append(.capacitor(
                        name: element.name, positive: element.nodeA,
                        negative: element.nodeB, capacitance: element.value
                    ))
                case .inductor:
                    mapped.append(.inductor(
                        name: element.name, positive: element.nodeA,
                        negative: element.nodeB, inductance: element.value,
                        initialCurrent: initialCurrents[element.name.lowercased()] ?? 0
                    ))
                case .currentSource:
                    mapped.append(.currentSource(
                        name: element.name, positive: element.nodeA,
                        negative: element.nodeB,
                        source: try Self.source(element)
                    ))
                case .voltageSource:
                    mapped.append(.voltageSource(
                        name: element.name, positive: element.nodeA,
                        negative: element.nodeB,
                        source: try Self.source(element),
                        initialCurrent: 0
                    ))
                case .diode, .bjt, .mosfet, .jfet:
                    throw NumericCoreAdapterError.unsupportedElement(element.name)
                }
            }
            devices = mapped
            model = try CircuitModel(nodes: nodes, referenceNode: 0, devices: mapped)
        }

        private static func source(_ element: LinearCircuit.Element) throws -> CircuitSource {
            guard let waveform = element.transient else {
                return .dc(element.magnitude(isDC: true))
            }
            let mapped: CircuitWaveform
            switch waveform {
            case .pulse(let initial, let pulsed, let delay, let rise, let fall, let width, let period):
                mapped = .pulse(
                    low: initial, high: pulsed, delay: delay, rise: rise, fall: fall,
                    width: width, period: period
                )
            case .sine(let offset, let amplitude, let frequency, let delay, let damping, let phase):
                guard delay == 0, damping == 0 else {
                    throw NumericCoreAdapterError.unsupportedElement(
                        "\(element.name) (delayed or damped sine waveform)"
                    )
                }
                mapped = .sinusoidal(
                    offset: offset, amplitude: amplitude, frequency: frequency,
                    phase: phase * .pi / 180
                )
            case .pwl:
                throw NumericCoreAdapterError.unsupportedElement(
                    "\(element.name) (piecewise-linear waveform)"
                )
            }
            return .transient(dc: element.magnitude(isDC: true), waveform: mapped)
        }

        func dcResult(_ operating: CircuitOperatingPoint) throws -> CircuitSimResult.DCResult {
            let components = try circuit.elements.map { element in
                let voltage = operating.nodeVoltages[element.nodeA] - operating.nodeVoltages[element.nodeB]
                let current: Double
                switch element.kind {
                case .resistor:
                    current = voltage / element.value
                case .capacitor:
                    current = 0
                case .inductor, .voltageSource:
                    guard let branch = operating.branchCurrents[element.name] else {
                        throw NumericCoreAdapterError.missingBranch(element.name)
                    }
                    current = branch
                case .currentSource:
                    current = element.magnitude(isDC: true)
                case .diode, .bjt, .mosfet, .jfet:
                    throw NumericCoreAdapterError.unsupportedElement(element.name)
                }
                return (element.name, voltage, current)
            }
            let sources = circuit.elements.compactMap { element -> (name: String, current: Double)? in
                guard element.kind == .voltageSource,
                      let current = operating.branchCurrents[element.name] else { return nil }
                return (element.name, current)
            }
            return .init(
                nodes: (1..<circuit.nodeCount).map {
                    (circuit.nodeNames[$0], operating.nodeVoltages[$0])
                },
                components: components,
                sources: sources,
                converged: operating.diagnostics.finite
            )
        }

        func acResult(
            _ operating: CircuitOperatingPoint,
            settings: AnalysisSettings
        ) throws -> CircuitSimResult.ACResult {
            let type = settings.acSweepType
            let estimated = FrequencySweep.pointCount(
                from: settings.acStartFrequency,
                to: settings.acStopFrequency,
                count: settings.acPointsPerDecade,
                type: type
            )
            guard estimated > 0 else { throw CircuitSimulationError.invalidACSettings }
            guard estimated <= FrequencySweep.maxPointCount else {
                throw CircuitSimulationError.tooManySamples
            }
            let frequencies = FrequencySweep.points(
                from: settings.acStartFrequency,
                to: settings.acStopFrequency,
                count: settings.acPointsPerDecade,
                type: type
            )
            guard !frequencies.isEmpty else { throw CircuitSimulationError.invalidACSettings }
            let excitations = circuit.elements.compactMap { element -> CircuitACExcitation? in
                guard element.kind == .voltageSource || element.kind == .currentSource else { return nil }
                let magnitude = element.magnitude(isDC: false)
                guard magnitude != 0 else { return nil }
                return CircuitACExcitation(
                    deviceName: element.name,
                    magnitude: magnitude,
                    phase: element.phaseDegrees * .pi / 180
                )
            }
            guard !excitations.isEmpty else {
                throw NumericCoreAdapterError.unsupportedAnalysis("AC analysis without an AC source")
            }
            let sweep = try model.acAnalysis(
                operatingState: operating.state,
                frequencies: frequencies,
                excitations: excitations
            )

            var nodeSeries = [[FreqPoint]](repeating: [], count: circuit.nodeCount)
            var componentSeries = [[FreqPoint]](repeating: [], count: circuit.elements.count)
            for point in sweep.points {
                try Task.checkCancellation()
                let voltages = try complexNodeVoltages(point)
                for node in 1..<circuit.nodeCount {
                    nodeSeries[node].append(freqPoint(point.frequency, voltages[node]))
                }
                for (index, element) in circuit.elements.enumerated() {
                    let voltage = voltages[element.nodeA] - voltages[element.nodeB]
                    let current: Complex
                    switch element.kind {
                    case .resistor:
                        current = voltage / Complex(element.value, 0)
                    case .capacitor:
                        current = voltage * Complex(0, 2 * .pi * point.frequency * element.value)
                    case .inductor, .voltageSource:
                        guard let unknown = try model.branchUnknownIndex(index) else {
                            throw NumericCoreAdapterError.missingBranch(element.name)
                        }
                        current = complex(point.unknowns[unknown])
                    case .currentSource:
                        current = Complex.fromPolar(
                            magnitude: element.magnitude(isDC: false),
                            phaseDegrees: element.phaseDegrees
                        )
                    case .diode, .bjt, .mosfet, .jfet:
                        throw NumericCoreAdapterError.unsupportedElement(element.name)
                    }
                    componentSeries[index].append(freqPoint(point.frequency, current))
                }
            }
            return .init(
                frequencies: frequencies,
                nodes: (1..<circuit.nodeCount).map { (circuit.nodeNames[$0], nodeSeries[$0]) },
                components: circuit.elements.enumerated().map { ($0.element.name, componentSeries[$0.offset]) }
            )
        }

        func transientResult(
            _ operating: CircuitOperatingPoint,
            settings: AnalysisSettings
        ) throws -> CircuitSimResult.TransientResult {
            guard settings.tranStep.isFinite, settings.tranStep > 0,
                  settings.tranStart.isFinite, settings.tranStart >= 0,
                  settings.tranStop.isFinite, settings.tranStop > settings.tranStart else {
                throw CircuitSimulationError.invalidTransientSettings
            }
            let stepCount = Int(((settings.tranStop - settings.tranStart) / settings.tranStep).rounded(.up))
            guard stepCount > 0 else { throw CircuitSimulationError.invalidTransientSettings }
            guard stepCount <= FrequencySweep.maxPointCount else {
                throw CircuitSimulationError.tooManySamples
            }

            var initial = operating.state
            let nodeOverrides = Dictionary(
                uniqueKeysWithValues: initialConditions.nodeVoltages.map {
                    ($0.key.lowercased(), $0.value)
                }
            )
            for node in circuit.nodeNames.indices {
                if let value = nodeOverrides[circuit.nodeNames[node].lowercased()],
                   let unknown = try model.nodeUnknownIndex(node) {
                    initial[unknown] = value
                }
            }
            let currentOverrides = Dictionary(
                uniqueKeysWithValues: initialConditions.elementCurrents.map {
                    ($0.key.lowercased(), $0.value)
                }
            )
            for (index, element) in circuit.elements.enumerated() {
                if let value = currentOverrides[element.name.lowercased()],
                   let unknown = try model.branchUnknownIndex(index) {
                    initial[unknown] = value
                }
            }

            let zeroDerivative = model.zeroDerivative
            let evaluation = try model.daeEvaluation(
                time: settings.tranStart, state: initial, derivative: zeroDerivative
            )
            let freeState = initial.indices.map { column in
                evaluation.jacobianDerivative.allSatisfy {
                    abs($0[column]) <= Double.ulpOfOne
                }
            }
            let consistent = try TimeIntegrator.consistentDAEInitialConditions(
                time: settings.tranStart,
                initialState: initial,
                initialDerivative: zeroDerivative,
                freeState: freeState,
                maxIterations: circuit.solverOptions.maximumIterations,
                tolerance: circuit.solverOptions.absoluteVoltageTolerance
            ) { time, state, derivative in
                try model.daeEvaluation(time: time, state: state, derivative: derivative)
            }
            let integrationEnd = settings.tranStart + Double(stepCount) * settings.tranStep
            let integrated = try model.transient(
                from: settings.tranStart,
                to: integrationEnd,
                initialState: consistent.state,
                initialDerivative: consistent.derivative,
                options: TimeIntegrationOptions(
                    absoluteTolerance: circuit.solverOptions.absoluteVoltageTolerance,
                    relativeTolerance: circuit.solverOptions.relativeTolerance,
                    initialStep: settings.tranStep,
                    minimumStep: max(settings.tranStep * 1e-9, 1e-15),
                    maximumStep: settings.tranStep,
                    maxSteps: FrequencySweep.maxPointCount,
                    maxNewtonIterations: circuit.solverOptions.maximumIterations,
                    newtonTolerance: circuit.solverOptions.absoluteVoltageTolerance
                )
            )
            guard integrated.termination == .reachedEnd else {
                throw CircuitSimulationError.invalidTransientSettings
            }

            let times = (0...stepCount).map {
                settings.tranStart + Double($0) * settings.tranStep
            }
            var states: [[Double]] = []
            states.reserveCapacity(times.count)
            for time in times {
                try Task.checkCancellation()
                guard let state = integrated.state(at: time) else {
                    throw CircuitSimulationError.invalidTransientSettings
                }
                states.append(state)
            }
            var nodeSeries = [[Double]](repeating: [], count: circuit.nodeCount)
            var componentSeries = [[Double]](repeating: [], count: circuit.elements.count)
            var previousVoltages = [Double](repeating: 0, count: circuit.elements.count)
            for (sample, state) in states.enumerated() {
                let voltages = try model.nodeVoltages(for: state)
                for node in circuit.nodeNames.indices { nodeSeries[node].append(voltages[node]) }
                for (index, element) in circuit.elements.enumerated() {
                    let voltage = voltages[element.nodeA] - voltages[element.nodeB]
                    let current: Double
                    switch element.kind {
                    case .resistor:
                        current = voltage / element.value
                    case .capacitor:
                        current = sample == 0 ? 0 : element.value
                            * (voltage - previousVoltages[index]) / settings.tranStep
                    case .inductor, .voltageSource:
                        guard let unknown = try model.branchUnknownIndex(index) else {
                            throw NumericCoreAdapterError.missingBranch(element.name)
                        }
                        current = state[unknown]
                    case .currentSource:
                        current = element.transient?.value(at: times[sample])
                            ?? element.magnitude(isDC: true)
                    case .diode, .bjt, .mosfet, .jfet:
                        throw NumericCoreAdapterError.unsupportedElement(element.name)
                    }
                    componentSeries[index].append(current)
                    previousVoltages[index] = voltage
                }
            }
            return .init(
                times: times,
                nodes: (1..<circuit.nodeCount).map { (circuit.nodeNames[$0], nodeSeries[$0]) },
                components: circuit.elements.enumerated().map {
                    ($0.element.name, componentSeries[$0.offset])
                }
            )
        }

        private func complexNodeVoltages(_ point: CircuitACPoint) throws -> [Complex] {
            try circuit.nodeNames.indices.map { node in
                guard let unknown = try model.nodeUnknownIndex(node) else { return .zero }
                return complex(point.unknowns[unknown])
            }
        }

        private func complex(_ value: CircuitComplex) -> Complex {
            Complex(value.real, value.imaginary)
        }

        private func freqPoint(_ frequency: Double, _ value: Complex) -> FreqPoint {
            FreqPoint(
                freqHz: frequency,
                magnitudeDb: value.magnitudeDecibels,
                phaseDeg: value.phaseDegrees
            )
        }
    }
}
