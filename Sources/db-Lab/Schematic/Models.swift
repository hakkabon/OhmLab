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

    public init(
        id: UUID = UUID(),
        descriptorId: String,
        refDes: String,
        position: GridPoint,
        rotation: Int = 0,
        parameters: [String: Double] = [:]
    ) {
        self.id = id
        self.descriptorId = descriptorId
        self.refDes = refDes
        self.position = position
        self.rotation = rotation
        self.parameters = parameters
    }
}

public struct WireSegment: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var points: [GridPoint]

    public init(id: UUID = UUID(), points: [GridPoint]) {
        self.id = id; self.points = points
    }

    public var segments: [(GridPoint, GridPoint)] {
        Array(zip(points, points.dropFirst()))
    }
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
}

/// The persistable geometry of a schematic. Connectivity is always derived.
public struct SchematicSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var symbols: [SymbolInstance]
    public var wires: [WireSegment]
    public var netLabels: [NetLabel]

    public static let currentSchemaVersion = 1

    public init(
        schemaVersion: Int = SchematicSnapshot.currentSchemaVersion,
        symbols: [SymbolInstance] = [],
        wires: [WireSegment] = [],
        netLabels: [NetLabel] = []
    ) {
        self.schemaVersion = schemaVersion
        self.symbols = symbols
        self.wires = wires
        self.netLabels = netLabels
    }
}

@MainActor
public class SchematicDocument: ObservableObject {
    @Published public private(set) var symbols: [SymbolInstance] = []
    @Published public private(set) var wires: [WireSegment] = []
    @Published public private(set) var netLabels: [NetLabel] = []
    @Published public private(set) var nets: [Net] = []

    @Published public var selectedSymbolID: UUID?
    @Published public var selectedWireID: UUID?
    @Published public var selectedLabelID: UUID?

    @Published public private(set) var canUndo = false
    @Published public private(set) var canRedo = false

    private var undoStack: [HistoryEntry] = []
    private var redoStack: [HistoryEntry] = []
    private let undoLimit = 100

    private struct HistoryEntry {
        var snapshot: SchematicSnapshot
        var selectedSymbolID: UUID?
        var selectedWireID: UUID?
        var selectedLabelID: UUID?
    }

    public init() {}

    // MARK: - Snapshots

    public func snapshot() -> SchematicSnapshot {
        SchematicSnapshot(symbols: symbols, wires: wires, netLabels: netLabels)
    }

    public func replaceContents(with snapshot: SchematicSnapshot) {
        symbols = snapshot.symbols
        wires = snapshot.wires
        netLabels = snapshot.netLabels
        selectedSymbolID = nil
        selectedWireID = nil
        selectedLabelID = nil
        undoStack.removeAll()
        redoStack.removeAll()
        updateUndoAvailability()
        rebuildConnectivity()
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
            selectedSymbolID: selectedSymbolID,
            selectedWireID: selectedWireID,
            selectedLabelID: selectedLabelID
        )
    }

    private func apply(_ entry: HistoryEntry) {
        symbols = entry.snapshot.symbols
        wires = entry.snapshot.wires
        netLabels = entry.snapshot.netLabels
        selectedSymbolID = entry.selectedSymbolID
        selectedWireID = entry.selectedWireID
        selectedLabelID = entry.selectedLabelID
        rebuildConnectivity()
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
        rebuildConnectivity()
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
        rebuildConnectivity()
    }

    public func rotateSymbol(id: UUID, by degrees: Int) {
        guard let index = symbols.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        symbols[index].rotation = (((symbols[index].rotation + degrees) % 360) + 360) % 360
        rebuildConnectivity()
    }

    public func setRotation(id: UUID, to degrees: Int) {
        guard let index = symbols.firstIndex(where: { $0.id == id }) else { return }
        let normalized = ((degrees % 360) + 360) % 360
        guard symbols[index].rotation != normalized else { return }
        checkpoint()
        symbols[index].rotation = normalized
        rebuildConnectivity()
    }

    public func deleteSymbol(id: UUID) {
        guard let index = symbols.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        symbols.remove(at: index)
        if selectedSymbolID == id { selectedSymbolID = nil }
        rebuildConnectivity()
    }

    public func setReference(id: UUID, to reference: String) {
        guard let index = symbols.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        guard symbols[index].refDes != trimmed else { return }
        checkpoint()
        symbols[index].refDes = trimmed
        rebuildConnectivity()
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
        rebuildConnectivity()
    }

    public func deleteWire(id: UUID) {
        guard let index = wires.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        wires.remove(at: index)
        if selectedWireID == id { selectedWireID = nil }
        rebuildConnectivity()
    }

    // MARK: - Net labels

    public func addNetLabel(name: String, at position: GridPoint) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        checkpoint()
        netLabels.append(NetLabel(name: trimmed.uppercased(), position: position))
        rebuildConnectivity()
    }

    public func renameNetLabel(id: UUID, to name: String) {
        guard let index = netLabels.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces).uppercased()
        guard !trimmed.isEmpty, netLabels[index].name != trimmed else { return }
        checkpoint()
        netLabels[index].name = trimmed
        rebuildConnectivity()
    }

    public func deleteNetLabel(id: UUID) {
        guard let index = netLabels.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        netLabels.remove(at: index)
        if selectedLabelID == id { selectedLabelID = nil }
        rebuildConnectivity()
    }

    // MARK: - Connectivity

    public func rebuildConnectivity() {
        self.nets = ConnectivityBuilder.build(symbols: symbols, wires: wires, labels: netLabels)
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
