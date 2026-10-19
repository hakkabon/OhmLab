import CoreGraphics

/// Shared pin-placement math so connectivity, diagnostics, and rendering all
/// agree on where a component's pins land on the grid. Previously this rotation
/// logic was duplicated in three places, which let them drift apart.
public enum PinGeometry {
    /// The grid offset of a pin, in cells, after applying the symbol rotation.
    public static func rotatedOffset(forPinAt position: CGPoint, rotation: Int) -> (x: Int, y: Int) {
        let x = Int((position.x / GridPoint.gridSize).rounded())
        let y = Int((position.y / GridPoint.gridSize).rounded())
        switch ((rotation % 360) + 360) % 360 {
        case 90: return (-y, x)
        case 180: return (-x, -y)
        case 270: return (y, -x)
        default: return (x, y)
        }
    }

    public static func location(ofPinAt position: CGPoint, on symbol: SymbolInstance) -> GridPoint {
        let offset = rotatedOffset(forPinAt: position, rotation: symbol.rotation)
        return GridPoint(symbol.position.x + offset.x, symbol.position.y + offset.y)
    }

    public static func location(of pin: PinDescriptor, on symbol: SymbolInstance) -> GridPoint {
        location(ofPinAt: pin.position, on: symbol)
    }

    public static func pinLocations(
        for symbol: SymbolInstance,
        descriptor: ComponentDescriptor
    ) -> [(ref: PinRef, location: GridPoint)] {
        descriptor.pins.map { pin in
            (PinRef(symbolId: symbol.id, pinId: pin.id), location(of: pin, on: symbol))
        }
    }
}
