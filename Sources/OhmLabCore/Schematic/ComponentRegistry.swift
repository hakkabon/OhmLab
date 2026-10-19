import CoreGraphics
import Foundation

public enum ComponentSymbol: String, Sendable {
    case resistor
    case capacitor
    case inductor
    case inductorSeries
    case voltageSource
    case currentSource
    case diode
    case npnTransistor
    case pnpTransistor
    case nmosTransistor
    case pmosTransistor
    case njfTransistor
    case pjfTransistor
    case ground
    /// A subcircuit instance: a box whose pins are the referenced sheet's ports.
    case subcircuit
}

public struct ComponentParameterDescriptor: Sendable {
    public let id: String
    public let name: String
    public let unit: String
    public let defaultValue: Double

    public init(id: String, name: String, unit: String, defaultValue: Double) {
        self.id = id
        self.name = name
        self.unit = unit
        self.defaultValue = defaultValue
    }
}

public struct PinDescriptor: Sendable {
    public let id: String
    public let name: String
    public let position: CGPoint

    public init(id: String, name: String, position: CGPoint) {
        self.id = id
        self.name = name
        self.position = position
    }
}

public struct ComponentDescriptor: Sendable {
    public let id: String
    public let prefix: String
    public let displayName: String
    public let symbol: ComponentSymbol
    public let pins: [PinDescriptor]
    public let parameters: [ComponentParameterDescriptor]

    public init(
        id: String,
        prefix: String,
        displayName: String,
        symbol: ComponentSymbol,
        pins: [PinDescriptor],
        parameters: [ComponentParameterDescriptor] = []
    ) {
        self.id = id
        self.prefix = prefix
        self.displayName = displayName
        self.symbol = symbol
        self.pins = pins
        self.parameters = parameters
    }

    public var defaultParameterValues: [String: Double] {
        Dictionary(uniqueKeysWithValues: parameters.map { ($0.id, $0.defaultValue) })
    }
}

public final class ComponentRegistry: @unchecked Sendable {
    public static let shared = ComponentRegistry()
    private let lock = NSLock()
    private var registry: [String: ComponentDescriptor]

    private init() {
        let twoTerminalPins = [
            PinDescriptor(id: "1", name: "1", position: CGPoint(x: -40, y: 0)),
            PinDescriptor(id: "2", name: "2", position: CGPoint(x: 40, y: 0))
        ]
        // Order is significant: collector, base, emitter.
        let transistorPins = [
            PinDescriptor(id: "collector", name: "C", position: CGPoint(x: 40, y: -40)),
            PinDescriptor(id: "base", name: "B", position: CGPoint(x: -40, y: 0)),
            PinDescriptor(id: "emitter", name: "E", position: CGPoint(x: 40, y: 40))
        ]
        // Order is significant: drain, gate, source, bulk.
        let mosfetPins = [
            PinDescriptor(id: "drain", name: "D", position: CGPoint(x: 40, y: -40)),
            PinDescriptor(id: "gate", name: "G", position: CGPoint(x: -40, y: 0)),
            PinDescriptor(id: "source", name: "S", position: CGPoint(x: 40, y: 40)),
            PinDescriptor(id: "bulk", name: "B", position: CGPoint(x: 40, y: 0))
        ]
        // Order is significant: drain, gate, source.
        let jfetPins = [
            PinDescriptor(id: "drain", name: "D", position: CGPoint(x: 40, y: -40)),
            PinDescriptor(id: "gate", name: "G", position: CGPoint(x: -40, y: 0)),
            PinDescriptor(id: "source", name: "S", position: CGPoint(x: 40, y: 40))
        ]
        registry = [
            "resistor": ComponentDescriptor(
                id: "resistor",
                prefix: "R",
                displayName: "Resistor",
                symbol: .resistor,
                pins: twoTerminalPins,
                parameters: [
                    ComponentParameterDescriptor(id: "resistance", name: "Resistance", unit: "Ω", defaultValue: 1_000)
                ]
            ),
            "capacitor": ComponentDescriptor(
                id: "capacitor",
                prefix: "C",
                displayName: "Capacitor",
                symbol: .capacitor,
                pins: twoTerminalPins,
                parameters: [
                    ComponentParameterDescriptor(id: "capacitance", name: "Capacitance", unit: "F", defaultValue: 1e-6)
                ]
            ),
            "inductor": ComponentDescriptor(
                id: "inductor",
                prefix: "L",
                displayName: "Inductor",
                symbol: .inductor,
                pins: twoTerminalPins,
                parameters: [
                    ComponentParameterDescriptor(id: "inductance", name: "Inductance", unit: "H", defaultValue: 1e-3)
                ]
            ),
            "inductor-series-resistance": ComponentDescriptor(
                id: "inductor-series-resistance",
                prefix: "L",
                displayName: "Inductor with Series Resistance",
                symbol: .inductorSeries,
                pins: twoTerminalPins,
                parameters: [
                    ComponentParameterDescriptor(id: "inductance", name: "Inductance", unit: "H", defaultValue: 1e-3),
                    ComponentParameterDescriptor(id: "seriesResistance", name: "Series resistance", unit: "Ω", defaultValue: 0.2)
                ]
            ),
            "voltage-source": ComponentDescriptor(
                id: "voltage-source",
                prefix: "V",
                displayName: "Voltage Source",
                symbol: .voltageSource,
                pins: twoTerminalPins,
                parameters: [
                    ComponentParameterDescriptor(id: "dcVoltage", name: "DC voltage", unit: "V", defaultValue: 0),
                    ComponentParameterDescriptor(id: "acMagnitude", name: "AC magnitude", unit: "V", defaultValue: 1),
                    ComponentParameterDescriptor(id: "acPhaseDegrees", name: "AC phase", unit: "°", defaultValue: 0)
                ]
            ),
            "current-source": ComponentDescriptor(
                id: "current-source",
                prefix: "I",
                displayName: "Current Source",
                symbol: .currentSource,
                pins: twoTerminalPins,
                parameters: [
                    ComponentParameterDescriptor(id: "dcCurrent", name: "DC current", unit: "A", defaultValue: 0),
                    ComponentParameterDescriptor(id: "acMagnitude", name: "AC magnitude", unit: "A", defaultValue: 1),
                    ComponentParameterDescriptor(id: "acPhaseDegrees", name: "AC phase", unit: "°", defaultValue: 0)
                ]
            ),
            "diode": ComponentDescriptor(
                id: "diode",
                prefix: "D",
                displayName: "Diode",
                symbol: .diode,
                pins: twoTerminalPins,
                parameters: [
                    ComponentParameterDescriptor(id: "saturationCurrent", name: "Saturation current", unit: "A", defaultValue: 1e-14),
                    ComponentParameterDescriptor(id: "emissionCoefficient", name: "Emission coefficient", unit: "", defaultValue: 1)
                ]
            ),
            "npn-transistor": ComponentDescriptor(
                id: "npn-transistor",
                prefix: "Q",
                displayName: "NPN Transistor",
                symbol: .npnTransistor,
                pins: transistorPins,
                parameters: [
                    ComponentParameterDescriptor(id: "saturationCurrent", name: "Saturation current", unit: "A", defaultValue: 1e-15),
                    ComponentParameterDescriptor(id: "forwardBeta", name: "Forward beta", unit: "", defaultValue: 100),
                    ComponentParameterDescriptor(id: "reverseBeta", name: "Reverse beta", unit: "", defaultValue: 1)
                ]
            ),
            "pnp-transistor": ComponentDescriptor(
                id: "pnp-transistor",
                prefix: "Q",
                displayName: "PNP Transistor",
                symbol: .pnpTransistor,
                pins: transistorPins,
                parameters: [
                    ComponentParameterDescriptor(id: "saturationCurrent", name: "Saturation current", unit: "A", defaultValue: 1e-15),
                    ComponentParameterDescriptor(id: "forwardBeta", name: "Forward beta", unit: "", defaultValue: 100),
                    ComponentParameterDescriptor(id: "reverseBeta", name: "Reverse beta", unit: "", defaultValue: 1)
                ]
            ),
            "nmos-transistor": ComponentDescriptor(
                id: "nmos-transistor",
                prefix: "M",
                displayName: "N-MOSFET",
                symbol: .nmosTransistor,
                pins: mosfetPins,
                parameters: Self.mosfetParameters(thresholdVoltage: 1)
            ),
            "pmos-transistor": ComponentDescriptor(
                id: "pmos-transistor",
                prefix: "M",
                displayName: "P-MOSFET",
                symbol: .pmosTransistor,
                pins: mosfetPins,
                parameters: Self.mosfetParameters(thresholdVoltage: -1)
            ),
            "njfet-transistor": ComponentDescriptor(
                id: "njfet-transistor",
                prefix: "J",
                displayName: "N-JFET",
                symbol: .njfTransistor,
                pins: jfetPins,
                parameters: Self.jfetParameters(thresholdVoltage: -2)
            ),
            "pjfet-transistor": ComponentDescriptor(
                id: "pjfet-transistor",
                prefix: "J",
                displayName: "P-JFET",
                symbol: .pjfTransistor,
                pins: jfetPins,
                parameters: Self.jfetParameters(thresholdVoltage: 2)
            ),
            "ground": ComponentDescriptor(
                id: "ground",
                prefix: "GND",
                displayName: "Ground",
                symbol: .ground,
                pins: [PinDescriptor(id: "1", name: "1", position: CGPoint(x: 0, y: -20))]
            ),
            // A subcircuit instance has no static pins; they are derived from the
            // referenced sheet's ports at use sites (see SubcircuitCatalog).
            SubcircuitInstance.descriptorId: ComponentDescriptor(
                id: SubcircuitInstance.descriptorId,
                prefix: "X",
                displayName: "Subcircuit",
                symbol: .subcircuit,
                pins: []
            )
        ]
    }

    /// Shared Level 1 parameter set for the N- and P-MOSFET descriptors. The
    /// only difference is the sign of the threshold voltage.
    private static func mosfetParameters(thresholdVoltage: Double) -> [ComponentParameterDescriptor] {
        [
            ComponentParameterDescriptor(id: "thresholdVoltage", name: "Threshold voltage", unit: "V", defaultValue: thresholdVoltage),
            ComponentParameterDescriptor(id: "transconductanceParameter", name: "Transconductance parameter", unit: "A/V²", defaultValue: 2e-5),
            ComponentParameterDescriptor(id: "channelLengthModulation", name: "Channel-length modulation", unit: "1/V", defaultValue: 0),
            ComponentParameterDescriptor(id: "bodyEffect", name: "Body effect", unit: "√V", defaultValue: 0),
            ComponentParameterDescriptor(id: "surfacePotential", name: "Surface potential", unit: "V", defaultValue: 0.6)
        ]
    }

    /// Shared Shichman-Hodges parameter set for the N- and P-JFET descriptors.
    /// The only difference is the sign of the threshold voltage.
    private static func jfetParameters(thresholdVoltage: Double) -> [ComponentParameterDescriptor] {
        [
            ComponentParameterDescriptor(id: "thresholdVoltage", name: "Threshold voltage", unit: "V", defaultValue: thresholdVoltage),
            ComponentParameterDescriptor(id: "transconductanceParameter", name: "Transconductance parameter", unit: "A/V²", defaultValue: 1e-4),
            ComponentParameterDescriptor(id: "channelLengthModulation", name: "Channel-length modulation", unit: "1/V", defaultValue: 0),
            ComponentParameterDescriptor(id: "gateSaturationCurrent", name: "Gate saturation current", unit: "A", defaultValue: 1e-14)
        ]
    }

    public var allDescriptors: [ComponentDescriptor] {
        lock.lock(); defer { lock.unlock() }
        return registry.values.sorted { $0.displayName < $1.displayName }
    }

    public func descriptor(for id: String) -> ComponentDescriptor? {
        lock.lock(); defer { lock.unlock() }
        return registry[id]
    }

    /// Registers a plugin/custom descriptor at runtime. A built-in (or already
    /// registered) id is never overwritten: the call returns `false` and leaves
    /// the existing descriptor in place.
    @discardableResult
    public func register(_ descriptor: ComponentDescriptor) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard registry[descriptor.id] == nil else { return false }
        registry[descriptor.id] = descriptor
        return true
    }

    /// Removes a previously registered descriptor (used to unload a plugin, or
    /// to clean up in tests). Built-ins can be removed too, so callers should
    /// treat this as an explicit, deliberate operation.
    @discardableResult
    public func unregister(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return registry.removeValue(forKey: id) != nil
    }
}
