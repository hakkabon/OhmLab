// KiCadCompanionMerge.swift
// Three-way merge and change planning for the KiCad companion.
//
// A sync that finds changes on both sides used to stop and ask for
// `--prefer kicad|ohmlab`, which discards the other side's work wholesale.
// With a base snapshot recorded at the last successful sync we can do better:
// for each modelled object we know what the common ancestor looked like, so a
// change that exists on only one side is taken from that side, and only a
// genuine same-field collision is reported as a conflict.
//
// The base snapshot is stored beside the companion state as
// `.ohmlab-companion-base.json`. It contains OhmLab-modelled symbols and sheet
// structure only. KiCad-only objects (wires, junctions, graphics, unsupported
// symbols) are not merged because they never leave the KiCad drawing; the
// preserving writer keeps them verbatim.

import Foundation

/// The snapshot both sides agreed on at the last successful sync.
public struct KiCadCompanionBase: Codable, Equatable, Sendable {
    public static let currentContractVersion = 1
    public static let fileName = ".ohmlab-companion-base.json"

    public let contractVersion: Int
    public let syncedAt: String
    public let snapshot: SchematicSnapshot

    public init(
        contractVersion: Int = KiCadCompanionBase.currentContractVersion,
        syncedAt: String,
        snapshot: SchematicSnapshot
    ) {
        self.contractVersion = contractVersion
        self.syncedAt = syncedAt
        self.snapshot = snapshot
    }
}

/// Whether an object was added, changed, or removed relative to the base.
public enum KiCadChangeKind: String, Codable, Equatable, Sendable {
    case added
    case updated
    case removed
}

/// One planned object change, suitable for a human-readable dry run.
public struct KiCadObjectChange: Codable, Equatable, Sendable {
    /// The sheet's display name; the root sheet uses the project name.
    public let sheet: String
    /// `symbol` or `sheet`.
    public let kind: String
    /// Reference designator for a symbol, sheet name for a child sheet.
    public let identifier: String
    public let change: KiCadChangeKind
    /// Changed fields, such as `parameters.resistance` or `position`.
    public let fields: [String]
    /// `kicad`, `ohmlab`, or `both`.
    public let source: String
    public let uuid: UUID

    public init(
        sheet: String,
        kind: String,
        identifier: String,
        change: KiCadChangeKind,
        fields: [String],
        source: String,
        uuid: UUID
    ) {
        self.sheet = sheet
        self.kind = kind
        self.identifier = identifier
        self.change = change
        self.fields = fields
        self.source = source
        self.uuid = uuid
    }
}

/// A same-field collision that three-way merge cannot resolve.
public struct KiCadMergeConflict: Codable, Equatable, Sendable {
    public let sheet: String
    public let kind: String
    public let identifier: String
    public let field: String
    public let kicad: String
    public let ohmlab: String

    public init(
        sheet: String,
        kind: String,
        identifier: String,
        field: String,
        kicad: String,
        ohmlab: String
    ) {
        self.sheet = sheet
        self.kind = kind
        self.identifier = identifier
        self.field = field
        self.kicad = kicad
        self.ohmlab = ohmlab
    }

    public var description: String {
        "\(sheet) \(identifier) \(field): KiCad \(kicad), OhmLab \(ohmlab)"
    }
}

/// A non-mutating description of what a sync would do.
public struct KiCadSyncPlan: Codable, Equatable, Sendable {
    public let direction: String
    public let kicadChanged: Bool
    public let bundleChanged: Bool
    public let changes: [KiCadObjectChange]
    public let conflicts: [KiCadMergeConflict]
    public let warnings: [String]
    /// True when the plan can be applied without a preference or conflict
    /// resolution.
    public let applicable: Bool

    public init(
        direction: String,
        kicadChanged: Bool,
        bundleChanged: Bool,
        changes: [KiCadObjectChange],
        conflicts: [KiCadMergeConflict],
        warnings: [String],
        applicable: Bool
    ) {
        self.direction = direction
        self.kicadChanged = kicadChanged
        self.bundleChanged = bundleChanged
        self.changes = changes
        self.conflicts = conflicts
        self.warnings = warnings
        self.applicable = applicable
    }
}

/// Result of a three-way merge over one schematic snapshot.
struct KiCadMergeOutput {
    var snapshot: SchematicSnapshot
    var changes: [KiCadObjectChange]
    var conflicts: [KiCadMergeConflict]
}

enum KiCadCompanionMerge {
    // MARK: - Reading and writing the base

    static func readBase(from bundle: URL) throws -> KiCadCompanionBase? {
        let url = bundle.appendingPathComponent(KiCadCompanionBase.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else {
            throw KiCadCompanionError.invalidState("the merge base could not be read")
        }
        guard let base = try? JSONDecoder().decode(KiCadCompanionBase.self, from: data) else {
            throw KiCadCompanionError.invalidState("the merge base is not valid companion JSON")
        }
        guard base.contractVersion <= KiCadCompanionBase.currentContractVersion else {
            throw KiCadCompanionError.invalidState(
                "merge base contract version \(base.contractVersion) is newer than \(KiCadCompanionBase.currentContractVersion)"
            )
        }
        return base
    }

    static func writeBase(_ base: KiCadCompanionBase, to bundle: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(base)
        let url = bundle.appendingPathComponent(KiCadCompanionBase.fileName)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - One-sided diff

    /// Changes from `base` to `current`, attributed to `source`.
    static func diff(
        from base: SchematicSnapshot?,
        to current: SchematicSnapshot,
        rootName: String,
        source: String
    ) -> [KiCadObjectChange] {
        let base = base ?? SchematicSnapshot()
        var changes: [KiCadObjectChange] = []

        changes.append(contentsOf: symbolChanges(
            base: base.symbols,
            current: current.symbols,
            sheet: rootName,
            source: source
        ))

        let baseSheets = Dictionary(
            base.sheets.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let currentSheets = Dictionary(
            current.sheets.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for sheet in current.sheets {
            guard let previous = baseSheets[sheet.id] else {
                changes.append(KiCadObjectChange(
                    sheet: sheet.name,
                    kind: "sheet",
                    identifier: sheet.name,
                    change: .added,
                    fields: [],
                    source: source,
                    uuid: sheet.id
                ))
                continue
            }
            var fields: [String] = []
            if previous.name != sheet.name { fields.append("name") }
            if previous.ports != sheet.ports { fields.append("ports") }
            if !fields.isEmpty {
                changes.append(KiCadObjectChange(
                    sheet: sheet.name,
                    kind: "sheet",
                    identifier: sheet.name,
                    change: .updated,
                    fields: fields,
                    source: source,
                    uuid: sheet.id
                ))
            }
            changes.append(contentsOf: symbolChanges(
                base: previous.symbols,
                current: sheet.symbols,
                sheet: sheet.name,
                source: source
            ))
        }
        for sheet in base.sheets where currentSheets[sheet.id] == nil {
            changes.append(KiCadObjectChange(
                sheet: sheet.name,
                kind: "sheet",
                identifier: sheet.name,
                change: .removed,
                fields: [],
                source: source,
                uuid: sheet.id
            ))
        }
        return changes.sorted(by: changeOrder)
    }

    private static func symbolChanges(
        base: [SymbolInstance],
        current: [SymbolInstance],
        sheet: String,
        source: String
    ) -> [KiCadObjectChange] {
        let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentByID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changes: [KiCadObjectChange] = []

        for symbol in current {
            guard let previous = baseByID[symbol.id] else {
                changes.append(KiCadObjectChange(
                    sheet: sheet,
                    kind: "symbol",
                    identifier: symbol.refDes,
                    change: .added,
                    fields: [],
                    source: source,
                    uuid: symbol.id
                ))
                continue
            }
            let fields = changedSymbolFields(previous, symbol)
            if !fields.isEmpty {
                changes.append(KiCadObjectChange(
                    sheet: sheet,
                    kind: "symbol",
                    identifier: symbol.refDes,
                    change: .updated,
                    fields: fields,
                    source: source,
                    uuid: symbol.id
                ))
            }
        }
        for symbol in base where currentByID[symbol.id] == nil {
            changes.append(KiCadObjectChange(
                sheet: sheet,
                kind: "symbol",
                identifier: symbol.refDes,
                change: .removed,
                fields: [],
                source: source,
                uuid: symbol.id
            ))
        }
        return changes
    }

    static func changedSymbolFields(
        _ base: SymbolInstance,
        _ current: SymbolInstance
    ) -> [String] {
        var fields: [String] = []
        if base.descriptorId != current.descriptorId { fields.append("descriptorId") }
        if base.refDes != current.refDes { fields.append("refDes") }
        if base.position != current.position { fields.append("position") }
        if base.rotation != current.rotation { fields.append("rotation") }
        if base.sheetRef != current.sheetRef { fields.append("sheetRef") }
        let keys = Set(base.parameters.keys).union(current.parameters.keys)
        for key in keys.sorted() where base.parameters[key] != current.parameters[key] {
            fields.append("parameters.\(key)")
        }
        return fields
    }

    // MARK: - Three-way merge

    static func merge(
        base: SchematicSnapshot,
        kicad: SchematicSnapshot,
        bundle: SchematicSnapshot,
        rootName: String
    ) -> KiCadMergeOutput {
        var conflicts: [KiCadMergeConflict] = []
        var changes: [KiCadObjectChange] = []

        let mergedSymbols = mergeSymbols(
            base: base.symbols,
            kicad: kicad.symbols,
            bundle: bundle.symbols,
            sheet: rootName,
            changes: &changes,
            conflicts: &conflicts
        )

        let baseSheets = Dictionary(base.sheets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kicadSheets = Dictionary(kicad.sheets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let bundleSheets = Dictionary(bundle.sheets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sheetIDs = orderedSheetIDs(base: base.sheets, kicad: kicad.sheets, bundle: bundle.sheets)

        var mergedSheets: [Sheet] = []
        for id in sheetIDs {
            let b = baseSheets[id]
            let k = kicadSheets[id]
            let o = bundleSheets[id]
            switch (b, k, o) {
            case (nil, nil, nil):
                continue

            case (nil, let k?, nil):
                mergedSheets.append(k)
                changes.append(sheetChange(k, .added, source: "kicad"))
            case (nil, nil, let o?):
                mergedSheets.append(o)
                changes.append(sheetChange(o, .added, source: "ohmlab"))
            case (nil, let k?, let o?):
                if k == o {
                    mergedSheets.append(k)
                    changes.append(sheetChange(k, .added, source: "both"))
                } else {
                    mergedSheets.append(o)
                    conflicts.append(KiCadMergeConflict(
                        sheet: o.name,
                        kind: "sheet",
                        identifier: o.name,
                        field: "sheet",
                        kicad: "added",
                        ohmlab: "added differently"
                    ))
                    changes.append(sheetChange(o, .added, source: "both"))
                }

            case (let b?, nil, nil):
                changes.append(sheetChange(b, .removed, source: "both"))
            case (let b?, nil, let o?):
                if o == b {
                    changes.append(sheetChange(b, .removed, source: "kicad"))
                } else {
                    mergedSheets.append(o)
                    conflicts.append(KiCadMergeConflict(
                        sheet: o.name,
                        kind: "sheet",
                        identifier: o.name,
                        field: "sheet",
                        kicad: "removed",
                        ohmlab: "modified"
                    ))
                }
            case (let b?, let k?, nil):
                if k == b {
                    changes.append(sheetChange(b, .removed, source: "ohmlab"))
                } else {
                    mergedSheets.append(k)
                    conflicts.append(KiCadMergeConflict(
                        sheet: k.name,
                        kind: "sheet",
                        identifier: k.name,
                        field: "sheet",
                        kicad: "modified",
                        ohmlab: "removed"
                    ))
                }

            case (let b?, let k?, let o?):
                var merged = o
                var fields: [String] = []
                let name = resolve(b.name, k.name, o.name)
                if name.conflict {
                    conflicts.append(KiCadMergeConflict(
                        sheet: o.name,
                        kind: "sheet",
                        identifier: o.name,
                        field: "name",
                        kicad: k.name,
                        ohmlab: o.name
                    ))
                }
                merged.name = name.value
                if merged.name != b.name { fields.append("name") }

                let ports = resolve(b.ports, k.ports, o.ports)
                if ports.conflict {
                    conflicts.append(KiCadMergeConflict(
                        sheet: o.name,
                        kind: "sheet",
                        identifier: o.name,
                        field: "ports",
                        kicad: "\(k.ports.count) port(s)",
                        ohmlab: "\(o.ports.count) port(s)"
                    ))
                }
                merged.ports = ports.value
                if merged.ports != b.ports { fields.append("ports") }

                merged.symbols = mergeSymbols(
                    base: b.symbols,
                    kicad: k.symbols,
                    bundle: o.symbols,
                    sheet: merged.name,
                    changes: &changes,
                    conflicts: &conflicts
                )
                merged.wires = o.wires
                merged.netLabels = o.netLabels
                mergedSheets.append(merged)
                if !fields.isEmpty {
                    changes.append(KiCadObjectChange(
                        sheet: merged.name,
                        kind: "sheet",
                        identifier: merged.name,
                        change: .updated,
                        fields: fields,
                        source: "both",
                        uuid: merged.id
                    ))
                }
            }
        }

        let merged = SchematicSnapshot(
            schemaVersion: max(base.schemaVersion, kicad.schemaVersion, bundle.schemaVersion),
            symbols: mergedSymbols,
            wires: bundle.wires,
            netLabels: bundle.netLabels,
            sheets: mergedSheets
        )
        return KiCadMergeOutput(
            snapshot: merged,
            changes: changes.sorted(by: changeOrder),
            conflicts: conflicts.sorted { $0.description < $1.description }
        )
    }

    private static func mergeSymbols(
        base: [SymbolInstance],
        kicad: [SymbolInstance],
        bundle: [SymbolInstance],
        sheet: String,
        changes: inout [KiCadObjectChange],
        conflicts: inout [KiCadMergeConflict]
    ) -> [SymbolInstance] {
        let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kicadByID = Dictionary(kicad.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let bundleByID = Dictionary(bundle.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = orderedIDs(base, kicad, bundle)

        var mergedByID: [UUID: SymbolInstance] = [:]
        var additions: [UUID: String] = [:]

        for id in ids {
            let b = baseByID[id]
            let k = kicadByID[id]
            let o = bundleByID[id]
            switch (b, k, o) {
            case (nil, nil, nil):
                continue

            case (nil, let k?, nil):
                mergedByID[id] = k
                additions[id] = "kicad"
                changes.append(symbolChange(k, sheet: sheet, .added, fields: [], source: "kicad"))
            case (nil, nil, let o?):
                mergedByID[id] = o
                additions[id] = "ohmlab"
                changes.append(symbolChange(o, sheet: sheet, .added, fields: [], source: "ohmlab"))
            case (nil, let k?, let o?):
                if k == o {
                    mergedByID[id] = k
                    additions[id] = "both"
                    changes.append(symbolChange(k, sheet: sheet, .added, fields: [], source: "both"))
                } else {
                    mergedByID[id] = o
                    additions[id] = "both"
                    conflicts.append(KiCadMergeConflict(
                        sheet: sheet,
                        kind: "symbol",
                        identifier: o.refDes,
                        field: "symbol",
                        kicad: "added differently",
                        ohmlab: "added differently"
                    ))
                }

            case (let b?, nil, nil):
                changes.append(symbolChange(b, sheet: sheet, .removed, fields: [], source: "both"))
            case (let b?, nil, let o?):
                if o == b {
                    changes.append(symbolChange(b, sheet: sheet, .removed, fields: [], source: "kicad"))
                } else {
                    mergedByID[id] = o
                    conflicts.append(KiCadMergeConflict(
                        sheet: sheet,
                        kind: "symbol",
                        identifier: o.refDes,
                        field: "symbol",
                        kicad: "removed",
                        ohmlab: "modified"
                    ))
                }
            case (let b?, let k?, nil):
                if k == b {
                    changes.append(symbolChange(b, sheet: sheet, .removed, fields: [], source: "ohmlab"))
                } else {
                    mergedByID[id] = k
                    conflicts.append(KiCadMergeConflict(
                        sheet: sheet,
                        kind: "symbol",
                        identifier: k.refDes,
                        field: "symbol",
                        kicad: "modified",
                        ohmlab: "removed"
                    ))
                }

            case (let b?, let k?, let o?):
                let (merged, fields, failures) = mergeSymbol(
                    base: b,
                    kicad: k,
                    bundle: o,
                    sheet: sheet
                )
                mergedByID[id] = merged
                conflicts.append(contentsOf: failures)
                if !fields.isEmpty {
                    let source = k == b ? "ohmlab" : (o == b ? "kicad" : "both")
                    changes.append(symbolChange(
                        merged,
                        sheet: sheet,
                        .updated,
                        fields: fields,
                        source: source
                    ))
                }
            }
        }

        // Keep the bundle's order for symbols it owns, then append additions
        // from KiCad in KiCad's order so repeated plans are deterministic.
        var ordered: [SymbolInstance] = []
        var emitted: Set<UUID> = []
        for symbol in bundle {
            guard let merged = mergedByID[symbol.id], emitted.insert(symbol.id).inserted else { continue }
            ordered.append(merged)
        }
        for symbol in kicad where emitted.insert(symbol.id).inserted {
            if let merged = mergedByID[symbol.id] { ordered.append(merged) }
        }
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString })
        where emitted.insert(id).inserted {
            if let merged = mergedByID[id] { ordered.append(merged) }
        }
        return ordered
    }

    private static func mergeSymbol(
        base: SymbolInstance,
        kicad: SymbolInstance,
        bundle: SymbolInstance,
        sheet: String
    ) -> (SymbolInstance, [String], [KiCadMergeConflict]) {
        var merged = bundle
        var fields: [String] = []
        var conflicts: [KiCadMergeConflict] = []

        func scalar<T: Equatable>(
            _ field: String,
            _ baseValue: T,
            _ kicadValue: T,
            _ bundleValue: T
        ) -> T {
            let resolved = resolve(baseValue, kicadValue, bundleValue)
            if resolved.conflict {
                conflicts.append(KiCadMergeConflict(
                    sheet: sheet,
                    kind: "symbol",
                    identifier: bundle.refDes,
                    field: field,
                    kicad: String(describing: kicadValue),
                    ohmlab: String(describing: bundleValue)
                ))
            }
            if resolved.value != baseValue { fields.append(field) }
            return resolved.value
        }

        merged.descriptorId = scalar("descriptorId", base.descriptorId, kicad.descriptorId, bundle.descriptorId)
        merged.refDes = scalar("refDes", base.refDes, kicad.refDes, bundle.refDes)
        merged.position = scalar("position", base.position, kicad.position, bundle.position)
        merged.rotation = scalar("rotation", base.rotation, kicad.rotation, bundle.rotation)
        merged.sheetRef = scalar("sheetRef", base.sheetRef, kicad.sheetRef, bundle.sheetRef)

        let keys = Set(base.parameters.keys)
            .union(kicad.parameters.keys)
            .union(bundle.parameters.keys)
        for key in keys.sorted() {
            let resolved = resolve(
                base.parameters[key],
                kicad.parameters[key],
                bundle.parameters[key]
            )
            if resolved.conflict {
                conflicts.append(KiCadMergeConflict(
                    sheet: sheet,
                    kind: "symbol",
                    identifier: merged.refDes,
                    field: "parameters.\(key)",
                    kicad: format(kicad.parameters[key]),
                    ohmlab: format(bundle.parameters[key])
                ))
            }
            if resolved.value != base.parameters[key] {
                merged.parameters[key] = resolved.value
                fields.append("parameters.\(key)")
            }
        }

        return (merged, fields, conflicts)
    }

    private static func resolve<T: Equatable>(_ base: T, _ kicad: T, _ bundle: T) -> (value: T, conflict: Bool) {
        if kicad == bundle { return (kicad, false) }
        if kicad == base { return (bundle, false) }
        if bundle == base { return (kicad, false) }
        return (bundle, true)
    }

    private static func format(_ value: Double?) -> String {
        guard let value else { return "removed" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(value)
    }

    private static func symbolChange(
        _ symbol: SymbolInstance,
        sheet: String,
        _ change: KiCadChangeKind,
        fields: [String],
        source: String
    ) -> KiCadObjectChange {
        KiCadObjectChange(
            sheet: sheet,
            kind: "symbol",
            identifier: symbol.refDes,
            change: change,
            fields: fields,
            source: source,
            uuid: symbol.id
        )
    }

    private static func sheetChange(
        _ sheet: Sheet,
        _ change: KiCadChangeKind,
        source: String
    ) -> KiCadObjectChange {
        KiCadObjectChange(
            sheet: sheet.name,
            kind: "sheet",
            identifier: sheet.name,
            change: change,
            fields: [],
            source: source,
            uuid: sheet.id
        )
    }

    /// Stable ordering: base first, then KiCad additions, then bundle additions.
    private static func orderedIDs(
        _ base: [SymbolInstance],
        _ kicad: [SymbolInstance],
        _ bundle: [SymbolInstance]
    ) -> [UUID] {
        var ids: [UUID] = []
        var seen: Set<UUID> = []
        for id in base.map(\.id) + kicad.map(\.id) + bundle.map(\.id) where seen.insert(id).inserted {
            ids.append(id)
        }
        return ids
    }

    /// Child-sheet order follows the bundle (which controls page numbers),
    /// then KiCad additions, then sheets only the base knew about.
    private static func orderedSheetIDs(
        base: [Sheet],
        kicad: [Sheet],
        bundle: [Sheet]
    ) -> [UUID] {
        var ids: [UUID] = []
        var seen: Set<UUID> = []
        for id in bundle.map(\.id) + kicad.map(\.id) + base.map(\.id) where seen.insert(id).inserted {
            ids.append(id)
        }
        return ids
    }

    private static func changeOrder(_ lhs: KiCadObjectChange, _ rhs: KiCadObjectChange) -> Bool {
        if lhs.sheet != rhs.sheet { return lhs.sheet < rhs.sheet }
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        if lhs.identifier != rhs.identifier { return lhs.identifier < rhs.identifier }
        return lhs.change.rawValue < rhs.change.rawValue
    }
}
