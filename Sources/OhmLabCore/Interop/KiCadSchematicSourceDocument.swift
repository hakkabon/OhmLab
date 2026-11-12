// KiCadSchematicSourceDocument.swift
// Lossless view of an existing `.kicad_sch` file for non-destructive writes.
//
// The writer can regenerate a whole schematic from OhmLab's model, but that
// discards the parts of a KiCad drawing OhmLab does not model: wire geometry,
// junctions, page settings, title blocks, graphics, custom fields, and
// unsupported symbols. Preservation mode therefore starts from the source
// document and replaces only the top-level nodes whose model objects changed.
//
// The document records each top-level child with its exact source text,
// including the whitespace before it. Reassembling an untouched document is
// byte-identical; a patched node is re-serialised canonically in place while
// every other node keeps its original bytes.

import Foundation

/// One top-level child of a `.kicad_sch` root list.
struct KiCadSourceNode: Equatable, Sendable {
    /// Whitespace between the previous node (or the root open paren) and this
    /// node. Kept so an untouched file round-trips byte-for-byte.
    var trivia: String
    /// The exact source text of the node, from `(` through `)`.
    var raw: String
    /// The parsed node.
    var value: SExpression
    /// The head atom (`symbol`, `wire`, `label`, …).
    var kind: String
    /// The node's direct `(uuid …)` child, when it has one.
    var uuid: UUID?

    init(trivia: String, raw: String, value: SExpression, kind: String, uuid: UUID?) {
        self.trivia = trivia
        self.raw = raw
        self.value = value
        self.kind = kind
        self.uuid = uuid
    }

    /// Builds a replacement node for `value`, keeping this node's trivia.
    func replacing(value: SExpression, kind: String? = nil, uuid: UUID? = nil) -> KiCadSourceNode {
        KiCadSourceNode(
            trivia: trivia,
            raw: KiCadSExpressionWriter.text(value),
            value: value,
            kind: kind ?? self.kind,
            uuid: uuid ?? self.uuid
        )
    }
}

/// A `.kicad_sch` file split into its root envelope and top-level children.
struct KiCadSchematicSourceDocument: Equatable, Sendable {
    /// Everything through the root list's opening parenthesis, including a
    /// byte-order mark or leading whitespace when present.
    var prefix: String
    var nodes: [KiCadSourceNode]
    /// From the whitespace before the root closing parenthesis through the end
    /// of the file.
    var suffix: String

    init(text: String) throws {
        let scanned = try KiCadSchematicSourceDocument.scan(text)
        prefix = scanned.prefix
        nodes = scanned.nodes
        suffix = scanned.suffix
    }

    /// The UUID declared by the document's own `(uuid …)` child.
    var rootUUID: UUID? {
        nodes.first { $0.kind == "uuid" }?.value.ownArguments.first?.text
            .flatMap { UUID(uuidString: $0) }
    }

    /// The KiCad file format version, when declared.
    var version: Int? {
        nodes.first { $0.kind == "version" }?.value.ownArguments.first?.text.flatMap(Int.init)
    }

    /// Renders the document, optionally replacing the top-level children.
    func rendered(with nodes: [KiCadSourceNode]? = nil) -> String {
        let children = nodes ?? self.nodes
        return prefix + children.map { $0.trivia + $0.raw }.joined() + suffix
    }

    /// A deterministic newline-plus-indent used when appending a node.
    var defaultTrivia: String {
        nodes.last?.trivia ?? "\n\t"
    }

    /// Finds a top-level node by kind and UUID.
    func node(kind: String, uuid: UUID) -> KiCadSourceNode? {
        nodes.first { $0.kind == kind && $0.uuid == uuid }
    }

    // MARK: - Scanning

    private static func scan(
        _ text: String
    ) throws -> (prefix: String, nodes: [KiCadSourceNode], suffix: String) {
        let characters = Array(text)
        guard !characters.isEmpty else { throw SExpressionError.empty }

        var index = 0
        if characters.first == "\u{FEFF}" { index = 1 }

        while index < characters.count, characters[index].isWhitespace {
            index += 1
        }
        guard index < characters.count, characters[index] == "(" else {
            throw SExpressionError.unexpectedCharacter(
                index < characters.count ? characters[index] : " ",
                offset: index
            )
        }
        let rootOpen = index
        index += 1

        // The root list's head atom (`kicad_sch`) is part of the envelope, not
        // a child node.
        while index < characters.count, characters[index].isWhitespace {
            index += 1
        }
        let headStart = index
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace || character == "(" || character == ")" { break }
            index += 1
        }
        guard index > headStart else {
            throw SExpressionError.unexpectedCharacter("(", offset: rootOpen)
        }
        let prefixEnd = index

        var nodes: [KiCadSourceNode] = []
        var suffixStart = characters.count

        while true {
            let triviaStart = index
            while index < characters.count, characters[index].isWhitespace {
                index += 1
            }
            guard index < characters.count else {
                throw SExpressionError.unexpectedEnd
            }
            if characters[index] == ")" {
                suffixStart = triviaStart
                break
            }

            let nodeStart = index
            var depth = 0
            var inString = false
            var escaped = false
            while index < characters.count {
                let character = characters[index]
                if inString {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        inString = false
                    }
                } else if character == "\"" {
                    inString = true
                } else if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        index += 1
                        break
                    }
                }
                index += 1
            }
            guard depth == 0, !inString else {
                throw SExpressionError.unexpectedEnd
            }

            let nodeEnd = index
            let raw = String(characters[nodeStart..<nodeEnd])
            let value = try SExpressionParser.parse(raw)
            guard case .list(let children) = value,
                  let head = children.first?.atom else {
                throw SExpressionError.unexpectedCharacter("(", offset: nodeStart)
            }
            let uuid = (value.first("uuid")?.ownArguments.first?.text)
                .flatMap { UUID(uuidString: $0) }
            nodes.append(KiCadSourceNode(
                trivia: String(characters[triviaStart..<nodeStart]),
                raw: raw,
                value: value,
                kind: head,
                uuid: uuid
            ))
        }

        return (
            prefix: String(characters[0..<prefixEnd]),
            nodes: nodes,
            suffix: String(characters[suffixStart..<characters.count])
        )
    }
}

/// A small canonical serialiser for patched nodes.
///
/// Only nodes that OhmLab changed pass through here; untouched nodes are
/// emitted from their original bytes. Lists that contain child lists are
/// written one child per line with tab indentation, matching the shape of
/// hand-written KiCad files closely enough to produce a readable diff.
enum KiCadSExpressionWriter {
    static func text(_ expression: SExpression) -> String {
        render(expression, depth: 0)
    }

    private static func render(_ expression: SExpression, depth: Int) -> String {
        switch expression {
        case .atom(let value):
            return value
        case .string(let value):
            return KiCadSymbolLibrary.quoted(value)
        case .list(let children):
            guard !children.isEmpty else { return "()" }
            let compact = children.allSatisfy { child in
                if case .list = child { return false }
                return true
            }
            if compact {
                return "(" + children.map { render($0, depth: depth) }.joined(separator: " ") + ")"
            }
            let indentation = String(repeating: "\t", count: depth + 1)
            let closing = String(repeating: "\t", count: depth)
            // Keep the head and any leading atoms/strings (for example
            // `property "Value" "2k"`) on the opening line, then put child
            // lists on their own lines. This matches KiCad's own shape.
            let leading = children.prefix { $0.text != nil }
            let rest = children.dropFirst(leading.count)
            let firstLine = "(" + leading.map { render($0, depth: depth) }.joined(separator: " ")
            let body = rest
                .map { indentation + render($0, depth: depth + 1) }
                .joined(separator: "\n")
            guard !rest.isEmpty else { return firstLine + ")" }
            return firstLine + "\n" + body + "\n" + closing + ")"
        }
    }
}
