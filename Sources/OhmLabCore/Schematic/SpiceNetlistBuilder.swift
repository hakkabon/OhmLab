import Foundation

public enum SpiceNetlistBuildError: LocalizedError {
    case missingGround
    case missingComponent(String)
    case missingParameter(reference: String, parameter: String)
    case invalidParameter(reference: String, parameter: String)
    case invalidReference(String)
    case duplicateReference(String)
    case missingPin(reference: String, pin: String)
    case recursiveSubcircuit(String)
    case missingSheet(String)

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
        case .recursiveSubcircuit(let name):
            return "The subcircuit \(name) instantiates itself (directly or indirectly)."
        case .missingSheet(let name):
            return "The subcircuit instance \(name) refers to a sheet that no longer exists."
        }
    }
}

/// Projects a schematic (including any subcircuit hierarchy) into SPICE text.
///
/// Flat circuits emit primitives and `.model` cards exactly as before. When the
/// snapshot carries child sheets, each referenced sheet becomes a `.subckt`
/// block and each instance an `X` line, so the existing SPICE parser performs
/// the flattening. Buses expand naturally: member nets carry their `NAME[k]`
/// names straight through.
public enum SpiceNetlistBuilder {
    @MainActor
    public static func build(from document: SchematicDocument) throws -> String {
        try build(snapshot: document.snapshot())
    }

    public static func build(snapshot: SchematicSnapshot) throws -> String {
        var emitter = Emitter(snapshot: snapshot)
        return try emitter.build()
    }

    private struct Emitter {
        let root: Sheet
        let catalog: SubcircuitCatalog
        var emittedSheets: Set<UUID> = []
        var recursionStack: [UUID] = []
        var usedModelNames: Set<String> = []
        var usedSubcircuitNames: Set<String> = []
        var subcircuitNameByID: [UUID: String] = [:]

        init(snapshot: SchematicSnapshot) {
            root = Sheet(
                name: "Main",
                symbols: snapshot.symbols,
                wires: snapshot.wires,
                netLabels: snapshot.netLabels
            )
            catalog = SubcircuitCatalog(sheets: snapshot.sheets)
        }

        mutating func build() throws -> String {
            var elementLines: [String] = []
            var modelLines: [String] = []
            try emitElements(in: root, isRoot: true, lines: &elementLines, models: &modelLines)

            var definitions: [String] = []
            for child in referencedChildren(in: root) {
                try emitDefinition(child, definitions: &definitions, models: &modelLines)
            }

            var lines = ["* Generated from OhmLab schematic"]
            lines += elementLines
            lines += definitions
            lines += modelLines
            lines.append(".end")
            return lines.joined(separator: "\n")
        }

        private func referencedChildren(in sheet: Sheet) -> [Sheet] {
            var seen: Set<UUID> = []
            var result: [Sheet] = []
            for symbol in sheet.symbols.sorted(by: { $0.refDes < $1.refDes }) {
                guard let reference = symbol.sheetRef,
                      !seen.contains(reference),
                      let child = catalog.sheet(id: reference) else { continue }
                seen.insert(reference)
                result.append(child)
            }
            return result
        }

        private mutating func emitDefinition(
            _ sheet: Sheet,
            definitions: inout [String],
            models: inout [String]
        ) throws {
            guard !emittedSheets.contains(sheet.id) else { return }
            guard !recursionStack.contains(sheet.id) else {
                throw SpiceNetlistBuildError.recursiveSubcircuit(sheet.name)
            }
            recursionStack.append(sheet.id)
            var body: [String] = []
            try emitElements(in: sheet, isRoot: false, lines: &body, models: &models)
            for child in referencedChildren(in: sheet) {
                try emitDefinition(child, definitions: &definitions, models: &models)
            }
            recursionStack.removeLast()
            emittedSheets.insert(sheet.id)

            var header = ".subckt \(subcircuitName(for: sheet))"
            if !sheet.ports.isEmpty {
                header += " " + sheet.ports.map { $0.name }.joined(separator: " ")
            }
            definitions.append(header)
            definitions.append(contentsOf: body.map { "  \($0)" })
            definitions.append(".ends")
        }

        private mutating func emitElements(
            in sheet: Sheet,
            isRoot: Bool,
            lines: inout [String],
            models: inout [String]
        ) throws {
            let nets = ConnectivityBuilder.build(
                symbols: sheet.symbols,
                wires: sheet.wires,
                labels: sheet.netLabels,
                catalog: catalog
            )
            if isRoot {
                guard nets.contains(where: \.isGround) else {
                    throw SpiceNetlistBuildError.missingGround
                }
            }

            let nodeMap = NodeMap.build(from: nets)
            var nodeByPin: [PinRef: String] = [:]
            for net in nets {
                guard let node = nodeMap.nodeNameByNetID[net.id] else { continue }
                for pin in net.connectedPins {
                    nodeByPin[pin] = node
                }
            }

            var references = Set<String>()
            for symbol in sheet.symbols.sorted(by: { $0.refDes < $1.refDes }) {
                guard let descriptor = catalog.descriptor(for: symbol) else {
                    throw SpiceNetlistBuildError.missingComponent(symbol.refDes)
                }
                if descriptor.symbol == .ground { continue }

                let normalizedReference = symbol.refDes.uppercased()
                guard normalizedReference.first == descriptor.prefix.first,
                      normalizedReference.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
                    throw SpiceNetlistBuildError.invalidReference(symbol.refDes)
                }
                guard references.insert(normalizedReference).inserted else {
                    throw SpiceNetlistBuildError.duplicateReference(symbol.refDes)
                }

                if symbol.isSubcircuitInstance {
                    try emitInstance(symbol, descriptor: descriptor, nodeByPin: nodeByPin, lines: &lines)
                    continue
                }

                if descriptor.symbol == .npnTransistor || descriptor.symbol == .pnpTransistor {
                    guard descriptor.pins.count == 3,
                          let collectorNode = nodeByPin[PinRef(symbolId: symbol.id, pinId: descriptor.pins[0].id)],
                          let baseNode = nodeByPin[PinRef(symbolId: symbol.id, pinId: descriptor.pins[1].id)],
                          let emitterNode = nodeByPin[PinRef(symbolId: symbol.id, pinId: descriptor.pins[2].id)] else {
                        throw SpiceNetlistBuildError.missingPin(reference: symbol.refDes, pin: "collector, base, or emitter")
                    }
                    let saturation = try parameter("saturationCurrent", descriptor: descriptor, symbol: symbol)
                    try validate(saturation, parameter: "saturation current", symbol: symbol)
                    let forwardBeta = try parameter("forwardBeta", descriptor: descriptor, symbol: symbol)
                    try validate(forwardBeta, parameter: "forward beta", symbol: symbol)
                    let reverseBeta = try parameter("reverseBeta", descriptor: descriptor, symbol: symbol)
                    try validate(reverseBeta, parameter: "reverse beta", symbol: symbol)
                    let modelName = modelName(base: "QMOD\(symbol.refDes.dropFirst())")
                    let type = descriptor.symbol == .pnpTransistor ? "PNP" : "NPN"
                    lines.append("\(symbol.refDes) \(collectorNode) \(baseNode) \(emitterNode) \(modelName)")
                    models.append(
                        ".model \(modelName) \(type)(IS=\(spiceNumber(saturation)) "
                        + "BF=\(spiceNumber(forwardBeta)) BR=\(spiceNumber(reverseBeta)))"
                    )
                    continue
                }
                if descriptor.symbol == .nmosTransistor || descriptor.symbol == .pmosTransistor {
                    guard descriptor.pins.count == 4,
                          let drainNode = nodeByPin[PinRef(symbolId: symbol.id, pinId: descriptor.pins[0].id)],
                          let gateNode = nodeByPin[PinRef(symbolId: symbol.id, pinId: descriptor.pins[1].id)],
                          let sourceNode = nodeByPin[PinRef(symbolId: symbol.id, pinId: descriptor.pins[2].id)],
                          let bulkNode = nodeByPin[PinRef(symbolId: symbol.id, pinId: descriptor.pins[3].id)] else {
                        throw SpiceNetlistBuildError.missingPin(reference: symbol.refDes, pin: "drain, gate, source, or bulk")
                    }
                    let threshold = try parameter("thresholdVoltage", descriptor: descriptor, symbol: symbol)
                    guard threshold.isFinite else {
                        throw SpiceNetlistBuildError.invalidParameter(reference: symbol.refDes, parameter: "thresholdVoltage")
                    }
                    let transconductance = try parameter("transconductanceParameter", descriptor: descriptor, symbol: symbol)
                    try validate(transconductance, parameter: "transconductance parameter", symbol: symbol)
                    let modulation = try parameter("channelLengthModulation", descriptor: descriptor, symbol: symbol)
                    try validate(modulation, parameter: "channel-length modulation", symbol: symbol, allowsZero: true)
                    let bodyEffect = try parameter("bodyEffect", descriptor: descriptor, symbol: symbol)
                    try validate(bodyEffect, parameter: "body effect", symbol: symbol, allowsZero: true)
                    let surfacePotential = try parameter("surfacePotential", descriptor: descriptor, symbol: symbol)
                    try validate(surfacePotential, parameter: "surface potential", symbol: symbol)
                    let modelName = modelName(base: "MMOD\(symbol.refDes.dropFirst())")
                    let type = descriptor.symbol == .pmosTransistor ? "PMOS" : "NMOS"
                    lines.append("\(symbol.refDes) \(drainNode) \(gateNode) \(sourceNode) \(bulkNode) \(modelName)")
                    models.append(
                        ".model \(modelName) \(type)(VTO=\(spiceNumber(threshold)) "
                        + "KP=\(spiceNumber(transconductance)) LAMBDA=\(spiceNumber(modulation)) "
                        + "GAMMA=\(spiceNumber(bodyEffect)) PHI=\(spiceNumber(surfacePotential)))"
                    )
                    continue
                }
                if descriptor.symbol == .njfTransistor || descriptor.symbol == .pjfTransistor {
                    guard descriptor.pins.count == 3,
                          let drainNode = nodeByPin[PinRef(symbolId: symbol.id, pinId: descriptor.pins[0].id)],
                          let gateNode = nodeByPin[PinRef(symbolId: symbol.id, pinId: descriptor.pins[1].id)],
                          let sourceNode = nodeByPin[PinRef(symbolId: symbol.id, pinId: descriptor.pins[2].id)] else {
                        throw SpiceNetlistBuildError.missingPin(reference: symbol.refDes, pin: "drain, gate, or source")
                    }
                    let threshold = try parameter("thresholdVoltage", descriptor: descriptor, symbol: symbol)
                    guard threshold.isFinite else {
                        throw SpiceNetlistBuildError.invalidParameter(reference: symbol.refDes, parameter: "thresholdVoltage")
                    }
                    let transconductance = try parameter("transconductanceParameter", descriptor: descriptor, symbol: symbol)
                    try validate(transconductance, parameter: "transconductance parameter", symbol: symbol)
                    let modulation = try parameter("channelLengthModulation", descriptor: descriptor, symbol: symbol)
                    try validate(modulation, parameter: "channel-length modulation", symbol: symbol, allowsZero: true)
                    let gateSaturation = try parameter("gateSaturationCurrent", descriptor: descriptor, symbol: symbol)
                    try validate(gateSaturation, parameter: "gate saturation current", symbol: symbol)
                    let modelName = modelName(base: "JMOD\(symbol.refDes.dropFirst())")
                    let type = descriptor.symbol == .pjfTransistor ? "PJF" : "NJF"
                    lines.append("\(symbol.refDes) \(drainNode) \(gateNode) \(sourceNode) \(modelName)")
                    models.append(
                        ".model \(modelName) \(type)(VTO=\(spiceNumber(threshold)) "
                        + "BETA=\(spiceNumber(transconductance)) LAMBDA=\(spiceNumber(modulation)) "
                        + "IS=\(spiceNumber(gateSaturation)))"
                    )
                    continue
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
                    let modelName = modelName(base: "DMOD\(symbol.refDes.dropFirst())")
                    lines.append("\(symbol.refDes) \(firstNode) \(secondNode) \(modelName)")
                    models.append(
                        ".model \(modelName) D(IS=\(spiceNumber(saturation)) N=\(spiceNumber(emission)))"
                    )
                case .npnTransistor, .pnpTransistor, .nmosTransistor, .pmosTransistor,
                     .njfTransistor, .pjfTransistor, .ground, .subcircuit:
                    break // handled above
                }
            }
        }

        private mutating func emitInstance(
            _ symbol: SymbolInstance,
            descriptor: ComponentDescriptor,
            nodeByPin: [PinRef: String],
            lines: inout [String]
        ) throws {
            guard let reference = symbol.sheetRef, let sheet = catalog.sheet(id: reference) else {
                throw SpiceNetlistBuildError.missingSheet(symbol.refDes)
            }
            var nodes: [String] = []
            for port in sheet.ports {
                guard let node = nodeByPin[PinRef(symbolId: symbol.id, pinId: port.name)] else {
                    throw SpiceNetlistBuildError.missingPin(reference: symbol.refDes, pin: port.name)
                }
                nodes.append(node)
            }
            let instanceLine = ([symbol.refDes] + nodes + [subcircuitName(for: sheet)]).joined(separator: " ")
            lines.append(instanceLine)
        }

        private mutating func modelName(base: String) -> String {
            var candidate = base
            var suffix = 2
            while !usedModelNames.insert(candidate).inserted {
                candidate = "\(base)_\(suffix)"
                suffix += 1
            }
            return candidate
        }

        private mutating func subcircuitName(for sheet: Sheet) -> String {
            if let existing = subcircuitNameByID[sheet.id] { return existing }
            let base = sanitizeIdentifier(sheet.name)
            var candidate = base
            var suffix = 2
            while !usedSubcircuitNames.insert(candidate).inserted {
                candidate = "\(base)_\(suffix)"
                suffix += 1
            }
            subcircuitNameByID[sheet.id] = candidate
            return candidate
        }

        private func sanitizeIdentifier(_ raw: String) -> String {
            var result = raw.trimmingCharacters(in: .whitespaces)
            result = String(result.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
            if result.isEmpty { result = "SUBCKT" }
            if let first = result.first, first.isNumber { result = "S" + result }
            return result
        }

        private func parameter(
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

        private func sourceValues(
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

        private func validate(
            _ value: Double,
            parameter: String,
            symbol: SymbolInstance,
            allowsZero: Bool = false
        ) throws {
            guard value.isFinite, allowsZero ? value >= 0 : value > 0 else {
                throw SpiceNetlistBuildError.invalidParameter(reference: symbol.refDes, parameter: parameter)
            }
        }

        private func spiceNumber(_ value: Double) -> String {
            String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)
        }
    }
}
