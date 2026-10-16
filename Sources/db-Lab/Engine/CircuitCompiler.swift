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
        try compile(symbols: document.symbols, wires: document.wires, labels: document.netLabels)
    }

    public static func compile(
        symbols: [SymbolInstance],
        wires: [WireSegment],
        labels: [NetLabel] = []
    ) throws -> LinearCircuit {
        let nets = ConnectivityBuilder.build(symbols: symbols, wires: wires, labels: labels)

        guard let groundNet = nets.first(where: \.isGround) else {
            throw CircuitCompileError.missingGround
        }
        guard symbols.contains(where: {
            ComponentRegistry.shared.descriptor(for: $0.descriptorId)?.symbol != .ground
        }) else {
            throw CircuitCompileError.emptyCircuit
        }

        var nodeNames = ["0"]
        var nodeIndexByNet: [Int: Int] = [:]
        // Every ground symbol is the same reference node, matching SPICE's node 0.
        for net in nets where net.isGround {
            nodeIndexByNet[net.id] = 0
        }
        for net in nets.filter({ !$0.isGround }).sorted(by: { $0.id < $1.id }) {
            nodeIndexByNet[net.id] = nodeNames.count
            nodeNames.append(net.name)
        }

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
                let magnitude = try parameter("voltage", descriptor: descriptor, symbol: symbol)
                elements.append(.init(kind: .voltageSource, nodeA: a, nodeB: b, value: magnitude, name: symbol.refDes))
            case .currentSource:
                let (a, b) = try twoTerminalNodes(for: symbol, descriptor: descriptor)
                let magnitude = try parameter("current", descriptor: descriptor, symbol: symbol)
                elements.append(.init(kind: .currentSource, nodeA: a, nodeB: b, value: magnitude, name: symbol.refDes))
            }
        }

        return LinearCircuit(nodeNames: nodeNames, elements: elements)
    }
}
