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
    public static func build(
        symbols: [SymbolInstance],
        wires: [WireSegment],
        labels: [NetLabel] = []
    ) -> [Net] {
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

        // Labels connect to wires they sit on, exactly like a wire vertex.
        for label in labels {
            for (start, end) in segments where liesOnSegment(label.position, start, end) {
                unionFind.union(label.position, start)
            }
        }

        let symbolsByID = Dictionary(uniqueKeysWithValues: symbols.map { ($0.id, $0) })
        var pinLocations: [(ref: PinRef, location: GridPoint)] = []
        for symbol in symbols {
            guard let descriptor = ComponentRegistry.shared.descriptor(for: symbol.descriptorId) else {
                continue
            }

            for entry in PinGeometry.pinLocations(for: symbol, descriptor: descriptor) {
                pinLocations.append(entry)

                for (start, end) in segments where liesOnSegment(entry.location, start, end) {
                    unionFind.union(entry.location, start)
                }
            }
        }

        var pinsByRoot: [GridPoint: [PinRef]] = [:]
        for pin in pinLocations {
            let root = unionFind.find(pin.location)
            pinsByRoot[root, default: []].append(pin.ref)
        }

        // Attach a label name to each root, deterministically choosing the
        // lexicographically smallest name when several labels share a net.
        var labelNameByRoot: [GridPoint: String] = [:]
        for label in labels {
            let root = unionFind.find(label.position)
            if let existing = labelNameByRoot[root] {
                labelNameByRoot[root] = min(existing, label.name)
            } else {
                labelNameByRoot[root] = label.name
            }
        }

        let sortedGroups = pinsByRoot.map { root, pins in
            (root: root, pins: pins.sorted {
                pinSortKey($0, symbolsByID: symbolsByID) < pinSortKey($1, symbolsByID: symbolsByID)
            })
        }.sorted {
            guard let first = $0.pins.first, let second = $1.pins.first else { return $0.pins.count < $1.pins.count }
            return pinSortKey(first, symbolsByID: symbolsByID) < pinSortKey(second, symbolsByID: symbolsByID)
        }

        // Every net that has pins gets an entry; also include roots that carry a
        // label but no pins so a label on a bare wire is still visible.
        var netIDs: [GridPoint: Int] = [:]
        var nextID = 1
        for group in sortedGroups {
            netIDs[group.root] = nextID
            nextID += 1
        }
        var orderedRoots = sortedGroups.map(\.root)
        for label in labels.sorted(by: { labelSortKey($0) < labelSortKey($1) }) {
            let root = unionFind.find(label.position)
            if netIDs[root] == nil {
                netIDs[root] = nextID
                nextID += 1
                orderedRoots.append(root)
            }
        }

        return orderedRoots.map { root in
            let pins = pinsByRoot[root] ?? []
            let isGround = pins.contains { symbolsByID[$0.symbolId]?.descriptorId == "ground" }
            let labelName = labelNameByRoot[root]
            let id = netIDs[root] ?? 1
            return Net(
                id: id,
                name: isGround ? "0" : (labelName ?? "N\(id)"),
                connectedPins: pins,
                isGround: isGround,
                isLabeled: labelName != nil
            )
        }
    }

    private static func labelSortKey(_ label: NetLabel) -> (String, Int, Int, String) {
        (label.name, label.position.x, label.position.y, label.id.uuidString)
    }

    static func liesOnSegment(_ point: GridPoint, _ start: GridPoint, _ end: GridPoint) -> Bool {
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
