// SpiceNetlistParser.swift
// A small, well-scoped SPICE reader for the element set the solver supports:
// R, C, L, independent V and I sources, plus `.ac` analysis cards.
//
// This is intentionally not a full SPICE implementation. Unsupported cards are
// reported instead of being silently ignored, so the UI can tell the user what
// was and was not included in the analysis.

import Foundation

public enum SpiceParseError: LocalizedError {
    case empty
    case missingGround
    case malformed(line: Int, text: String)
    case unsupportedElement(line: Int, name: String)
    case unsupportedCard(line: Int, text: String)
    case invalidValue(line: Int, text: String)
    case invalidAnalysis(line: Int, text: String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "The netlist is empty."
        case .missingGround:
            return "The netlist has no node 0 (ground) reference."
        case .malformed(let line, let text):
            return "Line \(line): could not parse \"\(text)\"."
        case .unsupportedElement(let line, let name):
            return "Line \(line): element \(name) is not supported yet (only R, C, L, V, I)."
        case .unsupportedCard(let line, let text):
            return "Line \(line): directive \"\(text)\" is not supported."
        case .invalidValue(let line, let text):
            return "Line \(line): \"\(text)\" is not a valid numeric value."
        case .invalidAnalysis(let line, let text):
            return "Line \(line): \"\(text)\" is not a valid .ac analysis."
        }
    }
}

public struct SpiceAnalysisCard: Sendable, Equatable {
    public var hasAC: Bool
    public var sweep: FrequencySweepType
    /// Points per decade/octave, or the total point count for a linear sweep.
    public var points: Int
    public var startFrequency: Double
    public var stopFrequency: Double
    public var hasOperatingPoint: Bool
    public var hasTransient: Bool
    public var tranStep: Double
    public var tranStop: Double
    public var tranStart: Double

    public static let none = SpiceAnalysisCard(
        hasAC: false,
        sweep: .dec,
        points: 20,
        startFrequency: 1,
        stopFrequency: 1e6,
        hasOperatingPoint: false,
        hasTransient: false,
        tranStep: 1e-4,
        tranStop: 1e-2,
        tranStart: 0
    )
}

public struct ParsedSpiceNetlist: Sendable {
    public var circuit: LinearCircuit
    public var analysis: SpiceAnalysisCard
}

public enum SpiceNetlistParser {
    public static func parse(_ text: String) throws -> ParsedSpiceNetlist {
        let rawLines = text.components(separatedBy: .newlines)
        var nodeNames = ["0"]
        var nodeIndex: [String: Int] = ["0": 0]
        var elements: [LinearCircuit.Element] = []
        var analysis = SpiceAnalysisCard.none
        var sawContent = false

        // SPICE node names are case-insensitive; "0" is always ground.
        func node(_ name: String) -> Int {
            let key = name.uppercased()
            if let existing = nodeIndex[key] { return existing }
            let index = nodeNames.count
            nodeIndex[key] = index
            nodeNames.append(name)
            return index
        }

        for (offset, rawLine) in rawLines.enumerated() {
            let lineNumber = offset + 1
            let stripped = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty { continue }
            if stripped.hasPrefix("*") { continue }

            if stripped.hasPrefix(".") {
                let tokens = stripped.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                let directive = tokens[0].lowercased()
                switch directive {
                case ".ac":
                    analysis.hasAC = true
                    try parseAC(tokens: tokens, line: lineNumber, text: stripped, into: &analysis)
                case ".op":
                    analysis.hasOperatingPoint = true
                case ".tran":
                    analysis.hasTransient = true
                    try parseTran(tokens: tokens, line: lineNumber, text: stripped, into: &analysis)
                case ".end", ".ends":
                    break
                case ".dc", ".noise", ".disto", ".four", ".print", ".plot", ".save", ".param", ".include", ".lib", ".model", ".subckt", ".options":
                    throw SpiceParseError.unsupportedCard(line: lineNumber, text: stripped)
                default:
                    throw SpiceParseError.unsupportedCard(line: lineNumber, text: stripped)
                }
                sawContent = true
                continue
            }

            let tokens = stripped.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 3 else {
                throw SpiceParseError.malformed(line: lineNumber, text: stripped)
            }
            let name = tokens[0]
            guard let kindLetter = name.uppercased().first else {
                throw SpiceParseError.malformed(line: lineNumber, text: stripped)
            }
            let a = node(tokens[1])
            let b = node(tokens[2])

            switch kindLetter {
            case "R", "C", "L":
                guard tokens.count >= 4 else { throw SpiceParseError.malformed(line: lineNumber, text: stripped) }
                let value = try parseNumber(tokens[3], line: lineNumber)
                let kind: LinearCircuit.ElementKind = kindLetter == "R" ? .resistor : (kindLetter == "C" ? .capacitor : .inductor)
                elements.append(.init(kind: kind, nodeA: a, nodeB: b, value: value, name: name))
            case "V", "I":
                guard tokens.count >= 4 else { throw SpiceParseError.malformed(line: lineNumber, text: stripped) }
                let spec = tokens.dropFirst(3).joined(separator: " ")
                let source = try parseSource(spec, line: lineNumber, text: stripped)
                let kind: LinearCircuit.ElementKind = kindLetter == "V" ? .voltageSource : .currentSource
                elements.append(.init(
                    kind: kind,
                    nodeA: a,
                    nodeB: b,
                    value: source.ac ?? source.dc ?? 0,
                    phaseDegrees: source.phaseDegrees,
                    dcValue: source.dc,
                    acValue: source.ac,
                    transient: source.waveform,
                    name: name
                ))
            default:
                throw SpiceParseError.unsupportedElement(line: lineNumber, name: name)
            }
            sawContent = true
        }

        guard sawContent, !elements.isEmpty else { throw SpiceParseError.empty }
        guard nodeIndex["0"] != nil else { throw SpiceParseError.missingGround }

        return ParsedSpiceNetlist(
            circuit: LinearCircuit(nodeNames: nodeNames, elements: elements),
            analysis: analysis
        )
    }

    // MARK: - Helpers

    private static func stripComment(_ line: String) -> String {
        if let semicolon = line.firstIndex(of: ";") {
            return String(line[line.startIndex..<semicolon])
        }
        return line
    }

    private static func parseAC(
        tokens: [String],
        line: Int,
        text: String,
        into analysis: inout SpiceAnalysisCard
    ) throws {
        // .ac <dec|oct|lin> <points> <fstart> <fstop>
        guard tokens.count >= 5 else { throw SpiceParseError.invalidAnalysis(line: line, text: text) }
        guard let sweep = FrequencySweepType(rawValue: tokens[1].lowercased()) else {
            throw SpiceParseError.invalidAnalysis(line: line, text: text)
        }
        guard let points = Int(tokens[2]) else {
            throw SpiceParseError.invalidAnalysis(line: line, text: text)
        }
        let start = try parseNumber(tokens[3], line: line)
        let stop = try parseNumber(tokens[4], line: line)
        guard points > 0, start > 0, stop > start else {
            throw SpiceParseError.invalidAnalysis(line: line, text: text)
        }
        analysis.sweep = sweep
        analysis.points = points
        analysis.startFrequency = start
        analysis.stopFrequency = stop
    }

    private static func parseTran(
        tokens: [String],
        line: Int,
        text: String,
        into analysis: inout SpiceAnalysisCard
    ) throws {
        // .tran <tstep> <tstop> [tstart [tmax]]
        guard tokens.count >= 3 else { throw SpiceParseError.invalidAnalysis(line: line, text: text) }
        let step = try parseNumber(tokens[1], line: line)
        let stop = try parseNumber(tokens[2], line: line)
        let start = tokens.count > 3 ? try parseNumber(tokens[3], line: line) : 0
        guard step > 0, stop > start, start >= 0 else {
            throw SpiceParseError.invalidAnalysis(line: line, text: text)
        }
        analysis.tranStep = step
        analysis.tranStop = stop
        analysis.tranStart = start
    }

    private struct SourceSpec {
        var dc: Double?
        var ac: Double?
        var phaseDegrees: Double
        var waveform: Waveform?
    }

    /// Parses a source's specification, keeping DC, AC, and transient shapes
    /// separate: `DC 5`, `AC 1 90`, `5 AC 1`, `PULSE(0 5 0 1n 1n 1 2)`, etc.
    /// Phase only applies to AC.
    private static func parseSource(
        _ spec: String,
        line: Int,
        text: String
    ) throws -> SourceSpec {
        var dc: Double?
        var ac: Double?
        var phase: Double = 0
        var waveform: Waveform?

        var working = spec
        if let match = waveformPattern.firstMatch(in: spec, range: NSRange(spec.startIndex..., in: spec)),
           let nameRange = Range(match.range(at: 1), in: spec),
           let argsRange = Range(match.range(at: 2), in: spec) {
            let name = spec[nameRange].uppercased()
            let args = splitArguments(String(spec[argsRange]))
            waveform = try parseWaveform(name: name, args: args, line: line, text: text)
            if let wholeRange = Range(match.range(at: 0), in: spec) {
                working = spec.replacingCharacters(in: wholeRange, with: " ")
            }
        }

        let tokens = working.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," }).map(String.init)
        var index = 0
        while index < tokens.count {
            let token = tokens[index].uppercased()
            if token == "AC" {
                guard index + 1 < tokens.count else { throw SpiceParseError.malformed(line: line, text: text) }
                ac = try parseNumber(tokens[index + 1], line: line)
                if index + 2 < tokens.count, let parsedPhase = try? parseNumber(tokens[index + 2], line: line) {
                    phase = parsedPhase
                    index += 3
                } else {
                    index += 2
                }
            } else if token == "DC" {
                guard index + 1 < tokens.count else { throw SpiceParseError.malformed(line: line, text: text) }
                dc = try parseNumber(tokens[index + 1], line: line)
                index += 2
            } else {
                let value = try parseNumber(tokens[index], line: line)
                if dc == nil {
                    dc = value
                } else {
                    phase = value
                }
                index += 1
            }
        }
        guard dc != nil || ac != nil || waveform != nil else {
            throw SpiceParseError.malformed(line: line, text: text)
        }
        return SourceSpec(dc: dc, ac: ac, phaseDegrees: phase, waveform: waveform)
    }

    private static func splitArguments(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," || $0 == "\n" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func parseWaveform(
        name: String,
        args: [String],
        line: Int,
        text: String
    ) throws -> Waveform {
        func numbers() throws -> [Double] {
            try args.map { try parseNumber($0, line: line) }
        }
        switch name {
        case "PULSE":
            let v = try numbers()
            guard v.count >= 2 else { throw SpiceParseError.malformed(line: line, text: text) }
            return .pulse(
                initial: v[0],
                pulsed: v[1],
                delay: v.count > 2 ? v[2] : 0,
                riseTime: v.count > 3 ? v[3] : 0,
                fallTime: v.count > 4 ? v[4] : 0,
                pulseWidth: v.count > 5 ? v[5] : .infinity,
                period: v.count > 6 ? v[6] : 0
            )
        case "SIN":
            let v = try numbers()
            guard v.count >= 3 else { throw SpiceParseError.malformed(line: line, text: text) }
            return .sine(
                offset: v[0],
                amplitude: v[1],
                frequency: v[2],
                delay: v.count > 3 ? v[3] : 0,
                damping: v.count > 4 ? v[4] : 0,
                phaseDegrees: v.count > 5 ? v[5] : 0
            )
        case "PWL":
            let v = try numbers()
            guard v.count >= 2 else { throw SpiceParseError.malformed(line: line, text: text) }
            var points: [WaveformPoint] = []
            var index = 0
            while index + 1 < v.count {
                points.append(WaveformPoint(time: v[index], value: v[index + 1]))
                index += 2
            }
            guard !points.isEmpty else { throw SpiceParseError.malformed(line: line, text: text) }
            return .pwl(points: points)
        default:
            throw SpiceParseError.unsupportedCard(line: line, text: text)
        }
    }

    /// Parse a SPICE-style value with optional engineering suffix, e.g. `4.7k`,
    /// `10uF`, `2.2meg`, `1e-3`. Trailing unit letters after a suffix are ignored.
    static func parseNumber(_ token: String, line: Int) throws -> Double {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard let match = numberPattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let numericRange = Range(match.range(at: 1), in: trimmed),
              let value = Double(trimmed[numericRange]) else {
            throw SpiceParseError.invalidValue(line: line, text: token)
        }

        guard match.range(at: 2).location != NSNotFound,
              let suffixRange = Range(match.range(at: 2), in: trimmed) else {
            return value
        }

        let normalized = trimmed[suffixRange].lowercased()
        let multiplier: Double
        if normalized.hasPrefix("meg") {
            multiplier = 1e6
        } else {
            switch normalized.first {
            case "t": multiplier = 1e12
            case "g": multiplier = 1e9
            case "k": multiplier = 1e3
            case "m": multiplier = 1e-3
            case "u": multiplier = 1e-6
            case "n": multiplier = 1e-9
            case "p": multiplier = 1e-12
            case "f": multiplier = 1e-15
            default: multiplier = 1
            }
        }
        return value * multiplier
    }

    private static let waveformPattern: NSRegularExpression = {
        // Groups: 1 = function name, 2 = parenthesised argument list.
        try! NSRegularExpression(pattern: "(?i)\\b(PULSE|SIN|PWL)\\s*\\(([^)]*)\\)")
    }()

    private static let numberPattern: NSRegularExpression = {
        // Groups: 1 = numeric mantissa/exponent, 2 = trailing suffix letters.
        try! NSRegularExpression(pattern: "^([+-]?(?:\\d+\\.?\\d*|\\.\\d+)(?:[eE][+-]?\\d+)?)([a-zA-Z]*)$")
    }()
}
