// KiCadInterchange.swift
// Netlist-level interchange with KiCad (and other SPICE tools).
//
// OhmLab does not parse `.kicad_sch` natively; instead it borrows KiCad's own
// exporter (`kicad-cli sch export netlist --format spice`) to obtain a SPICE
// netlist, then reads that with the hardened netlist parser. The reverse
// direction is a plain SPICE netlist, which KiCad/ngspice can open directly.

import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// A SPICE netlist (`.cir`), falling back to plain text when the system has
    /// no declaration for the extension.
    public static let spiceNetlist = UTType(filenameExtension: "cir") ?? .plainText
}

public enum KiCadInterchangeError: LocalizedError {
    case unreadableFile(String)
    case emptyFile(String)
    case unsupportedFormat(String)
    case requiresKiCad(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let name):
            return "Could not read \(name)."
        case .emptyFile(let name):
            return "\(name) contains no netlist text."
        case .unsupportedFormat(let name):
            return "\(name) is not a supported netlist or schematic file."
        case .requiresKiCad(let name):
            return "\(name) is a KiCad schematic; this needs `kicad-cli` on macOS. "
                + "Export a SPICE netlist from KiCad and import that instead."
        }
    }
}

/// A small facade over the two interchange directions:
///
/// * **Import** — a `.kicad_sch` (via `kicad-cli`, macOS only) or a SPICE
///   netlist file (`.cir`/`.net`/`.sp`/…) becomes netlist text the editor and
///   engine can run.
/// * **Export** — a schematic is projected to a SPICE netlist (see
///   `SpiceNetlistBuilder`) that KiCad and ngspice accept as-is.
public enum KiCadInterchange {
    public static let netlistExtensions: Set<String> = ["cir", "net", "sp", "spi", "ckt", "txt"]
    public static let schematicExtensions: Set<String> = ["kicad_sch"]

    /// Reads a SPICE netlist from disk as UTF-8 text.
    public static func readNetlist(at url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else {
            throw KiCadInterchangeError.unreadableFile(url.lastPathComponent)
        }
        let text = String(decoding: data, as: UTF8.self)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KiCadInterchangeError.emptyFile(url.lastPathComponent)
        }
        return text
    }

    /// Parses SPICE netlist text, tolerating the benign control cards KiCad and
    /// ngspice emit (`.title`, `.save`, …).
    public static func parseNetlist(
        _ text: String,
        include: SpiceIncludeResolver? = nil
    ) throws -> ParsedSpiceNetlist {
        try SpiceNetlistParser.parse(text, include: include)
    }

    /// Resolves `.include` paths relative to `directory`, so imported netlists
    /// that pull in model libraries load correctly.
    public static func fileIncludeResolver(relativeTo directory: URL) -> SpiceIncludeResolver {
        { path in
            let candidate: URL
            if path.hasPrefix("/") {
                candidate = URL(fileURLWithPath: path)
            } else {
                candidate = directory.appendingPathComponent(path)
            }
            return (try? String(contentsOf: candidate, encoding: .utf8))
        }
    }

    #if os(macOS)
    /// Converts a `.kicad_sch` schematic to a SPICE netlist via `kicad-cli` and
    /// returns the netlist text exactly as KiCad wrote it.
    public static func exportedNetlistText(at url: URL, executable: URL? = nil) throws -> String {
        try KiCadCLIClient.exportSpiceNetlist(from: url, executable: executable)
    }

    /// Converts a `.kicad_sch` schematic to a SPICE netlist via `kicad-cli` and
    /// parses it.
    public static func importSchematic(
        at url: URL,
        executable: URL? = nil
    ) throws -> ParsedSpiceNetlist {
        let text = try exportedNetlistText(at: url, executable: executable)
        return try parseNetlist(text, include: fileIncludeResolver(relativeTo: url.deletingLastPathComponent()))
    }
    #else
    /// `.kicad_sch` import needs `kicad-cli`, which is macOS only. On other
    /// platforms a SPICE netlist export of the schematic should be imported.
    public static func exportedNetlistText(at url: URL, executable: URL? = nil) throws -> String {
        throw KiCadInterchangeError.requiresKiCad(url.lastPathComponent)
    }

    public static func importSchematic(
        at url: URL,
        executable: URL? = nil
    ) throws -> ParsedSpiceNetlist {
        throw KiCadInterchangeError.requiresKiCad(url.lastPathComponent)
    }
    #endif

    /// Projects a schematic to a SPICE netlist KiCad/ngspice can open.
    @MainActor
    public static func exportNetlist(from document: SchematicDocument) throws -> String {
        try SpiceNetlistBuilder.build(from: document)
    }

    /// Writes netlist text to disk as UTF-8.
    public static func writeNetlist(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
