// CircuitDocument.swift
// Observable document model for a circuit design + simulation session.

import Combine
import Foundation
import SwiftUI

@MainActor
final class CircuitDocument: ObservableObject, Identifiable {
    let id: UUID

    @Published var name: String = "Untitled Circuit"
    @Published var usesSchematic: Bool = true
    @Published var netlistText: String = defaultNetlist
    @Published var schematic: SchematicDocument = SchematicDocument()
    @Published var settings: AnalysisSettings = .default
    /// Imported vendor model libraries, visible to netlist parsing without an
    /// explicit `.include`.
    @Published var modelLibraries: [SpiceModelLibrary] = []

    /// The netlist with `.include`/`.lib` cards resolved at import time. Nil
    /// when the document has not been imported or the text was edited by hand.
    @Published var resolvedNetlistText: String?
    /// Directory of the imported netlist/schematic. Relative include paths are
    /// resolved against it when `resolvedNetlistText` is unavailable.
    @Published var importBaseDirectory: URL?

    /// Where the current netlist text came from, when it was imported rather
    /// than typed. Cleared as soon as the netlist is edited by hand.
    struct ImportSource: Equatable {
        enum Kind: Equatable {
            case spiceNetlist, kicadSchematic, kicadProject

            var label: String {
                switch self {
                case .spiceNetlist: "SPICE netlist"
                case .kicadSchematic: "KiCad schematic"
                case .kicadProject: "KiCad project"
                }
            }
        }
        let fileName: String
        let kind: Kind
        /// Directory containing the imported file; relative includes resolve
        /// here before falling back to imported library locations.
        let directory: URL?

        init(fileName: String, kind: Kind, directory: URL? = nil) {
            self.fileName = fileName
            self.kind = kind
            self.directory = directory
        }
    }
    @Published var importSource: ImportSource?
    /// Non-fatal notes from parsing an imported netlist (skipped includes,
    /// ignored directives). Distinct from `diagnostics`, which also covers
    /// hand-entered netlists and are always recomputed.
    @Published var importWarnings: [String] = []

    // Results
    @Published var simulationResult: CircuitSimResult?
    @Published var isSimulating: Bool = false
    @Published var simulationError: String?

    /// A completed simulation kept for comparison. Overlaid runs are drawn on
    /// top of the live result in every plot.
    struct RunSnapshot: Identifiable {
        let id: UUID
        var label: String
        let date: Date
        let settings: AnalysisSettings
        let result: CircuitSimResult
        var isOverlaid: Bool
    }

    @Published var runHistory: [RunSnapshot] = []
    static let maxRunHistory = 8

    /// Bumped whenever the persisted content (schematic, netlist, settings, or
    /// libraries) changes. The document host observes this to mirror the change
    /// back into the `FileDocument` for autosave.
    @Published private(set) var contentVersion = 0

    // Diagnostics
    @Published var diagnostics: [Diagnostic] = []

    // Document lifecycle
    @Published var fileURL: URL?
    @Published var lastSavedAt: Date?
    @Published var isDirty: Bool = false

    private var cancellables = Set<AnyCancellable>()
    private var autosaveTask: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    private var simulationTask: Task<Void, Never>?
    private var simulationGeneration: UInt64 = 0

    /// Set while `importNetlist` is assigning `netlistText`, so the change
    /// observer does not clear the provenance it is about to record.
    private var applyingImport = false

    /// Opt-in so that documents created outside the app (e.g. in tests) never
    /// write to the shared recovery directory.
    var autosaveRecoveryEnabled = false

    init(id: UUID = UUID()) {
        self.id = id

        // Only content changes dirty the document; selection and undo-availability
        // changes do not publish a new content version.
        schematic.$contentVersion
            .dropFirst()
            .sink { [weak self] _ in self?.contentDidChange() }
            .store(in: &cancellables)

        $netlistText
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                // Hand edits invalidate the import provenance and the inlined
                // netlist. The import directory is kept so relative includes can
                // still be resolved by the engine.
                if !self.applyingImport {
                    self.importSource = nil
                    self.importWarnings = []
                    self.resolvedNetlistText = nil
                }
                self.contentDidChange()
            }
            .store(in: &cancellables)

        $settings
            .dropFirst()
            .sink { [weak self] _ in self?.contentDidChange() }
            .store(in: &cancellables)

        $modelLibraries
            .dropFirst()
            .sink { [weak self] _ in self?.contentDidChange() }
            .store(in: &cancellables)

        $usesSchematic
            .dropFirst()
            .sink { [weak self] _ in self?.contentDidChange() }
            .store(in: &cancellables)

        refreshDiagnostics()
    }

    // MARK: - Change tracking

    private func contentDidChange() {
        cancelSimulation()
        isDirty = true
        contentVersion &+= 1
        simulationResult = nil
        simulationError = nil
        scheduleDiagnosticsRefresh()
        scheduleAutosave()
    }

    /// Diagnostics and netlist projection are comparatively expensive and a drag
    /// emits a burst of content changes, so coalesce them on a short debounce.
    private func scheduleDiagnosticsRefresh() {
        diagnosticsTask?.cancel()
        diagnosticsTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshDiagnostics()
        }
    }

    func refreshDiagnostics() {
        diagnostics = usesSchematic
            ? CircuitDiagnostics.analyze(schematic)
            : netlistDiagnostics()
    }

    private func netlistDiagnostics() -> [Diagnostic] {
        do {
            _ = try SpiceNetlistLoader.parse(
                effectiveNetlistText,
                libraries: modelLibraries,
                baseDirectory: importBaseDirectory
            )
            return []
        } catch {
            return [Diagnostic(severity: .error, message: error.localizedDescription)]
        }
    }

    var hasBlockingErrors: Bool {
        diagnostics.contains { $0.severity == .error }
    }

    /// The text handed to the engine: the include-resolved netlist when one was
    /// captured at import, otherwise the editor's text with the import
    /// directory supplying relative include paths.
    var effectiveNetlistText: String {
        resolvedNetlistText ?? netlistText
    }

    // MARK: - Simulation

    /// Starts a document-owned simulation. A new run or a content edit cancels
    /// the previous task and invalidates any result it might still produce.
    func startSimulation() {
        cancelSimulation()
        simulationTask = Task { @MainActor [weak self] in
            await self?.runSimulation()
        }
    }

    func cancelSimulation() {
        simulationGeneration &+= 1
        simulationTask?.cancel()
        simulationTask = nil
        isSimulating = false
    }

    func runSimulation() async {
        simulationGeneration &+= 1
        let generation = simulationGeneration
        let startingContentVersion = contentVersion
        isSimulating = true
        simulationError = nil
        simulationResult = nil
        defer {
            if generation == simulationGeneration {
                isSimulating = false
                simulationTask = nil
            }
        }
        do {
            let result: CircuitSimResult
            if usesSchematic {
                result = try await EngineClient.shared.simulate(
                    snapshot: schematic.snapshot(),
                    settings: settings
                )
            } else {
                result = try await EngineClient.shared.simulate(
                    netlist: effectiveNetlistText,
                    settings: settings,
                    libraries: modelLibraries,
                    baseDirectory: importBaseDirectory
                )
            }
            guard !Task.isCancelled,
                  generation == simulationGeneration,
                  startingContentVersion == contentVersion else { return }
            simulationResult = result
            recordRun(result)
        } catch is CancellationError {
            // Cancellation is expected when the document changes or closes.
        } catch {
            guard generation == simulationGeneration,
                  startingContentVersion == contentVersion else { return }
            simulationError = error.localizedDescription
        }
    }

    // MARK: - Run history

    /// Keeps the newest run for comparison, capping the history length.
    private func recordRun(_ result: CircuitSimResult) {
        let snapshot = RunSnapshot(
            id: UUID(),
            label: runLabel(),
            date: Date(),
            settings: settings,
            result: result,
            isOverlaid: false
        )
        runHistory.insert(snapshot, at: 0)
        if runHistory.count > Self.maxRunHistory {
            runHistory.removeLast(runHistory.count - Self.maxRunHistory)
        }
    }

    private func runLabel() -> String {
        var modes: [String] = []
        if settings.runDC { modes.append("DC") }
        if settings.runAC { modes.append("AC") }
        if settings.runTransient { modes.append("Tran") }
        if settings.runDCSweep { modes.append("Sweep") }
        let summary = modes.isEmpty ? "Run" : modes.joined(separator: "+")
        let time = Date().formatted(date: .omitted, time: .standard)
        return "\(summary) @ \(time)"
    }

    func toggleRunOverlay(id: UUID) {
        guard let index = runHistory.firstIndex(where: { $0.id == id }) else { return }
        runHistory[index].isOverlaid.toggle()
    }

    func removeRun(id: UUID) {
        runHistory.removeAll { $0.id == id }
    }

    func clearRuns() {
        runHistory.removeAll()
    }

    /// Runs currently marked for overlay, oldest first.
    var overlaidRuns: [RunSnapshot] {
        runHistory.filter(\.isOverlaid).reversed()
    }

    // MARK: - Persistence

    func makeFile() -> CircuitFile {
        CircuitFile(
            name: name,
            schematic: schematic.snapshot(),
            analysis: settings,
            netlistText: netlistText,
            resolvedNetlistText: resolvedNetlistText,
            usesSchematic: usesSchematic,
            modelLibraries: modelLibraries.map { StoredModelLibrary(name: $0.name, text: $0.rawText) },
            importBaseDirectory: importBaseDirectory?.path
        )
    }

    func load(_ file: CircuitFile, fallbackBaseDirectory: URL? = nil) {
        name = file.name
        settings = file.analysis
        schematic.replaceContents(with: file.schematic)
        if let text = file.netlistText { netlistText = text }
        resolvedNetlistText = file.resolvedNetlistText
        importBaseDirectory = file.importBaseDirectory.map {
            URL(fileURLWithPath: $0)
        } ?? fallbackBaseDirectory
        usesSchematic = file.usesSchematic ?? true
        modelLibraries = (file.modelLibraries ?? []).compactMap { stored in
            try? SpiceModelLibrary.parse(stored.text, name: stored.name)
        }
        // Older documents have no resolved netlist. If the document's own
        // directory is known, inline from there so relative includes work
        // without requiring a re-import.
        if resolvedNetlistText == nil, usesSchematic == false, importBaseDirectory != nil {
            refreshImportWarnings()
        }
        simulationResult = nil
        simulationError = nil
        // Loading runs the same change notifications as editing; the content is
        // now the persisted state, so it is clean.
        autosaveTask?.cancel()
        diagnosticsTask?.cancel()
        refreshDiagnostics()
        isDirty = false
    }

    func save(to url: URL) throws {
        try CircuitFileStore.write(makeFile(), to: url)
        fileURL = url
        lastSavedAt = Date()
        isDirty = false
        CircuitFileStore.clearRecovery(id: id)
    }

    // MARK: - Interchange

    /// Replaces the netlist with imported SPICE text and switches to netlist
    /// mode so it can be run immediately.
    func importNetlist(_ text: String, source: ImportSource? = nil) {
        applyingImport = true
        netlistText = text
        importSource = source
        importBaseDirectory = source?.directory
        usesSchematic = false
        applyingImport = false
        refreshImportWarnings()
    }

    /// Reconstructs a schematic (with subcircuit hierarchy) from SPICE text and
    /// switches to schematic mode. The original netlist is retained so nothing
    /// is lost if the drawing does not round-trip perfectly.
    @discardableResult
    func importSchematic(_ text: String, source: ImportSource? = nil) -> [String] {
        let result = SchematicImporter.importNetlist(text)
        applyingImport = true
        netlistText = text
        if let source {
            importSource = source
            importBaseDirectory = source.directory
        }
        applyingImport = false
        schematic.replaceContents(with: result.snapshot)
        usesSchematic = true
        refreshImportWarnings()
        importWarnings = result.warnings + importWarnings
        refreshDiagnostics()
        return result.warnings
    }

    /// Loads a directly read KiCad schematic hierarchy into the editor. The
    /// snapshot keeps KiCad's UUIDs, references, values, hierarchy, and model
    /// libraries; the projected netlist is retained for export and for tools
    /// that still read netlist text.
    @discardableResult
    func importKiCadSchematic(
        _ result: KiCadSchematicReadResult,
        source: ImportSource? = nil
    ) -> [String] {
        applyingImport = true
        netlistText = (try? SpiceNetlistBuilder.export(
            snapshot: result.snapshot,
            title: source?.fileName ?? name,
            analysis: .default,
            libraryTexts: result.modelLibraries.map(\.rawText)
        )) ?? ""
        if let source {
            importSource = source
            importBaseDirectory = source.directory
        }
        applyingImport = false
        schematic.replaceContents(with: result.snapshot)
        modelLibraries = result.modelLibraries
        usesSchematic = true
        refreshImportWarnings()
        importWarnings = result.warnings + importWarnings
        refreshDiagnostics()
        return result.warnings
    }

    /// The SPICE netlist to hand to another tool: the projection when editing a
    /// schematic, otherwise the include-resolved netlist. When the resolved
    /// text is unavailable (for example after a hand edit), it is rebuilt from
    /// the import directory.
    func netlistForExport() throws -> String {
        if usesSchematic {
            return try SpiceNetlistBuilder.export(
                snapshot: schematic.snapshot(),
                title: name,
                analysis: settings,
                libraryTexts: modelLibraries.map(\.rawText)
            )
        }
        if let resolvedNetlistText { return resolvedNetlistText }
        return SpiceIncludePipeline.inline(
            netlistText,
            baseDirectory: importBaseDirectory,
            libraries: modelLibraries
        ).text
    }

    /// Imports either a KiCad schematic/project (read directly, with a
    /// `kicad-cli` fallback on macOS) or a SPICE netlist file.
    ///
    /// Import never blocks on parse errors: the netlist text is loaded as-is and
    /// the diagnostics panel reports anything the engine cannot run.
    func importDesign(at url: URL) throws {
        let ext = url.pathExtension.lowercased()
        let directory = url.deletingLastPathComponent()
        let source: ImportSource
        var importedURL = url
        if KiCadInterchange.schematicExtensions.contains(ext) {
            let root = KiCadProjectInterchange.rootSchematic(for: url) ?? url
            importedURL = root
            source = ImportSource(
                fileName: root.lastPathComponent,
                kind: root == url ? .kicadSchematic : .kicadProject,
                directory: root.deletingLastPathComponent()
            )
            try importKiCadDesign(at: root, source: source)
        } else if ext == KiCadProjectInterchange.projectExtension {
            guard let root = KiCadProjectInterchange.rootSchematic(for: url) else {
                throw KiCadInterchangeError.unsupportedFormat(url.lastPathComponent)
            }
            importedURL = root
            source = ImportSource(
                fileName: url.lastPathComponent,
                kind: .kicadProject,
                directory: root.deletingLastPathComponent()
            )
            try importKiCadDesign(at: root, source: source)
        } else if KiCadInterchange.netlistExtensions.contains(ext) {
            source = ImportSource(
                fileName: url.lastPathComponent,
                kind: .spiceNetlist,
                directory: directory
            )
            importNetlist(try KiCadInterchange.readNetlist(at: url), source: source)
        } else if Self.modelLibraryExtensions.contains(ext) {
            try importModelLibrary(at: url)
            name = url.deletingPathExtension().lastPathComponent
            return
        } else {
            throw KiCadInterchangeError.unsupportedFormat(url.lastPathComponent)
        }
        name = importedURL.deletingPathExtension().lastPathComponent
    }

    /// Reads a KiCad schematic hierarchy directly. On macOS a direct-read
    /// failure falls back to `kicad-cli`; elsewhere the reader's error is
    /// reported so the user sees the actual parse problem.
    private func importKiCadDesign(at root: URL, source: ImportSource) throws {
        do {
            let result = try KiCadSchematicReader.readProject(at: root)
            importKiCadSchematic(result, source: source)
        } catch {
            #if os(macOS)
            let text = try KiCadInterchange.exportedNetlistText(at: root)
            importNetlist(text, source: source)
            #else
            throw error
            #endif
        }
    }

    /// Resolves includes and records parser/inlining warnings. Also captures the
    /// inlined text so simulation and export do not depend on the source files.
    private func refreshImportWarnings() {
        let inlined = SpiceIncludePipeline.inline(
            netlistText,
            baseDirectory: importBaseDirectory,
            libraries: modelLibraries
        )
        resolvedNetlistText = inlined.text == netlistText ? nil : inlined.text
        var warnings = inlined.warnings
        // Parse the already-inlined text directly so unresolved cards are not
        // reported twice by a second pass through the pipeline.
        let include = SpiceLibraryManager(libraries: modelLibraries)
            .includeResolver(relativeTo: importBaseDirectory)
        if let parsed = try? SpiceNetlistParser.parse(
            inlined.text,
            include: include,
            libraries: modelLibraries
        ) {
            warnings.append(contentsOf: parsed.warnings)
        }
        importWarnings = warnings
    }

    /// Imports a vendor model library from disk so its `.model`/`.subckt` cards
    /// are available to the netlist. Returns the number of model definitions
    /// the file contributed.
    @discardableResult
    func importModelLibrary(at url: URL) throws -> Int {
        let text = try String(contentsOf: url, encoding: .utf8)
        let library = try SpiceModelLibrary.parse(
            text,
            name: url.deletingPathExtension().lastPathComponent,
            sourcePath: url.path
        )
        modelLibraries.append(library)
        return library.models.count
    }

    func removeModelLibrary(id: UUID) {
        modelLibraries.removeAll { $0.id == id }
    }

    /// File extensions treated as vendor model libraries by `importDesign`.
    static let modelLibraryExtensions: Set<String> = ["lib", "mod"]

    static func recovered(from file: CircuitFile) -> CircuitDocument {
        let document = CircuitDocument()
        document.load(file)
        document.name = file.name + " (Recovered)"
        document.isDirty = true
        return document
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard autosaveRecoveryEnabled else { return }
        autosaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            CircuitFileStore.saveRecovery(self.makeFile(), id: self.id)
        }
    }
}

// MARK: - Default netlist (RC low-pass filter example)

private let defaultNetlist = """
* RC Low-Pass Filter
* fc = 1/(2*pi*R*C) = 1/(2*pi*1000*1e-6) ≈ 159 Hz
V1 1 0 AC 1
R1 1 2 1000
C1 2 0 1e-6
.AC DEC 20 1 100000
.END
"""
