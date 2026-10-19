// KiCadProjectInterchange.swift
// Project-level interchange with KiCad.
//
// OhmLab does not parse `.kicad_sch`/`.kicad_pro` natively; it borrows KiCad's
// own exporter (`kicad-cli sch export netlist --format spice`) and stores the
// resulting netlist as the project's sheet. `kicad-cli` flattens the KiCad
// sheet hierarchy into a single top-level netlist, so an imported project is a
// faithful, engine-ready circuit. Export writes a valid `.ohmlabproj` bundle
// plus per-sheet SPICE netlists (and a `top.cir` entry point) that KiCad and
// ngspice read directly.

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

    /// The top-level `.kicad_sch` for `url`, whether `url` is a project or a
    /// schematic. Returns nil when `url` is neither.
    public static func topSchematic(for url: URL) -> URL? {
        switch url.pathExtension.lowercased() {
        case schematicExtension:
            return url
        case projectExtension:
            let stem = url.deletingPathExtension()
            return stem.appendingPathExtension(schematicExtension)
        default:
            return nil
        }
    }

    #if os(macOS)
    /// Imports a KiCad project (or top schematic) into a single-sheet OhmLab
    /// project whose sheet holds the flattened SPICE netlist.
    public static func importProject(
        at url: URL,
        executable: URL? = nil,
        now: Date = Date()
    ) throws -> ProjectBundle {
        guard let schematic = topSchematic(for: url) else {
            throw KiCadProjectError.unrecognizedProject(url.lastPathComponent)
        }
        let netlist = try KiCadCLIClient.exportSpiceNetlist(from: schematic, executable: executable)
        let name = url.deletingPathExtension().lastPathComponent
        return makeImportedBundle(name: name, netlist: netlist, sourceURL: url, topSchematic: schematic, now: now)
    }
    #else
    public static func importProject(
        at url: URL,
        executable: URL? = nil,
        now: Date = Date()
    ) throws -> ProjectBundle {
        guard topSchematic(for: url) != nil else {
            throw KiCadProjectError.unrecognizedProject(url.lastPathComponent)
        }
        throw KiCadProjectError.requiresKiCad(url.lastPathComponent)
    }
    #endif

    /// Builds the bundle for an imported netlist. Split out so the mapping to a
    /// `ProjectBundle` is testable without running KiCad.
    static func makeImportedBundle(
        name: String,
        netlist: String,
        sourceURL: URL,
        topSchematic: URL,
        now: Date
    ) -> ProjectBundle {
        let document = CircuitFile(
            name: name,
            schematic: SchematicSnapshot(),
            analysis: .default,
            netlistText: netlist,
            usesSchematic: false
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
        }
        return written
    }

    /// The SPICE netlist for a document: its stored netlist text, or a projection
    /// of its schematic when it is in schematic mode.
    static func netlist(for document: CircuitFile) throws -> String {
        if document.usesSchematic == false, let text = document.netlistText,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if let text = document.netlistText,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           document.usesSchematic != true {
            return text
        }
        return try SpiceNetlistBuilder.build(snapshot: document.schematic)
    }
}
