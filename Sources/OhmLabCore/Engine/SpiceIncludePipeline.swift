// SpiceIncludePipeline.swift
// Resolves `.include`/`.lib` cards into a self-contained netlist.
//
// Imported netlists are usually not self-contained: they point at sibling model
// files, sometimes through several levels of includes. This pipeline reads those
// files, extracts `.lib <file> <section>` bodies, and rewrites the netlist so
// simulation and export no longer depend on the original directory layout.
//
// Resolution is deliberately best-effort. A missing or oversized file is
// reported as a warning and its card is left in place so the regular parser (or
// a later import) can still try to resolve it. A cycle is replaced by a comment
// so the rewritten netlist cannot reintroduce it.

import Foundation

/// The result of resolving every `.include`/`.lib` card in a netlist.
public struct SpiceInlinedNetlist: Equatable, Sendable {
    /// The rewritten netlist. Unresolved cards remain in this text.
    public var text: String
    /// Non-fatal notes about cards that were skipped or rewritten.
    public var warnings: [String]
    /// Include paths that could not be inlined and were left in `text`.
    public var unresolvedCards: [String]

    /// True when every include card was resolved.
    public var isFullyResolved: Bool { unresolvedCards.isEmpty }

    public init(text: String, warnings: [String] = [], unresolvedCards: [String] = []) {
        self.text = text
        self.warnings = warnings
        self.unresolvedCards = unresolvedCards
    }
}

public enum SpiceIncludePipeline {
    /// Maximum number of nested include files below the root netlist.
    public static let maximumNestingDepth = 16
    /// Maximum number of bytes read from included files.
    public static let maximumExpandedBytes = 16 * 1024 * 1024

    /// Inlines every `.include`/`.lib` card reachable from `text`.
    ///
    /// Relative paths are resolved against the directory of the file that
    /// contains the card, then against `baseDirectory`, then against the
    /// directory of every imported model library. This mirrors
    /// `SpiceLibraryManager.includeResolver(relativeTo:)` while also supporting
    /// includes nested inside other include files.
    public static func inline(
        _ text: String,
        baseDirectory: URL? = nil,
        libraries: [SpiceModelLibrary] = [],
        maximumDepth: Int = maximumNestingDepth,
        maximumBytes: Int = maximumExpandedBytes
    ) -> SpiceInlinedNetlist {
        var expander = Expander(
            baseDirectory: baseDirectory,
            libraries: libraries,
            maximumDepth: maximumDepth,
            maximumBytes: maximumBytes
        )
        let resolved = expander.expand(text, relativeTo: baseDirectory, depth: 0)
        return SpiceInlinedNetlist(
            text: resolved,
            warnings: expander.warnings,
            unresolvedCards: expander.unresolvedCards
        )
    }

    private struct Expander {
        let baseDirectory: URL?
        let libraryDirectories: [URL]
        let maximumDepth: Int
        let maximumBytes: Int

        var warnings: [String] = []
        var unresolvedCards: [String] = []
        /// Bytes read from included files so far.
        var expandedBytes = 0
        /// Canonical paths of the files currently being expanded, used to stop
        /// cycles without rejecting the same file included from two branches.
        var stack: [String] = []

        init(
            baseDirectory: URL?,
            libraries: [SpiceModelLibrary],
            maximumDepth: Int,
            maximumBytes: Int
        ) {
            self.baseDirectory = baseDirectory
            self.libraryDirectories = libraries.compactMap { library in
                library.sourcePath.map {
                    URL(fileURLWithPath: $0).deletingLastPathComponent()
                }
            }
            self.maximumDepth = maximumDepth
            self.maximumBytes = maximumBytes
        }

        mutating func expand(_ text: String, relativeTo directory: URL?, depth: Int) -> String {
            // Fold `+` continuation lines first so a card split across lines is
            // still recognized. Folding preserves the line count.
            let folded = SpiceNetlistParser.foldContinuations(text)
            let lines = folded.components(separatedBy: .newlines)
            var output: [String] = []
            output.reserveCapacity(lines.count)

            for (offset, rawLine) in lines.enumerated() {
                let lineNumber = offset + 1
                let stripped = SpiceNetlistParser.stripComment(rawLine)
                    .trimmingCharacters(in: .whitespaces)
                let tokens = SpiceNetlistParser.splitTokens(stripped)
                guard let directive = tokens.first?.lowercased() else {
                    output.append(rawLine)
                    continue
                }

                // `.endl` only terminates a `.lib` section. A whole-file include
                // may bring one along; the section body itself is already in the
                // output, so the marker is dropped.
                if directive == ".endl" {
                    output.append("")
                    continue
                }

                guard directive == ".include" || directive == ".lib" else {
                    output.append(rawLine)
                    continue
                }

                let path = SpiceNetlistParser.unquoted(tokens.count >= 2 ? tokens[1] : "")
                guard !path.isEmpty else {
                    warnings.append("Skipped \(directive) card with no path (line \(lineNumber)).")
                    output.append(rawLine)
                    continue
                }

                // A two-token `.lib <section>` is a section marker inside a
                // library file, not an include. Paths carry a slash, a dot, or
                // a tilde; section names generally do not.
                if directive == ".lib", tokens.count == 2,
                   !path.contains("/"), !path.contains("."), !path.hasPrefix("~") {
                    output.append("")
                    continue
                }

                guard depth < maximumDepth else {
                    warnings.append(
                        "Stopped expanding .include: nesting is too deep at \"\(path)\" (line \(lineNumber))."
                    )
                    unresolvedCards.append(path)
                    output.append(rawLine)
                    continue
                }

                guard let url = resolve(path, relativeTo: directory) else {
                    warnings.append("Skipped \(directive) \"\(path)\": file could not be resolved.")
                    unresolvedCards.append(path)
                    output.append(rawLine)
                    continue
                }

                let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard !stack.contains(canonical) else {
                    warnings.append("Skipped cyclic \(directive) \"\(path)\".")
                    unresolvedCards.append(path)
                    // Drop the card so the resolved text cannot reintroduce the
                    // cycle when it is parsed or exported.
                    output.append("* Skipped cyclic \(directive) \"\(path)\".")
                    continue
                }

                guard let data = try? Data(contentsOf: url),
                      let contents = String(data: data, encoding: .utf8) else {
                    warnings.append("Skipped \(directive) \"\(path)\": file could not be read.")
                    unresolvedCards.append(path)
                    output.append(rawLine)
                    continue
                }

                guard expandedBytes + data.count <= maximumBytes else {
                    warnings.append("Skipped \(directive) \"\(path)\": expanded netlist is too large.")
                    unresolvedCards.append(path)
                    output.append(rawLine)
                    continue
                }

                var body = contents
                if directive == ".lib", tokens.count >= 3 {
                    let section = SpiceNetlistParser.unquoted(tokens[2])
                    guard let extracted = SpiceNetlistParser.librarySection(
                        named: section,
                        in: body
                    ) else {
                        warnings.append(
                            "Skipped .lib \"\(path)\" section \"\(section)\": section not found."
                        )
                        unresolvedCards.append(path)
                        output.append(rawLine)
                        continue
                    }
                    body = extracted
                }

                expandedBytes += data.count
                stack.append(canonical)
                output.append(
                    expand(
                        body,
                        relativeTo: url.deletingLastPathComponent(),
                        depth: depth + 1
                    )
                )
                stack.removeLast()
            }
            return output.joined(separator: "\n")
        }

        private func resolve(_ path: String, relativeTo directory: URL?) -> URL? {
            let expanded = (path as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                let url = URL(fileURLWithPath: expanded)
                return FileManager.default.fileExists(atPath: url.path)
                    ? url.standardizedFileURL
                    : nil
            }

            var directories: [URL] = []
            if let directory { directories.append(directory) }
            if let baseDirectory,
               baseDirectory.standardizedFileURL != directory?.standardizedFileURL {
                directories.append(baseDirectory)
            }
            directories.append(contentsOf: libraryDirectories)

            for directory in directories {
                let candidate = directory.appendingPathComponent(expanded).standardizedFileURL
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            return nil
        }
    }
}

/// Shared frontend for the engine: inline includes, then parse the netlist.
public enum SpiceNetlistLoader {
    public static func parse(
        _ netlist: String,
        parameterOverrides: [String: Double] = [:],
        libraries: [SpiceModelLibrary] = [],
        baseDirectory: URL? = nil
    ) throws -> ParsedSpiceNetlist {
        let inlined = SpiceIncludePipeline.inline(
            netlist,
            baseDirectory: baseDirectory,
            libraries: libraries
        )
        // The resolver is a fallback for cards the pipeline could not inline
        // (for example when a caller supplies an in-memory library location).
        let include = SpiceLibraryManager(libraries: libraries)
            .includeResolver(relativeTo: baseDirectory)
        var parsed = try SpiceNetlistParser.parse(
            inlined.text,
            include: include,
            parameterOverrides: parameterOverrides,
            libraries: libraries
        )
        parsed.warnings.insert(contentsOf: inlined.warnings, at: 0)
        return parsed
    }
}
