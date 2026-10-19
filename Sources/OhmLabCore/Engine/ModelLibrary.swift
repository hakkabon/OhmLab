import Foundation

/// A `.model`/`.subckt` collection imported from a vendor or vendor-neutral
/// SPICE file (e.g. a transistor library). Importing a library makes its
/// model and subcircuit cards visible to `SpiceNetlistParser.parse` without an
/// explicit `.include`, while cards written directly in the netlist still take
/// precedence.
public struct SpiceModelLibrary: Identifiable, Sendable {
    /// A browsable summary of one imported model definition.
    public struct ModelSummary: Identifiable, Sendable, Equatable {
        public enum Kind: String, Sendable, CaseIterable {
            case diode = "Diode"
            case bjt = "BJT"
            case mosfet = "MOSFET"
            case jfet = "JFET"
        }

        public let name: String
        public let kind: Kind

        public var id: String { "\(kind.rawValue):\(name)" }
    }

    public let id: UUID
    public var name: String
    /// Filesystem location the library was read from, when known.
    public var sourcePath: String?
    public var rawText: String
    /// Non-fatal notes recorded while scanning the file.
    public var warnings: [String]
    /// Every model definition found, sorted by kind then name.
    public var models: [ModelSummary]
    /// Names of the `.subckt` blocks found, sorted.
    public var subcircuitNames: [String]
    /// Parsed definitions used to seed the netlist parser.
    var definitions: LibraryDefinitions

    /// True when the library contributed no models and no subcircuits.
    public var isEmpty: Bool { models.isEmpty && subcircuitNames.isEmpty }

    init(
        id: UUID = UUID(),
        name: String,
        sourcePath: String? = nil,
        rawText: String,
        warnings: [String],
        models: [ModelSummary],
        subcircuitNames: [String],
        definitions: LibraryDefinitions
    ) {
        self.id = id
        self.name = name
        self.sourcePath = sourcePath
        self.rawText = rawText
        self.warnings = warnings
        self.models = models
        self.subcircuitNames = subcircuitNames
        self.definitions = definitions
    }

    /// Scans `text` for `.model` cards and `.subckt` blocks and packages them
    /// into a library. Throws when the text contains no usable definitions.
    public static func parse(
        _ text: String,
        name: String? = nil,
        sourcePath: String? = nil
    ) throws -> SpiceModelLibrary {
        let scanned = SpiceNetlistParser.scanDefinitions(text)
        let definitions = scanned.definitions
        var models: [ModelSummary] = []
        models += definitions.diodeModels.keys.map { ModelSummary(name: $0, kind: .diode) }
        models += definitions.bjtModels.keys.map { ModelSummary(name: $0, kind: .bjt) }
        models += definitions.mosfetModels.keys.map { ModelSummary(name: $0, kind: .mosfet) }
        models += definitions.jfetModels.keys.map { ModelSummary(name: $0, kind: .jfet) }
        models.sort { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
        let subcircuits = definitions.subcircuits.keys.sorted()

        let resolvedName = name?.isEmpty == false
            ? name!
            : (sourcePath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Model Library")

        let library = SpiceModelLibrary(
            name: resolvedName,
            sourcePath: sourcePath,
            rawText: text,
            warnings: scanned.warnings,
            models: models,
            subcircuitNames: subcircuits,
            definitions: definitions
        )
        guard !library.isEmpty else { throw SpiceModelLibraryError.noDefinitions(fileName: resolvedName) }
        return library
    }
}

public enum SpiceModelLibraryError: LocalizedError, Equatable {
    case noDefinitions(fileName: String)
    case unreadable(fileName: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .noDefinitions(fileName):
            return "“\(fileName)” contains no .model cards or .subckt blocks."
        case let .unreadable(fileName, reason):
            return "Could not read “\(fileName)”: \(reason)"
        }
    }
}

/// Owns the set of imported model libraries and resolves `.include`/`.lib`
/// paths against them. Value semantics keep it easy to store in the document.
public struct SpiceLibraryManager: Sendable {
    public private(set) var libraries: [SpiceModelLibrary]

    public init(libraries: [SpiceModelLibrary] = []) {
        self.libraries = libraries
    }

    public var isEmpty: Bool { libraries.isEmpty }

    public mutating func add(_ library: SpiceModelLibrary) {
        libraries.append(library)
    }

    public mutating func remove(id: UUID) {
        libraries.removeAll { $0.id == id }
    }

    public mutating func removeAll() {
        libraries.removeAll()
    }

    /// Reads a model file from disk and adds it. Returns the imported library.
    @discardableResult
    public mutating func addContents(of url: URL, name: String? = nil) throws -> SpiceModelLibrary {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw SpiceModelLibraryError.unreadable(
                fileName: url.lastPathComponent,
                reason: error.localizedDescription
            )
        }
        let resolvedName = name ?? url.deletingPathExtension().lastPathComponent
        let library = try SpiceModelLibrary.parse(text, name: resolvedName, sourcePath: url.path)
        add(library)
        return library
    }

    /// Every model name across all libraries, sorted and de-duplicated.
    public var modelNames: [String] {
        Array(Set(libraries.flatMap { $0.models.map(\.name) })).sorted()
    }

    /// A resolver that reads `.include`/`.lib` paths, trying each library's
    /// directory (and an optional document base directory) in turn.
    public func includeResolver(relativeTo baseDirectory: URL? = nil) -> SpiceIncludeResolver {
        let directories = ([baseDirectory] + libraries.compactMap { library in
            library.sourcePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        }).compactMap { $0 }

        return { path in
            let expanded = (path as NSString).expandingTildeInPath
            var candidates: [URL] = []
            if expanded.hasPrefix("/") {
                candidates.append(URL(fileURLWithPath: expanded))
            } else {
                candidates.append(contentsOf: directories.map { $0.appendingPathComponent(path) })
            }
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            return nil
        }
    }
}
