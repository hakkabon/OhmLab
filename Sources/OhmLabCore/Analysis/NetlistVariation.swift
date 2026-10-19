// NetlistVariation.swift
// Editable view of a netlist's component values.
//
// Monte Carlo, corner, and optimisation analyses all vary component values, so
// they share one primitive: enumerate the top-level two-terminal devices and
// their nominal values, then rewrite those values by reference designator. Only
// literal-valued R/L/C and DC-valued V/I devices are editable here; devices
// whose value is a `{parameter}` expression are left to `.step`/`.param`.

import Foundation

/// A top-level two-terminal device with a literal value.
public struct NetlistDevice: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case resistor, capacitor, inductor, voltageSource, currentSource

        /// The set of kinds a tolerance is usually applied to.
        public var isPassive: Bool {
            self == .resistor || self == .capacitor || self == .inductor
        }
    }

    public var designator: String
    public var kind: Kind
    public var value: Double

    public init(designator: String, kind: Kind, value: Double) {
        self.designator = designator
        self.kind = kind
        self.value = value
    }
}

public enum NetlistValueRewriter {
    /// Every top-level, literal-valued device in the netlist, in file order.
    public static func devices(in netlist: String) -> [NetlistDevice] {
        var result: [NetlistDevice] = []
        forEachTopLevelDeviceLine(netlist) { line in
            let tokens = SpiceNetlistParser.splitTokens(line)
            guard let kind = kind(of: tokens[0]),
                  let index = valueTokenIndex(for: tokens),
                  let value = SpiceNumber.parse(tokens[index]) else { return }
            result.append(NetlistDevice(designator: tokens[0], kind: kind, value: value))
        }
        return result
    }

    /// The designator → nominal value map for every editable device.
    public static func nominalValues(in netlist: String) -> [String: Double] {
        var result: [String: Double] = [:]
        for device in devices(in: netlist) {
            result[device.designator] = device.value
        }
        return result
    }

    /// Rewrites the value of every device named in `values` (case-insensitive),
    /// leaving all other lines unchanged. Designators that name no editable
    /// device are simply ignored.
    public static func rewrite(_ netlist: String, values: [String: Double]) -> String {
        guard !values.isEmpty else { return netlist }
        var map: [String: Double] = [:]
        for (key, value) in values { map[key.uppercased()] = value }

        var lines = netlist.components(separatedBy: .newlines)
        var depth = 0
        for index in lines.indices {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let lowered = trimmed.lowercased()

            if lowered == ".ends" || lowered.hasPrefix(".ends ") {
                depth = max(0, depth - 1)
                continue
            }
            if depth > 0 { continue }
            if lowered == ".subckt" || lowered.hasPrefix(".subckt ") {
                depth += 1
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("*")
                || trimmed.hasPrefix("+") || trimmed.hasPrefix(".") {
                continue
            }

            let tokens = SpiceNetlistParser.splitTokens(trimmed)
            guard let index2 = valueTokenIndex(for: tokens),
                  let newValue = map[tokens[0].uppercased()] else { continue }

            var updated = tokens
            updated[index2] = format(newValue)
            let indent = String(raw.prefix { $0 == " " || $0 == "\t" })
            lines[index] = indent + updated.joined(separator: " ")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Line scanning

    /// Invokes `body` for each top-level (non-subcircuit, non-directive,
    /// non-continuation) device line.
    private static func forEachTopLevelDeviceLine(_ netlist: String, _ body: (String) -> Void) {
        var depth = 0
        for raw in netlist.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let lowered = trimmed.lowercased()
            if lowered == ".ends" || lowered.hasPrefix(".ends ") {
                depth = max(0, depth - 1)
                continue
            }
            if depth > 0 { continue }
            if lowered == ".subckt" || lowered.hasPrefix(".subckt ") {
                depth += 1
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("*")
                || trimmed.hasPrefix("+") || trimmed.hasPrefix(".") {
                continue
            }
            body(trimmed)
        }
    }

    private static func kind(of designator: String) -> NetlistDevice.Kind? {
        switch designator.uppercased().first {
        case "R": return .resistor
        case "C": return .capacitor
        case "L": return .inductor
        case "V": return .voltageSource
        case "I": return .currentSource
        default: return nil
        }
    }

    /// The index of the editable value token, or nil when the device has no
    /// literal value (for example an AC-only source or a `{param}` value).
    private static func valueTokenIndex(for tokens: [String]) -> Int? {
        guard tokens.count >= 4, let kind = kind(of: tokens[0]) else { return nil }
        switch kind {
        case .resistor, .capacitor, .inductor:
            return SpiceNumber.parse(tokens[3]) != nil ? 3 : nil
        case .voltageSource, .currentSource:
            if tokens[3].caseInsensitiveCompare("DC") == .orderedSame {
                return tokens.count >= 5 && SpiceNumber.parse(tokens[4]) != nil ? 4 : nil
            }
            if tokens[3].caseInsensitiveCompare("AC") == .orderedSame { return nil }
            return SpiceNumber.parse(tokens[3]) != nil ? 3 : nil
        }
    }

    static func format(_ value: Double) -> String {
        String(format: "%.12g", value)
    }
}

/// Injects a `.temp` card into a netlist, replacing any existing one so the
/// requested ambient temperature actually takes effect.
public enum NetlistTemperature {
    public static func setting(_ celsius: Double, in netlist: String) -> String {
        let card = ".temp \(NetlistValueRewriter.format(celsius))"
        var lines = netlist.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            return !(trimmed == ".temp" || trimmed.hasPrefix(".temp "))
        }
        lines.insert(card, at: 0)
        return lines.joined(separator: "\n")
    }
}
