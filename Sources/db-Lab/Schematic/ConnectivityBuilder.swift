import Foundation

private struct UnionFind {
    private var parent: [GridPoint: GridPoint] = [:]
    private var rank: [GridPoint: Int] = [:]

    mutating func find(_ point: GridPoint) -> GridPoint {
        guard let parentPoint = parent[point] else {
            parent[point] = point
            rank[point] = 0
            return point
        }

        if parentPoint != point {
            let root = find(parentPoint)
            parent[point] = root
            return root
        }
        return point
    }

    mutating func union(_ first: GridPoint, _ second: GridPoint) {
        let firstRoot = find(first)
        let secondRoot = find(second)
        guard firstRoot != secondRoot else { return }

        let firstRank = rank[firstRoot, default: 0]
        let secondRank = rank[secondRoot, default: 0]
        if firstRank < secondRank {
            parent[firstRoot] = secondRoot
        } else if firstRank > secondRank {
            parent[secondRoot] = firstRoot
        } else {
            parent[secondRoot] = firstRoot
            rank[firstRoot] = firstRank + 1
        }
    }
}

public enum ConnectivityBuilder {
    public static func build(symbols: [SymbolInstance], wires: [WireSegment]) -> [Net] {
        var unionFind = UnionFind()
        let segments = wires.flatMap { wire in
            zip(wire.points, wire.points.dropFirst()).map { ($0, $1) }
        }

        for (start, end) in segments {
            unionFind.union(start, end)
        }

        let wireVertices = Set(wires.flatMap(\.points))
        for vertex in wireVertices {
            for (start, end) in segments where liesOnSegment(vertex, start, end) {
                unionFind.union(vertex, start)
            }
        }

        let symbolsByID = Dictionary(uniqueKeysWithValues: symbols.map { ($0.id, $0) })
        var pinLocations: [(ref: PinRef, location: GridPoint)] = []
        for symbol in symbols {
            guard let descriptor = ComponentRegistry.shared.descriptor(for: symbol.descriptorId) else {
                continue
            }

            for pin in descriptor.pins {
                let offset = rotatedOffset(for: pin.position, rotation: symbol.rotation)
                let location = GridPoint(symbol.position.x + offset.x, symbol.position.y + offset.y)
                pinLocations.append((PinRef(symbolId: symbol.id, pinId: pin.id), location))

                for (start, end) in segments where liesOnSegment(location, start, end) {
                    unionFind.union(location, start)
                }
            }
        }

        var pinsByRoot: [GridPoint: [PinRef]] = [:]
        for pin in pinLocations {
            let root = unionFind.find(pin.location)
            pinsByRoot[root, default: []].append(pin.ref)
        }

        let sortedGroups = pinsByRoot.values.map { pins in
            pins.sorted { pinSortKey($0, symbolsByID: symbolsByID) < pinSortKey($1, symbolsByID: symbolsByID) }
        }.sorted {
            guard let first = $0.first, let second = $1.first else { return $0.count < $1.count }
            return pinSortKey(first, symbolsByID: symbolsByID) < pinSortKey(second, symbolsByID: symbolsByID)
        }

        return sortedGroups.enumerated().map { index, pins in
            let isGround = pins.contains { symbolsByID[$0.symbolId]?.descriptorId == "ground" }
            return Net(
                id: index + 1,
                name: isGround ? "0" : "N\(index + 1)",
                connectedPins: pins,
                isGround: isGround
            )
        }
    }

    private static func rotatedOffset(for position: CGPoint, rotation: Int) -> (x: Int, y: Int) {
        let x = Int((position.x / GridPoint.gridSize).rounded())
        let y = Int((position.y / GridPoint.gridSize).rounded())
        switch ((rotation % 360) + 360) % 360 {
        case 90: return (-y, x)
        case 180: return (-x, -y)
        case 270: return (y, -x)
        default: return (x, y)
        }
    }

    private static func liesOnSegment(_ point: GridPoint, _ start: GridPoint, _ end: GridPoint) -> Bool {
        if start.x == end.x {
            return point.x == start.x && point.y >= min(start.y, end.y) && point.y <= max(start.y, end.y)
        }
        if start.y == end.y {
            return point.y == start.y && point.x >= min(start.x, end.x) && point.x <= max(start.x, end.x)
        }
        return false
    }

    private static func pinSortKey(
        _ pin: PinRef,
        symbolsByID: [UUID: SymbolInstance]
    ) -> (String, String, String) {
        (
            symbolsByID[pin.symbolId]?.refDes ?? "",
            pin.symbolId.uuidString,
            pin.pinId
        )
    }
}
