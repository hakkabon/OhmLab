// SExpression.swift
// A small, lossless reader for the S-expression syntax used by KiCad's
// `.kicad_sch` and `.kicad_sym` files.
//
// The reader keeps quoted strings distinct from bare atoms because KiCad uses
// both (`(label "OUT")` versus `(at 1.27 0 90)`). It does not interpret the
// tree; the KiCad reader does that on top.

import Foundation

/// One node in an S-expression tree.
public indirect enum SExpression: Equatable, Sendable {
    /// An unquoted token such as `kicad_sch`, `at`, or `1.27`.
    case atom(String)
    /// A quoted string such as `"Device:R"`.
    case string(String)
    /// A parenthesised list.
    case list([SExpression])

    public var atom: String? {
        if case .atom(let value) = self { return value }
        return nil
    }

    /// The value of an atom or quoted string.
    public var text: String? {
        switch self {
        case .atom(let value), .string(let value): return value
        case .list: return nil
        }
    }

    public var list: [SExpression]? {
        if case .list(let values) = self { return values }
        return nil
    }

    public var double: Double? {
        guard let text else { return nil }
        return Double(text)
    }

    public var int: Int? {
        guard let text else { return nil }
        return Int(text)
    }

    /// The first direct child list whose head atom is `name`.
    public func first(_ name: String) -> SExpression? {
        guard case .list(let values) = self else { return nil }
        return values.first { $0.list?.first?.atom == name }
    }

    /// Every direct child list whose head atom is `name`.
    public func all(_ name: String) -> [SExpression] {
        guard case .list(let values) = self else { return [] }
        return values.filter { $0.list?.first?.atom == name }
    }

    /// The arguments of this node itself (its list without the head atom).
    public var ownArguments: [SExpression] {
        guard case .list(let values) = self else { return [] }
        return Array(values.dropFirst())
    }

    /// The arguments of the first direct child list whose head atom is `name`.
    public func arguments(of name: String) -> [SExpression]? {
        guard let child = first(name) else { return nil }
        return child.ownArguments
    }

    /// The arguments of every direct child list whose head atom is `name`.
    public func argumentLists(of name: String) -> [[SExpression]] {
        all(name).map(\.ownArguments)
    }

    /// The first argument of the first child list named `name`.
    public func value(of name: String) -> String? {
        arguments(of: name)?.first?.text
    }

    /// Convenience for `(property "Name" "Value" …)`.
    public func property(_ name: String) -> String? {
        for entry in all("property") {
            let arguments = entry.ownArguments
            guard arguments.count >= 2, arguments[0].text == name else { continue }
            return arguments[1].text
        }
        return nil
    }
}

public enum SExpressionError: LocalizedError, Equatable {
    case empty
    case unexpectedEnd
    case unexpectedCharacter(Character, offset: Int)
    case unexpectedClose(offset: Int)
    case trailingData(offset: Int)
    case unterminatedString(offset: Int)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "The file contains no S-expression."
        case .unexpectedEnd:
            return "The S-expression ends before its closing parenthesis."
        case .unexpectedCharacter(let character, let offset):
            return "Unexpected character “\(character)” at offset \(offset)."
        case .unexpectedClose(let offset):
            return "Unexpected “)” at offset \(offset)."
        case .trailingData(let offset):
            return "Unexpected data after the root S-expression at offset \(offset)."
        case .unterminatedString(let offset):
            return "Unterminated string starting at offset \(offset)."
        }
    }
}

public enum SExpressionParser {
    /// Parses exactly one root list, tolerating surrounding whitespace and a
    /// leading UTF-8 byte-order mark.
    public static func parse(_ text: String) throws -> SExpression {
        var parser = Parser(text: text)
        let value = try parser.parseRoot()
        try parser.ensureFinished()
        return value
    }

    private struct Parser {
        let characters: [Character]
        var index = 0

        init(text: String) {
            var cleaned = text
            if cleaned.first == "\u{FEFF}" { cleaned.removeFirst() }
            characters = Array(cleaned)
        }

        mutating func parseRoot() throws -> SExpression {
            skipWhitespace()
            guard index < characters.count else { throw SExpressionError.empty }
            let value = try parseValue()
            return value
        }

        mutating func ensureFinished() throws {
            skipWhitespace()
            guard index < characters.count else { return }
            throw SExpressionError.trailingData(offset: index)
        }

        mutating func parseValue() throws -> SExpression {
            skipWhitespace()
            guard index < characters.count else { throw SExpressionError.unexpectedEnd }
            switch characters[index] {
            case "(":
                return try parseList()
            case ")":
                throw SExpressionError.unexpectedClose(offset: index)
            case "\"":
                return try parseString()
            default:
                return try parseAtom()
            }
        }

        mutating func parseList() throws -> SExpression {
            precondition(characters[index] == "(")
            index += 1
            var values: [SExpression] = []
            while true {
                skipWhitespace()
                guard index < characters.count else { throw SExpressionError.unexpectedEnd }
                if characters[index] == ")" {
                    index += 1
                    return .list(values)
                }
                values.append(try parseValue())
            }
        }

        mutating func parseString() throws -> SExpression {
            let start = index
            precondition(characters[index] == "\"")
            index += 1
            var value = ""
            while index < characters.count {
                let character = characters[index]
                index += 1
                if character == "\"" {
                    return .string(value)
                }
                if character == "\\" {
                    guard index < characters.count else {
                        throw SExpressionError.unterminatedString(offset: start)
                    }
                    let escaped = characters[index]
                    index += 1
                    switch escaped {
                    case "n": value.append("\n")
                    case "r": value.append("\r")
                    case "t": value.append("\t")
                    case "\\": value.append("\\")
                    case "\"": value.append("\"")
                    case "x":
                        let digits = characters[index..<min(index + 2, characters.count)]
                        if digits.count == 2, let scalar = UInt32(String(digits), radix: 16),
                           let unicode = UnicodeScalar(scalar) {
                            value.append(Character(unicode))
                            index += 2
                        } else {
                            value.append("x")
                        }
                    default:
                        // KiCad occasionally escapes other characters; keep the
                        // literal so no information is lost.
                        value.append(escaped)
                    }
                } else {
                    value.append(character)
                }
            }
            throw SExpressionError.unterminatedString(offset: start)
        }

        mutating func parseAtom() throws -> SExpression {
            let start = index
            while index < characters.count {
                let character = characters[index]
                if character.isWhitespace || character == "(" || character == ")" || character == "\"" {
                    break
                }
                index += 1
            }
            guard index > start else {
                throw SExpressionError.unexpectedCharacter(characters[index], offset: index)
            }
            return .atom(String(characters[start..<index]))
        }

        mutating func skipWhitespace() {
            while index < characters.count, characters[index].isWhitespace {
                index += 1
            }
        }
    }
}
