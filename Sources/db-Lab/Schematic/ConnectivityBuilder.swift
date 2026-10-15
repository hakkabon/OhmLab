import Foundation

class UnionFind {
    var parent: [GridPoint: GridPoint] = [:]
    var rank: [GridPoint: Int] = [:]
    
    func find(_ i: GridPoint) -> GridPoint {
        if parent[i] == nil { parent[i] = i; rank[i] = 0 }
        if parent[i]! != i { parent[i] = find(parent[i]!) }
        return parent[i]!
    }
    
    func union(_ i: GridPoint, _ j: GridPoint) {
        let rootI = find(i)
        let rootJ = find(j)
        if rootI != rootJ {
            if rank[rootI]! < rank[rootJ]! { parent[rootI] = rootJ }
            else if rank[rootI]! > rank[rootJ]! { parent[rootJ] = rootI }
            else { parent[rootJ] = rootI; rank[rootI]! += 1 }
        }
    }
}

public enum ConnectivityBuilder {
    public static func build(symbols: [SymbolInstance], wires: [WireSegment]) -> [Net] {
        let uf = UnionFind()
        let registry = ComponentRegistry.shared
        
        // 1. Union wire segments
        for wire in wires {
            for i in 0..<(wire.points.count - 1) {
                uf.union(wire.points[i], wire.points[i+1])
            }
        }
        
        // 2. Union pins that touch wire endpoints or other pins
        var pinLocations: [PinRef: GridPoint] = [:]
        for sym in symbols {
            let desc = registry.descriptor(for: sym.descriptorId)
            for pin in (desc?.pins ?? []) {
                // Simplified absolute position calculation (ignoring rotation for this basic patch)
                let absPoint = GridPoint(sym.position.x + Int(pin.position.x / GridPoint.gridSize),
                                         sym.position.y + Int(pin.position.y / GridPoint.gridSize))
                let ref = PinRef(symbolId: sym.id, pinId: pin.id)
                pinLocations[ref] = absPoint
                
                // Union with any wire point that matches
                for wire in wires {
                    if wire.points.contains(absPoint) {
                        uf.union(absPoint, absPoint) // ensures it's in the UF tree
                    }
                }
            }
        }
        
        // 3. Group into Nets
        var netGroups: [GridPoint: [PinRef]] = [:]
        for (ref, loc) in pinLocations {
            let root = uf.find(loc)
            netGroups[root, default: []].append(ref)
        }
        
        // 4. Build Net objects
        var result: [Net] = []
        var netId = 1
        for (root, pins) in netGroups {
            let isGround = pins.contains { ref in
                let sym = symbols.first { $0.id == ref.symbolId }
                return sym?.descriptorId == "ground"
            }
            let name = isGround ? "0" : "N\(netId)"
            var net = Net(id: netId, name: name, connectedPins: pins)
            net.isGround = isGround
            result.append(net)
            netId += 1
        }
        
        return result
    }
}
