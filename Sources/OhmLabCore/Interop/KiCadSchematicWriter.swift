// KiCadSchematicWriter.swift
// Native writing of `.kicad_sch` projects.
//
// The writer is the inverse of `KiCadSchematicReader`. It emits one schematic
// file per OhmLab sheet, a project-local symbol library, a generated SPICE
// model library, a `sym-lib-table`, and a `.kicad_pro` wrapper. Connectivity is
// guaranteed by placing a label at every pin (plus a power symbol on every
// ground net), so the exported project does not depend on reproducing KiCad's
// wire geometry exactly.

import Foundation

public struct KiCadSchematicWriteResult: Sendable {
    /// Files written, in deterministic order.
    public var files: [URL]
    /// Non-fatal notes (unsupported symbols, missing sheets, …).
    public var warnings: [String]

    public init(files: [URL], warnings: [String]) {
        self.files = files
        self.warnings = warnings
    }
}

public enum KiCadSchematicWriter {
    public static let schematicExtension = KiCadProjectInterchange.schematicExtension
    public static let projectExtension = KiCadProjectInterchange.projectExtension

    /// Writes a complete KiCad project for `snapshot` into `directory`.
    public static func writeProject(
        snapshot: SchematicSnapshot,
        name: String,
        to directory: URL
    ) throws -> KiCadSchematicWriteResult {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let modelsDirectory = directory.appendingPathComponent("models", isDirectory: true)
        try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let projectName = sanitizedProjectName(name)
        let rootID = KiCadRoundTrip.stableUUID("\(projectName)/root")
        let rootSheet = Sheet(
            id: rootID,
            name: projectName,
            symbols: snapshot.symbols,
            wires: snapshot.wires,
            netLabels: snapshot.netLabels
        )
        let sheets = [rootSheet] + snapshot.sheets
        let catalog = SubcircuitCatalog(sheets: snapshot.sheets)
        let fileNames = assignFileNames(root: rootSheet, children: snapshot.sheets, projectName: projectName)
        let models = KiCadModelLibrary.make(for: snapshot)

        var warnings: [String] = []
        var written: [URL] = []
        var nextPage = 2

        for (index, sheet) in sheets.enumerated() {
            guard let fileName = fileNames[sheet.id] else { continue }
            let text = schematicText(
                sheet: sheet,
                isRoot: index == 0,
                projectName: projectName,
                rootID: rootID,
                fileNames: fileNames,
                catalog: catalog,
                models: models,
                nextPage: &nextPage,
                warnings: &warnings
            )
            let url = directory.appendingPathComponent(fileName)
            try text.write(to: url, atomically: true, encoding: .utf8)
            written.append(url)
        }

        let symbolLibraryURL = directory.appendingPathComponent(KiCadSymbolLibrary.fileName)
        try KiCadSymbolLibrary.libraryText().write(to: symbolLibraryURL, atomically: true, encoding: .utf8)
        written.append(symbolLibraryURL)

        let tableURL = directory.appendingPathComponent("sym-lib-table")
        try symbolLibraryTable().write(to: tableURL, atomically: true, encoding: .utf8)
        written.append(tableURL)

        let modelURL = modelsDirectory.appendingPathComponent(KiCadModelLibrary.fileName)
        try models.text.write(to: modelURL, atomically: true, encoding: .utf8)
        written.append(modelURL)

        let projectURL = directory.appendingPathComponent("\(projectName).\(projectExtension)")
        try projectFile(name: projectName, rootID: rootID).write(to: projectURL, atomically: true, encoding: .utf8)
        written.append(projectURL)

        return KiCadSchematicWriteResult(files: written, warnings: warnings)
    }

    // MARK: - File names

    static func assignFileNames(root: Sheet, children: [Sheet], projectName: String) -> [UUID: String] {
        var used: Set<String> = []
        var result: [UUID: String] = [:]
        result[root.id] = uniqueFileName("\(projectName).\(schematicExtension)", used: &used)
        for (index, sheet) in children.enumerated() {
            let base = slug(sheet.name).isEmpty ? "sheet-\(index + 1)" : slug(sheet.name)
            result[sheet.id] = uniqueFileName("\(base).\(schematicExtension)", used: &used)
        }
        return result
    }

    static func uniqueFileName(_ candidate: String, used: inout Set<String>) -> String {
        let stem = (candidate as NSString).deletingPathExtension
        let ext = (candidate as NSString).pathExtension
        var name = candidate
        var suffix = 2
        while !used.insert(name.lowercased()).inserted {
            name = "\(stem)-\(suffix).\(ext)"
            suffix += 1
        }
        return name
    }

    static func slug(_ raw: String) -> String {
        let mapped = raw.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }

    static func sanitizedProjectName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "OhmLab" : trimmed
        let sanitized = candidate.map { character -> Character in
            character.isLetter || character.isNumber || character == "_" || character == "-" || character == "."
                ? character
                : "-"
        }
        let result = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return result.isEmpty ? "OhmLab" : result
    }

    // MARK: - Schematic text

    static func schematicText(
        sheet: Sheet,
        isRoot: Bool,
        projectName: String,
        rootID: UUID,
        fileNames: [UUID: String],
        catalog: SubcircuitCatalog,
        models: KiCadModelLibraryResult,
        nextPage: inout Int,
        warnings: inout [String]
    ) -> String {
        let nets = ConnectivityBuilder.build(
            symbols: sheet.symbols,
            wires: sheet.wires,
            labels: sheet.netLabels,
            catalog: catalog
        )

        var symbols = sheet.symbols.map { symbol -> SymbolInstance in
            // KiCad sheet nodes have no rotation. Normalize subcircuit instances
            // so the labels and sheet pins share the same unrotated geometry.
            guard symbol.isSubcircuitInstance, symbol.rotation != 0 else { return symbol }
            var normalized = symbol
            normalized.rotation = 0
            return normalized
        }
        var usedLibIds: Set<String> = []
        var occupied = occupiedPoints(in: sheet, catalog: catalog)
        let groundNets = nets.filter(\.isGround)
        let representedGroundNets = Set(
            groundNets.filter { net in
                net.connectedPins.contains { pin in
                    symbols.first { $0.id == pin.symbolId }?.descriptorId == "ground"
                }
            }.map(\.id)
        )
        var syntheticGroundLabels: [String] = []
        for (index, net) in groundNets.enumerated() where !representedGroundNets.contains(net.id) {
            let position = freePosition(
                preferred: GridPoint(2, 2 + index * 2),
                occupied: &occupied
            )
            let ground = SymbolInstance(
                id: KiCadRoundTrip.stableUUID("\(KiCadRoundTrip.uuidString(sheet.id))/ground/\(index)"),
                descriptorId: "ground",
                refDes: "GND\(index + 1)",
                position: position
            )
            symbols.append(ground)
            if let descriptor = ComponentRegistry.shared.descriptor(for: "ground"),
               let pin = descriptor.pins.first {
                let location = PinGeometry.location(of: pin, on: ground)
                occupied.insert(location)
                syntheticGroundLabels.append(contentsOf: localLabelLines(
                    name: "0",
                    point: location,
                    uuid: KiCadRoundTrip.stableUUID(
                        "\(KiCadRoundTrip.uuidString(sheet.id))/groundlabel/\(index)"
                    )
                ))
            }
        }

        let symbolsByID = Dictionary(uniqueKeysWithValues: symbols.map { ($0.id, $0) })
        var descriptorsByID: [UUID: ComponentDescriptor] = [:]
        for symbol in symbols {
            if let descriptor = catalog.descriptor(for: symbol) {
                descriptorsByID[symbol.id] = descriptor
            } else {
                warnings.append("Skipped \(symbol.refDes): its descriptor \(symbol.descriptorId) is not registered.")
            }
        }

        var symbolLines: [String] = []
        var sheetLines: [String] = []
        let orderedSymbols = symbols.sorted(by: symbolOrder)
        for symbol in orderedSymbols {
            guard let descriptor = descriptorsByID[symbol.id] else { continue }
            if symbol.isSubcircuitInstance {
                guard let reference = symbol.sheetRef,
                      let child = catalog.sheet(id: reference),
                      let fileName = fileNames[child.id] else {
                    warnings.append("Skipped subcircuit instance \(symbol.refDes): its sheet is missing.")
                    continue
                }
                let page = nextPage
                nextPage += 1
                sheetLines.append(contentsOf: sheetNodeLines(
                    symbol: symbol,
                    sheet: child,
                    fileName: fileName,
                    projectName: projectName,
                    rootID: rootID,
                    page: page
                ))
            } else {
                let libId = KiCadSymbolLibrary.libId(for: descriptor)
                usedLibIds.insert(libId)
                symbolLines.append(contentsOf: symbolNodeLines(
                    symbol: symbol,
                    descriptor: descriptor,
                    libId: libId,
                    projectName: projectName,
                    rootID: rootID,
                    models: models
                ))
            }
        }

        let wireLines = sheet.wires.sorted { $0.id.uuidString < $1.id.uuidString }
            .map(wireNodeText)
        let labelLines = labelNodes(
            sheet: sheet,
            nets: nets,
            symbolsByID: symbolsByID,
            descriptorsByID: descriptorsByID,
            isRoot: isRoot
        ) + syntheticGroundLabels

        var lines: [String] = [
            "(kicad_sch",
            "\t(version 20250114)",
            "\t(generator \"eeschema\")",
            "\t(generator_version \"10.0\")",
            "\t(uuid \(quoted(KiCadRoundTrip.uuidString(sheet.id))))",
            "\t(paper \"A4\")"
        ]
        let embedded = KiCadSymbolLibrary.embeddedSymbols(libIds: usedLibIds)
        if !embedded.isEmpty {
            lines.append(embedded)
        }
        lines.append(contentsOf: symbolLines)
        lines.append(contentsOf: sheetLines)
        lines.append(contentsOf: wireLines)
        lines.append(contentsOf: labelLines)
        lines.append("\t(sheet_instances")
        lines.append("\t\t(path \"/\" (page \"1\"))")
        lines.append("\t)")
        lines.append("\t(embedded_fonts no)")
        lines.append(")")
        return lines.joined(separator: "\n") + "\n"
    }

    static func symbolOrder(_ first: SymbolInstance, _ second: SymbolInstance) -> Bool {
        if first.refDes == second.refDes {
            return first.id.uuidString < second.id.uuidString
        }
        return first.refDes < second.refDes
    }

    static func occupiedPoints(in sheet: Sheet, catalog: SubcircuitCatalog) -> Set<GridPoint> {
        var points = Set(sheet.wires.flatMap(\.points))
        for symbol in sheet.symbols {
            guard let descriptor = catalog.descriptor(for: symbol) else { continue }
            for pin in descriptor.pins {
                points.insert(PinGeometry.location(of: pin, on: symbol))
            }
        }
        return points
    }

    static func freePosition(preferred: GridPoint, occupied: inout Set<GridPoint>) -> GridPoint {
        if !occupied.contains(preferred) {
            occupied.insert(preferred)
            return preferred
        }
        for offset in 1...200 {
            for candidate in [
                GridPoint(preferred.x + offset, preferred.y),
                GridPoint(preferred.x, preferred.y + offset),
                GridPoint(preferred.x + offset, preferred.y + offset)
            ] where !occupied.contains(candidate) {
                occupied.insert(candidate)
                return candidate
            }
        }
        occupied.insert(preferred)
        return preferred
    }

    // MARK: - Placed symbols

    static func symbolNodeLines(
        symbol: SymbolInstance,
        descriptor: ComponentDescriptor,
        libId: String,
        projectName: String,
        rootID: UUID,
        models: KiCadModelLibraryResult
    ) -> [String] {
        let position = symbol.position
        let x = KiCadRoundTrip.millimetres(grid: position.x)
        let y = KiCadRoundTrip.millimetres(grid: position.y)
        let rotation = ((symbol.rotation % 360) + 360) % 360
        let reference = descriptor.symbol == .ground
            ? (symbol.refDes.hasPrefix("#") ? symbol.refDes : "#\(symbol.refDes)")
            : symbol.refDes

        var lines: [String] = [
            "\t(symbol",
            "\t\t(lib_id \(quoted(libId)))",
            "\t\t(at \(x) \(y) \(rotation))",
            "\t\t(unit 1)",
            "\t\t(exclude_from_sim no)",
            "\t\t(in_bom yes)",
            "\t\t(on_board yes)",
            "\t\t(dnp no)",
            "\t\t(uuid \(quoted(KiCadRoundTrip.uuidString(symbol.id))))"
        ]

        let propertyX = KiCadRoundTrip.millimetres(Double(position.x) * 1.27 + 2.54)
        lines.append(contentsOf: placedProperty(
            name: "Reference",
            value: reference,
            x: propertyX,
            y: KiCadRoundTrip.millimetres(Double(position.y) * 1.27 - 2.54),
            hidden: false
        ))
        lines.append(contentsOf: placedProperty(
            name: "Value",
            value: valueText(for: symbol, descriptor: descriptor, models: models),
            x: propertyX,
            y: KiCadRoundTrip.millimetres(Double(position.y) * 1.27 + 2.54),
            hidden: false
        ))
        lines.append(contentsOf: placedProperty(name: "Footprint", value: "", x: x, y: y, hidden: true))
        lines.append(contentsOf: placedProperty(name: "Datasheet", value: "", x: x, y: y, hidden: true))
        lines.append(contentsOf: placedProperty(
            name: "Description",
            value: descriptor.displayName,
            x: x,
            y: y,
            hidden: true
        ))

        if let modelName = models.modelNameBySymbolID[symbol.id] {
            lines.append(contentsOf: placedProperty(name: "Sim.Name", value: modelName, x: x, y: y, hidden: true))
            lines.append(contentsOf: placedProperty(
                name: "Sim.Library",
                value: KiCadModelLibrary.relativePath,
                x: x,
                y: y,
                hidden: true
            ))
        }

        lines.append(contentsOf: placedProperty(
            name: KiCadRoundTrip.descriptorProperty,
            value: descriptor.id,
            x: x,
            y: y,
            hidden: true
        ))
        let encoded = KiCadRoundTrip.encode(parameters: symbol.parameters)
        if !encoded.isEmpty {
            lines.append(contentsOf: placedProperty(
                name: KiCadRoundTrip.parametersProperty,
                value: encoded,
                x: x,
                y: y,
                hidden: true
            ))
        }
        lines.append(contentsOf: placedProperty(
            name: KiCadRoundTrip.referenceProperty,
            value: symbol.refDes,
            x: x,
            y: y,
            hidden: true
        ))
        if rotation != 0 {
            lines.append(contentsOf: placedProperty(
                name: KiCadRoundTrip.rotationProperty,
                value: String(rotation),
                x: x,
                y: y,
                hidden: true
            ))
        }

        for pin in KiCadSymbolLibrary.pinSpecs(for: descriptor) {
            let pinUUID = KiCadRoundTrip.stableUUID(
                "\(KiCadRoundTrip.uuidString(symbol.id))/pin/\(pin.number)"
            )
            lines.append("\t\t(pin \(quoted(pin.number))")
            lines.append("\t\t\t(uuid \(quoted(KiCadRoundTrip.uuidString(pinUUID))))")
            lines.append("\t\t)")
        }

        lines.append("\t\t(instances")
        lines.append("\t\t\t(project \(quoted(projectName))")
        lines.append("\t\t\t\t(path \(quoted("/\(KiCadRoundTrip.uuidString(rootID))"))")
        lines.append("\t\t\t\t\t(reference \(quoted(reference)))")
        lines.append("\t\t\t\t\t(unit 1)")
        lines.append("\t\t\t\t)")
        lines.append("\t\t\t)")
        lines.append("\t\t)")
        lines.append("\t)")
        return lines
    }

    static func valueText(
        for symbol: SymbolInstance,
        descriptor: ComponentDescriptor,
        models: KiCadModelLibraryResult
    ) -> String {
        func parameter(_ key: String, default fallback: Double) -> Double {
            symbol.parameters[key] ?? descriptor.defaultParameterValues[key] ?? fallback
        }
        switch descriptor.symbol {
        case .resistor:
            return KiCadRoundTrip.spiceNumber(parameter("resistance", default: 1_000))
        case .capacitor:
            return KiCadRoundTrip.spiceNumber(parameter("capacitance", default: 1e-6))
        case .inductor, .inductorSeries:
            return KiCadRoundTrip.spiceNumber(parameter("inductance", default: 1e-3))
        case .voltageSource:
            return KiCadRoundTrip.spiceNumber(parameter("dcVoltage", default: 0))
        case .currentSource:
            return KiCadRoundTrip.spiceNumber(parameter("dcCurrent", default: 0))
        case .diode, .npnTransistor, .pnpTransistor,
             .nmosTransistor, .pmosTransistor,
             .njfTransistor, .pjfTransistor:
            return models.modelNameBySymbolID[symbol.id] ?? descriptor.displayName
        case .ground:
            return "0"
        case .subcircuit:
            return descriptor.displayName
        }
    }

    static func placedProperty(
        name: String,
        value: String,
        x: String,
        y: String,
        hidden: Bool
    ) -> [String] {
        var lines: [String] = [
            "\t\t(property \(quoted(name)) \(quoted(value))",
            "\t\t\t(at \(x) \(y) 0)"
        ]
        if hidden {
            lines.append("\t\t\t(effects (font (size 1.27 1.27)) (hide yes))")
        } else {
            lines.append("\t\t\t(effects (font (size 1.27 1.27)) (justify left))")
        }
        lines.append("\t\t)")
        return lines
    }

    // MARK: - Sheet nodes

    static func sheetNodeLines(
        symbol: SymbolInstance,
        sheet: Sheet,
        fileName: String,
        projectName: String,
        rootID: UUID,
        page: Int
    ) -> [String] {
        let descriptor = SubcircuitInstance.descriptor(for: symbol, sheet: sheet)
        let unrotated = SymbolInstance(
            id: symbol.id,
            descriptorId: symbol.descriptorId,
            refDes: symbol.refDes,
            position: symbol.position,
            rotation: 0,
            parameters: symbol.parameters,
            sheetRef: symbol.sheetRef
        )
        let pinLocations = descriptor.pins.map { pin in
            (pin: pin, location: PinGeometry.location(of: pin, on: unrotated))
        }
        let xs = pinLocations.map(\.location.x)
        let ys = pinLocations.map(\.location.y)
        var left = xs.min() ?? symbol.position.x
        var right = xs.max() ?? symbol.position.x
        var top = ys.min() ?? symbol.position.y
        var bottom = ys.max() ?? symbol.position.y
        if left == right {
            if sheet.ports.allSatisfy(\.isInput) {
                right = left + 6
            } else {
                left = right - 6
            }
        }
        top -= 1
        bottom += 1

        let leftText = KiCadRoundTrip.millimetres(grid: left)
        let topText = KiCadRoundTrip.millimetres(grid: top)
        let width = KiCadRoundTrip.millimetres(Double(right - left) * 1.27)
        let height = KiCadRoundTrip.millimetres(Double(bottom - top) * 1.27)

        var lines: [String] = [
            "\t(sheet",
            "\t\t(at \(leftText) \(topText))",
            "\t\t(size \(width) \(height))",
            "\t\t(fields_autoplaced yes)",
            "\t\t(stroke (width 0.1524) (type solid))",
            "\t\t(fill (color 0 0 0 0.0000))",
            "\t\t(uuid \(quoted(KiCadRoundTrip.uuidString(symbol.id))))"
        ]
        lines.append(contentsOf: placedProperty(
            name: "Sheetname",
            value: sheet.name,
            x: leftText,
            y: KiCadRoundTrip.millimetres(Double(top) * 1.27 - 0.7116),
            hidden: false
        ))
        lines.append(contentsOf: placedProperty(
            name: "Sheetfile",
            value: fileName,
            x: leftText,
            y: KiCadRoundTrip.millimetres(Double(bottom) * 1.27 + 0.5884),
            hidden: false
        ))
        lines.append(contentsOf: placedProperty(
            name: KiCadRoundTrip.referenceProperty,
            value: symbol.refDes,
            x: leftText,
            y: topText,
            hidden: true
        ))
        lines.append(contentsOf: placedProperty(
            name: KiCadRoundTrip.positionProperty,
            value: KiCadRoundTrip.encode(position: symbol.position),
            x: leftText,
            y: topText,
            hidden: true
        ))
        if let sheetRef = symbol.sheetRef {
            lines.append(contentsOf: placedProperty(
                name: KiCadRoundTrip.sheetRefProperty,
                value: KiCadRoundTrip.uuidString(sheetRef),
                x: leftText,
                y: topText,
                hidden: true
            ))
        }

        for (pin, location) in pinLocations {
            let port = sheet.ports.first { $0.name == pin.id }
            let shape = port?.isInput == false ? "output" : "input"
            let angle = location.x <= left ? 180 : 0
            let pinUUID = KiCadRoundTrip.stableUUID(
                "\(KiCadRoundTrip.uuidString(symbol.id))/sheetpin/\(pin.id)"
            )
            lines.append("\t\t(pin \(quoted(pin.id)) \(shape)")
            lines.append("\t\t\t(at \(KiCadRoundTrip.millimetres(grid: location.x)) \(KiCadRoundTrip.millimetres(grid: location.y)) \(angle))")
            lines.append("\t\t\t(effects (font (size 1.27 1.27)) (justify \(angle == 180 ? "right" : "left")))")
            lines.append("\t\t\t(uuid \(quoted(KiCadRoundTrip.uuidString(pinUUID))))")
            lines.append("\t\t)")
        }

        lines.append("\t\t(instances")
        lines.append("\t\t\t(project \(quoted(projectName))")
        lines.append("\t\t\t\t(path \(quoted("/\(KiCadRoundTrip.uuidString(rootID))"))")
        lines.append("\t\t\t\t\t(page \(quoted(String(page))))")
        lines.append("\t\t\t\t)")
        lines.append("\t\t\t)")
        lines.append("\t\t)")
        lines.append("\t)")
        return lines
    }

    // MARK: - Wires and labels

    /// Maps an OhmLab descriptor pin to the KiCad library pin that represents
    /// it. This mirrors the role-based mapping used by the reader so that
    /// labels land exactly on the generated KiCad pins.
    static func kicadPinSpec(
        for pin: PinDescriptor,
        descriptor: ComponentDescriptor
    ) -> KiCadSymbolLibrary.PinSpec? {
        let specs = KiCadSymbolLibrary.pinSpecs(for: descriptor)
        let roles = KiCadSymbolLibrary.pinRoles(for: descriptor)
        let index = descriptor.pins.firstIndex(where: { $0.id == pin.id })
        let role = index.flatMap { $0 < roles.count ? roles[$0] : nil } ?? pin.id
        let normalized = role.uppercased()
        if let match = specs.first(where: { $0.name.uppercased() == normalized }) {
            return match
        }
        if let index, index < specs.count {
            return specs[index]
        }
        return nil
    }

    static func wireNodeText(_ wire: WireSegment) -> String {
        let points = wire.points
            .map { "(xy \(KiCadRoundTrip.millimetres(grid: $0.x)) \(KiCadRoundTrip.millimetres(grid: $0.y)))" }
            .joined(separator: " ")
        let head = wire.isBus ? "bus" : "wire"
        return """
        \t(\(head)
        \t\t(pts \(points))
        \t\t(stroke (width 0) (type solid))
        \t\t(uuid \(quoted(KiCadRoundTrip.uuidString(wire.id))))
        \t)
        """
    }

    static func labelNodes(
        sheet: Sheet,
        nets: [Net],
        symbolsByID: [UUID: SymbolInstance],
        descriptorsByID: [UUID: ComponentDescriptor],
        isRoot: Bool
    ) -> [String] {
        var lines: [String] = []
        var emitted: Set<LabelKey> = []
        var hierarchicalPorts: Set<String> = []
        let ports = Dictionary(
            sheet.ports.map { ($0.name.uppercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        func location(for pin: PinRef) -> GridPoint? {
            guard let symbol = symbolsByID[pin.symbolId],
                  let descriptor = descriptorsByID[pin.symbolId],
                  let descriptorPin = descriptor.pins.first(where: { $0.id == pin.pinId }) else {
                return nil
            }
            // Subcircuit instances are drawn as KiCad sheet symbols, whose pins
            // are laid out from the unrotated OhmLab geometry.
            if symbol.isSubcircuitInstance {
                let unrotated = SymbolInstance(
                    id: symbol.id,
                    descriptorId: symbol.descriptorId,
                    refDes: symbol.refDes,
                    position: symbol.position,
                    rotation: 0,
                    parameters: symbol.parameters,
                    sheetRef: symbol.sheetRef
                )
                return PinGeometry.location(of: descriptorPin, on: unrotated)
            }
            // Regular symbols must place labels on the actual KiCad pins.
            // Sources and diodes deliberately use a different pin layout from
            // the OhmLab grid geometry, so derive the location from the
            // generated library pin specs rather than from `PinGeometry`.
            guard let spec = kicadPinSpec(for: descriptorPin, descriptor: descriptor) else {
                return PinGeometry.location(of: descriptorPin, on: symbol)
            }
            let radians = Double(symbol.rotation) * Double.pi / 180
            let cosine = cos(radians)
            let sine = sin(radians)
            let rotatedX = spec.x * cosine - spec.y * sine
            let rotatedY = spec.x * sine + spec.y * cosine
            let xMillimetres = Double(symbol.position.x) * 1.27 - rotatedX
            let yMillimetres = Double(symbol.position.y) * 1.27 - rotatedY
            return GridPoint(
                Int((xMillimetres / 1.27).rounded()),
                Int((yMillimetres / 1.27).rounded())
            )
        }

        let orderedNets = nets.sorted { $0.id < $1.id }
        for net in orderedNets {
            let port = ports[net.name.uppercased()]
            let pins = net.connectedPins.sorted {
                pinSortKey($0, symbolsByID: symbolsByID) < pinSortKey($1, symbolsByID: symbolsByID)
            }
            var portEmitted = port == nil || hierarchicalPorts.contains(port!.name.uppercased())
            for pin in pins {
                guard let point = location(for: pin) else { continue }
                let key = LabelKey(name: net.name, point: point)
                guard emitted.insert(key).inserted else { continue }
                if let port, !portEmitted, !isRoot {
                    portEmitted = true
                    hierarchicalPorts.insert(port.name.uppercased())
                    lines.append(contentsOf: hierarchicalLabelLines(
                        name: port.name,
                        port: port,
                        point: point,
                        uuid: port.id
                    ))
                } else {
                    lines.append(contentsOf: localLabelLines(
                        name: net.name,
                        point: point,
                        uuid: KiCadRoundTrip.stableUUID(
                            "\(KiCadRoundTrip.uuidString(sheet.id))/label/\(net.name)/\(point.x)/\(point.y)"
                        )
                    ))
                }
            }
        }

        // Preserve labels that are not attached to a pin (for example a label
        // on a bare wire or a bus declaration).
        for label in sheet.netLabels.sorted(by: { labelSortKey($0) < labelSortKey($1) }) {
            let key = LabelKey(name: label.name, point: label.position)
            guard emitted.insert(key).inserted else { continue }
            if let port = ports[label.name.uppercased()], !isRoot, !hierarchicalPorts.contains(port.name.uppercased()) {
                hierarchicalPorts.insert(port.name.uppercased())
                lines.append(contentsOf: hierarchicalLabelLines(
                    name: port.name,
                    port: port,
                    point: label.position,
                    uuid: port.id
                ))
            } else {
                lines.append(contentsOf: localLabelLines(
                    name: label.name,
                    point: label.position,
                    uuid: label.id
                ))
            }
        }

        // A declared port with no label at all still needs a hierarchical
        // label so KiCad's sheet pin has a matching net inside the sheet.
        for port in sheet.ports.sorted(by: { $0.name < $1.name })
        where !isRoot && !hierarchicalPorts.contains(port.name.uppercased()) {
            let index = sheet.ports.firstIndex(where: { $0.id == port.id }) ?? 0
            let point = GridPoint(2, 2 + index * 2)
            hierarchicalPorts.insert(port.name.uppercased())
            lines.append(contentsOf: hierarchicalLabelLines(
                name: port.name,
                port: port,
                point: point,
                uuid: port.id
            ))
        }

        return lines
    }

    static func localLabelLines(name: String, point: GridPoint, uuid: UUID) -> [String] {
        [
            "\t(label \(quoted(name))",
            "\t\t(at \(KiCadRoundTrip.millimetres(grid: point.x)) \(KiCadRoundTrip.millimetres(grid: point.y)) 0)",
            "\t\t(effects (font (size 1.27 1.27)) (justify left bottom))",
            "\t\t(uuid \(quoted(KiCadRoundTrip.uuidString(uuid))))",
            "\t)"
        ]
    }

    static func hierarchicalLabelLines(name: String, port: SheetPort, point: GridPoint, uuid: UUID) -> [String] {
        [
            "\t(hierarchical_label \(quoted(name))",
            "\t\t(shape \(port.isInput ? "input" : "output"))",
            "\t\t(at \(KiCadRoundTrip.millimetres(grid: point.x)) \(KiCadRoundTrip.millimetres(grid: point.y)) 0)",
            "\t\t(effects (font (size 1.27 1.27)) (justify left bottom))",
            "\t\t(uuid \(quoted(KiCadRoundTrip.uuidString(uuid))))",
            "\t)"
        ]
    }

    struct LabelKey: Hashable {
        var name: String
        var point: GridPoint
    }

    static func pinSortKey(_ pin: PinRef, symbolsByID: [UUID: SymbolInstance]) -> (String, String, String) {
        (
            symbolsByID[pin.symbolId]?.refDes ?? "",
            pin.symbolId.uuidString,
            pin.pinId
        )
    }

    static func labelSortKey(_ label: NetLabel) -> (String, Int, Int, String) {
        (label.name, label.position.x, label.position.y, label.id.uuidString)
    }

    // MARK: - Project files

    static func symbolLibraryTable() -> String {
        """
        (sym_lib_table
          (version 7)
          (lib (name "OhmLab")(type "KiCad")(uri "${KIPRJMOD}/OhmLab.kicad_sym")(options "")(descr "OhmLab generated symbols"))
        )

        """
    }

    static func projectFile(name: String, rootID: UUID) -> String {
        let filename = "\(name).\(projectExtension)"
        return """
        {
          "board": {},
          "meta": {"filename": \(quotedJSON(filename)), "version": 1},
          "schematic": {},
          "sheets": [[\(quotedJSON(KiCadRoundTrip.uuidString(rootID))), \(quotedJSON(name))]]
        }

        """
    }

    static func quotedJSON(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func quoted(_ value: String) -> String {
        KiCadSymbolLibrary.quoted(value)
    }
}
