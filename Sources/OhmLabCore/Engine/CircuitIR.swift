import Foundation

/// Engine-neutral, JSON-stable circuit representation used at the OhmLab 0.8
/// backend boundary. SPICE parsing and schematic connectivity remain frontend
/// concerns; numerical backends consume this normalized representation.
public struct CircuitIR: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var referenceNode: Int
    public var nodes: [Node]
    public var devices: [Device]
    public var solver: SolverConfiguration
    public var initialConditions: Conditions

    public init(
        schemaVersion: Int = currentSchemaVersion,
        referenceNode: Int = 0,
        nodes: [Node],
        devices: [Device],
        solver: SolverConfiguration = .init(),
        initialConditions: Conditions = .init()
    ) throws {
        self.schemaVersion = schemaVersion
        self.referenceNode = referenceNode
        self.nodes = nodes
        self.devices = devices
        self.solver = solver
        self.initialConditions = initialConditions
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, referenceNode, nodes, devices, solver, initialConditions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            referenceNode: container.decode(Int.self, forKey: .referenceNode),
            nodes: container.decode([Node].self, forKey: .nodes),
            devices: container.decode([Device].self, forKey: .devices),
            solver: container.decode(SolverConfiguration.self, forKey: .solver),
            initialConditions: container.decode(Conditions.self, forKey: .initialConditions)
        )
    }

    public struct Node: Codable, Equatable, Sendable {
        public var name: String
        public init(name: String) { self.name = name }
    }

    public enum DeviceKind: String, Codable, Sendable, CaseIterable, Comparable {
        case resistor, capacitor, inductor
        case voltageSource = "voltage-source"
        case currentSource = "current-source"
        case diode, bjt, mosfet, jfet

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        var terminalCount: Int {
            switch self {
            case .resistor, .capacitor, .inductor, .voltageSource, .currentSource, .diode: 2
            case .bjt, .jfet: 3
            case .mosfet: 4
            }
        }
    }

    public struct Device: Codable, Equatable, Sendable {
        public var name: String
        public var kind: DeviceKind
        /// Ordered terminals. Two-terminal devices use positive/anode then
        /// negative/cathode. BJT uses C/B/E, MOSFET D/G/S/B, JFET D/G/S.
        public var terminals: [Int]
        /// R, C, or L value. Sources and nonlinear devices use their typed data.
        public var value: Double?
        public var source: Source?
        public var diode: DiodeModel?
        public var bjt: BJTModel?
        public var mosfet: MOSFETModel?
        public var jfet: JFETModel?

        public init(
            name: String,
            kind: DeviceKind,
            terminals: [Int],
            value: Double? = nil,
            source: Source? = nil,
            diode: DiodeModel? = nil,
            bjt: BJTModel? = nil,
            mosfet: MOSFETModel? = nil,
            jfet: JFETModel? = nil
        ) {
            self.name = name
            self.kind = kind
            self.terminals = terminals
            self.value = value
            self.source = source
            self.diode = diode
            self.bjt = bjt
            self.mosfet = mosfet
            self.jfet = jfet
        }
    }

    public struct Source: Codable, Equatable, Sendable {
        public var dcValue: Double
        public var acMagnitude: Double
        public var acPhaseDegrees: Double
        public var transient: TransientWaveform?

        public init(
            dcValue: Double,
            acMagnitude: Double,
            acPhaseDegrees: Double = 0,
            transient: TransientWaveform? = nil
        ) {
            self.dcValue = dcValue
            self.acMagnitude = acMagnitude
            self.acPhaseDegrees = acPhaseDegrees
            self.transient = transient
        }
    }

    public struct TransientWaveform: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case pulse, sine, piecewiseLinear = "pwl" }
        public var kind: Kind
        /// Named parameters keep the wire format self-describing. Pulse uses
        /// initial/pulsed/delay/riseTime/fallTime/pulseWidth/period; sine uses
        /// offset/amplitude/frequency/delay/damping/phaseDegrees.
        public var parameters: [String: Double]
        public var points: [WaveformPointIR]

        public init(kind: Kind, parameters: [String: Double] = [:], points: [WaveformPointIR] = []) {
            self.kind = kind
            self.parameters = parameters
            self.points = points
        }
    }

    public struct WaveformPointIR: Codable, Equatable, Sendable {
        public var time: Double
        public var value: Double
        public init(time: Double, value: Double) { self.time = time; self.value = value }
    }

    public struct DiodeModel: Codable, Equatable, Sendable {
        public var saturationCurrent: Double
        public var emissionCoefficient: Double
        public var thermalVoltage: Double
        public var area: Double
        public var saturationCurrentTemperatureExponent: Double
        public var activationEnergy: Double
    }

    public struct BJTModel: Codable, Equatable, Sendable {
        public enum Polarity: String, Codable, Sendable { case npn, pnp }
        public var polarity: Polarity
        public var saturationCurrent: Double
        public var forwardBeta: Double
        public var reverseBeta: Double
        public var thermalVoltage: Double
        public var saturationCurrentTemperatureExponent: Double
        public var activationEnergy: Double
        public var betaTemperatureExponent: Double
    }

    public struct MOSFETModel: Codable, Equatable, Sendable {
        public enum Polarity: String, Codable, Sendable { case nmos, pmos }
        public var polarity: Polarity
        public var thresholdVoltage: Double
        public var transconductanceParameter: Double
        public var channelLengthModulation: Double
        public var bodyEffect: Double
        public var surfacePotential: Double
        public var mobilityTemperatureExponent: Double
        public var thresholdTemperatureCoefficient: Double
    }

    public struct JFETModel: Codable, Equatable, Sendable {
        public enum Polarity: String, Codable, Sendable { case njf, pjf }
        public var polarity: Polarity
        public var thresholdVoltage: Double
        public var transconductanceParameter: Double
        public var channelLengthModulation: Double
        public var gateSaturationCurrent: Double
        public var thermalVoltage: Double
        public var mobilityTemperatureExponent: Double
        public var thresholdTemperatureCoefficient: Double
        public var saturationCurrentTemperatureExponent: Double
        public var activationEnergy: Double
    }

    public struct SolverConfiguration: Codable, Equatable, Sendable {
        public var relativeTolerance: Double
        public var absoluteCurrentTolerance: Double
        public var absoluteVoltageTolerance: Double
        public var minimumConductance: Double
        public var maximumIterations: Int
        public var temperatureCelsius: Double
        public var nominalTemperatureCelsius: Double

        public init(
            relativeTolerance: Double = 1e-3,
            absoluteCurrentTolerance: Double = 1e-12,
            absoluteVoltageTolerance: Double = 1e-6,
            minimumConductance: Double = 1e-12,
            maximumIterations: Int = 100,
            temperatureCelsius: Double = 27,
            nominalTemperatureCelsius: Double = 27
        ) {
            self.relativeTolerance = relativeTolerance
            self.absoluteCurrentTolerance = absoluteCurrentTolerance
            self.absoluteVoltageTolerance = absoluteVoltageTolerance
            self.minimumConductance = minimumConductance
            self.maximumIterations = maximumIterations
            self.temperatureCelsius = temperatureCelsius
            self.nominalTemperatureCelsius = nominalTemperatureCelsius
        }
    }

    public struct Conditions: Codable, Equatable, Sendable {
        public var nodeVoltages: [String: Double]
        public var elementCurrents: [String: Double]
        public init(nodeVoltages: [String: Double] = [:], elementCurrents: [String: Double] = [:]) {
            self.nodeVoltages = nodeVoltages
            self.elementCurrents = elementCurrents
        }
    }
}

public enum CircuitIRError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case invalidReferenceNode
    case invalidNodeNames
    case invalidDevice(String)
    case invalidWaveform(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "Circuit IR version \(version) is not supported."
        case .invalidReferenceNode: return "Circuit IR has an invalid reference node."
        case .invalidNodeNames: return "Circuit IR node names must be non-empty and unique."
        case .invalidDevice(let name): return "Circuit IR device \(name) is malformed."
        case .invalidWaveform(let name): return "Circuit IR source \(name) has a malformed waveform."
        }
    }
}

public extension CircuitIR {
    init(linearCircuit: LinearCircuit, initialConditions: InitialConditions = .init()) throws {
        try self.init(
            nodes: linearCircuit.nodeNames.map(Node.init),
            devices: linearCircuit.elements.map(Self.device(from:)),
            solver: .init(linearCircuit.solverOptions),
            initialConditions: .init(
                nodeVoltages: initialConditions.nodeVoltages,
                elementCurrents: initialConditions.elementCurrents
            )
        )
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CircuitIRError.unsupportedVersion(schemaVersion)
        }
        guard referenceNode == 0, nodes.indices.contains(referenceNode), nodes[0].name == "0" else {
            throw CircuitIRError.invalidReferenceNode
        }
        let nodeKeys = nodes.map { $0.name.lowercased() }
        guard nodes.allSatisfy({ !$0.name.isEmpty }), Set(nodeKeys).count == nodes.count else {
            throw CircuitIRError.invalidNodeNames
        }
        let names = devices.map { $0.name.lowercased() }
        guard Set(names).count == devices.count else { throw CircuitIRError.invalidDevice("<duplicate>") }
        let solverValues = [
            solver.relativeTolerance, solver.absoluteCurrentTolerance,
            solver.absoluteVoltageTolerance, solver.minimumConductance,
            solver.temperatureCelsius, solver.nominalTemperatureCelsius,
        ]
        guard solverValues.allSatisfy(\.isFinite), solver.relativeTolerance > 0,
              solver.absoluteCurrentTolerance > 0, solver.absoluteVoltageTolerance > 0,
              solver.minimumConductance > 0, solver.maximumIterations > 0,
              solver.temperatureCelsius > -273.15, solver.nominalTemperatureCelsius > -273.15,
              initialConditions.nodeVoltages.allSatisfy({ !$0.key.isEmpty && $0.value.isFinite }),
              initialConditions.elementCurrents.allSatisfy({ !$0.key.isEmpty && $0.value.isFinite }) else {
            throw CircuitIRError.invalidDevice("<configuration>")
        }
        for device in devices {
            guard !device.name.isEmpty,
                  device.terminals.count == device.kind.terminalCount,
                  device.terminals.allSatisfy(nodes.indices.contains) else {
                throw CircuitIRError.invalidDevice(device.name)
            }
            switch device.kind {
            case .resistor, .capacitor, .inductor:
                guard let value = device.value, value.isFinite, value > 0 else {
                    throw CircuitIRError.invalidDevice(device.name)
                }
            case .voltageSource, .currentSource:
                guard let source = device.source,
                      [source.dcValue, source.acMagnitude, source.acPhaseDegrees].allSatisfy(\.isFinite) else {
                    throw CircuitIRError.invalidDevice(device.name)
                }
                try Self.validate(source.transient, name: device.name)
            case .diode:
                guard let model = device.diode,
                      [model.saturationCurrent, model.emissionCoefficient, model.thermalVoltage,
                       model.area, model.saturationCurrentTemperatureExponent,
                       model.activationEnergy].allSatisfy(\.isFinite),
                      model.saturationCurrent > 0, model.emissionCoefficient > 0,
                      model.thermalVoltage > 0, model.area > 0 else {
                    throw CircuitIRError.invalidDevice(device.name)
                }
            case .bjt:
                guard let model = device.bjt,
                      [model.saturationCurrent, model.forwardBeta, model.reverseBeta,
                       model.thermalVoltage, model.saturationCurrentTemperatureExponent,
                       model.activationEnergy, model.betaTemperatureExponent].allSatisfy(\.isFinite),
                      model.saturationCurrent > 0, model.forwardBeta > 0,
                      model.reverseBeta > 0, model.thermalVoltage > 0 else {
                    throw CircuitIRError.invalidDevice(device.name)
                }
            case .mosfet:
                guard let model = device.mosfet,
                      [model.thresholdVoltage, model.transconductanceParameter,
                       model.channelLengthModulation, model.bodyEffect, model.surfacePotential,
                       model.mobilityTemperatureExponent,
                       model.thresholdTemperatureCoefficient].allSatisfy(\.isFinite),
                      model.transconductanceParameter > 0,
                      model.channelLengthModulation >= 0, model.bodyEffect >= 0,
                      model.surfacePotential > 0 else {
                    throw CircuitIRError.invalidDevice(device.name)
                }
            case .jfet:
                guard let model = device.jfet,
                      [model.thresholdVoltage, model.transconductanceParameter,
                       model.channelLengthModulation, model.gateSaturationCurrent,
                       model.thermalVoltage, model.mobilityTemperatureExponent,
                       model.thresholdTemperatureCoefficient,
                       model.saturationCurrentTemperatureExponent,
                       model.activationEnergy].allSatisfy(\.isFinite),
                      model.transconductanceParameter > 0,
                      model.channelLengthModulation >= 0,
                      model.gateSaturationCurrent > 0, model.thermalVoltage > 0 else {
                    throw CircuitIRError.invalidDevice(device.name)
                }
            }
        }

        let nodeNames = Set(nodes.map { $0.name.lowercased() })
        let deviceNames = Set(devices.map { $0.name.lowercased() })
        guard initialConditions.nodeVoltages.keys.allSatisfy({ nodeNames.contains($0.lowercased()) }),
              initialConditions.elementCurrents.keys.allSatisfy({ deviceNames.contains($0.lowercased()) }) else {
            throw CircuitIRError.invalidDevice("<initial-conditions>")
        }
    }

    func makeLinearCircuit() throws -> LinearCircuit {
        try validate()
        let elements = try devices.map { device -> LinearCircuit.Element in
            let t = device.terminals
            switch device.kind {
            case .resistor, .capacitor, .inductor:
                return .init(
                    kind: nativeKind(device.kind), nodeA: t[0], nodeB: t[1],
                    value: device.value!, name: device.name
                )
            case .voltageSource, .currentSource:
                let source = device.source!
                return .init(
                    kind: nativeKind(device.kind), nodeA: t[0], nodeB: t[1],
                    value: source.dcValue, phaseDegrees: source.acPhaseDegrees,
                    dcValue: source.dcValue, acValue: source.acMagnitude,
                    transient: try waveform(from: source.transient, name: device.name),
                    name: device.name
                )
            case .diode:
                return .init(kind: .diode, nodeA: t[0], nodeB: t[1], value: 0,
                             diode: .init(device.diode!), name: device.name)
            case .bjt:
                return .init(kind: .bjt, nodeA: t[0], nodeB: t[2], nodeC: t[1], value: 0,
                             bjt: .init(device.bjt!), name: device.name)
            case .mosfet:
                return .init(kind: .mosfet, nodeA: t[0], nodeB: t[2], nodeC: t[1], nodeD: t[3], value: 0,
                             mosfet: .init(device.mosfet!), name: device.name)
            case .jfet:
                return .init(kind: .jfet, nodeA: t[0], nodeB: t[2], nodeC: t[1], value: 0,
                             jfet: .init(device.jfet!), name: device.name)
            }
        }
        return LinearCircuit(nodeNames: nodes.map(\.name), elements: elements, solverOptions: solver.native)
    }

    var nativeInitialConditions: InitialConditions {
        .init(nodeVoltages: initialConditions.nodeVoltages, elementCurrents: initialConditions.elementCurrents)
    }

    private static func validate(_ waveform: TransientWaveform?, name: String) throws {
        guard let waveform else { return }
        guard waveform.parameters.values.allSatisfy(\.isFinite),
              waveform.points.allSatisfy({ $0.time.isFinite && $0.value.isFinite }) else {
            throw CircuitIRError.invalidWaveform(name)
        }
        let required: Set<String>
        switch waveform.kind {
        case .pulse:
            required = ["initial", "pulsed", "delay", "riseTime", "fallTime", "pulseWidth", "period"]
        case .sine:
            required = ["offset", "amplitude", "frequency", "delay", "damping", "phaseDegrees"]
        case .piecewiseLinear:
            guard !waveform.points.isEmpty,
                  zip(waveform.points, waveform.points.dropFirst()).allSatisfy({ $0.0.time < $0.1.time }) else {
                throw CircuitIRError.invalidWaveform(name)
            }
            required = []
        }
        guard required.isSubset(of: waveform.parameters.keys) else {
            throw CircuitIRError.invalidWaveform(name)
        }
    }

    private static func device(from element: LinearCircuit.Element) -> Device {
        let kind = DeviceKind(element.kind)
        let terminals: [Int]
        switch element.kind {
        case .bjt: terminals = [element.nodeA, element.nodeC ?? element.nodeB, element.nodeB]
        case .mosfet: terminals = [element.nodeA, element.nodeC ?? element.nodeB, element.nodeB, element.nodeD ?? element.nodeB]
        case .jfet: terminals = [element.nodeA, element.nodeC ?? element.nodeB, element.nodeB]
        default: terminals = [element.nodeA, element.nodeB]
        }
        let source: Source? = switch element.kind {
        case .voltageSource, .currentSource:
            .init(dcValue: element.magnitude(isDC: true),
                  acMagnitude: element.magnitude(isDC: false),
                  acPhaseDegrees: element.phaseDegrees,
                  transient: element.transient.map(TransientWaveform.init))
        default: nil
        }
        return Device(
            name: element.name, kind: kind, terminals: terminals,
            value: [.resistor, .capacitor, .inductor].contains(kind) ? element.value : nil,
            source: source, diode: element.diode.map(DiodeModel.init),
            bjt: element.bjt.map(BJTModel.init), mosfet: element.mosfet.map(MOSFETModel.init),
            jfet: element.jfet.map(JFETModel.init)
        )
    }

    private func nativeKind(_ kind: DeviceKind) -> LinearCircuit.ElementKind {
        switch kind {
        case .resistor: .resistor; case .capacitor: .capacitor; case .inductor: .inductor
        case .voltageSource: .voltageSource; case .currentSource: .currentSource
        case .diode: .diode; case .bjt: .bjt; case .mosfet: .mosfet; case .jfet: .jfet
        }
    }

    private func waveform(from value: TransientWaveform?, name: String) throws -> Waveform? {
        guard let value else { return nil }
        try Self.validate(value, name: name)
        let p = value.parameters
        switch value.kind {
        case .pulse:
            return .pulse(initial: p["initial"]!, pulsed: p["pulsed"]!, delay: p["delay"]!,
                          riseTime: p["riseTime"]!, fallTime: p["fallTime"]!,
                          pulseWidth: p["pulseWidth"]!, period: p["period"]!)
        case .sine:
            return .sine(offset: p["offset"]!, amplitude: p["amplitude"]!, frequency: p["frequency"]!,
                         delay: p["delay"]!, damping: p["damping"]!, phaseDegrees: p["phaseDegrees"]!)
        case .piecewiseLinear:
            return .pwl(points: value.points.map { .init(time: $0.time, value: $0.value) })
        }
    }
}

/// The single frontend entry point for lowering SPICE into Circuit IR v1.
public enum CircuitIRCompiler {
    public static func compile(
        netlist: String,
        libraries: [SpiceModelLibrary] = []
    ) throws -> CircuitIR {
        let include = SpiceLibraryManager(libraries: libraries).includeResolver()
        let parsed = try SpiceNetlistParser.parse(netlist, include: include, libraries: libraries)
        return try CircuitIR(linearCircuit: parsed.circuit, initialConditions: parsed.initialConditions)
    }
}

private extension CircuitIR.DeviceKind {
    init(_ kind: LinearCircuit.ElementKind) {
        switch kind {
        case .resistor: self = .resistor; case .capacitor: self = .capacitor; case .inductor: self = .inductor
        case .voltageSource: self = .voltageSource; case .currentSource: self = .currentSource
        case .diode: self = .diode; case .bjt: self = .bjt; case .mosfet: self = .mosfet; case .jfet: self = .jfet
        }
    }
}

private extension CircuitIR.TransientWaveform {
    init(_ waveform: Waveform) {
        switch waveform {
        case .pulse(let initial, let pulsed, let delay, let rise, let fall, let width, let period):
            self.init(kind: .pulse, parameters: [
                "initial": initial, "pulsed": pulsed, "delay": delay, "riseTime": rise,
                "fallTime": fall, "pulseWidth": width, "period": period,
            ])
        case .sine(let offset, let amplitude, let frequency, let delay, let damping, let phase):
            self.init(kind: .sine, parameters: [
                "offset": offset, "amplitude": amplitude, "frequency": frequency,
                "delay": delay, "damping": damping, "phaseDegrees": phase,
            ])
        case .pwl(let points):
            self.init(kind: .piecewiseLinear, points: points.map { .init(time: $0.time, value: $0.value) })
        }
    }
}

private extension CircuitIR.SolverConfiguration {
    init(_ options: SolverOptions) {
        self.init(relativeTolerance: options.relativeTolerance,
                  absoluteCurrentTolerance: options.absoluteCurrentTolerance,
                  absoluteVoltageTolerance: options.absoluteVoltageTolerance,
                  minimumConductance: options.minimumConductance,
                  maximumIterations: options.maximumIterations,
                  temperatureCelsius: options.temperatureCelsius,
                  nominalTemperatureCelsius: options.nominalTemperatureCelsius)
    }
    var native: SolverOptions {
        .init(relativeTolerance: relativeTolerance,
              absoluteCurrentTolerance: absoluteCurrentTolerance,
              absoluteVoltageTolerance: absoluteVoltageTolerance,
              minimumConductance: minimumConductance,
              maximumIterations: maximumIterations,
              temperatureCelsius: temperatureCelsius,
              nominalTemperatureCelsius: nominalTemperatureCelsius)
    }
}

private extension CircuitIR.DiodeModel {
    init(_ value: LinearCircuit.DiodeParameters) {
        self.init(saturationCurrent: value.saturationCurrent, emissionCoefficient: value.emissionCoefficient,
                  thermalVoltage: value.thermalVoltage, area: value.area,
                  saturationCurrentTemperatureExponent: value.saturationCurrentTemperatureExponent,
                  activationEnergy: value.activationEnergy)
    }
}
private extension LinearCircuit.DiodeParameters {
    init(_ value: CircuitIR.DiodeModel) {
        self.init(saturationCurrent: value.saturationCurrent, emissionCoefficient: value.emissionCoefficient,
                  thermalVoltage: value.thermalVoltage, area: value.area,
                  saturationCurrentTemperatureExponent: value.saturationCurrentTemperatureExponent,
                  activationEnergy: value.activationEnergy)
    }
}
private extension CircuitIR.BJTModel {
    init(_ value: LinearCircuit.BJTParameters) {
        self.init(polarity: value.polarity == .npn ? .npn : .pnp,
                  saturationCurrent: value.saturationCurrent, forwardBeta: value.forwardBeta,
                  reverseBeta: value.reverseBeta, thermalVoltage: value.thermalVoltage,
                  saturationCurrentTemperatureExponent: value.saturationCurrentTemperatureExponent,
                  activationEnergy: value.activationEnergy, betaTemperatureExponent: value.betaTemperatureExponent)
    }
}
private extension LinearCircuit.BJTParameters {
    init(_ value: CircuitIR.BJTModel) {
        self.init(polarity: value.polarity == .npn ? .npn : .pnp,
                  saturationCurrent: value.saturationCurrent, forwardBeta: value.forwardBeta,
                  reverseBeta: value.reverseBeta, thermalVoltage: value.thermalVoltage,
                  saturationCurrentTemperatureExponent: value.saturationCurrentTemperatureExponent,
                  activationEnergy: value.activationEnergy, betaTemperatureExponent: value.betaTemperatureExponent)
    }
}
private extension CircuitIR.MOSFETModel {
    init(_ value: LinearCircuit.MOSFETParameters) {
        self.init(polarity: value.polarity == .nmos ? .nmos : .pmos,
                  thresholdVoltage: value.thresholdVoltage,
                  transconductanceParameter: value.transconductanceParameter,
                  channelLengthModulation: value.channelLengthModulation,
                  bodyEffect: value.bodyEffect, surfacePotential: value.surfacePotential,
                  mobilityTemperatureExponent: value.mobilityTemperatureExponent,
                  thresholdTemperatureCoefficient: value.thresholdTemperatureCoefficient)
    }
}
private extension LinearCircuit.MOSFETParameters {
    init(_ value: CircuitIR.MOSFETModel) {
        self.init(polarity: value.polarity == .nmos ? .nmos : .pmos,
                  thresholdVoltage: value.thresholdVoltage,
                  transconductanceParameter: value.transconductanceParameter,
                  channelLengthModulation: value.channelLengthModulation,
                  bodyEffect: value.bodyEffect, surfacePotential: value.surfacePotential,
                  mobilityTemperatureExponent: value.mobilityTemperatureExponent,
                  thresholdTemperatureCoefficient: value.thresholdTemperatureCoefficient)
    }
}
private extension CircuitIR.JFETModel {
    init(_ value: LinearCircuit.JFETParameters) {
        self.init(polarity: value.polarity == .njf ? .njf : .pjf,
                  thresholdVoltage: value.thresholdVoltage,
                  transconductanceParameter: value.transconductanceParameter,
                  channelLengthModulation: value.channelLengthModulation,
                  gateSaturationCurrent: value.gateSaturationCurrent, thermalVoltage: value.thermalVoltage,
                  mobilityTemperatureExponent: value.mobilityTemperatureExponent,
                  thresholdTemperatureCoefficient: value.thresholdTemperatureCoefficient,
                  saturationCurrentTemperatureExponent: value.saturationCurrentTemperatureExponent,
                  activationEnergy: value.activationEnergy)
    }
}
private extension LinearCircuit.JFETParameters {
    init(_ value: CircuitIR.JFETModel) {
        self.init(polarity: value.polarity == .njf ? .njf : .pjf,
                  thresholdVoltage: value.thresholdVoltage,
                  transconductanceParameter: value.transconductanceParameter,
                  channelLengthModulation: value.channelLengthModulation,
                  gateSaturationCurrent: value.gateSaturationCurrent, thermalVoltage: value.thermalVoltage,
                  mobilityTemperatureExponent: value.mobilityTemperatureExponent,
                  thresholdTemperatureCoefficient: value.thresholdTemperatureCoefficient,
                  saturationCurrentTemperatureExponent: value.saturationCurrentTemperatureExponent,
                  activationEnergy: value.activationEnergy)
    }
}
