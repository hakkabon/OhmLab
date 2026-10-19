// SpiceNumber.swift
// Public access to the netlist parser's numeric-literal handling, for front ends
// (e.g. the CLI's `--ac 1 1meg`) that accept the same values as a netlist.

import Foundation

public enum SpiceNumber {
    /// Parses a SPICE numeric literal with an optional scale suffix or unit
    /// letter: `1k`, `2.2m`, `1e3`, `10uF`, `-5`. Returns `nil` when the token
    /// does not start with a number.
    public static func parse(_ token: String) -> Double? {
        try? SpiceNetlistParser.parseNumber(token, line: 0)
    }
}
