import Foundation

/// A node-naming conflict that would make two distinct nets share one SPICE
/// node name.
public enum NodeMapError: LocalizedError, Equatable {
    /// A non-ground net claimed `"0"`, which SPICE reserves for ground.
    case reservedGroundName(netID: Int)
    /// Two distinct nets resolved to the same node name.
    case duplicateName(name: String, netIDs: [Int])

    public var errorDescription: String? {
        switch self {
        case .reservedGroundName:
            return "\"0\" is reserved for ground. Rename the net label."
        case .duplicateName(let name, _):
            return "More than one net is named \"\(name)\". Net labels must be unique."
        }
    }
}

/// Deterministic mapping from connectivity nets to solver node numbers and
/// names. Ground nets collapse to node 0 (`"0"`); every other net receives a
/// unique, stable name.
///
/// Shared by the compiler and the netlist exporter so that both always agree on
/// node identity, and reserved names (like `"0"`) can never be handed to a
/// non-ground net. Same-named labels are already merged into one net by
/// `ConnectivityBuilder`; a name collision that survives that merge is a real
/// modelling error, so `build` reports it instead of silently renaming a node.
public struct NodeMap {
    /// Node names indexed by node number; index 0 is always ground (`"0"`).
    public let nodeNames: [String]
    public let nodeIndexByNetID: [Int: Int]
    public let nodeNameByNetID: [Int: String]

    public static func build(from nets: [Net]) throws -> NodeMap {
        var nodeNames = ["0"]
        var indexByNet: [Int: Int] = [:]
        var nameByNet: [Int: String] = [:]
        // Keyed by the uppercased name: SPICE node names are case-insensitive,
        // so `OUT` and `out` are the same node.
        var netIDByKey: [String: Int] = [:]

        for net in nets where net.isGround {
            indexByNet[net.id] = 0
            nameByNet[net.id] = "0"
        }

        for net in nets.filter({ !$0.isGround }).sorted(by: { $0.id < $1.id }) {
            let trimmed = net.name.trimmingCharacters(in: .whitespaces)
            // "0" is reserved for ground; a non-ground net may never claim it.
            if trimmed == "0" {
                throw NodeMapError.reservedGroundName(netID: net.id)
            }
            let name = trimmed.isEmpty ? "N\(net.id)" : trimmed
            let key = name.uppercased()
            if let existing = netIDByKey[key] {
                throw NodeMapError.duplicateName(name: name, netIDs: [existing, net.id])
            }
            netIDByKey[key] = net.id
            indexByNet[net.id] = nodeNames.count
            nameByNet[net.id] = name
            nodeNames.append(name)
        }

        return NodeMap(nodeNames: nodeNames, nodeIndexByNetID: indexByNet, nodeNameByNetID: nameByNet)
    }
}
