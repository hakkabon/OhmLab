// SchematicImporter.swift
// Best-effort conversion of a SPICE netlist into a hierarchical schematic.
//
// Elements are placed on a grid, each pin is routed orthogonally to a
// per-net rail, and nets are labelled so the drawing round-trips back to a
// netlist. `.subckt` blocks become child sheets; `X` instances become
// subcircuit-instance symbols whose pins are the referenced sheet's ports.
//
// The router is deliberately conservative: every pin gets its own vertical
// "lane" and the only shared geometry is a single horizontal rail per net, so
// crossing wires never merge (connectivity only forms at shared vertices).

import CoreGraphics
import Foundation

public struct SchematicImportResult {
    public var snapshot: SchematicSnapshot
    public var warnings: [String]

    public init(snapshot: SchematicSnapshot, warnings: [String]) {
        self.snapshot = snapshot
        self.warnings = warnings
    }
}

public enum SchematicImporter {
    private static let groundAliases: Set<String> = ["0", "GND", "GROUND", "AGND"]

    public static func importNetlist(_ text: String) -> SchematicImportResult {
        var warnings: [String] = []

        let scan = SpiceNetlistParser.scanDefinitions(text)
        warnings.append(contentsOf: scan.warnings)

        let structure = scanStructure(text)
        warnings.append(contentsOf: structure.warnings)

        // Create every sheet up front (id + ports) so instances can reference
        // them before any body is drawn.
        var sheets: [Sheet] = []
        var sheetIdByName: [String: UUID] = [:]
        for definition in structure.subcircuits {
            let ports = definition.ports.map { SheetPort(name: $0, isInput: true) }
            let sheet = Sheet(name: definition.name, ports: ports)
            sheets.append(sheet)
            sheetIdByName[definition.name.uppercased()] = sheet.id
        }

        let context = BuildContext(
            models: scan.definitions,
            sheetIdByName: sheetIdByName,
            catalog: SubcircuitCatalog(sheets: sheets)
        )

        let root = buildContent(
            lines: structure.root,
            ports: [],
            context: context,
            warnings: &warnings
        )

        for index in sheets.indices {
            let definition = structure.subcircuits[index]
            let content = buildContent(
                lines: definition.lines,
                ports: definition.ports,
                context: context,
                warnings: &warnings
            )
            sheets[index].symbols = content.symbols
            sheets[index].wires = content.wires
            sheets[index].netLabels = content.netLabels
        }

        let snapshot = SchematicSnapshot(
            symbols: root.symbols,
            wires: root.wires,
            netLabels: root.netLabels,
            sheets: sheets
        )
        return SchematicImportResult(snapshot: snapshot, warnings: warnings)
    }

    // MARK: - Structure scan

    private struct SubcircuitStructure {
        var name: String
        var ports: [String]
        var lines: [String]
    }

    private struct Structure {
        var root: [String]
        var subcircuits: [SubcircuitStructure]
        var warnings: [String]
    }

    private static func scanStructure(_ text: String) -> Structure {
        var root: [String] = []
        var subcircuits: [SubcircuitStructure] = []
        var warnings: [String] = []
        var current: SubcircuitStructure?

        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lineNumber = offset + 1
            let stripped = SpiceNetlistParser.stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty || stripped.hasPrefix("*") { continue }
            let tokens = SpiceNetlistParser.splitTokens(stripped)
            guard let first = tokens.first else { continue }
            let directive = first.lowercased()

            switch directive {
            case ".subckt":
                if let open = current {
                    warnings.append("Nested .subckt on line \(lineNumber); \(open.name) was closed early.")
                    subcircuits.append(open)
                }
                current = SubcircuitStructure(
                    name: tokens.count > 1 ? tokens[1] : "SUBCKT\(subcircuits.count + 1)",
                    ports: ports(from: tokens),
                    lines: []
                )
            case ".ends":
                if let finished = current { subcircuits.append(finished) }
                current = nil
            default:
                guard !stripped.hasPrefix(".") else { continue }
                if current != nil {
                    current?.lines.append(stripped)
                } else {
                    root.append(stripped)
                }
            }
        }

        if let open = current {
            warnings.append("Subcircuit \(open.name) was missing its .ends.")
            subcircuits.append(open)
        }
        return Structure(root: root, subcircuits: subcircuits, warnings: warnings)
    }

    private static func ports(from tokens: [String]) -> [String] {
        var ports: [String] = []
        var inParameters = false
        for token in tokens.dropFirst(2) {
            if token.lowercased() == "params:" {
                inParameters = true
            } else if token.contains("=") {
                inParameters = true
            } else if !inParameters {
                ports.append(token)
            }
        }
        return ports
    }

    // MARK: - Build context

    private struct BuildContext {
        var models: LibraryDefinitions
        var sheetIdByName: [String: UUID]
        var catalog: SubcircuitCatalog
    }

    private struct SheetContent {
        var symbols: [SymbolInstance] = []
        var wires: [WireSegment] = []
        var netLabels: [NetLabel] = []
    }

    private enum DeviceKind {
        case resistor, capacitor, inductor, voltageSource, currentSource, diode
        case bjt, mosfet, jfet
        case subcircuit(name: String)
    }

    private struct RawDevice {
        var reference: String
        var kind: DeviceKind
        var nodes: [String]
        var trailing: [String]
    }

    private struct Resolved {
        var symbol: SymbolInstance
        var descriptor: ComponentDescriptor
        /// One node name per descriptor pin, in pin order.
        var nodes: [String]
    }

    // MARK: - Content build

    private static func buildContent(
        lines: [String],
        ports: [String],
        context: BuildContext,
        warnings: inout [String]
    ) -> SheetContent {
        let joined = joinContinuations(lines)
        var devices: [RawDevice] = []
        for line in joined {
            if let device = parseDevice(line, warnings: &warnings) {
                devices.append(device)
            }
        }

        // Resolve every device, then assign grid positions.
        var resolved: [Resolved] = []
        for device in devices {
            if let entry = resolve(device, context: context, warnings: &warnings) {
                resolved.append(entry)
            }
        }
        guard !resolved.isEmpty else { return SheetContent() }

        layout(&resolved)

        // Gather each pin's net and its private vertical lane.
        var netPins: [String: [(point: GridPoint, lane: Int)]] = [:]
        var displayNameByKey: [String: String] = [:]
        var netOrder: [String] = []

        for entry in resolved {
            var rightLanes = 0
            var leftLanes = 0
            for (index, pin) in entry.descriptor.pins.enumerated() {
                guard index < entry.nodes.count else { break }
                let location = PinGeometry.location(of: pin, on: entry.symbol)
                let offset = PinGeometry.rotatedOffset(
                    forPinAt: pin.position,
                    rotation: entry.symbol.rotation
                )
                let lane: Int
                if offset.x >= 0 {
                    lane = entry.symbol.position.x + 4 + rightLanes
                    rightLanes += 1
                } else {
                    lane = entry.symbol.position.x - 4 - leftLanes
                    leftLanes += 1
                }
                let key = nodeKey(entry.nodes[index])
                if netPins[key] == nil { netOrder.append(key) }
                netPins[key, default: []].append((location, lane))
                if displayNameByKey[key] == nil {
                    displayNameByKey[key] = displayName(entry.nodes[index])
                }
            }
        }

        let maxPinY = netPins.values.flatMap { $0 }.map(\.point.y).max() ?? 0
        let railBase = maxPinY + 6

        var content = SheetContent()
        content.symbols = resolved.map(\.symbol)

        var railYByKey: [String: Int] = [:]
        var minLaneByKey: [String: Int] = [:]

        for (netIndex, key) in netOrder.enumerated() {
            let pins = netPins[key] ?? []
            let railY = railBase + netIndex * 2
            railYByKey[key] = railY
            let lanes = pins.map(\.lane)
            let minLane = lanes.min() ?? 0
            let maxLane = lanes.max() ?? 0
            minLaneByKey[key] = minLane

            // Orthogonal route: pin -> across to its lane -> down to the rail.
            for pin in pins {
                content.wires.append(WireSegment(points: [
                    pin.point,
                    GridPoint(pin.lane, pin.point.y),
                    GridPoint(pin.lane, railY)
                ]))
            }
            if minLane != maxLane {
                content.wires.append(WireSegment(points: [
                    GridPoint(minLane, railY),
                    GridPoint(maxLane, railY)
                ]))
            }

            // Ground net gets a ground symbol and no label; everything else is
            // labelled with its original node name.
            if key == "0" {
                let ground = SymbolInstance(
                    descriptorId: "ground",
                    refDes: "GND1",
                    position: GridPoint(minLane, railY + 1)
                )
                content.symbols.append(ground)
            } else if let name = displayNameByKey[key] {
                content.netLabels.append(NetLabel(name: name, position: GridPoint(minLane, railY)))
            }
        }

        return content
    }

    private static func joinContinuations(_ lines: [String]) -> [String] {
        var result: [String] = []
        for line in lines {
            if line.hasPrefix("+"), !result.isEmpty {
                result[result.count - 1] += " " + line.dropFirst().trimmingCharacters(in: .whitespaces)
            } else {
                result.append(line)
            }
        }
        return result
    }

    private static func layout(_ resolved: inout [Resolved]) {
        let count = resolved.count
        let columns = min(4, max(1, Int(ceil(Double(count).squareRoot()))))
        for index in resolved.indices {
            let column = index % columns
            let row = index / columns
            let position = GridPoint(8 + column * 28 + row * 5, 8 + row * 12)
            resolved[index].symbol.position = position
        }
    }

    // MARK: - Device parsing

    private static func parseDevice(_ line: String, warnings: inout [String]) -> RawDevice? {
        let tokens = SpiceNetlistParser.splitTokens(line)
        guard let head = tokens.first, let designator = head.uppercased().first else { return nil }
        let rest = Array(tokens.dropFirst())

        switch designator {
        case "R", "C", "L", "V", "I", "D":
            guard rest.count >= 2 else {
                warnings.append("Skipped malformed element \"\(head)\".")
                return nil
            }
            let kind: DeviceKind
            switch designator {
            case "R": kind = .resistor
            case "C": kind = .capacitor
            case "L": kind = .inductor
            case "V": kind = .voltageSource
            case "I": kind = .currentSource
            default: kind = .diode
            }
            return RawDevice(reference: head, kind: kind, nodes: [rest[0], rest[1]], trailing: Array(rest.dropFirst(2)))
        case "Q":
            guard rest.count >= 3 else {
                warnings.append("Skipped malformed transistor \"\(head)\".")
                return nil
            }
            return RawDevice(reference: head, kind: .bjt, nodes: [rest[0], rest[1], rest[2]], trailing: Array(rest.dropFirst(3)))
        case "M":
            guard rest.count >= 4 else {
                warnings.append("Skipped malformed MOSFET \"\(head)\".")
                return nil
            }
            return RawDevice(reference: head, kind: .mosfet, nodes: Array(rest.prefix(4)), trailing: Array(rest.dropFirst(4)))
        case "J":
            guard rest.count >= 3 else {
                warnings.append("Skipped malformed JFET \"\(head)\".")
                return nil
            }
            return RawDevice(reference: head, kind: .jfet, nodes: [rest[0], rest[1], rest[2]], trailing: Array(rest.dropFirst(3)))
        case "X":
            var nodeTokens: [String] = []
            for token in rest where !token.contains("=") && token.lowercased() != "params:" {
                nodeTokens.append(token)
            }
            guard let name = nodeTokens.last else {
                warnings.append("Skipped malformed subcircuit instance \"\(head)\".")
                return nil
            }
            return RawDevice(
                reference: head,
                kind: .subcircuit(name: name),
                nodes: Array(nodeTokens.dropLast()),
                trailing: []
            )
        default:
            warnings.append("Skipped unsupported element \"\(head)\".")
            return nil
        }
    }

    private static func resolve(
        _ device: RawDevice,
        context: BuildContext,
        warnings: inout [String]
    ) -> Resolved? {
        let node = device.reference

        switch device.kind {
        case .resistor, .capacitor, .inductor:
            let descriptorId: String
            let parameter: String
            switch device.kind {
            case .resistor: descriptorId = "resistor"; parameter = "resistance"
            case .capacitor: descriptorId = "capacitor"; parameter = "capacitance"
            default: descriptorId = "inductor"; parameter = "inductance"
            }
            guard let descriptor = ComponentRegistry.shared.descriptor(for: descriptorId) else { return nil }
            var parameters = descriptor.defaultParameterValues
            if let value = numeric(device.trailing.first) {
                parameters[parameter] = value
            } else {
                warnings.append("\(node): using a default \(parameter) (no value given).")
            }
            return Resolved(
                symbol: SymbolInstance(descriptorId: descriptorId, refDes: node, position: .init(0, 0), parameters: parameters),
                descriptor: descriptor,
                nodes: device.nodes
            )

        case .voltageSource, .currentSource:
            let isVoltage = { if case .voltageSource = device.kind { return true } else { return false } }()
            let descriptorId = isVoltage ? "voltage-source" : "current-source"
            guard let descriptor = ComponentRegistry.shared.descriptor(for: descriptorId) else { return nil }
            var parameters = descriptor.defaultParameterValues
            let source = parseSource(device.trailing)
            if !source.recognized {
                warnings.append("\(node): source waveform was not fully understood; DC/AC values may be empty.")
            }
            parameters[isVoltage ? "dcVoltage" : "dcCurrent"] = source.dc ?? 0
            parameters["acMagnitude"] = source.ac ?? 0
            parameters["acPhaseDegrees"] = source.phase ?? 0
            return Resolved(
                symbol: SymbolInstance(descriptorId: descriptorId, refDes: node, position: .init(0, 0), parameters: parameters),
                descriptor: descriptor,
                nodes: device.nodes
            )

        case .diode:
            guard let descriptor = ComponentRegistry.shared.descriptor(for: "diode") else { return nil }
            var parameters = descriptor.defaultParameterValues
            let modelName = device.trailing.first?.uppercased()
            if let name = modelName, let model = context.models.diodeModels[name] {
                parameters["saturationCurrent"] = model.saturationCurrent
                parameters["emissionCoefficient"] = model.emissionCoefficient
            } else if let name = modelName {
                warnings.append("\(node): model \(name) was not found; diode uses editor defaults.")
            }
            return Resolved(
                symbol: SymbolInstance(descriptorId: "diode", refDes: node, position: .init(0, 0), parameters: parameters),
                descriptor: descriptor,
                nodes: device.nodes
            )

        case .bjt:
            guard let descriptor = ComponentRegistry.shared.descriptor(for: "npn-transistor") else { return nil }
            var parameters = descriptor.defaultParameterValues
            var descriptorId = "npn-transistor"
            if let name = device.trailing.first?.uppercased(), let model = context.models.bjtModels[name] {
                descriptorId = model.polarity == .pnp ? "pnp-transistor" : "npn-transistor"
                parameters["saturationCurrent"] = model.saturationCurrent
                parameters["forwardBeta"] = model.forwardBeta
                parameters["reverseBeta"] = model.reverseBeta
            } else if let resolvedDescriptor = ComponentRegistry.shared.descriptor(for: descriptorId) {
                parameters = resolvedDescriptor.defaultParameterValues
            }
            let finalDescriptor = ComponentRegistry.shared.descriptor(for: descriptorId) ?? descriptor
            return Resolved(
                symbol: SymbolInstance(descriptorId: descriptorId, refDes: node, position: .init(0, 0), parameters: parameters),
                descriptor: finalDescriptor,
                nodes: device.nodes
            )

        case .mosfet:
            var descriptorId = "nmos-transistor"
            var parameters: [String: Double] = [:]
            if let name = device.trailing.first?.uppercased(), let model = context.models.mosfetModels[name] {
                descriptorId = model.polarity == .pmos ? "pmos-transistor" : "nmos-transistor"
                parameters["thresholdVoltage"] = model.thresholdVoltage
                parameters["transconductanceParameter"] = model.transconductanceParameter
                parameters["channelLengthModulation"] = model.channelLengthModulation
                parameters["bodyEffect"] = model.bodyEffect
                parameters["surfacePotential"] = model.surfacePotential
            }
            guard let descriptor = ComponentRegistry.shared.descriptor(for: descriptorId) else { return nil }
            if parameters.isEmpty { parameters = descriptor.defaultParameterValues }
            return Resolved(
                symbol: SymbolInstance(descriptorId: descriptorId, refDes: node, position: .init(0, 0), parameters: parameters),
                descriptor: descriptor,
                nodes: device.nodes
            )

        case .jfet:
            var descriptorId = "njfet-transistor"
            var parameters: [String: Double] = [:]
            if let name = device.trailing.first?.uppercased(), let model = context.models.jfetModels[name] {
                descriptorId = model.polarity == .pjf ? "pjfet-transistor" : "njfet-transistor"
                parameters["thresholdVoltage"] = model.thresholdVoltage
                parameters["transconductanceParameter"] = model.transconductanceParameter
                parameters["channelLengthModulation"] = model.channelLengthModulation
                parameters["gateSaturationCurrent"] = model.gateSaturationCurrent
            }
            guard let descriptor = ComponentRegistry.shared.descriptor(for: descriptorId) else { return nil }
            if parameters.isEmpty { parameters = descriptor.defaultParameterValues }
            return Resolved(
                symbol: SymbolInstance(descriptorId: descriptorId, refDes: node, position: .init(0, 0), parameters: parameters),
                descriptor: descriptor,
                nodes: device.nodes
            )

        case .subcircuit(let name):
            let key = name.uppercased()
            guard let sheetId = context.sheetIdByName[key], let sheet = context.catalog.sheet(id: sheetId) else {
                warnings.append("\(node): subcircuit \(name) was not defined; instance skipped.")
                return nil
            }
            let symbol = SymbolInstance(
                descriptorId: SubcircuitInstance.descriptorId,
                refDes: node,
                position: .init(0, 0),
                sheetRef: sheetId
            )
            guard let descriptor = context.catalog.descriptor(for: symbol) else { return nil }
            if device.nodes.count != sheet.ports.count {
                warnings.append(
                    "\(node): expected \(sheet.ports.count) node(s) for \(name) but \(device.nodes.count) were given."
                )
            }
            return Resolved(symbol: symbol, descriptor: descriptor, nodes: device.nodes)
        }
    }

    // MARK: - Values

    private static func numeric(_ token: String?) -> Double? {
        guard let token else { return nil }
        if token.hasPrefix("{") { return nil }
        return try? SpiceNetlistParser.parseNumber(token, line: 0)
    }

    private struct SourceValues {
        var dc: Double?
        var ac: Double?
        var phase: Double?
        var recognized = true
    }

    private static func parseSource(_ tokens: [String]) -> SourceValues {
        var values = SourceValues()
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let keyword = token.uppercased()
            if keyword == "DC" {
                if index + 1 < tokens.count, let value = numeric(tokens[index + 1]) {
                    values.dc = value
                    index += 2
                    continue
                }
            } else if keyword == "AC" {
                if index + 1 < tokens.count, let value = numeric(tokens[index + 1]) {
                    values.ac = value
                    index += 2
                    if index < tokens.count, let phase = numeric(tokens[index]), !tokens[index].contains("=") {
                        values.phase = phase
                        index += 1
                    }
                    continue
                }
            } else if ["SIN", "PULSE", "PWL", "EXP", "SFFM"].contains(keyword) {
                values.recognized = false
                break
            } else if let value = numeric(token) {
                if values.dc == nil, values.ac == nil { values.dc = value }
                index += 1
                continue
            }
            index += 1
        }
        return values
    }

    private static func nodeKey(_ raw: String) -> String {
        let cleaned = SpiceNetlistParser.normalizedNodeName(raw)
        return groundAliases.contains(cleaned.uppercased()) ? "0" : cleaned.uppercased()
    }

    private static func displayName(_ raw: String) -> String {
        SpiceNetlistParser.normalizedNodeName(raw)
    }
}
