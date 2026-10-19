import CoreGraphics
import Foundation
import SwiftUI

public struct GridPoint: Hashable, Codable, Sendable {
    public let x: Int
    public let y: Int
    public static let gridSize: CGFloat = 20.0

    public init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
    public init(_ p: CGPoint) {
        self.x = Int(round(p.x / GridPoint.gridSize))
        self.y = Int(round(p.y / GridPoint.gridSize))
    }
    public func toCGPoint() -> CGPoint {
        CGPoint(x: CGFloat(x) * GridPoint.gridSize, y: CGFloat(y) * GridPoint.gridSize)
    }
}

public struct PinRef: Hashable, Codable, Sendable {
    public let symbolId: UUID
    public let pinId: String

    public init(symbolId: UUID, pinId: String) {
        self.symbolId = symbolId
        self.pinId = pinId
    }
}

public struct Net: Identifiable, Equatable {
    public let id: Int
    public var name: String
    public var connectedPins: [PinRef]
    public var isGround: Bool = false
    /// True when the net has a user-supplied label.
    public var isLabeled: Bool = false
}

public struct SymbolInstance: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var descriptorId: String
    public var refDes: String
    public var position: GridPoint
    public var rotation: Int // 0, 90, 180, 270
    public var parameters: [String: Double]
    /// When set, this symbol instantiates the sheet with this ID (a subcircuit
    /// instance). Its pins are the referenced sheet's ports.
    public var sheetRef: UUID?

    public init(
        id: UUID = UUID(),
        descriptorId: String,
        refDes: String,
        position: GridPoint,
        rotation: Int = 0,
        parameters: [String: Double] = [:],
        sheetRef: UUID? = nil
    ) {
        self.id = id
        self.descriptorId = descriptorId
        self.refDes = refDes
        self.position = position
        self.rotation = rotation
        self.parameters = parameters
        self.sheetRef = sheetRef
    }

    /// True when this symbol is a subcircuit instance.
    public var isSubcircuitInstance: Bool { sheetRef != nil }
}

public struct WireSegment: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var points: [GridPoint]
    /// Bus wires bundle several member nets. They carry no single electrical
    /// connection of their own; members are bound by name (see `BusName`).
    public var isBus: Bool

    public init(id: UUID = UUID(), points: [GridPoint], isBus: Bool = false) {
        self.id = id; self.points = points; self.isBus = isBus
    }

    public var segments: [(GridPoint, GridPoint)] {
        Array(zip(points, points.dropFirst()))
    }
}

/// A parsed bus label. Declarations look like `DATA[7:0]`; member (bit-select)
/// labels look like `DATA[3]`. Plain labels parse to `nil`.
public struct BusName: Equatable, Sendable {
    public let base: String
    /// Present on declarations: the inclusive bit range (ascending).
    public let range: ClosedRange<Int>?
    /// Present on member labels: the single bit index.
    public let bit: Int?

    public static func parse(_ raw: String) -> BusName? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard name.hasSuffix("]"), let open = name.lastIndex(of: "[") else { return nil }
        let base = String(name[name.startIndex..<open])
        guard !base.isEmpty else { return nil }
        let inner = String(name[name.index(after: open)..<name.index(before: name.endIndex)])
        if let colon = inner.firstIndex(of: ":") {
            let lhs = String(inner[inner.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let rhs = String(inner[inner.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard let a = Int(lhs), let b = Int(rhs) else { return nil }
            return BusName(base: base, range: min(a, b)...max(a, b), bit: nil)
        }
        guard let bit = Int(inner.trimmingCharacters(in: .whitespaces)) else { return nil }
        return BusName(base: base, range: nil, bit: bit)
    }

    public var isDeclaration: Bool { range != nil }
    public var isBitSelect: Bool { bit != nil }

    /// The member labels (`DATA[0]`, `DATA[1]`, …) a declaration expands to.
    public var members: [String] {
        guard let range else { return [] }
        return range.map { "\(base)[\($0)]" }
    }

    public func member(_ index: Int) -> String { "\(base)[\(index)]" }
}

/// A named net label placed at a grid location. Labels give meaningful names to
/// nets (e.g. `IN`, `OUT`) and participate in connectivity at their position.
public struct NetLabel: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var position: GridPoint

    public init(id: UUID = UUID(), name: String, position: GridPoint) {
        self.id = id
        self.name = name
        self.position = position
    }

    /// The parsed bus form of this label, if any.
    public var busName: BusName? { BusName.parse(name) }
    public var isBus: Bool { busName != nil }
    public var isBusDeclaration: Bool { busName?.isDeclaration ?? false }
    public var isBitSelect: Bool { busName?.isBitSelect ?? false }
}

/// A port exposed by a sheet. Ports bind to the same-named net (a net label)
/// inside the sheet, and become pins on a subcircuit instance that uses it.
public struct SheetPort: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    /// Direction hint only; affects where the pin is drawn on the instance box.
    public var isInput: Bool

    public init(id: UUID = UUID(), name: String, isInput: Bool = true) {
        self.id = id
        self.name = name
        self.isInput = isInput
    }
}

/// A drawable sheet in the hierarchy. The root sheet is stored separately (as
/// the top-level symbols/wires/labels of a `SchematicSnapshot`); child sheets
/// live in `SchematicSnapshot.sheets`. A sheet may itself contain subcircuit
/// instances of other sheets, forming a hierarchy.
public struct Sheet: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var ports: [SheetPort]
    public var symbols: [SymbolInstance]
    public var wires: [WireSegment]
    public var netLabels: [NetLabel]

    public init(
        id: UUID = UUID(),
        name: String,
        ports: [SheetPort] = [],
        symbols: [SymbolInstance] = [],
        wires: [WireSegment] = [],
        netLabels: [NetLabel] = []
    ) {
        self.id = id
        self.name = name
        self.ports = ports
        self.symbols = symbols
        self.wires = wires
        self.netLabels = netLabels
    }

    public var portNames: [String] { ports.map(\.name) }
}

/// The persistable geometry of a schematic. Connectivity is always derived.
public struct SchematicSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var symbols: [SymbolInstance]
    public var wires: [WireSegment]
    public var netLabels: [NetLabel]
    /// Child sheets referenced by subcircuit instances (v2 and later).
    public var sheets: [Sheet]

    public static let currentSchemaVersion = 2

    public init(
        schemaVersion: Int = SchematicSnapshot.currentSchemaVersion,
        symbols: [SymbolInstance] = [],
        wires: [WireSegment] = [],
        netLabels: [NetLabel] = [],
        sheets: [Sheet] = []
    ) {
        self.schemaVersion = schemaVersion
        self.symbols = symbols
        self.wires = wires
        self.netLabels = netLabels
        self.sheets = sheets
    }
}

@MainActor
public class SchematicDocument: ObservableObject {
    /// The active sheet's content. Always mirrors `sheets[activeSheetIndex]`.
    @Published public private(set) var symbols: [SymbolInstance] = []
    @Published public private(set) var wires: [WireSegment] = []
    @Published public private(set) var netLabels: [NetLabel] = []
    @Published public private(set) var nets: [Net] = []

    /// Every sheet in the hierarchy; index 0 is the root (top-level) sheet.
    @Published public private(set) var sheets: [Sheet] = []
    @Published public private(set) var activeSheetId: UUID = UUID()

    @Published public var selectedSymbolID: UUID?
    @Published public var selectedWireID: UUID?
    @Published public var selectedLabelID: UUID?

    @Published public private(set) var canUndo = false
    @Published public private(set) var canRedo = false

    /// Monotonic counter bumped only when the persistable content changes.
    /// Observers (like the simulation document) subscribe to this instead of
    /// `objectWillChange`, so selecting or rotating the selection highlight does
    /// not dirty the document or discard results.
    @Published public private(set) var contentVersion = 0

    private var undoStack: [HistoryEntry] = []
    private var redoStack: [HistoryEntry] = []
    private let undoLimit = 100

    private struct HistoryEntry {
        var snapshot: SchematicSnapshot
        var activeSheetId: UUID
        var selectedSymbolID: UUID?
        var selectedWireID: UUID?
        var selectedLabelID: UUID?
    }

    public init() {
        let root = Sheet(name: "Main")
        sheets = [root]
        activeSheetId = root.id
        self.rebuildConnectivity()
    }

    // MARK: - Sheets / hierarchy

    public var activeSheetIndex: Int {
        sheets.firstIndex { $0.id == activeSheetId } ?? 0
    }

    public var activeSheet: Sheet { sheets[activeSheetIndex] }

    public var isAtRoot: Bool { activeSheetIndex == 0 }

    public func sheet(id: UUID) -> Sheet? { sheets.first { $0.id == id } }

    /// The breadcrumb from the root sheet down to the active sheet, following
    /// subcircuit instances in the current sheet stack.
    public var hierarchyPath: [Sheet] {
        var path: [Sheet] = []
        var visited: Set<UUID> = []
        var current = activeSheetId
        while let sheet = sheet(id: current), !visited.contains(sheet.id) {
            path.insert(sheet, at: 0)
            visited.insert(sheet.id)
            guard let parent = sheets.first(where: { candidate in
                candidate.symbols.contains { $0.sheetRef == sheet.id }
            }) else { break }
            current = parent.id
        }
        return path
    }

    /// Saves the active sheet's live content back into `sheets` and loads the
    /// requested sheet into the published properties.
    public func enterSheet(id: UUID) {
        guard sheet(id: id) != nil, id != activeSheetId else { return }
        syncActiveSheet()
        activeSheetId = id
        loadActiveSheet()
        markContentChanged()
    }

    public func goToRoot() {
        guard let root = sheets.first else { return }
        enterSheet(id: root.id)
    }

    public func goToParentSheet() {
        guard let parent = sheets.first(where: { candidate in
            candidate.symbols.contains { $0.sheetRef == activeSheetId }
        }) else { return }
        enterSheet(id: parent.id)
    }

    private func syncActiveSheet() {
        guard let index = sheets.firstIndex(where: { $0.id == activeSheetId }) else { return }
        sheets[index].symbols = symbols
        sheets[index].wires = wires
        sheets[index].netLabels = netLabels
    }

    private func loadActiveSheet() {
        guard let sheet = sheet(id: activeSheetId) else { return }
        symbols = sheet.symbols
        wires = sheet.wires
        netLabels = sheet.netLabels
        selectedSymbolID = nil
        selectedWireID = nil
        selectedLabelID = nil
    }

    /// Creates a new child sheet and returns it.
    @discardableResult
    public func addSheet(named name: String? = nil) -> Sheet {
        checkpoint()
        let resolved = name?.isEmpty == false ? name! : nextSheetName()
        let sheet = Sheet(name: resolved)
        sheets.append(sheet)
        markContentChanged()
        return sheet
    }

    private func nextSheetName() -> String {
        var index = sheets.count
        let existing = Set(sheets.map { $0.name.uppercased() })
        var name = "SUBCKT\(index)"
        while existing.contains(name.uppercased()) {
            index += 1
            name = "SUBCKT\(index)"
        }
        return name
    }

    public func renameSheet(id: UUID, to name: String) {
        guard let index = sheets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, sheets[index].name != trimmed else { return }
        checkpoint()
        sheets[index].name = trimmed
        markContentChanged()
    }

    public func deleteSheet(id: UUID) {
        guard sheets.count > 1, let index = sheets.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        sheets.remove(at: index)
        // Remove instances that referenced the deleted sheet, on every sheet.
        for sheetIndex in sheets.indices {
            let removed = sheets[sheetIndex].symbols.filter { $0.sheetRef == id }.map(\.id)
            sheets[sheetIndex].symbols.removeAll { $0.sheetRef == id }
            if activeSheetIndex == sheetIndex, let selected = selectedSymbolID, removed.contains(selected) {
                selectedSymbolID = nil
            }
        }
        if id == activeSheetId { activeSheetId = sheets[0].id }
        loadActiveSheet()
        markContentChanged()
    }

    // MARK: - Subcircuit instances

    /// Places an instance of `sheetId` at `position` on the active sheet.
    @discardableResult
    public func addSubcircuitInstance(sheetId: UUID, at position: GridPoint) -> SymbolInstance? {
        guard let sheet = sheet(id: sheetId) else { return nil }
        let existingReferences = Set(symbols.map { $0.refDes.uppercased() })
        var suffix = 1
        while existingReferences.contains("X\(suffix)".uppercased()) { suffix += 1 }
        let symbol = SymbolInstance(
            descriptorId: SubcircuitInstance.descriptorId,
            refDes: "X\(suffix)",
            position: position,
            sheetRef: sheetId
        )
        _ = sheet
        addSymbol(symbol)
        return symbol
    }

    // MARK: - Sheet ports

    public func addSheetPort(sheetId: UUID, name: String, isInput: Bool = true) {
        guard let index = sheets.firstIndex(where: { $0.id == sheetId }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !sheets[index].ports.contains(where: { $0.name == trimmed }) else { return }
        checkpoint()
        sheets[index].ports.append(SheetPort(name: trimmed, isInput: isInput))
        markContentChanged()
    }

    public func removeSheetPort(sheetId: UUID, portId: UUID) {
        guard let index = sheets.firstIndex(where: { $0.id == sheetId }) else { return }
        checkpoint()
        sheets[index].ports.removeAll { $0.id == portId }
        markContentChanged()
    }

    public func renameSheetPort(sheetId: UUID, portId: UUID, to name: String) {
        guard let index = sheets.firstIndex(where: { $0.id == sheetId }),
              let portIndex = sheets[index].ports.firstIndex(where: { $0.id == portId }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, sheets[index].ports[portIndex].name != trimmed else { return }
        checkpoint()
        sheets[index].ports[portIndex].name = trimmed
        markContentChanged()
    }

    public func setSheetPortInput(sheetId: UUID, portId: UUID, isInput: Bool) {
        guard let index = sheets.firstIndex(where: { $0.id == sheetId }),
              let portIndex = sheets[index].ports.firstIndex(where: { $0.id == portId }) else { return }
        guard sheets[index].ports[portIndex].isInput != isInput else { return }
        checkpoint()
        sheets[index].ports[portIndex].isInput = isInput
        markContentChanged()
    }

    // MARK: - Snapshots

    public func snapshot() -> SchematicSnapshot {
        syncActiveSheet()
        let root = sheets.first ?? Sheet(name: "Main")
        return SchematicSnapshot(
            symbols: root.symbols,
            wires: root.wires,
            netLabels: root.netLabels,
            sheets: Array(sheets.dropFirst())
        )
    }

    public func replaceContents(with snapshot: SchematicSnapshot) {
        let root = Sheet(
            name: "Main",
            symbols: snapshot.symbols,
            wires: snapshot.wires,
            netLabels: snapshot.netLabels
        )
        sheets = [root] + snapshot.sheets
        activeSheetId = root.id
        symbols = root.symbols
        wires = root.wires
        netLabels = root.netLabels
        selectedSymbolID = nil
        selectedWireID = nil
        selectedLabelID = nil
        undoStack.removeAll()
        redoStack.removeAll()
        updateUndoAvailability()
        markContentChanged()
    }

    // MARK: - Undo / redo

    /// Record the current document state so the next mutation can be undone.
    /// Call before a structural change or once at the start of a drag gesture.
    public func checkpoint() {
        undoStack.append(currentHistoryEntry())
        if undoStack.count > undoLimit {
            undoStack.removeFirst(undoStack.count - undoLimit)
        }
        redoStack.removeAll()
        updateUndoAvailability()
    }

    public func undo() {
        guard let entry = undoStack.popLast() else { return }
        redoStack.append(currentHistoryEntry())
        apply(entry)
        updateUndoAvailability()
    }

    public func redo() {
        guard let entry = redoStack.popLast() else { return }
        undoStack.append(currentHistoryEntry())
        apply(entry)
        updateUndoAvailability()
    }

    private func currentHistoryEntry() -> HistoryEntry {
        HistoryEntry(
            snapshot: snapshot(),
            activeSheetId: activeSheetId,
            selectedSymbolID: selectedSymbolID,
            selectedWireID: selectedWireID,
            selectedLabelID: selectedLabelID
        )
    }

    private func apply(_ entry: HistoryEntry) {
        let root = Sheet(
            name: "Main",
            symbols: entry.snapshot.symbols,
            wires: entry.snapshot.wires,
            netLabels: entry.snapshot.netLabels
        )
        sheets = [root] + entry.snapshot.sheets
        activeSheetId = sheets.contains(where: { $0.id == entry.activeSheetId })
            ? entry.activeSheetId
            : root.id
        loadActiveSheet()
        selectedSymbolID = entry.selectedSymbolID
        selectedWireID = entry.selectedWireID
        selectedLabelID = entry.selectedLabelID
        markContentChanged()
    }

    private func updateUndoAvailability() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: - Symbol editing

    public func addSymbol(_ symbol: SymbolInstance, recordUndo: Bool = true) {
        if recordUndo { checkpoint() }
        symbols.append(symbol)
        selectedSymbolID = symbol.id
        selectedWireID = nil
        selectedLabelID = nil
        markContentChanged()
    }

    @discardableResult
    public func addComponent(descriptorId: String, at position: GridPoint) -> SymbolInstance? {
        guard let descriptor = ComponentRegistry.shared.descriptor(for: descriptorId) else {
            return nil
        }
        let existingReferences = Set(symbols.map { $0.refDes.uppercased() })
        var suffix = 1
        while existingReferences.contains("\(descriptor.prefix)\(suffix)".uppercased()) {
            suffix += 1
        }
        let refDes = "\(descriptor.prefix)\(suffix)"
        let symbol = SymbolInstance(
            descriptorId: descriptorId,
            refDes: refDes,
            position: position,
            parameters: descriptor.defaultParameterValues
        )
        addSymbol(symbol)
        return symbol
    }

    public func moveSymbol(id: UUID, to position: GridPoint, recordUndo: Bool = false) {
        guard let index = symbols.firstIndex(where: { $0.id == id }) else { return }
        guard symbols[index].position != position else { return }
        if recordUndo { checkpoint() }
        symbols[index].position = position
        markContentChanged()
    }

    public func rotateSymbol(id: UUID, by degrees: Int) {
        guard let index = symbols.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        symbols[index].rotation = (((symbols[index].rotation + degrees) % 360) + 360) % 360
        markContentChanged()
    }

    public func setRotation(id: UUID, to degrees: Int) {
        guard let index = symbols.firstIndex(where: { $0.id == id }) else { return }
        let normalized = ((degrees % 360) + 360) % 360
        guard symbols[index].rotation != normalized else { return }
        checkpoint()
        symbols[index].rotation = normalized
        markContentChanged()
    }

    public func deleteSymbol(id: UUID) {
        guard let index = symbols.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        symbols.remove(at: index)
        if selectedSymbolID == id { selectedSymbolID = nil }
        markContentChanged()
    }

    public func setReference(id: UUID, to reference: String) {
        guard let index = symbols.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        guard symbols[index].refDes != trimmed else { return }
        checkpoint()
        symbols[index].refDes = trimmed
        markContentChanged()
    }

    public func setParameter(id: UUID, key: String, value: Double) {
        guard let index = symbols.firstIndex(where: { $0.id == id }) else { return }
        guard symbols[index].parameters[key] != value else { return }
        checkpoint()
        symbols[index].parameters[key] = value
    }

    // MARK: - Wire editing

    public func addWire(_ wire: WireSegment) {
        checkpoint()
        wires.append(wire)
        markContentChanged()
    }

    public func deleteWire(id: UUID) {
        guard let index = wires.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        wires.remove(at: index)
        if selectedWireID == id { selectedWireID = nil }
        markContentChanged()
    }

    // MARK: - Net labels

    public func addNetLabel(name: String, at position: GridPoint) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        checkpoint()
        netLabels.append(NetLabel(name: trimmed.uppercased(), position: position))
        markContentChanged()
    }

    public func renameNetLabel(id: UUID, to name: String) {
        guard let index = netLabels.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces).uppercased()
        guard !trimmed.isEmpty, netLabels[index].name != trimmed else { return }
        checkpoint()
        netLabels[index].name = trimmed
        markContentChanged()
    }

    public func deleteNetLabel(id: UUID) {
        guard let index = netLabels.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        netLabels.remove(at: index)
        if selectedLabelID == id { selectedLabelID = nil }
        markContentChanged()
    }

    // MARK: - Connectivity

    /// Bump the content version and re-derive connectivity. Content mutations go
    /// through here; selection-only changes deliberately do not.
    private func markContentChanged() {
        contentVersion &+= 1
        syncActiveSheet()
        rebuildConnectivity()
    }

    /// Resolves subcircuit-instance descriptors from the sheet hierarchy.
    public var subcircuitCatalog: SubcircuitCatalog {
        SubcircuitCatalog(sheets: sheets)
    }

    public func rebuildConnectivity() {
        self.nets = ConnectivityBuilder.build(
            symbols: symbols,
            wires: wires,
            labels: netLabels,
            catalog: subcircuitCatalog
        )
    }

    public func deleteSelection() {
        if let id = selectedSymbolID {
            deleteSymbol(id: id)
        } else if let id = selectedWireID {
            deleteWire(id: id)
        } else if let id = selectedLabelID {
            deleteNetLabel(id: id)
        }
    }
}
