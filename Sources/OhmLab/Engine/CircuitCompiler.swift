// CircuitCompiler.swift
// Projects the schematic (Layer 1) through connectivity (Layer 2) into a
// solver-ready linear circuit. This is the bridge the first milestone needs:
// the same document that is saved and edited becomes the matrix the engine
// actually solves.

import Foundation

public enum CircuitCompileError: LocalizedError {
    case missingGround
    case emptyCircuit
    case missingPin(reference: String)
    case missingParameter(reference: String, parameter: String)
    case invalidParameter(reference: String, parameter: String)
    case unsupportedComponent(reference: String, descriptor: String)

    public var errorDescription: String? {
        switch self {
        case .missingGround:
            return "Add a ground symbol so the circuit has a node 0 reference."
        case .emptyCircuit:
            return "The schematic has no components to simulate."
        case .missingPin(let reference):
            return "\(reference) has a pin that is not connected to a net."
        case .missingParameter(let reference, let parameter):
            return "\(reference) is missing its \(parameter) value."
        case .invalidParameter(let reference, let parameter):
            return "\(reference) has an invalid \(parameter) value."
        case .unsupportedComponent(let reference, let descriptor):
            return "\(reference) (\(descriptor)) is not yet supported by the solver."
        }
    }
}

public enum CircuitCompiler {
    @MainActor
    public static func compile(_ document: SchematicDocument) throws -> LinearCircuit {
        try compile(snapshot: document.snapshot())
    }

    /// Compiles a snapshot. A flat snapshot goes straight through the direct
    /// projector; a snapshot with child sheets is projected to a hierarchical
    /// SPICE netlist and parsed, which reuses the engine's subcircuit expansion.
    public static func compile(snapshot: SchematicSnapshot) throws -> LinearCircuit {
        if snapshot.sheets.isEmpty {
            return try compile(symbols: snapshot.symbols, wires: snapshot.wires, labels: snapshot.netLabels)
        }
        let text = try SpiceNetlistBuilder.build(snapshot: snapshot)
        return try SpiceNetlistParser.parse(text).circuit
    }

    public static func compile(
        symbols: [SymbolInstance],
        wires: [WireSegment],
        labels: [NetLabel] = []
    ) throws -> LinearCircuit {
        let nets = ConnectivityBuilder.build(symbols: symbols, wires: wires, labels: labels)

        guard nets.contains(where: \.isGround) else {
            throw CircuitCompileError.missingGround
        }
        guard symbols.contains(where: {
            ComponentRegistry.shared.descriptor(for: $0.descriptorId)?.symbol != .ground
        }) else {
            throw CircuitCompileError.emptyCircuit
        }

        // One shared, deterministic node mapping. Every ground symbol collapses
        // to node 0, matching SPICE.
        let nodeMap = NodeMap.build(from: nets)
        var nodeNames = nodeMap.nodeNames
        let nodeIndexByNet = nodeMap.nodeIndexByNetID

        var nodeByPin: [PinRef: Int] = [:]
        for net in nets {
            guard let node = nodeIndexByNet[net.id] else { continue }
            for pin in net.connectedPins {
                nodeByPin[pin] = node
            }
        }

        var elements: [LinearCircuit.Element] = []

        func node(for pin: PinRef, reference: String) throws -> Int {
            guard let node = nodeByPin[pin] else {
                throw CircuitCompileError.missingPin(reference: reference)
            }
            return node
        }

        func twoTerminalNodes(for symbol: SymbolInstance, descriptor: ComponentDescriptor) throws -> (Int, Int) {
            guard descriptor.pins.count == 2,
                  let firstPin = descriptor.pins.first,
                  let lastPin = descriptor.pins.last else {
                throw CircuitCompileError.unsupportedComponent(
                    reference: symbol.refDes,
                    descriptor: descriptor.displayName
                )
            }
            let a = try node(for: PinRef(symbolId: symbol.id, pinId: firstPin.id), reference: symbol.refDes)
            let b = try node(for: PinRef(symbolId: symbol.id, pinId: lastPin.id), reference: symbol.refDes)
            return (a, b)
        }

        func threeTerminalNodes(for symbol: SymbolInstance, descriptor: ComponentDescriptor) throws -> (collector: Int, base: Int, emitter: Int) {
            guard descriptor.pins.count == 3 else {
                throw CircuitCompileError.unsupportedComponent(
                    reference: symbol.refDes,
                    descriptor: descriptor.displayName
                )
            }
            let collector = try node(for: PinRef(symbolId: symbol.id, pinId: descriptor.pins[0].id), reference: symbol.refDes)
            let base = try node(for: PinRef(symbolId: symbol.id, pinId: descriptor.pins[1].id), reference: symbol.refDes)
            let emitter = try node(for: PinRef(symbolId: symbol.id, pinId: descriptor.pins[2].id), reference: symbol.refDes)
            return (collector, base, emitter)
        }

        func fourTerminalNodes(for symbol: SymbolInstance, descriptor: ComponentDescriptor) throws -> (drain: Int, gate: Int, source: Int, bulk: Int) {
            guard descriptor.pins.count == 4 else {
                throw CircuitCompileError.unsupportedComponent(
                    reference: symbol.refDes,
                    descriptor: descriptor.displayName
                )
            }
            let drain = try node(for: PinRef(symbolId: symbol.id, pinId: descriptor.pins[0].id), reference: symbol.refDes)
            let gate = try node(for: PinRef(symbolId: symbol.id, pinId: descriptor.pins[1].id), reference: symbol.refDes)
            let source = try node(for: PinRef(symbolId: symbol.id, pinId: descriptor.pins[2].id), reference: symbol.refDes)
            let bulk = try node(for: PinRef(symbolId: symbol.id, pinId: descriptor.pins[3].id), reference: symbol.refDes)
            return (drain, gate, source, bulk)
        }

        func parameter(_ name: String, descriptor: ComponentDescriptor, symbol: SymbolInstance) throws -> Double {
            guard descriptor.parameters.contains(where: { $0.id == name }),
                  let value = symbol.parameters[name], value.isFinite else {
                throw CircuitCompileError.missingParameter(reference: symbol.refDes, parameter: name)
            }
            return value
        }

        func positive(_ value: Double, parameter: String, symbol: SymbolInstance) throws -> Double {
            guard value > 0 else {
                throw CircuitCompileError.invalidParameter(reference: symbol.refDes, parameter: parameter)
            }
            return value
        }

        for symbol in symbols.sorted(by: { $0.refDes < $1.refDes }) {
            guard let descriptor = ComponentRegistry.shared.descriptor(for: symbol.descriptorId) else {
                throw CircuitCompileError.unsupportedComponent(
                    reference: symbol.refDes,
                    descriptor: symbol.descriptorId
                )
            }

            switch descriptor.symbol {
            case .ground:
                continue
            case .subcircuit:
                throw CircuitCompileError.unsupportedComponent(
                    reference: symbol.refDes,
                    descriptor: descriptor.displayName
                )
            case .resistor:
                let (a, b) = try twoTerminalNodes(for: symbol, descriptor: descriptor)
                let resistance = try positive(
                    try parameter("resistance", descriptor: descriptor, symbol: symbol),
                    parameter: "resistance",
                    symbol: symbol
                )
                elements.append(.init(kind: .resistor, nodeA: a, nodeB: b, value: resistance, name: symbol.refDes))
            case .capacitor:
                let (a, b) = try twoTerminalNodes(for: symbol, descriptor: descriptor)
                let capacitance = try positive(
                    try parameter("capacitance", descriptor: descriptor, symbol: symbol),
                    parameter: "capacitance",
                    symbol: symbol
                )
                elements.append(.init(kind: .capacitor, nodeA: a, nodeB: b, value: capacitance, name: symbol.refDes))
            case .inductor:
                let (a, b) = try twoTerminalNodes(for: symbol, descriptor: descriptor)
                let inductance = try positive(
                    try parameter("inductance", descriptor: descriptor, symbol: symbol),
                    parameter: "inductance",
                    symbol: symbol
                )
                elements.append(.init(kind: .inductor, nodeA: a, nodeB: b, value: inductance, name: symbol.refDes))
            case .inductorSeries:
                let (a, b) = try twoTerminalNodes(for: symbol, descriptor: descriptor)
                let inductance = try positive(
                    try parameter("inductance", descriptor: descriptor, symbol: symbol),
                    parameter: "inductance",
                    symbol: symbol
                )
                let resistance = try parameter("seriesResistance", descriptor: descriptor, symbol: symbol)
                guard resistance >= 0 else {
                    throw CircuitCompileError.invalidParameter(reference: symbol.refDes, parameter: "series resistance")
                }
                if resistance > 0 {
                    let internalNode = nodeNames.count
                    nodeNames.append("\(symbol.refDes)_SER")
                    elements.append(.init(kind: .resistor, nodeA: a, nodeB: internalNode, value: resistance, name: "R\(symbol.refDes)_SER"))
                    elements.append(.init(kind: .inductor, nodeA: internalNode, nodeB: b, value: inductance, name: symbol.refDes))
                } else {
                    elements.append(.init(kind: .inductor, nodeA: a, nodeB: b, value: inductance, name: symbol.refDes))
                }
            case .voltageSource:
                let (a, b) = try twoTerminalNodes(for: symbol, descriptor: descriptor)
                let dc = try parameter("dcVoltage", descriptor: descriptor, symbol: symbol)
                let ac = try parameter("acMagnitude", descriptor: descriptor, symbol: symbol)
                let phase = try parameter("acPhaseDegrees", descriptor: descriptor, symbol: symbol)
                elements.append(.init(
                    kind: .voltageSource,
                    nodeA: a,
                    nodeB: b,
                    value: ac,
                    phaseDegrees: phase,
                    dcValue: dc,
                    acValue: ac,
                    name: symbol.refDes
                ))
            case .currentSource:
                let (a, b) = try twoTerminalNodes(for: symbol, descriptor: descriptor)
                let dc = try parameter("dcCurrent", descriptor: descriptor, symbol: symbol)
                let ac = try parameter("acMagnitude", descriptor: descriptor, symbol: symbol)
                let phase = try parameter("acPhaseDegrees", descriptor: descriptor, symbol: symbol)
                elements.append(.init(
                    kind: .currentSource,
                    nodeA: a,
                    nodeB: b,
                    value: ac,
                    phaseDegrees: phase,
                    dcValue: dc,
                    acValue: ac,
                    name: symbol.refDes
                ))
            case .diode:
                let (a, b) = try twoTerminalNodes(for: symbol, descriptor: descriptor)
                let saturation = try positive(
                    try parameter("saturationCurrent", descriptor: descriptor, symbol: symbol),
                    parameter: "saturation current",
                    symbol: symbol
                )
                let emission = try positive(
                    try parameter("emissionCoefficient", descriptor: descriptor, symbol: symbol),
                    parameter: "emission coefficient",
                    symbol: symbol
                )
                elements.append(.init(
                    kind: .diode,
                    nodeA: a,
                    nodeB: b,
                    value: 0,
                    diode: .init(saturationCurrent: saturation, emissionCoefficient: emission),
                    name: symbol.refDes
                ))
            case .npnTransistor, .pnpTransistor:
                let (collector, base, emitter) = try threeTerminalNodes(for: symbol, descriptor: descriptor)
                let saturation = try positive(
                    try parameter("saturationCurrent", descriptor: descriptor, symbol: symbol),
                    parameter: "saturation current",
                    symbol: symbol
                )
                let forwardBeta = try positive(
                    try parameter("forwardBeta", descriptor: descriptor, symbol: symbol),
                    parameter: "forward beta",
                    symbol: symbol
                )
                let reverseBeta = try positive(
                    try parameter("reverseBeta", descriptor: descriptor, symbol: symbol),
                    parameter: "reverse beta",
                    symbol: symbol
                )
                elements.append(.init(
                    kind: .bjt,
                    nodeA: collector,
                    nodeB: emitter,
                    nodeC: base,
                    value: 0,
                    bjt: .init(
                        polarity: descriptor.symbol == .pnpTransistor ? .pnp : .npn,
                        saturationCurrent: saturation,
                        forwardBeta: forwardBeta,
                        reverseBeta: reverseBeta
                    ),
                    name: symbol.refDes
                ))
            case .nmosTransistor, .pmosTransistor:
                let (drain, gate, source, bulk) = try fourTerminalNodes(for: symbol, descriptor: descriptor)
                let threshold = try parameter("thresholdVoltage", descriptor: descriptor, symbol: symbol)
                guard threshold.isFinite else {
                    throw CircuitCompileError.invalidParameter(reference: symbol.refDes, parameter: "threshold voltage")
                }
                let transconductance = try positive(
                    try parameter("transconductanceParameter", descriptor: descriptor, symbol: symbol),
                    parameter: "transconductance parameter",
                    symbol: symbol
                )
                let modulation = try parameter("channelLengthModulation", descriptor: descriptor, symbol: symbol)
                guard modulation >= 0 else {
                    throw CircuitCompileError.invalidParameter(reference: symbol.refDes, parameter: "channel-length modulation")
                }
                let bodyEffect = try parameter("bodyEffect", descriptor: descriptor, symbol: symbol)
                guard bodyEffect >= 0 else {
                    throw CircuitCompileError.invalidParameter(reference: symbol.refDes, parameter: "body effect")
                }
                let surfacePotential = try positive(
                    try parameter("surfacePotential", descriptor: descriptor, symbol: symbol),
                    parameter: "surface potential",
                    symbol: symbol
                )
                elements.append(.init(
                    kind: .mosfet,
                    nodeA: drain,
                    nodeB: source,
                    nodeC: gate,
                    nodeD: bulk,
                    value: 0,
                    mosfet: .init(
                        polarity: descriptor.symbol == .pmosTransistor ? .pmos : .nmos,
                        thresholdVoltage: threshold,
                        transconductanceParameter: transconductance,
                        channelLengthModulation: modulation,
                        bodyEffect: bodyEffect,
                        surfacePotential: surfacePotential
                    ),
                    name: symbol.refDes
                ))
            case .njfTransistor, .pjfTransistor:
                let nodes = try threeTerminalNodes(for: symbol, descriptor: descriptor)
                let threshold = try parameter("thresholdVoltage", descriptor: descriptor, symbol: symbol)
                guard threshold.isFinite else {
                    throw CircuitCompileError.invalidParameter(reference: symbol.refDes, parameter: "threshold voltage")
                }
                let transconductance = try positive(
                    try parameter("transconductanceParameter", descriptor: descriptor, symbol: symbol),
                    parameter: "transconductance parameter",
                    symbol: symbol
                )
                let modulation = try parameter("channelLengthModulation", descriptor: descriptor, symbol: symbol)
                guard modulation >= 0 else {
                    throw CircuitCompileError.invalidParameter(reference: symbol.refDes, parameter: "channel-length modulation")
                }
                let gateSaturation = try positive(
                    try parameter("gateSaturationCurrent", descriptor: descriptor, symbol: symbol),
                    parameter: "gate saturation current",
                    symbol: symbol
                )
                elements.append(.init(
                    kind: .jfet,
                    nodeA: nodes.collector,
                    nodeB: nodes.emitter,
                    nodeC: nodes.base,
                    value: 0,
                    jfet: .init(
                        polarity: descriptor.symbol == .pjfTransistor ? .pjf : .njf,
                        thresholdVoltage: threshold,
                        transconductanceParameter: transconductance,
                        channelLengthModulation: modulation,
                        gateSaturationCurrent: gateSaturation
                    ),
                    name: symbol.refDes
                ))
            }
        }

        return LinearCircuit(nodeNames: nodeNames, elements: elements)
    }
}
