// ProjectBundle.swift
// A multi-sheet OhmLab project: a folder bundle (`.ohmlabproj`) holding a
// `project.json` manifest plus one `.ohmlab` document per sheet.
//
// The bundle is the unit that KiCad project interop and cloud sync operate on.
// It is a plain directory (so it diffs and syncs well) whose layout mirrors the
// single-document format: the manifest names each sheet's file, and every sheet
// is an ordinary `CircuitFile`.

import Foundation

/// One sheet within a project: a stable id, a display name, and the file that
/// stores it (relative to the bundle root).
public struct ProjectSheet: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var fileName: String

    public init(id: String, name: String, fileName: String) {
        self.id = id
        self.name = name
        self.fileName = fileName
    }

    /// A sheet for a document, deriving a filesystem-safe id and file name.
    public init(id: String = UUID().uuidString, name: String) {
        let slug = ProjectSheet.slug(from: name)
        self.id = id
        self.name = name
        self.fileName = "Sheets/\(slug)-\(id.prefix(8)).ohmlab"
    }

    /// A filesystem-safe stem (lowercase, alphanumerics and dashes).
    static func slug(from name: String) -> String {
        let mapped = name.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "sheet" : collapsed
    }
}

/// Where a bundle was imported from, so KiCad interop can round-trip.
public struct KiCadSource: Codable, Equatable, Sendable {
    /// The original project file (`.kicad_pro`) or top schematic (`.kicad_sch`).
    public var projectPath: String?
    public var topSchematic: String?
    /// ISO-8601 timestamp of the import.
    public var importedAt: String?

    public init(projectPath: String? = nil, topSchematic: String? = nil, importedAt: String? = nil) {
        self.projectPath = projectPath
        self.topSchematic = topSchematic
        self.importedAt = importedAt
    }
}

/// The bundle's `project.json`.
public struct ProjectManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var name: String
    public var sheets: [ProjectSheet]
    public var activeSheetID: String?
    public var modelLibraries: [StoredModelLibrary]
    public var kicadSource: KiCadSource?
    /// Free-form metadata (author, description, …) preserved across round-trips.
    public var metadata: [String: String]

    public static let currentSchemaVersion = 1

    public init(
        schemaVersion: Int = ProjectManifest.currentSchemaVersion,
        name: String,
        sheets: [ProjectSheet],
        activeSheetID: String? = nil,
        modelLibraries: [StoredModelLibrary] = [],
        kicadSource: KiCadSource? = nil,
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.sheets = sheets
        self.activeSheetID = activeSheetID
        self.modelLibraries = modelLibraries
        self.kicadSource = kicadSource
        self.metadata = metadata
    }

    public func sheet(id: String) -> ProjectSheet? {
        sheets.first { $0.id == id }
    }
}

public enum ProjectBundleError: LocalizedError, Equatable {
    case notFound(String)
    case missingManifest(String)
    case corruptManifest(String)
    case missingSheet(String)
    case emptyProject
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .notFound(let name):
            return "No project bundle was found at \(name)."
        case .missingManifest(let name):
            return "\(name) has no \(ProjectBundleStore.manifestFileName); it is not an OhmLab project."
        case .corruptManifest(let reason):
            return "The project manifest could not be read: \(reason)"
        case .missingSheet(let name):
            return "The project references a missing sheet file: \(name)."
        case .emptyProject:
            return "The project has no sheets."
        case .unsupportedVersion(let version):
            return "This project was created by a newer version of OhmLab (format \(version))."
        }
    }
}

/// An in-memory project: the manifest plus each sheet's document, keyed by id.
public struct ProjectBundle: Equatable, Sendable {
    public var manifest: ProjectManifest
    public var documents: [String: CircuitFile]

    public init(manifest: ProjectManifest, documents: [String: CircuitFile]) {
        self.manifest = manifest
        self.documents = documents
    }

    /// A single-sheet project wrapping one document.
    public static func single(_ file: CircuitFile, name: String? = nil) -> ProjectBundle {
        let sheet = ProjectSheet(id: "sheet-1", name: name ?? file.name)
        let document = CircuitFile(
            name: sheet.name,
            schematic: file.schematic,
            analysis: file.analysis,
            netlistText: file.netlistText,
            usesSchematic: file.usesSchematic,
            modelLibraries: file.modelLibraries
        )
        var manifest = ProjectManifest(name: name ?? file.name, sheets: [sheet], activeSheetID: sheet.id)
        manifest.modelLibraries = file.modelLibraries ?? []
        return ProjectBundle(manifest: manifest, documents: [sheet.id: document])
    }

    /// The active sheet's document, or the first one when unset.
    public var activeDocument: CircuitFile? {
        if let id = manifest.activeSheetID, let document = documents[id] { return document }
        guard let first = manifest.sheets.first else { return nil }
        return documents[first.id]
    }

    public var isWellFormed: Bool {
        !manifest.sheets.isEmpty && manifest.sheets.allSatisfy { documents[$0.id] != nil }
    }
}
