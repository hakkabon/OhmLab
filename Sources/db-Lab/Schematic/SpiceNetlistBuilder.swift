import Foundation

public enum SpiceNetlistBuildError: LocalizedError {
    case missingGround
    case missingComponent(String)
    case missingParameter(reference: String, parameter: String)
    case invalidParameter(reference: String, parameter: String)
    case invalidReference(String)
    case duplicateReference(String)
    case missingPin(reference: String, pin: String)

    public var errorDescription: String? {
        switch self {
        case .missingGround:
            return "Add a ground symbol before generating a SPICE netlist."
        case .missingComponent(let reference):
            return "The component \(reference) has no registered definition."
        case .missingParameter(let reference, let parameter):
            return "\(reference) is missing the \(parameter) value."
        case .invalidParameter(let reference, let parameter):
            return "\(reference) has an invalid \(parameter) value."
        case .invalidReference(let reference):
            return "\(reference) is not a valid SPICE reference designator."
        case .duplicateReference(let reference):
            return "The reference designator \(reference) is used more than once."
        case .missingPin(let reference, let pin):
            return "\(reference) pin \(pin) is not part of a net."
        }
    }
}

@MainActor
public enum SpiceNetlistBuilder {
    public static func build(from document: SchematicDocument) throws -> String {
        let nets = ConnectivityBuilder.build(
            symbols: document.symbols,
            wires: document.wires,
            labels: document.netLabels
        )
        guard nets.contains(where: \.isGround) else {
            throw SpiceNetlistBuildError.missingGround
        }

        // Share the compiler's node mapping so exported names always match the
        // names the solver reports.
        let nodeMap = NodeMap.build(from: nets)
        var nodeByPin: [PinRef: String] = [:]
        for net in nets {
            guard let node = nodeMap.nodeNameByNetID[net.id] else { continue }
            for pin in net.connectedPins {
                nodeByPin[pin] = node
            }
        }

        var lines = ["* Generated from db-Lab schematic"]
        var modelLines: [String] = []
        var references = Set<String>()
        for symbol in document.symbols.sorted(by: { $0.refDes < $1.refDes }) {
            guard let descriptor = ComponentRegistry.shared.descriptor(for: symbol.descriptorId) else {
                throw SpiceNetlistBuildError.missingComponent(symbol.refDes)
            }
            if descriptor.symbol == .ground {
                continue
            }
            let normalizedReference = symbol.refDes.uppercased()
            guard normalizedReference.first == descriptor.prefix.first,
                  normalizedReference.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
                throw SpiceNetlistBuildError.invalidReference(symbol.refDes)
            }
            guard references.insert(normalizedReference).inserted else {
                throw SpiceNetlistBuildError.duplicateReference(symbol.refDes)
            }
            guard descriptor.pins.count == 2,
                  let firstPin = descriptor.pins.first,
                  let secondPin = descriptor.pins.last,
                  let firstNode = nodeByPin[PinRef(symbolId: symbol.id, pinId: firstPin.id)],
                  let secondNode = nodeByPin[PinRef(symbolId: symbol.id, pinId: secondPin.id)] else {
                throw SpiceNetlistBuildError.missingPin(reference: symbol.refDes, pin: "1 or 2")
            }

            switch descriptor.symbol {
            case .resistor:
                let value = try parameter("resistance", descriptor: descriptor, symbol: symbol)
                try validate(value, parameter: "resistance", symbol: symbol)
                lines.append("\(symbol.refDes) \(firstNode) \(secondNode) \(spiceNumber(value))")
            case .capacitor:
                let value = try parameter("capacitance", descriptor: descriptor, symbol: symbol)
                try validate(value, parameter: "capacitance", symbol: symbol)
                lines.append("\(symbol.refDes) \(firstNode) \(secondNode) \(spiceNumber(value))")
            case .inductor:
                let value = try parameter("inductance", descriptor: descriptor, symbol: symbol)
                try validate(value, parameter: "inductance", symbol: symbol)
                lines.append("\(symbol.refDes) \(firstNode) \(secondNode) \(spiceNumber(value))")
            case .inductorSeries:
                let inductance = try parameter("inductance", descriptor: descriptor, symbol: symbol)
                let resistance = try parameter("seriesResistance", descriptor: descriptor, symbol: symbol)
                try validate(inductance, parameter: "inductance", symbol: symbol)
                try validate(resistance, parameter: "series resistance", symbol: symbol, allowsZero: true)
                if resistance > 0 {
                    let internalNode = "\(symbol.refDes)_SER"
                    let resistorReference = "R\(String(symbol.refDes.dropFirst()))_SER"
                    guard references.insert(resistorReference.uppercased()).inserted else {
                        throw SpiceNetlistBuildError.duplicateReference(resistorReference)
                    }
                    lines.append("\(resistorReference) \(firstNode) \(internalNode) \(spiceNumber(resistance))")
                    lines.append("\(symbol.refDes) \(internalNode) \(secondNode) \(spiceNumber(inductance))")
                } else {
                    lines.append("\(symbol.refDes) \(firstNode) \(secondNode) \(spiceNumber(inductance))")
                }
            case .voltageSource:
                let (dc, ac, phase) = try sourceValues(descriptor: descriptor, symbol: symbol, dcKey: "dcVoltage")
                lines.append(
                    "\(symbol.refDes) \(firstNode) \(secondNode) "
                    + "DC \(spiceNumber(dc)) AC \(spiceNumber(ac)) \(spiceNumber(phase))"
                )
            case .currentSource:
                let (dc, ac, phase) = try sourceValues(descriptor: descriptor, symbol: symbol, dcKey: "dcCurrent")
                lines.append(
                    "\(symbol.refDes) \(firstNode) \(secondNode) "
                    + "DC \(spiceNumber(dc)) AC \(spiceNumber(ac)) \(spiceNumber(phase))"
                )
            case .diode:
                let saturation = try parameter("saturationCurrent", descriptor: descriptor, symbol: symbol)
                try validate(saturation, parameter: "saturation current", symbol: symbol)
                let emission = try parameter("emissionCoefficient", descriptor: descriptor, symbol: symbol)
                try validate(emission, parameter: "emission coefficient", symbol: symbol)
                let modelName = "DMOD\(symbol.refDes.dropFirst())"
                lines.append("\(symbol.refDes) \(firstNode) \(secondNode) \(modelName)")
                modelLines.append(
                    ".model \(modelName) D(IS=\(spiceNumber(saturation)) N=\(spiceNumber(emission)))"
                )
            case .ground:
                break
            }
        }
        lines.append(contentsOf: modelLines)
        lines.append(".end")
        return lines.joined(separator: "\n")
    }

    private static func parameter(
        _ name: String,
        descriptor: ComponentDescriptor,
        symbol: SymbolInstance
    ) throws -> Double {
        guard descriptor.parameters.contains(where: { $0.id == name }),
              let value = symbol.parameters[name] else {
            throw SpiceNetlistBuildError.missingParameter(reference: symbol.refDes, parameter: name)
        }
        return value
    }

    /// Reads a source's DC magnitude, AC magnitude, and AC phase, rejecting any
    /// non-finite entry. Negative DC values and phases are valid.
    private static func sourceValues(
        descriptor: ComponentDescriptor,
        symbol: SymbolInstance,
        dcKey: String
    ) throws -> (dc: Double, ac: Double, phase: Double) {
        func value(_ key: String) throws -> Double {
            let raw = try parameter(key, descriptor: descriptor, symbol: symbol)
            guard raw.isFinite else {
                throw SpiceNetlistBuildError.invalidParameter(reference: symbol.refDes, parameter: key)
            }
            return raw
        }
        let dc = try value(dcKey)
        let ac = try value("acMagnitude")
        guard ac >= 0 else {
            throw SpiceNetlistBuildError.invalidParameter(reference: symbol.refDes, parameter: "acMagnitude")
        }
        return (dc, ac, try value("acPhaseDegrees"))
    }

    private static func validate(
        _ value: Double,
        parameter: String,
        symbol: SymbolInstance,
        allowsZero: Bool = false
    ) throws {
        guard value.isFinite, allowsZero ? value >= 0 : value > 0 else {
            throw SpiceNetlistBuildError.invalidParameter(reference: symbol.refDes, parameter: parameter)
        }
    }

    private static func spiceNumber(_ value: Double) -> String {
        String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
