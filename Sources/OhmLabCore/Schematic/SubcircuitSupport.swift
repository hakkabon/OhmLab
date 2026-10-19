// SubcircuitSupport.swift
// Subcircuit instances and the catalog that resolves their pins from the sheet
// hierarchy. A subcircuit instance is an ordinary `SymbolInstance` whose
// `sheetRef` points at a `Sheet`; its pins are the sheet's ports.

import CoreGraphics
import Foundation

public enum SubcircuitInstance {
    /// The registry id used by every subcircuit-instance symbol.
    public static let descriptorId = "subcircuit"

    /// Pins are laid out on a grid: inputs down the left edge, the rest down the
    /// right, so instances align with the wiring grid.
    static let pinSpacing: CGFloat = 40
    static let halfWidth: CGFloat = 60

    public static func pins(for sheet: Sheet?) -> [PinDescriptor] {
        guard let sheet, !sheet.ports.isEmpty else { return [] }
        let inputs = sheet.ports.filter(\.isInput)
        let outputs = sheet.ports.filter { !$0.isInput }
        let rows = max(inputs.count, outputs.count, 1)
        let height = CGFloat(rows + 1) * pinSpacing
        let top = -(height / 2) + pinSpacing

        var pins: [PinDescriptor] = []
        for (index, port) in inputs.enumerated() {
            pins.append(PinDescriptor(
                id: port.name,
                name: port.name,
                position: CGPoint(x: -halfWidth, y: top + CGFloat(index) * pinSpacing)
            ))
        }
        for (index, port) in outputs.enumerated() {
            pins.append(PinDescriptor(
                id: port.name,
                name: port.name,
                position: CGPoint(x: halfWidth, y: top + CGFloat(index) * pinSpacing)
            ))
        }
        return pins
    }

    public static func descriptor(for symbol: SymbolInstance, sheet: Sheet?) -> ComponentDescriptor {
        ComponentDescriptor(
            id: descriptorId,
            prefix: "X",
            displayName: sheet?.name ?? "Subcircuit",
            symbol: .subcircuit,
            pins: pins(for: sheet)
        )
    }

    /// The box height needed to draw all pins.
    public static func boxHeight(for sheet: Sheet?) -> CGFloat {
        let rows = max(sheet?.ports.count ?? 0, 1)
        return CGFloat(rows + 1) * pinSpacing
    }
}

/// Resolves descriptors for every symbol on a sheet, synthesizing subcircuit
/// instance descriptors from the referenced sheet's ports.
public struct SubcircuitCatalog: Sendable {
    private let sheetsByID: [UUID: Sheet]
    /// The sheet order (stable) used for traversal order in builders.
    public let sheets: [Sheet]

    public init(sheets: [Sheet]) {
        self.sheets = sheets
        self.sheetsByID = Dictionary(sheets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func sheet(id: UUID) -> Sheet? { sheetsByID[id] }

    public var isEmpty: Bool { sheetsByID.isEmpty }

    public func descriptor(for symbol: SymbolInstance) -> ComponentDescriptor? {
        if let reference = symbol.sheetRef {
            return SubcircuitInstance.descriptor(for: symbol, sheet: sheetsByID[reference])
        }
        return ComponentRegistry.shared.descriptor(for: symbol.descriptorId)
    }

    /// Pins for a symbol, using the catalog for subcircuit instances and the
    /// static registry otherwise.
    public func pins(for symbol: SymbolInstance) -> [PinDescriptor] {
        descriptor(for: symbol)?.pins ?? []
    }
}
