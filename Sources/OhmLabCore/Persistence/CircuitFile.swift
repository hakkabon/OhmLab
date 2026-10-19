// CircuitFile.swift
// Durable, versioned document format and a small file store.
//
// A `.ohmlab` file is JSON holding a schema version, the schematic geometry, and
// the analysis settings. The schema version lets future format changes migrate
// old documents instead of discarding them. Unsaved edits are mirrored to a
// recovery slot so a crash does not lose work.

import Foundation

public struct AnalysisSettings: Codable, Equatable, Sendable {
    public var runDC: Bool
    public var runAC: Bool
    public var runTransient: Bool
    public var acSweepType: FrequencySweepType
    public var acStartFrequency: Double
    public var acStopFrequency: Double
    /// Points per decade/octave, or the total point count for a linear sweep.
    public var acPointsPerDecade: Int
    /// Transient step size, stop time, and start time (for delayed output).
    public var tranStep: Double
    public var tranStop: Double
    public var tranStart: Double
    /// DC sweep of a single named source (schematic mode; netlists may also use
    /// a `.dc` card).
    public var runDCSweep: Bool
    public var dcSweepSource: String
    public var dcSweepStart: Double
    public var dcSweepStop: Double
    public var dcSweepStep: Double
    /// Net name the source is measured against (nil = all sources).
    public var inputNetName: String?
    /// Nets selected for plotting in the results panel.
    public var outputNetNames: [String]

    public static let `default` = AnalysisSettings(
        runDC: true,
        runAC: true,
        runTransient: false,
        acStartFrequency: 1,
        acStopFrequency: 1_000_000,
        acPointsPerDecade: 20,
        acSweepType: .dec,
        tranStep: 1e-4,
        tranStop: 1e-2,
        tranStart: 0,
        runDCSweep: false,
        dcSweepSource: "",
        dcSweepStart: 0,
        dcSweepStop: 5,
        dcSweepStep: 1,
        inputNetName: nil,
        outputNetNames: []
    )

    public init(
        runDC: Bool,
        runAC: Bool,
        runTransient: Bool = false,
        acStartFrequency: Double,
        acStopFrequency: Double,
        acPointsPerDecade: Int,
        acSweepType: FrequencySweepType = .dec,
        tranStep: Double = 1e-4,
        tranStop: Double = 1e-2,
        tranStart: Double = 0,
        runDCSweep: Bool = false,
        dcSweepSource: String = "",
        dcSweepStart: Double = 0,
        dcSweepStop: Double = 5,
        dcSweepStep: Double = 1,
        inputNetName: String? = nil,
        outputNetNames: [String] = []
    ) {
        self.runDC = runDC
        self.runAC = runAC
        self.runTransient = runTransient
        self.acSweepType = acSweepType
        self.acStartFrequency = acStartFrequency
        self.acStopFrequency = acStopFrequency
        self.acPointsPerDecade = acPointsPerDecade
        self.tranStep = tranStep
        self.tranStop = tranStop
        self.tranStart = tranStart
        self.runDCSweep = runDCSweep
        self.dcSweepSource = dcSweepSource
        self.dcSweepStart = dcSweepStart
        self.dcSweepStop = dcSweepStop
        self.dcSweepStep = dcSweepStep
        self.inputNetName = inputNetName
        self.outputNetNames = outputNetNames
    }

    private enum CodingKeys: String, CodingKey {
        case runDC, runAC, runTransient, acSweepType, acStartFrequency, acStopFrequency
        case acPointsPerDecade, tranStep, tranStop, tranStart, inputNetName, outputNetNames
        case runDCSweep, dcSweepSource, dcSweepStart, dcSweepStop, dcSweepStep
    }

    /// Custom decoding so documents written before `acSweepType` or the
    /// transient settings existed still load with sensible defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runDC = try container.decode(Bool.self, forKey: .runDC)
        runAC = try container.decode(Bool.self, forKey: .runAC)
        runTransient = try container.decodeIfPresent(Bool.self, forKey: .runTransient) ?? false
        acSweepType = try container.decodeIfPresent(FrequencySweepType.self, forKey: .acSweepType) ?? .dec
        acStartFrequency = try container.decode(Double.self, forKey: .acStartFrequency)
        acStopFrequency = try container.decode(Double.self, forKey: .acStopFrequency)
        acPointsPerDecade = try container.decode(Int.self, forKey: .acPointsPerDecade)
        tranStep = try container.decodeIfPresent(Double.self, forKey: .tranStep) ?? 1e-4
        tranStop = try container.decodeIfPresent(Double.self, forKey: .tranStop) ?? 1e-2
        tranStart = try container.decodeIfPresent(Double.self, forKey: .tranStart) ?? 0
        runDCSweep = try container.decodeIfPresent(Bool.self, forKey: .runDCSweep) ?? false
        dcSweepSource = try container.decodeIfPresent(String.self, forKey: .dcSweepSource) ?? ""
        dcSweepStart = try container.decodeIfPresent(Double.self, forKey: .dcSweepStart) ?? 0
        dcSweepStop = try container.decodeIfPresent(Double.self, forKey: .dcSweepStop) ?? 5
        dcSweepStep = try container.decodeIfPresent(Double.self, forKey: .dcSweepStep) ?? 1
        inputNetName = try container.decodeIfPresent(String.self, forKey: .inputNetName)
        outputNetNames = try container.decodeIfPresent([String].self, forKey: .outputNetNames) ?? []
    }
}

/// A vendor model library stored in a document. Only the raw text is kept; it
/// is re-scanned into a `SpiceModelLibrary` when the document is opened.
public struct StoredModelLibrary: Codable, Equatable, Sendable {
    public var name: String
    public var text: String

    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }
}

public struct CircuitFile: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var name: String
    public var schematic: SchematicSnapshot
    public var analysis: AnalysisSettings
    /// The netlist editor's text, when the document was last in netlist mode.
    public var netlistText: String?
    /// Which editor the document was last showing (`true` = schematic).
    public var usesSchematic: Bool?
    /// Imported vendor model libraries.
    public var modelLibraries: [StoredModelLibrary]?

    public static let currentSchemaVersion = 3

    public init(
        schemaVersion: Int = CircuitFile.currentSchemaVersion,
        name: String,
        schematic: SchematicSnapshot,
        analysis: AnalysisSettings,
        netlistText: String? = nil,
        usesSchematic: Bool? = nil,
        modelLibraries: [StoredModelLibrary]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.schematic = schematic
        self.analysis = analysis
        self.netlistText = netlistText
        self.usesSchematic = usesSchematic
        self.modelLibraries = modelLibraries
    }
}

public enum CircuitFileError: LocalizedError {
    case unsupportedVersion(Int)
    case corrupt

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "This document was created by a newer version of OhmLab (format \(version)) and cannot be opened."
        case .corrupt:
            return "The document is not a valid OhmLab circuit file."
        }
    }
}

public enum CircuitFileStore {
    /// File extension used for saved circuits.
    public static let fileExtension = "ohmlab"

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
        var file = file
        switch file.schemaVersion {
        case 1:
            // v1 stored a single `voltage`/`current` magnitude on sources. Split
            // it into the v2 DC/AC parameters, preserving the old behaviour
            // (the single value drove both DC and AC).
            file.schematic.symbols = file.schematic.symbols.map(migrateSourceParameters)
            file.schemaVersion = 2
            fallthrough
        case 2:
            // v3 persists netlist-mode text, the active editor, and imported
            // model libraries. Absent fields decode to nil, so nothing to do.
            file.schemaVersion = 3
            fallthrough
        case 3:
            return file
        default:
            throw CircuitFileError.unsupportedVersion(file.schemaVersion)
        }
    }

    private static func migrateSourceParameters(_ symbol: SymbolInstance) -> SymbolInstance {
        var symbol = symbol
        if let legacy = symbol.parameters.removeValue(forKey: "voltage") {
            symbol.parameters["dcVoltage"] = symbol.parameters["dcVoltage"] ?? legacy
            symbol.parameters["acMagnitude"] = symbol.parameters["acMagnitude"] ?? legacy
            symbol.parameters["acPhaseDegrees"] = symbol.parameters["acPhaseDegrees"] ?? 0
        }
        if let legacy = symbol.parameters.removeValue(forKey: "current") {
            symbol.parameters["dcCurrent"] = symbol.parameters["dcCurrent"] ?? legacy
            symbol.parameters["acMagnitude"] = symbol.parameters["acMagnitude"] ?? legacy
            symbol.parameters["acPhaseDegrees"] = symbol.parameters["acPhaseDegrees"] ?? 0
        }
        return symbol
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
    //
    // Each open document mirrors itself to its own recovery slot (keyed by the
    // document ID), so several unsaved documents survive a crash without
    // overwriting one another.

    private static let recoveryPrefix = "recovery-"

    private static func recoveryDirectory() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let directory = base.appendingPathComponent("OhmLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func recoveryURL(id: UUID) -> URL? {
        recoveryDirectory()?.appendingPathComponent("\(recoveryPrefix)\(id.uuidString).\(fileExtension)")
    }

    /// Mirror the in-memory document to its recovery slot. Best-effort.
    public static func saveRecovery(_ file: CircuitFile, id: UUID) {
        guard let url = recoveryURL(id: id) else { return }
        try? encode(file).write(to: url, options: .atomic)
    }

    public static func loadRecovery(id: UUID) -> CircuitFile? {
        guard let url = recoveryURL(id: id), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? read(from: url)
    }

    public static func clearRecovery(id: UUID) {
        guard let url = recoveryURL(id: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// All recoverable documents, stable-sorted by slot name.
    public static func loadAllRecoveries() -> [CircuitFile] {
        guard let directory = recoveryDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        return urls
            .filter { $0.lastPathComponent.hasPrefix(recoveryPrefix) && $0.pathExtension == fileExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? read(from: $0) }
    }
}
