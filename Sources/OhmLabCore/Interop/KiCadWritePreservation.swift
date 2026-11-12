// KiCadWritePreservation.swift
// Non-destructive write-back into an existing KiCad project.
//
// Generation mode (`KiCadSchematicWriter` without a source) redraws a schematic
// from OhmLab's model. That is the right behaviour for a new project, but it
// throws away wire geometry, junctions, page settings, title blocks, custom
// fields, and unsupported symbols that OhmLab does not model.
//
// Preservation mode starts from the existing `.kicad_sch` files and replaces
// only the objects OhmLab owns:
//
//   • an unchanged sheet is copied byte-for-byte;
//   • an unchanged symbol keeps its original node verbatim;
//   • a changed symbol is patched in place (value, reference, position,
//     rotation, OhmLab parameters, model binding);
//   • a new symbol/wire is appended;
//   • a deleted symbol is removed;
//   • every other top-level node (wires, junctions, labels, graphics, title
//     block, paper, sheet instances) is preserved exactly.
//
// The merge baseline is the current KiCad project: the reader is run again at
// write time, so "unchanged" means "still what KiCad would import", not "what
// the bundle recorded at import time".

import Foundation

/// The public contract for non-destructive KiCad write-back.
public enum KiCadWriteFidelityContract {
    public static let currentVersion = 1
}

enum KiCadPreservingWriter {    // MARK: - Loaded source project

    struct Loaded {
        var rootURL: URL
        var directory: URL
        var projectName: String
        var rootID: UUID
        var filesBySheetID: [UUID: URL]
        var baselineRoot: Sheet
        var baselineSheets: [UUID: Sheet]
        var documentsBySheetID: [UUID: KiCadSchematicSourceDocument]

        func baselineSheet(id: UUID) -> Sheet? {
            id == baselineRoot.id ? baselineRoot : baselineSheets[id]
        }
    }

    static func load(from url: URL) throws -> Loaded {
        let rootURL = try resolveRoot(url)
        let read = try KiCadSchematicReader.readProject(at: rootURL)
        let rootText = try String(contentsOf: rootURL, encoding: .utf8)
        let rootDocument = try KiCadSchematicSourceDocument(text: rootText)
        guard let rootID = rootDocument.rootUUID else {
            throw KiCadWritePreservationError.missingRootUUID(rootURL.lastPathComponent)
        }

        let projectName = rootURL.deletingPathExtension().lastPathComponent
        let baselineRoot = Sheet(
            id: rootID,
            name: projectName,
            symbols: read.snapshot.symbols,
            wires: read.snapshot.wires,
            netLabels: read.snapshot.netLabels
        )
        var baselineSheets: [UUID: Sheet] = [:]
        for sheet in read.snapshot.sheets {
            baselineSheets[sheet.id] = sheet
        }

        var documents: [UUID: KiCadSchematicSourceDocument] = [:]
        var files: [UUID: URL] = [:]
        for source in read.sourceFiles {
            guard let text = try? String(contentsOf: source, encoding: .utf8),
                  let document = try? KiCadSchematicSourceDocument(text: text),
                  let id = document.rootUUID else { continue }
            documents[id] = document
            files[id] = source.standardizedFileURL
        }
        // The root can be missing from `sourceFiles` if the reader loaded it
        // through a different spelling of the path.
        documents[rootID] = rootDocument
        files[rootID] = rootURL.standardizedFileURL

        return Loaded(
            rootURL: rootURL.standardizedFileURL,
            directory: rootURL.deletingLastPathComponent().standardizedFileURL,
            projectName: projectName,
            rootID: rootID,
            filesBySheetID: files,
            baselineRoot: baselineRoot,
            baselineSheets: baselineSheets,
            documentsBySheetID: documents
        )
    }

    private static func resolveRoot(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory) else {
            throw KiCadWritePreservationError.missingSource(standardized.path)
        }
        if !isDirectory.boolValue {
            guard let root = KiCadProjectInterchange.rootSchematic(for: standardized) else {
                throw KiCadWritePreservationError.missingSource(standardized.path)
            }
            return root
        }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: standardized,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let projects = contents
            .filter { $0.pathExtension.lowercased() == KiCadProjectInterchange.projectExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let preferred = projects.first(where: {
            $0.deletingPathExtension().lastPathComponent == standardized.lastPathComponent
        }) {
            return preferred
        }
        if let first = projects.first {
            return first
        }
        let schematics = contents
            .filter { $0.pathExtension.lowercased() == KiCadProjectInterchange.schematicExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let preferred = schematics.first(where: {
            $0.deletingPathExtension().lastPathComponent == standardized.lastPathComponent
        }) {
            return preferred
        }
        guard let first = schematics.first else {
            throw KiCadWritePreservationError.missingSource(standardized.path)
        }
        return first
    }

    /// A target-relative file name for a source sheet, or nil when the sheet
    /// has no source file or the file lives outside the project directory.
    static func relativeSourcePath(for sheetID: UUID, source: Loaded) -> String? {
        guard let url = source.filesBySheetID[sheetID] else { return nil }
        let base = source.directory.path.hasSuffix("/") ? source.directory.path : source.directory.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base) else { return nil }
        return String(path.dropFirst(base.count))
    }

    // MARK: - Write

    static func write(
        snapshot: SchematicSnapshot,
        name: String,
        to directory: URL,
        source: Loaded
    ) throws -> KiCadSchematicWriteResult {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let modelsDirectory = directory.appendingPathComponent("models", isDirectory: true)
        try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let projectName = source.projectName
        let rootSheet = Sheet(
            id: source.rootID,
            name: projectName,
            symbols: snapshot.symbols,
            wires: snapshot.wires,
            netLabels: snapshot.netLabels
        )
        let sheets = [rootSheet] + snapshot.sheets
        let catalog = SubcircuitCatalog(sheets: snapshot.sheets)
        let models = KiCadModelLibrary.make(for: snapshot)

        // Reuse source file names where possible so `Sheetfile` references stay
        // valid; invent deterministic names only for sheets OhmLab added.
        var fileNames: [UUID: String] = [:]
        var usedNames: Set<String> = []
        for sheet in sheets {
            if let relative = relativeSourcePath(for: sheet.id, source: source) {
                fileNames[sheet.id] = relative
                usedNames.insert(relative.lowercased())
            }
        }
        let generated = KiCadSchematicWriter.assignFileNames(
            root: rootSheet,
            children: snapshot.sheets,
            projectName: projectName
        )
        for sheet in sheets where fileNames[sheet.id] == nil {
            guard var candidate = generated[sheet.id] else { continue }
            if usedNames.contains(candidate.lowercased()) {
                candidate = KiCadSchematicWriter.uniqueFileName(candidate, used: &usedNames)
            } else {
                usedNames.insert(candidate.lowercased())
            }
            fileNames[sheet.id] = candidate
        }

        var warnings: [String] = []
        var written: [URL] = []
        var nextPage = max(sheets.count, 2)

        for sheet in sheets {
            guard let relative = fileNames[sheet.id] else { continue }
            let target = directory.appendingPathComponent(relative)
            let baseline = source.baselineSheet(id: sheet.id)
            let text: String
            if let baseline,
               let document = source.documentsBySheetID[sheet.id],
               sheetContentEqual(sheet, baseline) {
                // Fast path: the OhmLab sheet is exactly the imported sheet.
                text = document.rendered()
            } else if let document = source.documentsBySheetID[sheet.id] {
                let merged = merge(
                    document: document,
                    current: sheet,
                    baseline: baseline,
                    isRoot: sheet.id == rootSheet.id,
                    context: MergeContext(
                        projectName: projectName,
                        rootID: source.rootID,
                        fileNames: fileNames,
                        catalog: catalog,
                        models: models
                    ),
                    nextPage: &nextPage,
                    warnings: &warnings
                )
                text = merged
            } else {
                text = KiCadSchematicWriter.schematicText(
                    sheet: sheet,
                    isRoot: sheet.id == rootSheet.id,
                    projectName: projectName,
                    rootID: source.rootID,
                    fileNames: fileNames,
                    catalog: catalog,
                    models: models,
                    nextPage: &nextPage,
                    warnings: &warnings
                )
            }
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: target, atomically: true, encoding: .utf8)
            written.append(target)
        }

        // Bring the rest of the source project along when exporting to a new
        // directory: model libraries, symbol libraries, tables, page layouts,
        // and the project file itself. In-place sync already has these.
        try copySupportFiles(from: source, to: directory, written: &written)

        // Project-level files: never replace a file the user already has,
        // except our own generated model library, which may need new cards.
        let symbolLibrary = directory.appendingPathComponent(KiCadSymbolLibrary.fileName)
        if !fileManager.fileExists(atPath: symbolLibrary.path) {
            try KiCadSymbolLibrary.libraryText().write(to: symbolLibrary, atomically: true, encoding: .utf8)
            written.append(symbolLibrary)
        }

        let table = directory.appendingPathComponent("sym-lib-table")
        if !fileManager.fileExists(atPath: table.path) {
            try KiCadSchematicWriter.symbolLibraryTable().write(to: table, atomically: true, encoding: .utf8)
            written.append(table)
        }

        let modelURL = modelsDirectory.appendingPathComponent(KiCadModelLibrary.fileName)
        try models.text.write(to: modelURL, atomically: true, encoding: .utf8)
        written.append(modelURL)

        let projectURL = directory.appendingPathComponent("\(projectName).\(KiCadProjectInterchange.projectExtension)")
        if !fileManager.fileExists(atPath: projectURL.path) {
            try KiCadSchematicWriter.projectFile(name: projectName, rootID: source.rootID)
                .write(to: projectURL, atomically: true, encoding: .utf8)
            written.append(projectURL)
        }

        return KiCadSchematicWriteResult(files: written, warnings: warnings)
    }

    private static func copySupportFiles(
        from source: Loaded,
        to target: URL,
        written: inout [URL]
    ) throws {
        let fileManager = FileManager.default
        let sourceDirectory = source.directory.standardizedFileURL
        let targetDirectory = target.standardizedFileURL
        guard sourceDirectory.path != targetDirectory.path else { return }

        let base = sourceDirectory.path.hasSuffix("/")
            ? sourceDirectory.path
            : sourceDirectory.path + "/"
        guard let enumerator = fileManager.enumerator(
            at: sourceDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL
            guard standardized.path.hasPrefix(base) else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            if standardized.pathExtension.lowercased() == KiCadProjectInterchange.schematicExtension {
                continue
            }
            let relative = String(standardized.path.dropFirst(base.count))
            let destination = targetDirectory.appendingPathComponent(relative)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: standardized, to: destination)
            written.append(destination)
        }
    }

    private struct MergeContext {
        var projectName: String
        var rootID: UUID
        var fileNames: [UUID: String]
        var catalog: SubcircuitCatalog
        var models: KiCadModelLibraryResult
    }

    static func sheetContentEqual(_ current: Sheet, _ baseline: Sheet) -> Bool {
        current.name == baseline.name
            && current.ports == baseline.ports
            && current.symbols == baseline.symbols
            && current.wires == baseline.wires
            && current.netLabels == baseline.netLabels
    }

    // MARK: - Merge

    private static func merge(
        document: KiCadSchematicSourceDocument,
        current: Sheet,
        baseline: Sheet?,
        isRoot: Bool,
        context: MergeContext,
        nextPage: inout Int,
        warnings: inout [String]
    ) -> String {
        let currentByID = Dictionary(
            current.symbols.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let baselineByID = Dictionary(
            (baseline?.symbols ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let baselineNets = baseline.map {
            ConnectivityBuilder.build(
                symbols: $0.symbols,
                wires: $0.wires,
                labels: $0.netLabels,
                catalog: context.catalog
            )
        } ?? []

        var consumed: Set<UUID> = []
        var geometryChanged: Set<UUID> = []
        var sourceWireIDs: Set<UUID> = []
        var sourceLabelKeys: Set<String> = []

        // Labels that sat on a moved or deleted symbol's pins are stale; the
        // merge removes them and writes fresh labels on the new pins.
        var staleLabelKeys: Set<String> = []
        for symbol in baselineByID.values {
            let now = currentByID[symbol.id]
            let moved = now.map {
                $0.position != symbol.position
                    || $0.rotation != symbol.rotation
                    || $0.descriptorId != symbol.descriptorId
            } ?? true
            guard moved else { continue }
            for net in baselineNets {
                for pin in net.connectedPins where pin.symbolId == symbol.id {
                    guard let descriptor = context.catalog.descriptor(for: symbol),
                          let descriptorPin = descriptor.pins.first(where: { $0.id == pin.pinId }) else {
                        continue
                    }
                    let point = KiCadSchematicWriter.kicadLabelPoint(
                        for: descriptorPin,
                        descriptor: descriptor,
                        symbol: symbol
                    )
                    staleLabelKeys.insert(labelKey(name: net.name, point: point))
                }
            }
        }

        var output: [KiCadSourceNode] = []
        for node in document.nodes {
            switch node.kind {
            case "symbol":
                guard let id = node.uuid else {
                    output.append(node)
                    continue
                }
                if let symbol = currentByID[id] {
                    consumed.insert(id)
                    if let previous = baselineByID[id], previous == symbol {
                        output.append(node)
                        continue
                    }
                    guard let descriptor = context.catalog.descriptor(for: symbol) else {
                        warnings.append("Kept \(symbol.refDes) unchanged: its descriptor is not registered.")
                        output.append(node)
                        continue
                    }
                    if let previous = baselineByID[id],
                       previous.position != symbol.position
                        || previous.rotation != symbol.rotation
                        || previous.descriptorId != symbol.descriptorId {
                        geometryChanged.insert(id)
                    }
                    let patched = patchSymbolNode(
                        node.value,
                        symbol: symbol,
                        previous: baselineByID[id],
                        descriptor: descriptor,
                        models: context.models,
                        projectName: context.projectName
                    )
                    output.append(node.replacing(value: patched))
                } else if baselineByID[id] != nil {
                    // Delete the symbol; source wires and labels involved
                    // with it stay put so the user can tidy them in KiCad.
                } else {
                    // A symbol OhmLab does not model. Keeping it is the whole
                    // point of preservation mode.
                    output.append(node)
                }

            case "sheet":
                guard let id = node.uuid else {
                    output.append(node)
                    continue
                }
                if let symbol = currentByID[id], symbol.isSubcircuitInstance {
                    consumed.insert(id)
                    if let previous = baselineByID[id], previous == symbol {
                        output.append(node)
                        continue
                    }
                    if let previous = baselineByID[id],
                       previous.position != symbol.position {
                        geometryChanged.insert(id)
                    }
                    if let replacement = replaceSheetNode(
                        node: node,
                        symbol: symbol,
                        context: context,
                        nextPage: &nextPage,
                        warnings: &warnings
                    ) {
                        output.append(replacement)
                    } else {
                        output.append(node)
                    }
                } else if baselineByID[id] != nil {
                } else {
                    output.append(node)
                }

            case "wire", "bus":
                if let id = node.uuid { sourceWireIDs.insert(id) }
                output.append(node)

            case "label", "global_label", "hierarchical_label":
                let name = node.value.ownArguments.first?.text ?? ""
                let point = sourceLabelPoint(node.value)
                let key = labelKey(name: name, point: point)
                sourceLabelKeys.insert(key)
                if staleLabelKeys.contains(key) {
                    continue
                }
                output.append(node)

            case "lib_symbols":
                let required = Set(current.symbols.compactMap { symbol -> String? in
                    guard let descriptor = context.catalog.descriptor(for: symbol),
                          !symbol.isSubcircuitInstance else { return nil }
                    // A patched symbol keeps its source library id unless the
                    // component type changed; only those cases need a new
                    // definition embedded here.
                    if let previous = baselineByID[symbol.id],
                       previous.descriptorId == symbol.descriptorId {
                        return nil
                    }
                    return KiCadSymbolLibrary.libId(for: descriptor)
                })
                output.append(node.replacing(value: mergedLibrarySymbols(node.value, required: required)))

            default:
                output.append(node)
            }
        }

        // New symbols, wires, and sheet instances are appended in a stable
        // order so repeated writes are byte-identical.
        let trivia = document.defaultTrivia
        var appended: [KiCadSourceNode] = []

        for symbol in current.symbols.sorted(by: KiCadSchematicWriter.symbolOrder) {
            guard !consumed.contains(symbol.id),
                  let descriptor = context.catalog.descriptor(for: symbol) else { continue }
            geometryChanged.insert(symbol.id)
            if symbol.isSubcircuitInstance {
                guard let reference = symbol.sheetRef,
                      let child = context.catalog.sheet(id: reference),
                      let fileName = context.fileNames[child.id] else {
                    warnings.append("Skipped subcircuit instance \(symbol.refDes): its sheet is missing.")
                    continue
                }
                let page = nextPage
                nextPage += 1
                let lines = KiCadSchematicWriter.sheetNodeLines(
                    symbol: symbol,
                    sheet: child,
                    fileName: fileName,
                    projectName: context.projectName,
                    rootID: context.rootID,
                    page: page
                )
                appended.append(makeNode(from: lines.joined(separator: "\n"), trivia: trivia))
            } else {
                let libId = KiCadSymbolLibrary.libId(for: descriptor)
                let lines = KiCadSchematicWriter.symbolNodeLines(
                    symbol: symbol,
                    descriptor: descriptor,
                    libId: libId,
                    projectName: context.projectName,
                    rootID: context.rootID,
                    models: context.models
                )
                appended.append(makeNode(from: lines.joined(separator: "\n"), trivia: trivia))
            }
        }

        for wire in current.wires.sorted(by: { $0.id.uuidString < $1.id.uuidString })
        where !sourceWireIDs.contains(wire.id) {
            appended.append(makeNode(
                from: KiCadSchematicWriter.wireNodeText(wire),
                trivia: trivia
            ))
        }

        // Fresh labels for pins that moved, appeared, or changed shape.
        appended.append(contentsOf: generatedLabels(
            sheet: current,
            symbolIDs: geometryChanged,
            isRoot: isRoot,
            catalog: context.catalog,
            existing: sourceLabelKeys,
            trivia: trivia
        ))

        return document.rendered(with: output + appended)
    }

    // MARK: - Symbol patching

    private static func patchSymbolNode(
        _ node: SExpression,
        symbol: SymbolInstance,
        previous: SymbolInstance?,
        descriptor: ComponentDescriptor,
        models: KiCadModelLibraryResult,
        projectName: String
    ) -> SExpression {
        guard var children = node.list else { return node }
        let rotation = ((symbol.rotation % 360) + 360) % 360
        let x = KiCadRoundTrip.millimetres(grid: symbol.position.x)
        let y = KiCadRoundTrip.millimetres(grid: symbol.position.y)
        let reference = descriptor.symbol == .ground
            ? (symbol.refDes.hasPrefix("#") ? symbol.refDes : "#\(symbol.refDes)")
            : symbol.refDes

        // Keep the source's own library symbol unless the component changed
        // type. Replacing `Device:R` with `OhmLab:R` on a value edit would
        // re-bind the symbol to a different pin layout for no benefit.
        let descriptorChanged = previous?.descriptorId != symbol.descriptorId
        if descriptorChanged {
            let libId = KiCadSymbolLibrary.libId(for: descriptor)
            setChild("lib_id", .list([.atom("lib_id"), .string(libId)]), in: &children)
            // A different symbol shape needs its own pin set.
            children.removeAll { child in
                child.list?.first?.atom == "pin"
            }
            for pin in KiCadSymbolLibrary.pinSpecs(for: descriptor) {
                let pinUUID = KiCadRoundTrip.stableUUID(
                    "\(KiCadRoundTrip.uuidString(symbol.id))/pin/\(pin.number)"
                )
                children.append(.list([
                    .atom("pin"),
                    .string(pin.number),
                    .list([.atom("uuid"), .string(KiCadRoundTrip.uuidString(pinUUID))])
                ]))
            }
        }

        setChild(
            "at",
            .list([.atom("at"), .atom(x), .atom(y), .atom(String(rotation))]),
            in: &children
        )

        setProperty("Reference", reference, x: x, y: y, in: &children)

        let parametersChanged = previous?.parameters != symbol.parameters
        let rebindModel = descriptorChanged || parametersChanged
        if rebindModel {
            setProperty(
                "Value",
                KiCadSchematicWriter.valueText(for: symbol, descriptor: descriptor, models: models),
                x: x, y: y,
                in: &children
            )
        }
        if rebindModel, let modelName = models.modelNameBySymbolID[symbol.id] {
            // The component now has a concrete OhmLab model. Replace KiCad's
            // inline device binding so its simulator does not keep using the
            // old parameters; keep `Sim.Pins`, which is a pin mapping.
            for name in ["Sim.Device", "Sim.Params", "Sim.Type", "Sim.Level", "Sim.File"] {
                removeProperty(name, in: &children)
            }
            setProperty("Sim.Name", modelName, x: x, y: y, in: &children)
            setProperty("Sim.Library", KiCadModelLibrary.relativePath, x: x, y: y, in: &children)
        }
        setProperty(KiCadRoundTrip.descriptorProperty, descriptor.id, x: x, y: y, in: &children)
        let encoded = KiCadRoundTrip.encode(parameters: symbol.parameters)
        if encoded.isEmpty {
            removeProperty(KiCadRoundTrip.parametersProperty, in: &children)
        } else {
            setProperty(KiCadRoundTrip.parametersProperty, encoded, x: x, y: y, in: &children)
        }
        setProperty(KiCadRoundTrip.referenceProperty, symbol.refDes, x: x, y: y, in: &children)
        if rotation == 0 {
            removeProperty(KiCadRoundTrip.rotationProperty, in: &children)
        } else {
            setProperty(KiCadRoundTrip.rotationProperty, String(rotation), x: x, y: y, in: &children)
        }

        if let index = children.firstIndex(where: { $0.list?.first?.atom == "instances" }) {
            children[index] = replacingReference(in: children[index], reference: reference)
        }

        return .list(children)
    }

    private static func replaceSheetNode(
        node: KiCadSourceNode,
        symbol: SymbolInstance,
        context: MergeContext,
        nextPage: inout Int,
        warnings: inout [String]
    ) -> KiCadSourceNode? {
        guard let reference = symbol.sheetRef,
              let child = context.catalog.sheet(id: reference),
              let fileName = context.fileNames[child.id] else {
            warnings.append("Kept subcircuit instance \(symbol.refDes) unchanged: its sheet is missing.")
            return nil
        }
        let page = nextPage
        nextPage += 1
        let lines = KiCadSchematicWriter.sheetNodeLines(
            symbol: symbol,
            sheet: child,
            fileName: fileName,
            projectName: context.projectName,
            rootID: context.rootID,
            page: page
        )
        return makeNode(from: lines.joined(separator: "\n"), trivia: node.trivia)
    }

    // MARK: - Generated labels

    private static func generatedLabels(
        sheet: Sheet,
        symbolIDs: Set<UUID>,
        isRoot: Bool,
        catalog: SubcircuitCatalog,
        existing: Set<String>,
        trivia: String
    ) -> [KiCadSourceNode] {
        guard !symbolIDs.isEmpty else { return [] }
        let nets = ConnectivityBuilder.build(
            symbols: sheet.symbols,
            wires: sheet.wires,
            labels: sheet.netLabels,
            catalog: catalog
        )
        let symbolsByID = Dictionary(
            sheet.symbols.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let ports = Dictionary(
            sheet.ports.map { ($0.name.uppercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var emitted: Set<String> = []
        var nodes: [KiCadSourceNode] = []
        for net in nets.sorted(by: { $0.id < $1.id }) {
            for pin in net.connectedPins.sorted(by: { $0.symbolId.uuidString < $1.symbolId.uuidString })
            where symbolIDs.contains(pin.symbolId) {
                guard let symbol = symbolsByID[pin.symbolId],
                      let descriptor = catalog.descriptor(for: symbol),
                      let descriptorPin = descriptor.pins.first(where: { $0.id == pin.pinId }) else {
                    continue
                }
                let point = KiCadSchematicWriter.kicadLabelPoint(
                    for: descriptorPin,
                    descriptor: descriptor,
                    symbol: symbol
                )
                let key = labelKey(name: net.name, point: point)
                guard !existing.contains(key), emitted.insert(key).inserted else { continue }
                let lines: [String]
                if let port = ports[net.name.uppercased()], !isRoot {
                    lines = KiCadSchematicWriter.hierarchicalLabelLines(
                        name: port.name,
                        port: port,
                        point: point,
                        uuid: port.id
                    )
                } else {
                    lines = KiCadSchematicWriter.localLabelLines(
                        name: net.name,
                        point: point,
                        uuid: KiCadRoundTrip.stableUUID(
                            "\(KiCadRoundTrip.uuidString(sheet.id))/label/\(net.name)/\(point.x)/\(point.y)"
                        )
                    )
                }
                nodes.append(makeNode(from: lines.joined(separator: "\n"), trivia: trivia))
            }
        }
        return nodes
    }

    // MARK: - Node helpers

    static func makeNode(from text: String, trivia: String) -> KiCadSourceNode {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (try? SExpressionParser.parse(trimmed)) ?? .list([.atom("unknown")])
        let kind = value.list?.first?.atom ?? "unknown"
        let uuid = (value.first("uuid")?.ownArguments.first?.text).flatMap { UUID(uuidString: $0) }
        return KiCadSourceNode(trivia: trivia, raw: trimmed, value: value, kind: kind, uuid: uuid)
    }

    private static func sourceLabelPoint(_ node: SExpression) -> GridPoint {
        let arguments = node.arguments(of: "at") ?? []
        let x = arguments.first?.double ?? 0
        let y = arguments.count > 1 ? (arguments[1].double ?? 0) : 0
        return KiCadPoint(x: x, y: y).grid
    }

    private static func labelKey(name: String, point: GridPoint) -> String {
        "\(name)|\(point.x)|\(point.y)"
    }

    private static func setChild(
        _ head: String,
        _ replacement: SExpression,
        in children: inout [SExpression]
    ) {
        if let index = children.firstIndex(where: { $0.list?.first?.atom == head }) {
            children[index] = replacement
        } else {
            children.append(replacement)
        }
    }

    private static func setProperty(
        _ name: String,
        _ value: String,
        x: String,
        y: String,
        in children: inout [SExpression]
    ) {
        if let index = children.firstIndex(where: { isProperty($0, named: name) }) {
            var arguments = children[index].list ?? []
            if arguments.count >= 3 {
                arguments[2] = .string(value)
            }
            children[index] = .list(arguments)
        } else {
            children.append(propertyNode(name: name, value: value, x: x, y: y))
        }
    }

    private static func removeProperty(_ name: String, in children: inout [SExpression]) {
        children.removeAll { isProperty($0, named: name) }
    }

    private static func isProperty(_ node: SExpression, named name: String) -> Bool {
        guard let arguments = node.list, arguments.count >= 3,
              arguments.first?.atom == "property" else { return false }
        return arguments[1].text == name
    }

    private static func propertyNode(
        name: String,
        value: String,
        x: String,
        y: String
    ) -> SExpression {
        .list([
            .atom("property"),
            .string(name),
            .string(value),
            .list([.atom("at"), .atom(x), .atom(y), .atom("0")]),
            .list([
                .atom("effects"),
                .list([
                    .atom("font"),
                    .list([.atom("size"), .atom("1.27"), .atom("1.27")])
                ]),
                .list([.atom("hide"), .atom("yes")])
            ])
        ])
    }

    private static func replacingReference(in node: SExpression, reference: String) -> SExpression {
        guard var children = node.list else { return node }
        if let index = children.firstIndex(where: { $0.list?.first?.atom == "reference" }) {
            var arguments = children[index].list ?? []
            if arguments.count >= 2 {
                arguments[1] = .string(reference)
            }
            children[index] = .list(arguments)
        } else {
            for index in children.indices where children[index].list != nil {
                children[index] = replacingReference(in: children[index], reference: reference)
            }
        }
        return .list(children)
    }

    private static func mergedLibrarySymbols(
        _ node: SExpression,
        required: Set<String>
    ) -> SExpression {
        guard var children = node.list else { return node }
        let existing = Set(node.all("symbol").compactMap { $0.ownArguments.first?.text })
        let missing = required.subtracting(existing)
        guard !missing.isEmpty else { return node }
        let text = KiCadSymbolLibrary.embeddedSymbols(libIds: missing)
        guard let parsed = try? SExpressionParser.parse(text),
              let definitions = parsed.list else {
            return node
        }
        children.append(contentsOf: definitions.dropFirst())
        return .list(children)
    }
}

enum KiCadWritePreservationError: LocalizedError, Equatable {
    case missingSource(String)
    case missingRootUUID(String)

    var errorDescription: String? {
        switch self {
        case .missingSource(let path):
            return "No KiCad project or schematic was found at \(path) to preserve."
        case .missingRootUUID(let name):
            return "The KiCad schematic \(name) has no root UUID to preserve."
        }
    }
}
