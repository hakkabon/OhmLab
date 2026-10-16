import CoreGraphics
import SwiftUI

public struct GridPoint: Hashable {
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

public struct PinRef: Hashable {
    public let symbolId: UUID
    public let pinId: String
}

public struct Net: Identifiable {
    public let id: Int
    public var name: String
    public var connectedPins: [PinRef]
    public var isGround: Bool = false
}

public struct SymbolInstance: Identifiable, Equatable {
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

public struct WireSegment: Identifiable, Equatable {
    public let id: UUID
    public var points: [GridPoint]
    
    public init(id: UUID = UUID(), points: [GridPoint]) {
        self.id = id; self.points = points
    }
}

@MainActor
public class SchematicDocument: ObservableObject {
    @Published public var symbols: [SymbolInstance] = []
    @Published public var wires: [WireSegment] = []
    @Published public var nets: [Net] = []
    @Published public var selectedSymbolID: UUID?
    
    public init() {}
    
    public func addSymbol(_ symbol: SymbolInstance) {
        symbols.append(symbol)
        selectedSymbolID = symbol.id
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
    
    public func addWire(_ wire: WireSegment) {
        wires.append(wire)
        rebuildConnectivity()
    }
    
    public func rebuildConnectivity() {
        self.nets = ConnectivityBuilder.build(symbols: symbols, wires: wires)
    }
}
