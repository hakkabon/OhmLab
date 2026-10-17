// SpiceNetlistParser.swift
// A small, well-scoped SPICE reader for the element set the solver supports:
// R, C, L, independent V and I sources, diodes (D), bipolar transistors (Q),
// and `.subckt` definitions instantiated with `X` elements, plus `.ac` and
// `.tran` analysis cards.
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
    case missingModel(line: Int, name: String)
    case unknownSubcircuit(line: Int, name: String)
    case subcircuitPortMismatch(line: Int, name: String, expected: Int, found: Int)
    case recursiveSubcircuit(line: Int, name: String)
    case unterminatedSubcircuit(line: Int, name: String)
    case unknownParameter(line: Int, name: String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "The netlist is empty."
        case .missingGround:
            return "The netlist has no node 0 (ground) reference."
        case .malformed(let line, let text):
            return "Line \(line): could not parse \"\(text)\"."
        case .unsupportedElement(let line, let name):
            return "Line \(line): element \(name) is not supported yet (only R, C, L, V, I, D, Q, X)."
        case .unsupportedCard(let line, let text):
            return "Line \(line): directive \"\(text)\" is not supported."
        case .invalidValue(let line, let text):
            return "Line \(line): \"\(text)\" is not a valid numeric value."
        case .invalidAnalysis(let line, let text):
            return "Line \(line): \"\(text)\" is not a valid analysis card."
        case .missingModel(let line, let name):
            return "Line \(line): no .model named \"\(name)\" was defined for this device."
        case .unknownSubcircuit(let line, let name):
            return "Line \(line): no .subckt named \"\(name)\" was defined."
        case .subcircuitPortMismatch(let line, let name, let expected, let found):
            return "Line \(line): subcircuit \(name) expects \(expected) node(s) but \(found) were given."
        case .recursiveSubcircuit(let line, let name):
            return "Line \(line): subcircuit \(name) instantiates itself (infinite recursion)."
        case .unterminatedSubcircuit(let line, let name):
            return "Line \(line): subcircuit \(name) is missing its .ends."
        case .unknownParameter(let line, let name):
            return "Line \(line): parameter \"\(name)\" is not defined."
        }
    }
}

/// A parsed diode model from a `.model … D(…)` card.
private struct DiodeModelDefinition {
    var saturationCurrent = 1e-14
    var emissionCoefficient = 1.0
    var seriesResistance = 0.0
}

/// A parsed BJT model from a `.model … NPN(…)`/`PNP(…)` card.
private struct BJTModelDefinition {
    var polarity: LinearCircuit.BJTPolarity = .npn
    var saturationCurrent = 1e-15
    var forwardBeta = 100.0
    var reverseBeta = 1.0
}

/// A raw line of a `.subckt` body, kept with its source line number.
private struct SubcircuitLine {
    var text: String
    var number: Int
}

/// A parsed `.subckt <name> <ports…> [params: k=v …]` … `.ends` definition.
private struct SubcircuitDefinition {
    var name: String
    var ports: [String]
    /// Ordered parameter defaults, kept as unevaluated expressions so later
    /// defaults and instance overrides can reference earlier ones.
    var parameterDefaults: [(key: String, expression: String)]
    var body: [SubcircuitLine]
    var line: Int
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
        try Parser().run(text)
    }

    // MARK: - Parser

    /// Stateful reader. It first scans for `.subckt`/`.ends` blocks and `.model`
    /// cards, then expands the top-level elements, flattening every `X` instance
    /// into the element set the solver consumes.
    private final class Parser {
        private var nodeNames = ["0"]
        private var nodeIndex: [String: Int] = ["0": 0]
        private var elements: [LinearCircuit.Element] = []
        private var diodeModels: [String: DiodeModelDefinition] = [:]
        private var bjtModels: [String: BJTModelDefinition] = [:]
        private var subcircuits: [String: SubcircuitDefinition] = [:]
        private var pendingDiodes: [PendingDiode] = []
        private var pendingBJTs: [PendingBJT] = []
        private var analysis = SpiceAnalysisCard.none
        private var sawContent = false

        private struct PendingDiode {
            var name: String
            var anode: Int
            var cathode: Int
            var model: String
            var area: Double
            var line: Int
        }

        private struct PendingBJT {
            var name: String
            var collector: Int
            var base: Int
            var emitter: Int
            var model: String
            var line: Int
        }

        /// Lexical context while expanding a subcircuit instance: how to name
        /// local elements/nodes, which port names map to which external nodes,
        /// and the parameter and call-stack state.
        private struct Scope {
            var namePrefix = ""
            var portNodes: [String: Int] = [:]
            var parameters: [String: Double] = [:]
            var callStack: [String] = []
        }

        func run(_ text: String) throws -> ParsedSpiceNetlist {
            let rawLines = text.components(separatedBy: .newlines)
            var topLevel: [SubcircuitLine] = []
            var open: SubcircuitDefinition?

            for (offset, rawLine) in rawLines.enumerated() {
                let lineNumber = offset + 1
                let stripped = SpiceNetlistParser.stripComment(rawLine).trimmingCharacters(in: .whitespaces)
                if stripped.isEmpty || stripped.hasPrefix("*") { continue }
                let tokens = SpiceNetlistParser.splitTokens(stripped)
                guard let first = tokens.first else { continue }
                let directive = first.lowercased()

                switch directive {
                case ".subckt":
                    if let existing = open {
                        throw SpiceParseError.unterminatedSubcircuit(line: existing.line, name: existing.name)
                    }
                    open = try makeSubcircuit(tokens: tokens, line: lineNumber, text: stripped)
                    sawContent = true
                case ".ends":
                    if let finished = open {
                        subcircuits[finished.name.uppercased()] = finished
                        open = nil
                    }
                    sawContent = true
                case ".model":
                    try SpiceNetlistParser.parseModel(stripped, line: lineNumber, into: &diodeModels, bjtModels: &bjtModels)
                    sawContent = true
                    open?.body.append(SubcircuitLine(text: stripped, number: lineNumber))
                case _ where open != nil:
                    open?.body.append(SubcircuitLine(text: stripped, number: lineNumber))
                case _ where directive.hasPrefix("."):
                    try handleDirective(tokens: tokens, line: lineNumber, text: stripped)
                default:
                    topLevel.append(SubcircuitLine(text: stripped, number: lineNumber))
                }
            }

            if let existing = open {
                throw SpiceParseError.unterminatedSubcircuit(line: existing.line, name: existing.name)
            }

            for line in topLevel {
                try emit(line: line, scope: Scope())
            }

            try resolveDevices()

            guard sawContent, !elements.isEmpty else { throw SpiceParseError.empty }
            guard nodeIndex["0"] != nil else { throw SpiceParseError.missingGround }

            return ParsedSpiceNetlist(
                circuit: LinearCircuit(nodeNames: nodeNames, elements: elements),
                analysis: analysis
            )
        }

        // MARK: Directives

        private func handleDirective(tokens: [String], line: Int, text: String) throws {
            switch tokens[0].lowercased() {
            case ".ac":
                analysis.hasAC = true
                try SpiceNetlistParser.parseAC(tokens: tokens, line: line, text: text, into: &analysis)
            case ".op":
                analysis.hasOperatingPoint = true
            case ".tran":
                analysis.hasTransient = true
                try SpiceNetlistParser.parseTran(tokens: tokens, line: line, text: text, into: &analysis)
            case ".end":
                break
            default:
                throw SpiceParseError.unsupportedCard(line: line, text: text)
            }
            sawContent = true
        }

        private func makeSubcircuit(tokens: [String], line: Int, text: String) throws -> SubcircuitDefinition {
            guard tokens.count >= 2 else { throw SpiceParseError.malformed(line: line, text: text) }
            let name = tokens[1]
            var ports: [String] = []
            var defaults: [(key: String, expression: String)] = []
            var inParameters = false
            for token in tokens.dropFirst(2) {
                if token.lowercased() == "params:" {
                    inParameters = true
                } else if let equals = token.firstIndex(of: "=") {
                    let key = String(token[..<equals]).uppercased()
                    let expression = SpiceNetlistParser.unwrapBraces(String(token[token.index(after: equals)...]))
                    defaults.append((key: key, expression: expression))
                    inParameters = true
                } else if inParameters {
                    throw SpiceParseError.malformed(line: line, text: text)
                } else {
                    ports.append(token)
                }
            }
            return SubcircuitDefinition(name: name, ports: ports, parameterDefaults: defaults, body: [], line: line)
        }

        // MARK: Nodes and names

        private func node(_ name: String) -> Int {
            let key = name.uppercased()
            if let existing = nodeIndex[key] { return existing }
            let index = nodeNames.count
            nodeIndex[key] = index
            nodeNames.append(name)
            return index
        }

        private func resolveNode(_ raw: String, scope: Scope) -> Int {
            let key = raw.uppercased()
            if key == "0" { return 0 }
            if let external = scope.portNodes[key] { return external }
            if scope.namePrefix.isEmpty { return node(raw) }
            // Internal nodes are private to each instance, so they carry the
            // instance's name prefix to stay unique in the flattened circuit.
            return node("\(scope.namePrefix)\(raw)")
        }

        private func scopedName(_ local: String, scope: Scope) -> String {
            scope.namePrefix.isEmpty ? local : "\(scope.namePrefix)\(local)"
        }

        private func resolveValue(_ token: String, scope: Scope, line: SubcircuitLine) throws -> Double {
            try SpiceNetlistParser.evaluateValue(token, params: scope.parameters, line: line.number, text: line.text)
        }

        // MARK: Element emission

        private func emit(line: SubcircuitLine, scope: Scope) throws {
            let stripped = line.text
            let tokens = SpiceNetlistParser.splitTokens(stripped)
            if let first = tokens.first, first.hasPrefix(".") {
                // `.model` cards are collected globally in the scan pass; any
                // other directive is not valid inside a subcircuit body.
                if first.lowercased() == ".model" { return }
                throw SpiceParseError.unsupportedCard(line: line.number, text: stripped)
            }
            guard tokens.count >= 3 else {
                throw SpiceParseError.malformed(line: line.number, text: stripped)
            }
            let name = tokens[0]
            guard let kindLetter = name.uppercased().first else {
                throw SpiceParseError.malformed(line: line.number, text: stripped)
            }
            let localName = scopedName(name, scope: scope)

            switch kindLetter {
            case "R", "C", "L":
                guard tokens.count >= 4 else { throw SpiceParseError.malformed(line: line.number, text: stripped) }
                let value = try resolveValue(tokens[3], scope: scope, line: line)
                let kind: LinearCircuit.ElementKind = kindLetter == "R" ? .resistor : (kindLetter == "C" ? .capacitor : .inductor)
                elements.append(.init(
                    kind: kind,
                    nodeA: resolveNode(tokens[1], scope: scope),
                    nodeB: resolveNode(tokens[2], scope: scope),
                    value: value,
                    name: localName
                ))
            case "V", "I":
                guard tokens.count >= 4 else { throw SpiceParseError.malformed(line: line.number, text: stripped) }
                let rawSpec = tokens.dropFirst(3).joined(separator: " ")
                let spec = try SpiceNetlistParser.substituteParameters(
                    in: rawSpec,
                    params: scope.parameters,
                    line: line.number,
                    text: stripped
                )
                let source = try SpiceNetlistParser.parseSource(spec, line: line.number, text: stripped)
                let kind: LinearCircuit.ElementKind = kindLetter == "V" ? .voltageSource : .currentSource
                elements.append(.init(
                    kind: kind,
                    nodeA: resolveNode(tokens[1], scope: scope),
                    nodeB: resolveNode(tokens[2], scope: scope),
                    value: source.ac ?? source.dc ?? 0,
                    phaseDegrees: source.phaseDegrees,
                    dcValue: source.dc,
                    acValue: source.ac,
                    transient: source.waveform,
                    name: localName
                ))
            case "D":
                guard tokens.count >= 4 else { throw SpiceParseError.malformed(line: line.number, text: stripped) }
                let area = tokens.count >= 5 ? try resolveValue(tokens[4], scope: scope, line: line) : 1.0
                pendingDiodes.append(PendingDiode(
                    name: localName,
                    anode: resolveNode(tokens[1], scope: scope),
                    cathode: resolveNode(tokens[2], scope: scope),
                    model: tokens[3].uppercased(),
                    area: area,
                    line: line.number
                ))
            case "Q":
                // Q<name> <collector> <base> <emitter> <model>
                guard tokens.count >= 5 else { throw SpiceParseError.malformed(line: line.number, text: stripped) }
                pendingBJTs.append(PendingBJT(
                    name: localName,
                    collector: resolveNode(tokens[1], scope: scope),
                    base: resolveNode(tokens[2], scope: scope),
                    emitter: resolveNode(tokens[3], scope: scope),
                    model: tokens[4].uppercased(),
                    line: line.number
                ))
            case "X":
                try instantiate(tokens: tokens, scope: scope, line: line)
            default:
                throw SpiceParseError.unsupportedElement(line: line.number, name: name)
            }
            sawContent = true
        }

        private func instantiate(tokens: [String], scope: Scope, line: SubcircuitLine) throws {
            var nodeTokens: [String] = []
            var parameterTokens: [String] = []
            for token in tokens.dropFirst() {
                if token.contains("=") {
                    parameterTokens.append(token)
                } else if token.lowercased() == "params:" {
                    continue
                } else {
                    nodeTokens.append(token)
                }
            }
            guard let subcircuitToken = nodeTokens.last else {
                throw SpiceParseError.malformed(line: line.number, text: line.text)
            }
            let externalTokens = Array(nodeTokens.dropLast())
            let key = subcircuitToken.uppercased()
            guard let definition = subcircuits[key] else {
                throw SpiceParseError.unknownSubcircuit(line: line.number, name: subcircuitToken)
            }
            guard externalTokens.count == definition.ports.count else {
                throw SpiceParseError.subcircuitPortMismatch(
                    line: line.number,
                    name: definition.name,
                    expected: definition.ports.count,
                    found: externalTokens.count
                )
            }
            guard !scope.callStack.contains(key), scope.callStack.count < 32 else {
                throw SpiceParseError.recursiveSubcircuit(line: line.number, name: definition.name)
            }

            var child = Scope()
            child.namePrefix = "\(scope.namePrefix)\(tokens[0])."
            child.callStack = scope.callStack + [key]

            var parameters: [String: Double] = [:]
            for (name, expression) in definition.parameterDefaults {
                parameters[name.uppercased()] = try SpiceNetlistParser.evaluate(
                    expression, params: parameters, line: line.number, text: line.text
                )
            }
            for token in parameterTokens {
                let pair = token.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { continue }
                let name = String(pair[0]).uppercased()
                let expression = SpiceNetlistParser.unwrapBraces(String(pair[1]))
                parameters[name] = try SpiceNetlistParser.evaluate(
                    expression, params: parameters, line: line.number, text: line.text
                )
            }
            child.parameters = parameters

            // External nodes are resolved in the parent's scope, so a nested
            // instance can connect to its parent's ports and internal nodes.
            for (port, external) in zip(definition.ports, externalTokens) {
                child.portNodes[port.uppercased()] = resolveNode(external, scope: scope)
            }

            for bodyLine in definition.body {
                try emit(line: bodyLine, scope: child)
            }
        }

        // MARK: Device resolution

        private func resolveDevices() throws {
            // Diodes are resolved once every `.model` card has been read; a
            // model's series resistance expands to an internal series resistor.
            for pending in pendingDiodes {
                guard let definition = diodeModels[pending.model] else {
                    throw SpiceParseError.missingModel(line: pending.line, name: pending.model)
                }
                let parameters = LinearCircuit.DiodeParameters(
                    saturationCurrent: definition.saturationCurrent,
                    emissionCoefficient: definition.emissionCoefficient,
                    area: pending.area
                )
                if definition.seriesResistance > 0 {
                    let internalNode = nodeNames.count
                    nodeNames.append("\(pending.name)_SER")
                    elements.append(.init(
                        kind: .resistor,
                        nodeA: pending.anode,
                        nodeB: internalNode,
                        value: definition.seriesResistance,
                        name: "R\(pending.name)_SER"
                    ))
                    elements.append(.init(
                        kind: .diode,
                        nodeA: internalNode,
                        nodeB: pending.cathode,
                        value: 0,
                        diode: parameters,
                        name: pending.name
                    ))
                } else {
                    elements.append(.init(
                        kind: .diode,
                        nodeA: pending.anode,
                        nodeB: pending.cathode,
                        value: 0,
                        diode: parameters,
                        name: pending.name
                    ))
                }
            }

            for pending in pendingBJTs {
                guard let definition = bjtModels[pending.model] else {
                    throw SpiceParseError.missingModel(line: pending.line, name: pending.model)
                }
                elements.append(.init(
                    kind: .bjt,
                    nodeA: pending.collector,
                    nodeB: pending.emitter,
                    nodeC: pending.base,
                    value: 0,
                    bjt: LinearCircuit.BJTParameters(
                        polarity: definition.polarity,
                        saturationCurrent: definition.saturationCurrent,
                        forwardBeta: definition.forwardBeta,
                        reverseBeta: definition.reverseBeta
                    ),
                    name: pending.name
                ))
            }
        }
    }

    // MARK: - Helpers

    private static func stripComment(_ line: String) -> String {
        if let semicolon = line.firstIndex(of: ";") {
            return String(line[line.startIndex..<semicolon])
        }
        return line
    }

    /// Splits a line on whitespace, but never inside `{…}`, so parameter
    /// expressions like `{R + R}` remain a single token.
    private static func splitTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            if character == "{" {
                depth += 1
                current.append(character)
            } else if character == "}" {
                depth = max(0, depth - 1)
                current.append(character)
            } else if (character == " " || character == "\t") && depth == 0 {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    // MARK: - Parameters

    /// Removes a single pair of enclosing braces, e.g. `{2*k}` -> `2*k`.
    private static func unwrapBraces(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}"), trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    /// Resolves a single value token: a numeric literal (with optional suffix),
    /// a bare parameter name, or a `{expression}` over parameters and numbers.
    private static func evaluateValue(
        _ token: String,
        params: [String: Double],
        line: Int,
        text: String
    ) throws -> Double {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("{") {
            return try evaluate(unwrapBraces(trimmed), params: params, line: line, text: text)
        }
        if params[trimmed.uppercased()] != nil {
            return try evaluate(trimmed, params: params, line: line, text: text)
        }
        return try parseNumber(trimmed, line: line)
    }

    /// Replaces every `{expression}` in a source specification with its value,
    /// leaving plain numbers and keywords untouched.
    private static func substituteParameters(
        in spec: String,
        params: [String: Double],
        line: Int,
        text: String
    ) throws -> String {
        guard spec.contains("{") else { return spec }
        var result = ""
        var index = spec.startIndex
        while index < spec.endIndex {
            let character = spec[index]
            if character == "{" {
                guard let close = spec[index...].firstIndex(of: "}") else {
                    throw SpiceParseError.invalidValue(line: line, text: spec)
                }
                let expression = String(spec[spec.index(after: index)..<close])
                let value = try evaluate(expression, params: params, line: line, text: text)
                result += String(format: "%.12g", value)
                index = spec.index(after: close)
            } else {
                result.append(character)
                index = spec.index(after: index)
            }
        }
        return result
    }

    private static func evaluate(
        _ expression: String,
        params: [String: Double],
        line: Int,
        text: String
    ) throws -> Double {
        var evaluator = ExpressionEvaluator(expression: expression, params: params, line: line, text: text)
        return try evaluator.evaluate()
    }

    /// A minimal arithmetic evaluator for `{…}` parameter expressions. It
    /// supports `+ - * /`, parentheses, unary sign, parameter names, and numeric
    /// literals with SPICE engineering suffixes.
    private struct ExpressionEvaluator {
        private enum Token {
            case number(Double)
            case identifier(String)
            case op(Character)
            case leftParen
            case rightParen
        }

        private let tokens: [Token]
        private var index = 0
        private let params: [String: Double]
        private let line: Int
        private let text: String

        init(expression: String, params: [String: Double], line: Int, text: String) {
            self.tokens = ExpressionEvaluator.tokenize(expression, line: line)
            self.params = params
            self.line = line
            self.text = text
        }

        mutating func evaluate() throws -> Double {
            let value = try expression()
            guard index == tokens.count else {
                throw SpiceParseError.invalidValue(line: line, text: text)
            }
            return value
        }

        private mutating func expression() throws -> Double {
            var value = try term()
            while index < tokens.count, case .op(let op) = tokens[index], op == "+" || op == "-" {
                index += 1
                let rhs = try term()
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        private mutating func term() throws -> Double {
            var value = try factor()
            while index < tokens.count, case .op(let op) = tokens[index], op == "*" || op == "/" {
                index += 1
                let rhs = try factor()
                value = op == "*" ? value * rhs : value / rhs
            }
            return value
        }

        private mutating func factor() throws -> Double {
            guard index < tokens.count else {
                throw SpiceParseError.invalidValue(line: line, text: text)
            }
            switch tokens[index] {
            case .number(let value):
                index += 1
                return value
            case .identifier(let name):
                index += 1
                guard let value = params[name.uppercased()] else {
                    throw SpiceParseError.unknownParameter(line: line, name: name)
                }
                return value
            case .op(let op) where op == "-":
                index += 1
                return -(try factor())
            case .op(let op) where op == "+":
                index += 1
                return try factor()
            case .leftParen:
                index += 1
                let value = try expression()
                guard index < tokens.count, case .rightParen = tokens[index] else {
                    throw SpiceParseError.invalidValue(line: line, text: text)
                }
                index += 1
                return value
            default:
                throw SpiceParseError.invalidValue(line: line, text: text)
            }
        }

        private static func tokenize(_ expression: String, line: Int) -> [Token] {
            var tokens: [Token] = []
            var current = ""
            func flush() {
                guard !current.isEmpty else { return }
                if let value = try? SpiceNetlistParser.parseNumber(current, line: line) {
                    tokens.append(.number(value))
                } else {
                    tokens.append(.identifier(current))
                }
                current = ""
            }
            for character in expression {
                switch character {
                case "+", "-":
                    // Keep a sign that belongs to an exponent, e.g. `1e-3`.
                    if let last = current.last, last == "e" || last == "E" {
                        current.append(character)
                    } else {
                        flush()
                        tokens.append(.op(character))
                    }
                case "*", "/":
                    flush()
                    tokens.append(.op(character))
                case "(":
                    flush()
                    tokens.append(.leftParen)
                case ")":
                    flush()
                    tokens.append(.rightParen)
                case " ", "\t", "\n":
                    flush()
                default:
                    current.append(character)
                }
            }
            flush()
            return tokens
        }
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

    /// Parses `.model <name> D(<params>)` or `.model <name> NPN|PNP(<params>)`.
    /// Unknown parameters are ignored so standard cards load.
    private static func parseModel(
        _ text: String,
        line: Int,
        into models: inout [String: DiodeModelDefinition],
        bjtModels: inout [String: BJTModelDefinition]
    ) throws {
        var body = text
        if body.lowercased().hasPrefix(".model") {
            body = String(body.dropFirst(".model".count))
        }
        let parts = body.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            .map(String.init)
        guard parts.count >= 2 else { throw SpiceParseError.invalidAnalysis(line: line, text: text) }

        var typeToken = parts[1]
        if let paren = typeToken.firstIndex(of: "(") {
            typeToken = String(typeToken[..<paren])
        }
        let type = typeToken.uppercased()

        var paramText = String(parts[1].dropFirst(typeToken.count))
        if parts.count > 2 { paramText += " " + parts[2] }
        let values = parseKeyValues(paramText, line: line)
        let name = parts[0].uppercased()

        switch type {
        case "D":
            var definition = DiodeModelDefinition()
            if let isat = values["IS"] { definition.saturationCurrent = isat }
            if let n = values["N"] { definition.emissionCoefficient = n }
            if let rs = values["RS"] { definition.seriesResistance = rs }
            models[name] = definition
        case "NPN", "PNP":
            var definition = BJTModelDefinition()
            definition.polarity = type == "PNP" ? .pnp : .npn
            if let isat = values["IS"] { definition.saturationCurrent = isat }
            if let bf = values["BF"] { definition.forwardBeta = bf }
            if let br = values["BR"] { definition.reverseBeta = br }
            bjtModels[name] = definition
        default:
            throw SpiceParseError.unsupportedCard(line: line, text: text)
        }
    }

    private static func parseKeyValues(_ text: String, line: Int) -> [String: Double] {
        var result: [String: Double] = [:]
        let cleaned = text
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
        for token in cleaned.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," }) {
            let pair = token.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            if let value = try? parseNumber(String(pair[1]), line: line) {
                result[pair[0].uppercased()] = value
            }
        }
        return result
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
