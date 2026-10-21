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
/// The native engine remains the product default while device and transient
/// parity are completed. This adapter deliberately fails closed for unsupported
/// features instead of silently returning a partial simulation.
public struct NumericCoreEngineBackend: SimulationEngineBackend {
    public let identifier = "numeric-core"

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
        if effective.runTransient || parsed.analysis.hasTransient {
            throw NumericCoreAdapterError.unsupportedAnalysis("transient analysis")
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

        let bridge = try Bridge(circuit: parsed.circuit)
        let operating = try bridge.model.dcOperatingPointContinuation()
        let dc = effective.runDC ? try bridge.dcResult(operating) : nil
        let ac = effective.runAC ? try bridge.acResult(operating, settings: effective) : nil
        return CircuitSimResult(
            dc: dc,
            ac: ac,
            transient: nil,
            sweep: nil,
            fourier: [],
            warnings: parsed.warnings
        )
    }
}

private extension NumericCoreEngineBackend {
    struct Bridge {
        let circuit: LinearCircuit
        let model: CircuitModel
        let devices: [CircuitDevice]

        init(circuit: LinearCircuit) throws {
            self.circuit = circuit
            let nodes = circuit.nodeNames.map { CircuitNode(name: $0) }
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
                        initialCurrent: 0
                    ))
                case .currentSource:
                    mapped.append(.currentSource(
                        name: element.name, positive: element.nodeA,
                        negative: element.nodeB,
                        source: .dc(element.magnitude(isDC: true))
                    ))
                case .voltageSource:
                    mapped.append(.voltageSource(
                        name: element.name, positive: element.nodeA,
                        negative: element.nodeB,
                        source: .dc(element.magnitude(isDC: true)),
                        initialCurrent: 0
                    ))
                case .diode, .bjt, .mosfet, .jfet:
                    throw NumericCoreAdapterError.unsupportedElement(element.name)
                }
            }
            devices = mapped
            model = try CircuitModel(nodes: nodes, referenceNode: 0, devices: mapped)
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
