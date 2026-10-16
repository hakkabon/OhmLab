import Foundation

/// Deterministic mapping from connectivity nets to solver node numbers and
/// names. Ground nets collapse to node 0 (`"0"`); every other net receives a
/// unique, stable name.
///
/// Shared by the compiler and the netlist exporter so that both always agree on
/// node identity, and reserved names (like `"0"`) can never be handed to a
/// non-ground net.
public struct NodeMap {
    /// Node names indexed by node number; index 0 is always ground (`"0"`).
    public let nodeNames: [String]
    public let nodeIndexByNetID: [Int: Int]
    public let nodeNameByNetID: [Int: String]

    public static func build(from nets: [Net]) -> NodeMap {
        var nodeNames = ["0"]
        var indexByNet: [Int: Int] = [:]
        var nameByNet: [Int: String] = [:]
        var used: Set<String> = ["0"]

        for net in nets where net.isGround {
            indexByNet[net.id] = 0
            nameByNet[net.id] = "0"
        }

        for net in nets.filter({ !$0.isGround }).sorted(by: { $0.id < $1.id }) {
            let name = uniqueName(preferred: net.name, netID: net.id, used: &used)
            indexByNet[net.id] = nodeNames.count
            nameByNet[net.id] = name
            nodeNames.append(name)
        }

        return NodeMap(nodeNames: nodeNames, nodeIndexByNetID: indexByNet, nodeNameByNetID: nameByNet)
    }

    private static func uniqueName(preferred: String, netID: Int, used: inout Set<String>) -> String {
        let trimmed = preferred.trimmingCharacters(in: .whitespaces)
        // "0" is reserved for ground; a non-ground net may never claim it.
        let base = trimmed.isEmpty || trimmed == "0" ? "N\(netID)" : trimmed
        if used.insert(base).inserted { return base }
        var suffix = 2
        while true {
            let candidate = "\(base)_\(suffix)"
            if used.insert(candidate).inserted { return candidate }
            suffix += 1
        }
    }
}
