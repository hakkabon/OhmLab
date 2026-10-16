// CircuitFile.swift
// Durable, versioned document format and a small file store.
//
// A `.dblab` file is JSON holding a schema version, the schematic geometry, and
// the analysis settings. The schema version lets future format changes migrate
// old documents instead of discarding them. Unsaved edits are mirrored to a
// recovery slot so a crash does not lose work.

import Foundation

public struct AnalysisSettings: Codable, Equatable, Sendable {
    public var runDC: Bool
    public var runAC: Bool
    public var acStartFrequency: Double
    public var acStopFrequency: Double
    public var acPointsPerDecade: Int
    /// Net name the source is measured against (nil = all sources).
    public var inputNetName: String?
    /// Nets selected for plotting in the results panel.
    public var outputNetNames: [String]

    public static let `default` = AnalysisSettings(
        runDC: true,
        runAC: true,
        acStartFrequency: 1,
        acStopFrequency: 1_000_000,
        acPointsPerDecade: 20,
        inputNetName: nil,
        outputNetNames: []
    )

    public init(
        runDC: Bool,
        runAC: Bool,
        acStartFrequency: Double,
        acStopFrequency: Double,
        acPointsPerDecade: Int,
        inputNetName: String? = nil,
        outputNetNames: [String] = []
    ) {
        self.runDC = runDC
        self.runAC = runAC
        self.acStartFrequency = acStartFrequency
        self.acStopFrequency = acStopFrequency
        self.acPointsPerDecade = acPointsPerDecade
        self.inputNetName = inputNetName
        self.outputNetNames = outputNetNames
    }
}

public struct CircuitFile: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var name: String
    public var schematic: SchematicSnapshot
    public var analysis: AnalysisSettings

    public static let currentSchemaVersion = 1

    public init(
        schemaVersion: Int = CircuitFile.currentSchemaVersion,
        name: String,
        schematic: SchematicSnapshot,
        analysis: AnalysisSettings
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.schematic = schematic
        self.analysis = analysis
    }
}

public enum CircuitFileError: LocalizedError {
    case unsupportedVersion(Int)
    case corrupt

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "This document was created by a newer version of db-Lab (format \(version)) and cannot be opened."
        case .corrupt:
            return "The document is not a valid db-Lab circuit file."
        }
    }
}

public enum CircuitFileStore {
    /// File extension used for saved circuits.
    public static let fileExtension = "dblab"

    public static func encode(_ file: CircuitFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    public static func decode(_ data: Data) throws -> CircuitFile {
        let decoder = JSONDecoder()
        guard var file = try? decoder.decode(CircuitFile.self, from: data) else {
            throw CircuitFileError.corrupt
        }
        if file.schemaVersion > CircuitFile.currentSchemaVersion {
            throw CircuitFileError.unsupportedVersion(file.schemaVersion)
        }
        file = try migrate(file)
        return file
    }

    private static func migrate(_ file: CircuitFile) throws -> CircuitFile {
        // Only version 1 exists today; this switch is where future upgrades go.
        switch file.schemaVersion {
        case 1:
            return file
        default:
            throw CircuitFileError.unsupportedVersion(file.schemaVersion)
        }
    }

    public static func write(_ file: CircuitFile, to url: URL) throws {
        let data = try encode(file)
        try data.write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> CircuitFile {
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    // MARK: - Crash recovery

    private static func recoveryURL() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let directory = base.appendingPathComponent("db-Lab", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("recovery.dblab")
    }

    /// Mirror the in-memory document to the recovery slot. Best-effort.
    public static func saveRecovery(_ file: CircuitFile) {
        guard let url = recoveryURL() else { return }
        try? encode(file).write(to: url, options: .atomic)
    }

    public static func loadRecovery() -> CircuitFile? {
        guard let url = recoveryURL(), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? read(from: url)
    }

    public static func clearRecovery() {
        guard let url = recoveryURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    public static var hasRecovery: Bool {
        guard let url = recoveryURL() else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
