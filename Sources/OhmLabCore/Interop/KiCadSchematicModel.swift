// KiCadSchematicModel.swift
// The intermediate model produced by the direct `.kicad_sch` reader.
//
// This layer only understands KiCad's file syntax. It deliberately keeps the
// raw millimetre coordinates, UUIDs, library pin definitions, and instance
// properties; `KiCadSchematicReader` turns that into an OhmLab schematic.

import Foundation

enum KiCadSchematicParseError: LocalizedError, Equatable {
    case notASchematic(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .notASchematic(let name):
            return "\(name) is not a KiCad schematic."
        case .malformed(let detail):
            return "The KiCad schematic is malformed: \(detail)"
        }
    }
}

struct KiCadPoint: Equatable, Sendable {
    var x: Double
    var y: Double

    var grid: GridPoint {
        GridPoint(
            Int((x / KiCadSchematicFile.millimetresPerGrid).rounded()),
            Int((y / KiCadSchematicFile.millimetresPerGrid).rounded())
        )
    }
}

struct KiCadAt: Equatable, Sendable {
    var x: Double
    var y: Double
    var angle: Double

    var point: KiCadPoint { KiCadPoint(x: x, y: y) }
}

struct KiCadLibraryPin: Equatable, Sendable {
    var number: String
    var name: String
    var at: KiCadAt
    /// 0 means the pin is common to every unit; otherwise it is unit-specific.
    var unit: Int
    var hidden: Bool
}

struct KiCadLibrarySymbol: Equatable, Sendable {
    var libId: String
    var pins: [KiCadLibraryPin]
    var isPower: Bool

    func pins(for unit: Int) -> [KiCadLibraryPin] {
        let unitPins = pins.filter { $0.unit == unit }
        return unitPins.isEmpty ? pins.filter { $0.unit == 0 } : unitPins
    }
}

struct KiCadPlacedSymbol: Equatable, Sendable {
    var libId: String
    var at: KiCadAt
    var mirror: String?
    var unit: Int
    var uuid: UUID?
    var properties: [String: String]
    var pinUUIDs: [String: UUID]
    var reference: String
    var value: String
    var dnp: Bool
    var excludeFromSimulation: Bool

    var isPower: Bool { reference.hasPrefix("#") }
}

struct KiCadWire: Equatable, Sendable {
    var points: [KiCadPoint]
    var uuid: UUID?
}

enum KiCadLabelKind: String, Sendable {
    case local
    case global
    case hierarchical
}

struct KiCadLabel: Equatable, Sendable {
    var name: String
    var at: KiCadAt
    var kind: KiCadLabelKind
    var uuid: UUID?
}

struct KiCadSheetPin: Equatable, Sendable {
    var name: String
    var shape: String
    var at: KiCadAt
    var uuid: UUID?
}

struct KiCadSheet: Equatable, Sendable {
    var at: KiCadAt
    var width: Double
    var height: Double
    var uuid: UUID?
    var name: String
    var file: String
    var pins: [KiCadSheetPin]
    var page: String?
    var properties: [String: String]
}

struct KiCadSchematicFile: Equatable, Sendable {
    /// One grid cell is 1.27 mm (half of KiCad's 2.54 mm/0.1" pitch), which
    /// makes every standard KiCad coordinate land on an integer grid point.
    static let millimetresPerGrid = 1.27

    var version: Int?
    var uuid: UUID?
    var librarySymbols: [String: KiCadLibrarySymbol]
    var symbols: [KiCadPlacedSymbol]
    var wires: [KiCadWire]
    var junctions: [KiCadPoint]
    var labels: [KiCadLabel]
    var sheets: [KiCadSheet]
    var noConnects: [KiCadPoint]

    static func parse(_ text: String, fileName: String) throws -> KiCadSchematicFile {
        let root: SExpression
        do {
            root = try SExpressionParser.parse(text)
        } catch {
            throw KiCadSchematicParseError.malformed(error.localizedDescription)
        }
        guard let values = root.list, values.first?.atom == "kicad_sch" else {
            throw KiCadSchematicParseError.notASchematic(fileName)
        }

        var file = KiCadSchematicFile(
            version: root.value(of: "version").flatMap(Int.init),
            uuid: root.value(of: "uuid").flatMap(UUID.init(uuidString:)),
            librarySymbols: [:],
            symbols: [],
            wires: [],
            junctions: [],
            labels: [],
            sheets: [],
            noConnects: []
        )

        if let libraryNode = root.first("lib_symbols") {
            for symbolNode in libraryNode.all("symbol") {
                guard let libId = symbolNode.ownArguments.first?.text else { continue }
                file.librarySymbols[libId] = parseLibrarySymbol(symbolNode, libId: libId)
            }
        }

        for node in values.dropFirst() {
            guard let head = node.list?.first?.atom else { continue }
            switch head {
            case "symbol":
                if let symbol = parsePlacedSymbol(node) {
                    file.symbols.append(symbol)
                }
            case "wire":
                if let wire = parseWire(node) {
                    file.wires.append(wire)
                }
            case "junction":
                if let point = parsePoint(node) {
                    file.junctions.append(point)
                }
            case "no_connect":
                if let point = parsePoint(node) {
                    file.noConnects.append(point)
                }
            case "label":
                if let label = parseLabel(node, kind: .local) {
                    file.labels.append(label)
                }
            case "global_label":
                if let label = parseLabel(node, kind: .global) {
                    file.labels.append(label)
                }
            case "hierarchical_label":
                if let label = parseLabel(node, kind: .hierarchical) {
                    file.labels.append(label)
                }
            case "sheet":
                if let sheet = parseSheet(node) {
                    file.sheets.append(sheet)
                }
            default:
                continue
            }
        }

        return file
    }

    // MARK: - Library symbols

    private static func parseLibrarySymbol(_ node: SExpression, libId: String) -> KiCadLibrarySymbol {
        var pins: [KiCadLibraryPin] = []
        collectPins(in: node, unit: 0, into: &pins)
        return KiCadLibrarySymbol(
            libId: libId,
            pins: pins,
            isPower: node.first("power") != nil
        )
    }

    private static func collectPins(in node: SExpression, unit: Int, into pins: inout [KiCadLibraryPin]) {
        guard let values = node.list else { return }
        for child in values {
            guard let head = child.list?.first?.atom else { continue }
            switch head {
            case "pin":
                if let pin = parseLibraryPin(child, unit: unit) {
                    pins.append(pin)
                }
            case "symbol":
                let nestedUnit = nestedUnit(from: child) ?? unit
                collectPins(in: child, unit: nestedUnit, into: &pins)
            default:
                continue
            }
        }
    }

    /// Nested unit symbols are named `<symbol>_<unit>_<style>` (for example
    /// `R_1_1`). Unit 0 holds graphics shared by every unit.
    private static func nestedUnit(from node: SExpression) -> Int? {
        guard let name = node.ownArguments.first?.text else { return nil }
        let parts = name.split(separator: "_")
        guard parts.count >= 3, let unit = Int(parts[parts.count - 2]) else { return nil }
        return unit
    }

    private static func parseLibraryPin(_ node: SExpression, unit: Int) -> KiCadLibraryPin? {
        guard let at = parseAt(node) else { return nil }
        let number = node.value(of: "number") ?? ""
        let name = node.value(of: "name") ?? ""
        let hidden = node.first("hide").map { child in
            child.value(of: "hide") != "no"
        } ?? false
        return KiCadLibraryPin(
            number: number,
            name: name,
            at: at,
            unit: unit,
            hidden: hidden
        )
    }

    // MARK: - Placed symbols

    private static func parsePlacedSymbol(_ node: SExpression) -> KiCadPlacedSymbol? {
        guard let libId = node.value(of: "lib_id"), let at = parseAt(node) else { return nil }
        var properties: [String: String] = [:]
        for property in node.all("property") {
            let arguments = property.ownArguments
            guard arguments.count >= 2,
                  let name = arguments[0].text else { continue }
            properties[name] = arguments[1].text ?? ""
        }

        var pinUUIDs: [String: UUID] = [:]
        for pin in node.all("pin") {
            guard let number = pin.ownArguments.first?.text else { continue }
            if let uuidText = pin.value(of: "uuid"), let uuid = UUID(uuidString: uuidText) {
                pinUUIDs[number] = uuid
            }
        }

        let reference = properties["Reference"]
            ?? firstValue(in: node, named: "reference")
            ?? ""
        let value = properties["Value"] ?? ""

        return KiCadPlacedSymbol(
            libId: libId,
            at: at,
            mirror: node.value(of: "mirror"),
            unit: node.value(of: "unit").flatMap(Int.init) ?? 1,
            uuid: node.value(of: "uuid").flatMap(UUID.init(uuidString:)),
            properties: properties,
            pinUUIDs: pinUUIDs,
            reference: reference,
            value: value,
            dnp: node.value(of: "dnp") == "yes",
            excludeFromSimulation: node.value(of: "exclude_from_sim") == "yes"
        )
    }

    private static func firstValue(in node: SExpression, named name: String) -> String? {
        if let value = node.value(of: name) { return value }
        guard let values = node.list else { return nil }
        for child in values {
            if let value = firstValue(in: child, named: name) { return value }
        }
        return nil
    }

    // MARK: - Geometry

    private static func parseAt(_ node: SExpression) -> KiCadAt? {
        guard let arguments = node.arguments(of: "at"),
              arguments.count >= 2,
              let x = arguments[0].double,
              let y = arguments[1].double else { return nil }
        let angle = arguments.count >= 3 ? (arguments[2].double ?? 0) : 0
        return KiCadAt(x: x, y: y, angle: angle)
    }

    private static func parsePoint(_ node: SExpression) -> KiCadPoint? {
        guard let at = parseAt(node) else { return nil }
        return at.point
    }

    private static func parseWire(_ node: SExpression) -> KiCadWire? {
        guard let pointsNode = node.first("pts") else { return nil }
        let points = pointsNode.all("xy").compactMap { xy -> KiCadPoint? in
            let arguments = xy.ownArguments
            guard arguments.count >= 2,
                  let x = arguments[0].double,
                  let y = arguments[1].double else { return nil }
            return KiCadPoint(x: x, y: y)
        }
        guard points.count >= 2 else { return nil }
        return KiCadWire(
            points: points,
            uuid: node.value(of: "uuid").flatMap(UUID.init(uuidString:))
        )
    }

    private static func parseLabel(_ node: SExpression, kind: KiCadLabelKind) -> KiCadLabel? {
        guard let arguments = node.list, arguments.count >= 2,
              let name = arguments[1].text,
              let at = parseAt(node) else { return nil }
        return KiCadLabel(
            name: name,
            at: at,
            kind: kind,
            uuid: node.value(of: "uuid").flatMap(UUID.init(uuidString:))
        )
    }

    // MARK: - Sheets

    private static func parseSheet(_ node: SExpression) -> KiCadSheet? {
        guard let at = parseAt(node) else { return nil }
        let size = node.arguments(of: "size") ?? []
        let width = size.first?.double ?? 0
        let height = size.count >= 2 ? (size[1].double ?? 0) : 0

        var properties: [String: String] = [:]
        for property in node.all("property") {
            let arguments = property.ownArguments
            guard arguments.count >= 2,
                  let name = arguments[0].text else { continue }
            properties[name] = arguments[1].text ?? ""
        }

        let pins = node.all("pin").compactMap { pin -> KiCadSheetPin? in
            let arguments = pin.ownArguments
            guard arguments.count >= 2,
                  let name = arguments[0].text,
                  let at = parseAt(pin) else { return nil }
            let shape = arguments[1].text ?? "input"
            return KiCadSheetPin(
                name: name,
                shape: shape,
                at: at,
                uuid: pin.value(of: "uuid").flatMap(UUID.init(uuidString:))
            )
        }

        let name = properties["Sheetname"] ?? "Sheet"
        let file = properties["Sheetfile"] ?? ""
        let page = firstValue(in: node, named: "page")

        return KiCadSheet(
            at: at,
            width: width,
            height: height,
            uuid: node.value(of: "uuid").flatMap(UUID.init(uuidString:)),
            name: name,
            file: file,
            pins: pins,
            page: page,
            properties: properties
        )
    }
}
