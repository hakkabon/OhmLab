// KiCadProjectInterchange.swift
// Project-level interchange with KiCad.
//
// Import reads `.kicad_sch` natively through `KiCadSchematicReader`, preserving
// KiCad UUIDs, references, values, hierarchy, and model-library references.
// When direct reading fails on macOS, the import falls back to KiCad's own
// exporter (`kicad-cli sch export netlist --format spice`) and stores the
// flattened netlist instead. Export writes a valid `.ohmlabproj` bundle plus
// per-sheet SPICE netlists (and a `top.cir` entry point) that KiCad and ngspice
// read directly.

import Foundation

public enum KiCadProjectError: LocalizedError, Equatable {
    case unrecognizedProject(String)
    case requiresKiCad(String)

    public var errorDescription: String? {
        switch self {
        case .unrecognizedProject(let name):
            return "\(name) is not a KiCad project (.kicad_pro) or top schematic (.kicad_sch)."
        case .requiresKiCad(let name):
            return "Importing \(name) needs `kicad-cli` (macOS). Export a SPICE netlist from KiCad and import that instead."
        }
    }
}

public enum KiCadProjectInterchange {
    /// KiCad's native project/schematic extensions.
    public static let projectExtension = "kicad_pro"
    public static let schematicExtension = "kicad_sch"

    /// The conventional top-level `.kicad_sch` for `url`, whether `url` is a
    /// project or a schematic. Returns nil when `url` is neither.
    ///
    /// A project normally stores its root sheet beside itself under the same
    /// stem. When that file is absent, the directory is scanned for the sheet
    /// no other sheet references, which is the root of the hierarchy.
    public static func topSchematic(for url: URL) -> URL? {
        switch url.pathExtension.lowercased() {
        case schematicExtension:
            return url
        case projectExtension:
            let conventional = url.deletingPathExtension()
                .appendingPathExtension(schematicExtension)
            if FileManager.default.fileExists(atPath: conventional.path) {
                return conventional
            }
            return discoverRootSchematic(in: url.deletingLastPathComponent())
                ?? conventional
        default:
            return nil
        }
    }

    /// Resolves the root schematic for any file in a KiCad project. A
    /// `.kicad_pro` resolves through `topSchematic`; a `.kicad_sch` is walked
    /// up to the sheet that references it, so opening a child sheet still
    /// imports the whole project. Falls back to `url` when no unambiguous root
    /// exists.
    public static func rootSchematic(for url: URL) -> URL? {
        switch url.pathExtension.lowercased() {
        case projectExtension:
            return topSchematic(for: url)
        case schematicExtension:
            if let project = projectFile(for: url),
               let root = topSchematic(for: project) {
                return root
            }
            return rootReachable(from: url, in: url.deletingLastPathComponent()) ?? url
        default:
            return nil
        }
    }

    /// Sheet files referenced by `url`'s `(property "Sheetfile" "...")`
    /// entries, resolved against the schematic's directory.
    static func sheetReferences(in url: URL) -> [URL] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let directory = url.deletingLastPathComponent()
        let marker = "\"Sheetfile\""
        var references: [URL] = []
        var searchStart = text.startIndex
        while let markerRange = text.range(of: marker, range: searchStart..<text.endIndex) {
            var index = markerRange.upperBound
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard index < text.endIndex, text[index] == "\"" else {
                searchStart = markerRange.upperBound
                continue
            }
            let valueStart = text.index(after: index)
            guard let valueEnd = text[valueStart...].firstIndex(of: "\"") else { break }
            let path = String(text[valueStart..<valueEnd])
            if !path.isEmpty, !path.contains("${") {
                let resolved = path.hasPrefix("/")
                    ? URL(fileURLWithPath: path)
                    : directory.appendingPathComponent(path)
                references.append(resolved.standardizedFileURL)
            }
            searchStart = text.index(after: valueEnd)
        }
        return references
    }

    private static func projectFile(for schematic: URL) -> URL? {
        let directory = schematic.deletingLastPathComponent()
        let stem = schematic.deletingPathExtension().lastPathComponent
        let preferred = directory.appendingPathComponent(stem)
            .appendingPathExtension(projectExtension)
        if FileManager.default.fileExists(atPath: preferred.path) {
            return preferred
        }
        let projects = files(in: directory, extension: projectExtension)
        return projects.count == 1 ? projects[0] : nil
    }

    private static func discoverRootSchematic(in directory: URL) -> URL? {
        let schematics = files(in: directory, extension: schematicExtension)
        guard !schematics.isEmpty else { return nil }
        let referenced = Set(schematics.flatMap { sheetReferences(in: $0) })
        let roots = schematics.filter {
            !referenced.contains($0.standardizedFileURL)
        }
        if roots.count == 1 { return roots[0] }
        let directoryStem = directory.lastPathComponent
        return roots.first {
            $0.deletingPathExtension().lastPathComponent == directoryStem
        }
    }

    private static func rootReachable(from target: URL, in directory: URL) -> URL? {
        let schematics = files(in: directory, extension: schematicExtension)
        guard !schematics.isEmpty else { return nil }
        let references = Dictionary(uniqueKeysWithValues: schematics.map {
            ($0.standardizedFileURL, sheetReferences(in: $0))
        })
        let referenced = Set(references.values.flatMap { $0 })
        let roots = schematics.filter {
            !referenced.contains($0.standardizedFileURL)
        }
        let targetURL = target.standardizedFileURL
        for root in roots {
            var visited: Set<URL> = []
            var queue = [root.standardizedFileURL]
            while let current = queue.popLast() {
                if current == targetURL { return root }
                guard visited.insert(current).inserted else { continue }
                queue.append(contentsOf: references[current] ?? [])
            }
        }
        return nil
    }

    private static func files(in directory: URL, extension fileExtension: String) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == fileExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Imports a KiCad project (or top schematic) into an OhmLab project.
    ///
    /// Direct `.kicad_sch` reading is the default on every platform. On macOS,
    /// if the native reader cannot parse the project, import falls back to
    /// `kicad-cli` and stores the flattened SPICE netlist.
    public static func importProject(
        at url: URL,
        executable: URL? = nil,
        now: Date = Date()
    ) throws -> ProjectBundle {
        guard let schematic = rootSchematic(for: url) else {
            throw KiCadProjectError.unrecognizedProject(url.lastPathComponent)
        }
        let name = url.deletingPathExtension().lastPathComponent
        do {
            let read = try KiCadSchematicReader.readProject(at: schematic)
            return makeSchematicBundle(
                name: name,
                read: read,
                sourceURL: url,
                topSchematic: schematic,
                now: now
            )
        } catch {
            #if os(macOS)
            let netlist = try KiCadCLIClient.exportSpiceNetlist(from: schematic, executable: executable)
            return makeImportedBundle(
                name: name,
                netlist: netlist,
                sourceURL: url,
                topSchematic: schematic,
                now: now
            )
            #else
            throw KiCadProjectError.requiresKiCad(url.lastPathComponent)
            #endif
        }
    }

    /// Builds a schematic-backed bundle for a directly read KiCad project. The
    /// root sheet becomes the active document; child sheets live in the
    /// snapshot's hierarchy.
    static func makeSchematicBundle(
        name: String,
        read: KiCadSchematicReadResult,
        sourceURL: URL,
        topSchematic: URL,
        now: Date
    ) -> ProjectBundle {
        let baseDirectory = topSchematic.deletingLastPathComponent()
        let libraries = read.modelLibraries.map {
            StoredModelLibrary(name: $0.name, text: $0.rawText)
        }
        let document = CircuitFile(
            name: name,
            schematic: read.snapshot,
            analysis: .default,
            usesSchematic: true,
            modelLibraries: libraries,
            importBaseDirectory: baseDirectory.path
        )
        let sheet = ProjectSheet(id: "top", name: name, fileName: "Sheets/top.ohmlab")
        var manifest = ProjectManifest(
            name: name,
            sheets: [sheet],
            activeSheetID: sheet.id,
            modelLibraries: libraries,
            kicadSource: KiCadSource(
                projectPath: sourceURL.path,
                topSchematic: topSchematic.path,
                importedAt: ISO8601DateFormatter().string(from: now)
            )
        )
        manifest.metadata["source"] = "kicad"
        return ProjectBundle(manifest: manifest, documents: [sheet.id: document])
    }

    /// Builds the bundle for an imported netlist. Split out so the mapping to a
    /// `ProjectBundle` is testable without running KiCad.
    static func makeImportedBundle(
        name: String,
        netlist: String,
        sourceURL: URL,
        topSchematic: URL,
        now: Date
    ) -> ProjectBundle {
        let baseDirectory = sourceURL.deletingLastPathComponent()
        let inlined = SpiceIncludePipeline.inline(netlist, baseDirectory: baseDirectory)
        let document = CircuitFile(
            name: name,
            schematic: SchematicSnapshot(),
            analysis: .default,
            netlistText: netlist,
            resolvedNetlistText: inlined.text == netlist ? nil : inlined.text,
            usesSchematic: false,
            importBaseDirectory: baseDirectory.path
        )
        let sheet = ProjectSheet(id: "top", name: name, fileName: "Sheets/top.ohmlab")
        var manifest = ProjectManifest(
            name: name,
            sheets: [sheet],
            activeSheetID: sheet.id,
            kicadSource: KiCadSource(
                projectPath: sourceURL.path,
                topSchematic: topSchematic.path,
                importedAt: ISO8601DateFormatter().string(from: now)
            )
        )
        manifest.metadata["source"] = "kicad"
        return ProjectBundle(manifest: manifest, documents: [sheet.id: document])
    }

    /// Writes `bundle` as a `.ohmlabproj` directory and, alongside it, one SPICE
    /// netlist per sheet plus the active sheet as `top.cir`. Returns the files
    /// written (the bundle directory first).
    @discardableResult
    public static func exportProject(_ bundle: ProjectBundle, to directory: URL) throws -> [URL] {
        let fileManager = FileManager.default
        try ProjectBundleStore.write(bundle, to: directory)

        let netlistDirectory = directory.appendingPathComponent("netlists", isDirectory: true)
        try fileManager.createDirectory(at: netlistDirectory, withIntermediateDirectories: true)

        var written: [URL] = [directory]
        for sheet in bundle.manifest.sheets {
            guard let document = bundle.documents[sheet.id] else { continue }
            let netlist = try netlist(for: document)
            let stem = ProjectSheet.slug(from: sheet.name)
            let url = netlistDirectory.appendingPathComponent("\(stem).cir")
            try netlist.write(to: url, atomically: true, encoding: .utf8)
            written.append(url)
        }

        if let active = bundle.activeDocument {
            let topURL = directory.appendingPathComponent("top.cir")
            try netlist(for: active).write(to: topURL, atomically: true, encoding: .utf8)
            written.append(topURL)

            // A schematic-backed project also gets a real KiCad project so the
            // round trip works in both directions.
            if active.usesSchematic == true,
               !active.schematic.symbols.isEmpty || !active.schematic.sheets.isEmpty {
                let kicadDirectory = directory.appendingPathComponent("KiCad", isDirectory: true)
                let result = try KiCadSchematicWriter.writeProject(
                    snapshot: active.schematic,
                    name: bundle.manifest.name,
                    to: kicadDirectory
                )
                written.append(contentsOf: result.files)
            }
        }
        return written
    }

    /// The SPICE netlist for a document: its include-resolved netlist when one
    /// was captured at import, otherwise its stored netlist text, or a
    /// projection of its schematic when it is in schematic mode.
    static func netlist(for document: CircuitFile) throws -> String {
        if document.usesSchematic != true {
            if let text = document.resolvedNetlistText,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            if let text = document.netlistText,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return try SpiceNetlistBuilder.export(
            snapshot: document.schematic,
            title: document.name,
            analysis: document.analysis,
            libraryTexts: (document.modelLibraries ?? []).map(\.text)
        )
    }
}
