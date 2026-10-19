// CircuitProbe.swift
// A named scalar read from a solved circuit, e.g. `v(out)`, `i(R1)`, `vi(R1)`.
//
// Analyses that produce one operating point per trial (Monte Carlo, corners,
// optimisation) report on a small set of probes. The text form mirrors SPICE so
// it is natural on the CLI.

import Foundation

public enum CircuitProbe: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Absolute node voltage, `v(<node>)`.
    case nodeVoltage(String)
    /// Current through an element, `i(<element>)`.
    case elementCurrent(String)
    /// Voltage across an element, `vi(<element>)`.
    case elementVoltage(String)

    public var description: String {
        switch self {
        case .nodeVoltage(let name): return "v(\(name))"
        case .elementCurrent(let name): return "i(\(name))"
        case .elementVoltage(let name): return "vi(\(name))"
        }
    }

    /// Parses `v(node)`, `i(element)`, or `vi(element)`.
    public static func parse(_ text: String) -> CircuitProbe? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"), let open = trimmed.firstIndex(of: "(") else { return nil }
        let prefix = String(trimmed[trimmed.startIndex..<open]).lowercased()
        let name = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        switch prefix {
        case "v": return .nodeVoltage(name)
        case "i": return .elementCurrent(name)
        case "vi", "vr": return .elementVoltage(name)
        default: return nil
        }
    }

    /// Reads the probe from a DC operating point, matching names
    /// case-insensitively.
    public func value(in dc: CircuitSimResult.DCResult) -> Double? {
        func matches(_ candidate: String, _ target: String) -> Bool {
            candidate.caseInsensitiveCompare(target) == .orderedSame
        }
        switch self {
        case .nodeVoltage(let name):
            return dc.nodes.first { matches($0.name, name) }?.voltage
        case .elementCurrent(let name):
            if let component = dc.components.first(where: { matches($0.name, name) }) {
                return component.current
            }
            return dc.sources.first { matches($0.name, name) }?.current
        case .elementVoltage(let name):
            return dc.components.first { matches($0.name, name) }?.voltage
        }
    }

    /// Reads the probe from a DC operating point, throwing when the name is
    /// unknown so a typo is reported rather than silently treated as zero.
    public func requiredValue(in dc: CircuitSimResult.DCResult) throws -> Double {
        guard let value = value(in: dc) else {
            throw CircuitProbeError.unknownProbe(description)
        }
        return value
    }
}

public enum CircuitProbeError: LocalizedError, Equatable {
    case unknownProbe(String)
    case noProbes

    public var errorDescription: String? {
        switch self {
        case .unknownProbe(let name):
            return "No node or element matches \(name)."
        case .noProbes:
            return "Select at least one probe (e.g. v(out)) to report on."
        }
    }
}

/// An allowed range for a probe, used to compute yield.
public struct ProbeLimit: Codable, Equatable, Sendable {
    public var probe: CircuitProbe
    public var minimum: Double?
    public var maximum: Double?

    public init(probe: CircuitProbe, minimum: Double? = nil, maximum: Double? = nil) {
        self.probe = probe
        self.minimum = minimum
        self.maximum = maximum
    }

    /// True when `value` satisfies both bounds (absent bounds are ignored).
    public func contains(_ value: Double) -> Bool {
        if let minimum, value < minimum { return false }
        if let maximum, value > maximum { return false }
        return true
    }
}
