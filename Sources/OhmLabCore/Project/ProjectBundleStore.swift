// ProjectBundleStore.swift
// Reads and writes `.ohmlabproj` folder bundles (and single-file `.ohmlabzip`
// archives) to and from disk.

import Foundation

public enum ProjectBundleStore {
    /// The bundle folder extension.
    public static let bundleExtension = "ohmlabproj"
    /// The archive extension used for transport.
    public static let archiveExtension = "ohmlabzip"
    /// The manifest file name inside the bundle.
    public static let manifestFileName = "project.json"

    // MARK: - Folder bundle

    /// Reads a bundle from a directory.
    public static func read(from directory: URL) throws -> ProjectBundle {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            throw ProjectBundleError.notFound(directory.lastPathComponent)
        }
        guard isDirectory.boolValue else {
            throw ProjectBundleError.missingManifest(directory.lastPathComponent)
        }
        let manifestURL = directory.appendingPathComponent(manifestFileName)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw ProjectBundleError.missingManifest(directory.lastPathComponent)
        }
        let manifest = try decodeManifest(try Data(contentsOf: manifestURL))
        guard !manifest.sheets.isEmpty else { throw ProjectBundleError.emptyProject }

        var documents: [String: CircuitFile] = [:]
        for sheet in manifest.sheets {
            let url = directory.appendingPathComponent(sheet.fileName)
            guard let data = try? Data(contentsOf: url) else {
                throw ProjectBundleError.missingSheet(sheet.fileName)
            }
            documents[sheet.id] = try CircuitFileStore.decode(data)
        }
        return ProjectBundle(manifest: manifest, documents: documents)
    }

    /// Writes a bundle to a directory (creating it and any sheet subfolders).
    public static func write(_ bundle: ProjectBundle, to directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // Remove stale sheet files no longer referenced by the manifest.
        if let existing = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in existing where url.pathExtension == CircuitFileStore.fileExtension {
                try? fileManager.removeItem(at: url)
            }
        }

        for sheet in bundle.manifest.sheets {
            guard let document = bundle.documents[sheet.id] else { continue }
            let url = directory.appendingPathComponent(sheet.fileName)
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try CircuitFileStore.write(document, to: url)
        }
        try encodeManifest(bundle.manifest).write(
            to: directory.appendingPathComponent(manifestFileName),
            options: .atomic
        )
    }

    // MARK: - Archive

    /// Packs a bundle into a single `.ohmlabzip` (a stored ZIP of the folder).
    public static func archive(_ bundle: ProjectBundle, to url: URL) throws {
        var entries: [ZipArchive.Entry] = [
            ZipArchive.Entry(name: manifestFileName, data: try encodeManifest(bundle.manifest))
        ]
        for sheet in bundle.manifest.sheets {
            guard let document = bundle.documents[sheet.id] else { continue }
            entries.append(ZipArchive.Entry(
                name: sheet.fileName,
                data: try CircuitFileStore.encode(document)
            ))
        }
        let data = ZipArchive.create(entries)
        try data.write(to: url, options: .atomic)
    }

    /// Unpacks a `.ohmlabzip` archive into a temporary directory and reads it.
    public static func unarchive(from url: URL) throws -> ProjectBundle {
        let entries = try ZipArchive.read(try Data(contentsOf: url))
        guard let manifestEntry = entries.first(where: { $0.name == manifestFileName }) else {
            throw ProjectBundleError.missingManifest(url.lastPathComponent)
        }
        let manifest = try decodeManifest(manifestEntry.data)
        guard !manifest.sheets.isEmpty else { throw ProjectBundleError.emptyProject }

        var documents: [String: CircuitFile] = [:]
        for sheet in manifest.sheets {
            guard let entry = entries.first(where: { $0.name == sheet.fileName }) else {
                throw ProjectBundleError.missingSheet(sheet.fileName)
            }
            documents[sheet.id] = try CircuitFileStore.decode(entry.data)
        }
        return ProjectBundle(manifest: manifest, documents: documents)
    }

    // MARK: - Manifest coding

    static func encodeManifest(_ manifest: ProjectManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }

    static func decodeManifest(_ data: Data) throws -> ProjectManifest {
        guard let manifest = try? JSONDecoder().decode(ProjectManifest.self, from: data) else {
            throw ProjectBundleError.corruptManifest("not valid JSON")
        }
        guard manifest.schemaVersion <= ProjectManifest.currentSchemaVersion else {
            throw ProjectBundleError.unsupportedVersion(manifest.schemaVersion)
        }
        return manifest
    }
}
