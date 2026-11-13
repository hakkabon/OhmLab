// KiCadCompanion.swift
// KiCad-native companion: capability manifest, change detection, and
// bidirectional synchronisation between a KiCad project hierarchy and an
// OhmLab `.ohmlabproj` bundle.
//
// The companion keeps a small sidecar (`.ohmlab-companion.json`) inside the
// bundle. It records the KiCad and OhmLab digests observed at the last
// successful sync, so `auto` can tell which side changed and so conflicting
// edits are refused instead of silently losing work.
//
// Digests are content-based, ordered by relative path, and deliberately ignore
// volatile import metadata (`importedAt`, `resolvedNetlistText`, and
// `importBaseDirectory`). The same project therefore hashes the same on every
// run and on every machine.

import Foundation

public enum KiCadCompanionError: LocalizedError, Equatable {
    case missingProject(String)
    case missingBundle(String)
    case directionRequired
    case conflictingChanges
    case invalidDirection(String)
    case invalidPreference(String)
    case exportRequiresSchematic
    case mergeConflicts([String])
    case invalidState(String)

    public var errorDescription: String? {
        switch self {
        case .missingProject(let name):
            return "No KiCad project or project directory was found at \(name)."
        case .missingBundle(let name):
            return "No OhmLab project bundle was found at \(name)."
        case .directionRequired:
            return "The bundle already exists and has no companion state; pass --direction import or --direction export."
        case .conflictingChanges:
            return "Both the KiCad project and the OhmLab bundle changed since the last sync; pass --prefer kicad or --prefer ohmlab (or --force)."
        case .invalidDirection(let value):
            return "Unknown sync direction \(value); expected import, export, or auto."
        case .invalidPreference(let value):
            return "Unknown sync preference \(value); expected kicad or ohmlab."
        case .exportRequiresSchematic:
            return "Export sync needs a schematic-backed OhmLab document; this bundle has no writable KiCad schematic."
        case .mergeConflicts(let conflicts):
            let detail = conflicts.prefix(5).joined(separator: "; ")
            let more = conflicts.count > 5 ? " (and \(conflicts.count - 5) more)" : ""
            return "Both sides changed the same object; resolve with --prefer kicad|ohmlab or edit the collision: \(detail)\(more)."
        case .invalidState(let reason):
            return "The KiCad companion state is invalid: \(reason)"
        }
    }
}

/// What the companion can do, published by `ohm kicad companion --json`.
public struct KiCadCompanionCapabilities: Codable, Equatable, Sendable {
    public let nativeRead: Bool
    public let nativeWrite: Bool
    public let bidirectionalSync: Bool
    public let conflictDetection: Bool
    public let threeWayMerge: Bool
    public let dryRun: Bool

    public init(
        nativeRead: Bool = true,
        nativeWrite: Bool = true,
        bidirectionalSync: Bool = true,
        conflictDetection: Bool = true,
        threeWayMerge: Bool = true,
        dryRun: Bool = true
    ) {
        self.nativeRead = nativeRead
        self.nativeWrite = nativeWrite
        self.bidirectionalSync = bidirectionalSync
        self.conflictDetection = conflictDetection
        self.threeWayMerge = threeWayMerge
        self.dryRun = dryRun
    }
}

/// The companion contract manifest.
public struct KiCadCompanionManifest: Codable, Equatable, Sendable {
    public static let currentContractVersion = 2
    public static let stateFileName = ".ohmlab-companion.json"
    public static let baseFileName = KiCadCompanionBase.fileName

    public let contractVersion: Int
    public let productVersion: String
    public let productionBoundary: Int
    public let projectExtensions: [String]
    public let schematicExtensions: [String]
    public let digestExtensions: [String]
    public let directions: [String]
    public let preferences: [String]
    public let stateFileName: String
    public let baseFileName: String
    public let capabilities: KiCadCompanionCapabilities

    public init(
        contractVersion: Int = KiCadCompanionManifest.currentContractVersion,
        productVersion: String,
        productionBoundary: Int,
        projectExtensions: [String],
        schematicExtensions: [String],
        digestExtensions: [String],
        directions: [String],
        preferences: [String],
        stateFileName: String,
        baseFileName: String,
        capabilities: KiCadCompanionCapabilities
    ) {
        self.contractVersion = contractVersion
        self.productVersion = productVersion
        self.productionBoundary = productionBoundary
        self.projectExtensions = projectExtensions
        self.schematicExtensions = schematicExtensions
        self.digestExtensions = digestExtensions
        self.directions = directions
        self.preferences = preferences
        self.stateFileName = stateFileName
        self.baseFileName = baseFileName
        self.capabilities = capabilities
    }
}

/// The sidecar stored in the bundle after a successful sync.
public struct KiCadCompanionState: Codable, Equatable, Sendable {
    public static let currentContractVersion = 1

    public let contractVersion: Int
    public let kicadDigest: String
    public let bundleDigest: String
    public let syncedAt: String
    public let direction: String

    public init(
        kicadDigest: String,
        bundleDigest: String,
        syncedAt: String,
        direction: String,
        contractVersion: Int = KiCadCompanionState.currentContractVersion
    ) {
        self.contractVersion = contractVersion
        self.kicadDigest = kicadDigest
        self.bundleDigest = bundleDigest
        self.syncedAt = syncedAt
        self.direction = direction
    }
}

public enum KiCadSyncDirection: String, Codable, Sendable, CaseIterable {
    case importKiCad = "import"
    case exportOhmLab = "export"
    case auto
}

public enum KiCadSyncPreference: String, Codable, Sendable, CaseIterable {
    case kicad
    case ohmlab
}

public enum KiCadCompanionRecommendation: String, Codable, Sendable {
    case importKiCad = "import"
    case exportOhmLab = "export"
    case merge
    case conflict
    case upToDate = "up-to-date"
    case unknown
}

/// A non-mutating view of both sides and the last sync.
public struct KiCadCompanionStatus: Codable, Equatable, Sendable {
    public let kicadPath: String
    public let bundlePath: String
    public let kicadDigest: String
    public let bundleDigest: String
    public let state: KiCadCompanionState?
    public let kicadChanged: Bool
    public let bundleChanged: Bool
    public let inSync: Bool
    public let recommendation: KiCadCompanionRecommendation

    public init(
        kicadPath: String,
        bundlePath: String,
        kicadDigest: String,
        bundleDigest: String,
        state: KiCadCompanionState?,
        kicadChanged: Bool,
        bundleChanged: Bool,
        inSync: Bool,
        recommendation: KiCadCompanionRecommendation
    ) {
        self.kicadPath = kicadPath
        self.bundlePath = bundlePath
        self.kicadDigest = kicadDigest
        self.bundleDigest = bundleDigest
        self.state = state
        self.kicadChanged = kicadChanged
        self.bundleChanged = bundleChanged
        self.inSync = inSync
        self.recommendation = recommendation
    }
}

/// The outcome of a sync run.
public struct KiCadSyncResult: Codable, Equatable, Sendable {
    public let direction: String
    public let kicadDigest: String
    public let bundleDigest: String
    public let writtenFiles: [String]
    public let state: KiCadCompanionState
    public let warnings: [String]

    public init(
        direction: String,
        kicadDigest: String,
        bundleDigest: String,
        writtenFiles: [String],
        state: KiCadCompanionState,
        warnings: [String]
    ) {
        self.direction = direction
        self.kicadDigest = kicadDigest
        self.bundleDigest = bundleDigest
        self.writtenFiles = writtenFiles
        self.state = state
        self.warnings = warnings
    }
}

public enum KiCadCompanion {
    /// Extensions whose contents participate in the KiCad project digest.
    public static let digestExtensions = ["kicad_pro", "kicad_sch", "kicad_sym", "kicad_mod", "lib"]

    public static func manifest() -> KiCadCompanionManifest {
        KiCadCompanionManifest(
            productVersion: OhmLabRelease.version,
            productionBoundary: OhmLabRelease.productionBoundaryVersion,
            projectExtensions: [KiCadProjectInterchange.projectExtension],
            schematicExtensions: [KiCadProjectInterchange.schematicExtension],
            digestExtensions: digestExtensions,
            directions: KiCadSyncDirection.allCases.map(\.rawValue),
            preferences: KiCadSyncPreference.allCases.map(\.rawValue),
            stateFileName: KiCadCompanionManifest.stateFileName,
            baseFileName: KiCadCompanionManifest.baseFileName,
            capabilities: KiCadCompanionCapabilities()
        )
    }

    // MARK: - Digest

    /// The deterministic digest of every KiCad project file under `url`'s
    /// directory. `url` may be the project directory, a `.kicad_pro`, or a
    /// `.kicad_sch`; files are ordered by relative path.
    public static func digest(ofKiCadProjectAt url: URL) throws -> String {
        let directory = projectDirectory(for: url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw KiCadCompanionError.missingProject(url.lastPathComponent)
        }

        let base = directory.standardizedFileURL
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw KiCadCompanionError.missingProject(url.lastPathComponent)
        }

        var files: [(path: String, url: URL)] = []
        for case let fileURL as URL in enumerator {
            guard digestExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            files.append((relativePath(of: fileURL, under: base), fileURL))
        }
        files.sort { $0.path < $1.path }

        var data = Data()
        for file in files {
            let contents = try Data(contentsOf: file.url)
            appendDigestField(file.path, to: &data)
            appendDigestField(String(contents.count), to: &data)
            data.append(contents)
            data.append(0)
        }
        return StableSHA256.hexDigest(data)
    }

    /// The deterministic digest of a bundle's sheet names, canonical netlists,
    /// and analysis settings. Import timestamps and other volatile metadata are
    /// intentionally excluded.
    public static func digest(ofBundleAt url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw KiCadCompanionError.missingBundle(url.lastPathComponent)
        }
        let bundle = try ProjectBundleStore.read(from: url)
        var data = Data()
        appendDigestField(bundle.manifest.name, to: &data)
        for sheet in bundle.manifest.sheets.sorted(by: { $0.id < $1.id }) {
            guard let document = bundle.documents[sheet.id] else { continue }
            appendDigestField(sheet.id, to: &data)
            appendDigestField(sheet.name, to: &data)
            appendDigestField(canonicalAnalysis(document.analysis), to: &data)
            appendDigestField(try canonicalNetlist(for: document), to: &data)
        }
        return StableSHA256.hexDigest(data)
    }

    // MARK: - Status

    public static func status(kicad: URL, bundle: URL) throws -> KiCadCompanionStatus {
        let kicadDigest = try digest(ofKiCadProjectAt: kicad)
        let bundleDigest = try digest(ofBundleAt: bundle)
        let state = try readState(from: bundle)

        guard let state else {
            return KiCadCompanionStatus(
                kicadPath: kicad.path,
                bundlePath: bundle.path,
                kicadDigest: kicadDigest,
                bundleDigest: bundleDigest,
                state: nil,
                kicadChanged: true,
                bundleChanged: true,
                inSync: false,
                recommendation: .unknown
            )
        }

        let kicadChanged = kicadDigest != state.kicadDigest
        let bundleChanged = bundleDigest != state.bundleDigest
        let recommendation: KiCadCompanionRecommendation
        if kicadChanged && bundleChanged {
            // A base snapshot means the next sync can attempt a three-way
            // merge. Without one, the companion fails closed and the user must
            // choose a side once.
            let base = bundle.appendingPathComponent(KiCadCompanionBase.fileName)
            recommendation = FileManager.default.fileExists(atPath: base.path)
                ? .merge
                : .conflict
        } else if kicadChanged {
            recommendation = .importKiCad
        } else if bundleChanged {
            recommendation = .exportOhmLab
        } else {
            recommendation = .upToDate
        }
        return KiCadCompanionStatus(
            kicadPath: kicad.path,
            bundlePath: bundle.path,
            kicadDigest: kicadDigest,
            bundleDigest: bundleDigest,
            state: state,
            kicadChanged: kicadChanged,
            bundleChanged: bundleChanged,
            inSync: !kicadChanged && !bundleChanged,
            recommendation: recommendation
        )
    }

    // MARK: - Sync

    /// Synchronises a KiCad project hierarchy and an OhmLab bundle.
    ///
    /// `auto` imports when only KiCad changed, exports when only OhmLab
    /// changed, and three-way merges when both changed. A merge takes each
    /// side's non-conflicting changes; a same-field collision is reported
    /// unless `--prefer kicad|ohmlab` or `--force` resolves it. With no state,
    /// an existing bundle requires an explicit direction; a fresh bundle is
    /// imported from KiCad.
    public static func sync(
        kicad: URL,
        bundle: URL,
        direction: KiCadSyncDirection = .auto,
        prefer: KiCadSyncPreference? = nil,
        force: Bool = false,
        now: Date = Date()
    ) throws -> KiCadSyncResult {
        let fileManager = FileManager.default
        let decision = try resolveAction(
            kicad: kicad,
            bundle: bundle,
            direction: direction,
            prefer: prefer,
            force: force
        )

        guard let action = decision.action else {
            // Already in sync: leave the recorded state (and its timestamp)
            // untouched so repeated runs are byte-idempotent.
            let current = decision.state ?? KiCadCompanionState(
                kicadDigest: decision.kicadDigest,
                bundleDigest: decision.bundleDigest,
                syncedAt: ISO8601DateFormatter().string(from: now),
                direction: "none"
            )
            return KiCadSyncResult(
                direction: "none",
                kicadDigest: decision.kicadDigest,
                bundleDigest: decision.bundleDigest,
                writtenFiles: [],
                state: current,
                warnings: []
            )
        }

        var writtenFiles: [String] = []
        var warnings: [String] = []
        var baseSnapshot: SchematicSnapshot?

        switch action {
        case .importKiCad:
            let imported = try KiCadProjectInterchange.importProject(
                at: resolvedProjectURL(kicad),
                now: now
            )
            let merged = try merge(imported: imported, intoExistingBundleAt: bundle)
            try ProjectBundleStore.write(merged, to: bundle)
            writtenFiles.append(bundle.path)
            baseSnapshot = merged.activeDocument?.schematic

        case .exportOhmLab:
            let bundleValue = try ProjectBundleStore.read(from: bundle)
            guard let document = bundleValue.activeDocument,
                  document.usesSchematic == true,
                  !document.schematic.symbols.isEmpty || !document.schematic.sheets.isEmpty else {
                throw KiCadCompanionError.exportRequiresSchematic
            }
            let directory = projectDirectory(for: kicad)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = exportProjectName(bundle: bundleValue, kicad: kicad)
            let resolved = resolvedProjectURL(kicad)
            let preserveFrom = fileManager.fileExists(atPath: resolved.path) ? resolved : nil
            let result = try KiCadSchematicWriter.writeProject(
                snapshot: document.schematic,
                name: name,
                to: directory,
                preserving: preserveFrom
            )
            writtenFiles = result.files.map(\.path)
            warnings = result.warnings
            baseSnapshot = document.schematic

        case .merge:
            let bundleValue = try ProjectBundleStore.read(from: bundle)
            guard let base = try KiCadCompanionMerge.readBase(from: bundle) else {
                // A legacy state without a recorded base cannot be merged
                // safely; the caller must choose a side once.
                throw KiCadCompanionError.conflictingChanges
            }
            guard let document = bundleValue.activeDocument, document.usesSchematic == true else {
                throw KiCadCompanionError.exportRequiresSchematic
            }
            let imported = try KiCadProjectInterchange.importProject(
                at: resolvedProjectURL(kicad),
                now: now
            )
            guard let kicadSnapshot = imported.activeDocument?.schematic else {
                throw KiCadCompanionError.exportRequiresSchematic
            }
            let output = KiCadCompanionMerge.merge(
                base: base.snapshot,
                kicad: kicadSnapshot,
                bundle: document.schematic,
                rootName: bundleValue.manifest.name
            )
            guard output.conflicts.isEmpty else {
                throw KiCadCompanionError.mergeConflicts(
                    output.conflicts.map(\.description)
                )
            }

            let mergedBundle = try apply(
                output.snapshot,
                to: bundleValue,
                source: imported
            )
            try ProjectBundleStore.write(mergedBundle, to: bundle)
            writtenFiles.append(bundle.path)

            let directory = projectDirectory(for: kicad)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = exportProjectName(bundle: mergedBundle, kicad: kicad)
            let resolved = resolvedProjectURL(kicad)
            let preserveFrom = fileManager.fileExists(atPath: resolved.path) ? resolved : nil
            let result = try KiCadSchematicWriter.writeProject(
                snapshot: output.snapshot,
                name: name,
                to: directory,
                preserving: preserveFrom
            )
            writtenFiles.append(contentsOf: result.files.map(\.path))
            warnings = result.warnings
            baseSnapshot = output.snapshot

        case .none:
            break
        }

        let newKicadDigest = try digest(ofKiCadProjectAt: kicad)
        let newBundleDigest = try digest(ofBundleAt: bundle)
        let newState = KiCadCompanionState(
            kicadDigest: newKicadDigest,
            bundleDigest: newBundleDigest,
            syncedAt: ISO8601DateFormatter().string(from: now),
            direction: action.rawValue
        )
        try writeState(newState, to: bundle)
        if let baseSnapshot {
            try KiCadCompanionMerge.writeBase(
                KiCadCompanionBase(
                    syncedAt: newState.syncedAt,
                    snapshot: baseSnapshot
                ),
                to: bundle
            )
        }
        return KiCadSyncResult(
            direction: action.rawValue,
            kicadDigest: newKicadDigest,
            bundleDigest: newBundleDigest,
            writtenFiles: writtenFiles,
            state: newState,
            warnings: warnings
        )
    }

    /// Describes what a sync would do without writing anything.
    public static func plan(
        kicad: URL,
        bundle: URL,
        direction: KiCadSyncDirection = .auto,
        prefer: KiCadSyncPreference? = nil,
        force: Bool = false,
        now: Date = Date()
    ) throws -> KiCadSyncPlan {
        let decision = try resolveAction(
            kicad: kicad,
            bundle: bundle,
            direction: direction,
            prefer: prefer,
            force: force
        )
        let base = try KiCadCompanionMerge.readBase(from: bundle)

        guard let action = decision.action else {
            return KiCadSyncPlan(
                direction: "none",
                kicadChanged: decision.kicadChanged,
                bundleChanged: decision.bundleChanged,
                changes: [],
                conflicts: [],
                warnings: [],
                applicable: true
            )
        }

        switch action {
        case .importKiCad:
            let imported = try KiCadProjectInterchange.importProject(
                at: resolvedProjectURL(kicad),
                now: now
            )
            let snapshot = imported.activeDocument?.schematic ?? SchematicSnapshot()
            return KiCadSyncPlan(
                direction: action.rawValue,
                kicadChanged: decision.kicadChanged,
                bundleChanged: decision.bundleChanged,
                changes: KiCadCompanionMerge.diff(
                    from: base?.snapshot,
                    to: snapshot,
                    rootName: imported.manifest.name,
                    source: "kicad"
                ),
                conflicts: [],
                warnings: [],
                applicable: true
            )

        case .exportOhmLab:
            let bundleValue = try ProjectBundleStore.read(from: bundle)
            let snapshot = bundleValue.activeDocument?.schematic ?? SchematicSnapshot()
            return KiCadSyncPlan(
                direction: action.rawValue,
                kicadChanged: decision.kicadChanged,
                bundleChanged: decision.bundleChanged,
                changes: KiCadCompanionMerge.diff(
                    from: base?.snapshot,
                    to: snapshot,
                    rootName: bundleValue.manifest.name,
                    source: "ohmlab"
                ),
                conflicts: [],
                warnings: [],
                applicable: true
            )

        case .merge:
            guard let base else {
                return KiCadSyncPlan(
                    direction: "merge",
                    kicadChanged: decision.kicadChanged,
                    bundleChanged: decision.bundleChanged,
                    changes: [],
                    conflicts: [],
                    warnings: ["No merge base was recorded; rerun with --prefer kicad|ohmlab."],
                    applicable: false
                )
            }
            let bundleValue = try ProjectBundleStore.read(from: bundle)
            let imported = try KiCadProjectInterchange.importProject(
                at: resolvedProjectURL(kicad),
                now: now
            )
            let output = KiCadCompanionMerge.merge(
                base: base.snapshot,
                kicad: imported.activeDocument?.schematic ?? SchematicSnapshot(),
                bundle: bundleValue.activeDocument?.schematic ?? SchematicSnapshot(),
                rootName: bundleValue.manifest.name
            )
            return KiCadSyncPlan(
                direction: "merge",
                kicadChanged: decision.kicadChanged,
                bundleChanged: decision.bundleChanged,
                changes: output.changes,
                conflicts: output.conflicts,
                warnings: [],
                applicable: output.conflicts.isEmpty
            )

        case .none:
            return KiCadSyncPlan(
                direction: "none",
                kicadChanged: decision.kicadChanged,
                bundleChanged: decision.bundleChanged,
                changes: [],
                conflicts: [],
                warnings: [],
                applicable: true
            )
        }
    }

    private enum SyncAction: String {
        case importKiCad = "import"
        case exportOhmLab = "export"
        case merge
        case none
    }

    private struct SyncDecision {
        var action: SyncAction?
        var kicadDigest: String
        var bundleDigest: String
        var kicadChanged: Bool
        var bundleChanged: Bool
        var state: KiCadCompanionState?
    }

    private static func resolveAction(
        kicad: URL,
        bundle: URL,
        direction: KiCadSyncDirection,
        prefer: KiCadSyncPreference?,
        force: Bool
    ) throws -> SyncDecision {
        let fileManager = FileManager.default
        let kicadExists = fileManager.fileExists(atPath: kicad.path)
        let bundleExists = fileManager.fileExists(atPath: bundle.path)

        if !kicadExists && direction != .exportOhmLab {
            throw KiCadCompanionError.missingProject(kicad.lastPathComponent)
        }
        if !bundleExists && direction == .exportOhmLab {
            throw KiCadCompanionError.missingBundle(bundle.lastPathComponent)
        }

        let kicadDigest = kicadExists ? try digest(ofKiCadProjectAt: kicad) : ""
        let bundleDigest = bundleExists ? try digest(ofBundleAt: bundle) : ""
        let state = bundleExists ? try readState(from: bundle) : nil

        let kicadChanged: Bool
        let bundleChanged: Bool
        if let state {
            kicadChanged = kicadDigest != state.kicadDigest
            bundleChanged = bundleDigest != state.bundleDigest
        } else {
            kicadChanged = true
            bundleChanged = bundleExists
        }

        let action: SyncAction?
        switch direction {
        case .importKiCad:
            action = .importKiCad
        case .exportOhmLab:
            action = .exportOhmLab
        case .auto:
            if state == nil {
                if bundleExists {
                    throw KiCadCompanionError.directionRequired
                }
                action = .importKiCad
            } else if kicadChanged && bundleChanged {
                if let prefer {
                    action = prefer == .kicad ? .importKiCad : .exportOhmLab
                } else {
                    action = .merge
                }
            } else if kicadChanged {
                action = .importKiCad
            } else if bundleChanged {
                action = .exportOhmLab
            } else {
                action = nil
            }
        }

        // Conflict protection only applies once a baseline exists. Without
        // state, an explicit direction is the user's decision to overwrite.
        if state != nil {
            switch action {
            case .importKiCad:
                if bundleChanged && !force && prefer != .kicad {
                    throw KiCadCompanionError.conflictingChanges
                }
            case .exportOhmLab:
                if kicadChanged && !force && prefer != .ohmlab {
                    throw KiCadCompanionError.conflictingChanges
                }
            default:
                break
            }
        }

        return SyncDecision(
            action: action,
            kicadDigest: kicadDigest,
            bundleDigest: bundleDigest,
            kicadChanged: kicadChanged,
            bundleChanged: bundleChanged,
            state: state
        )
    }

    private static func apply(
        _ snapshot: SchematicSnapshot,
        to bundle: ProjectBundle,
        source: ProjectBundle
    ) throws -> ProjectBundle {
        guard let sheet = bundle.manifest.sheets.first(where: {
            $0.id == bundle.manifest.activeSheetID
        }) ?? bundle.manifest.sheets.first else {
            throw KiCadCompanionError.exportRequiresSchematic
        }
        guard var document = bundle.documents[sheet.id] else {
            throw KiCadCompanionError.exportRequiresSchematic
        }
        var merged = bundle
        document.schematic = snapshot
        document.usesSchematic = true
        merged.documents[sheet.id] = document
        if merged.manifest.kicadSource == nil {
            merged.manifest.kicadSource = source.manifest.kicadSource
        }
        return merged
    }

    // MARK: - State sidecar

    public static func readState(from bundle: URL) throws -> KiCadCompanionState? {
        let url = bundle.appendingPathComponent(KiCadCompanionManifest.stateFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else {
            throw KiCadCompanionError.invalidState("the sidecar could not be read")
        }
        guard let state = try? JSONDecoder().decode(KiCadCompanionState.self, from: data) else {
            throw KiCadCompanionError.invalidState("not valid companion JSON")
        }
        guard state.contractVersion <= KiCadCompanionState.currentContractVersion else {
            throw KiCadCompanionError.invalidState(
                "contract version \(state.contractVersion) is newer than \(KiCadCompanionState.currentContractVersion)"
            )
        }
        return state
    }

    public static func writeState(_ state: KiCadCompanionState, to bundle: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        let url = bundle.appendingPathComponent(KiCadCompanionManifest.stateFileName)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Helpers

    private static func merge(imported: ProjectBundle, intoExistingBundleAt bundle: URL) throws -> ProjectBundle {
        guard FileManager.default.fileExists(atPath: bundle.path),
              let existing = try? ProjectBundleStore.read(from: bundle) else {
            return imported
        }
        var merged = imported
        // Preserve the user's document analysis settings across a re-import.
        if let existingDocument = existing.activeDocument,
           let sheet = merged.manifest.sheets.first,
           var document = merged.documents[sheet.id] {
            document.analysis = existingDocument.analysis
            merged.documents[sheet.id] = document
        }
        // Imported metadata wins for keys it owns (such as "source"); every
        // other key survives the re-import.
        merged.manifest.metadata = existing.manifest.metadata
            .merging(merged.manifest.metadata) { _, importedValue in importedValue }
        return merged
    }

    private static func exportProjectName(bundle: ProjectBundle, kicad: URL) -> String {
        if let source = bundle.manifest.kicadSource?.projectPath
            ?? bundle.manifest.kicadSource?.topSchematic {
            let stem = URL(fileURLWithPath: source).deletingPathExtension().lastPathComponent
            if !stem.isEmpty { return stem }
        }
        if kicad.pathExtension.lowercased() == KiCadProjectInterchange.projectExtension
            || kicad.pathExtension.lowercased() == KiCadProjectInterchange.schematicExtension {
            let stem = kicad.deletingPathExtension().lastPathComponent
            if !stem.isEmpty { return stem }
        }
        return bundle.manifest.name
    }

    /// A directory may name a project by convention; resolve it to a concrete
    /// `.kicad_pro` (preferred) or `.kicad_sch` for import.
    private static func resolvedProjectURL(_ url: URL) -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return url
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let stem = url.lastPathComponent
        let projects = contents
            .filter { $0.pathExtension.lowercased() == KiCadProjectInterchange.projectExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let match = projects.first(where: {
            $0.deletingPathExtension().lastPathComponent == stem
        }) {
            return match
        }
        if let first = projects.first { return first }
        let schematics = contents
            .filter { $0.pathExtension.lowercased() == KiCadProjectInterchange.schematicExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let match = schematics.first(where: {
            $0.deletingPathExtension().lastPathComponent == stem
        }) {
            return match
        }
        return schematics.first ?? url
    }

    private static func projectDirectory(for url: URL) -> URL {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? url : url.deletingLastPathComponent()
        }
        // A missing path is a directory to create unless it names a project or
        // schematic file.
        let extensionName = url.pathExtension.lowercased()
        if extensionName == KiCadProjectInterchange.projectExtension
            || extensionName == KiCadProjectInterchange.schematicExtension {
            return url.deletingLastPathComponent()
        }
        return url
    }

    private static func relativePath(of url: URL, under base: URL) -> String {
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(basePath) else { return url.lastPathComponent }
        return String(path.dropFirst(basePath.count))
    }

    private static func appendDigestField(_ string: String, to data: inout Data) {
        data.append(Data(string.utf8))
        data.append(0)
    }

    private static func canonicalAnalysis(_ analysis: AnalysisSettings) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(analysis) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func canonicalNetlist(for document: CircuitFile) throws -> String {
        if document.usesSchematic == true {
            return try SpiceNetlistBuilder.export(
                snapshot: document.schematic,
                title: document.name,
                analysis: document.analysis,
                libraryTexts: (document.modelLibraries ?? []).map(\.text)
            )
        }
        return document.netlistText ?? ""
    }
}
