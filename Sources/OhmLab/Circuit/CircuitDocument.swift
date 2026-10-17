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

    /// Where the current netlist text came from, when it was imported rather
    /// than typed. Cleared as soon as the netlist is edited by hand.
    struct ImportSource: Equatable {
        enum Kind: Equatable { case spiceNetlist, kicadSchematic }
        let fileName: String
        let kind: Kind
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

    // Diagnostics
    @Published var diagnostics: [Diagnostic] = []

    // Document lifecycle
    @Published var fileURL: URL?
    @Published var lastSavedAt: Date?
    @Published var isDirty: Bool = false

    private var cancellables = Set<AnyCancellable>()
    private var autosaveTask: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?

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
                // Hand edits invalidate the import provenance; imports do not.
                if !self.applyingImport {
                    self.importSource = nil
                    self.importWarnings = []
                }
                self.contentDidChange()
            }
            .store(in: &cancellables)

        $settings
            .dropFirst()
            .sink { [weak self] _ in self?.contentDidChange() }
            .store(in: &cancellables)

        $usesSchematic
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.simulationResult = nil
                    self?.simulationError = nil
                    self?.refreshDiagnostics()
                }
            }
            .store(in: &cancellables)

        refreshDiagnostics()
    }

    // MARK: - Change tracking

    private func contentDidChange() {
        isDirty = true
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
            _ = try SpiceNetlistParser.parse(netlistText)
            return []
        } catch {
            return [Diagnostic(severity: .error, message: error.localizedDescription)]
        }
    }

    var hasBlockingErrors: Bool {
        diagnostics.contains { $0.severity == .error }
    }

    // MARK: - Simulation

    func runSimulation() async {
        isSimulating = true
        simulationError = nil
        simulationResult = nil
        do {
            let result: CircuitSimResult
            if usesSchematic {
                result = try await EngineClient.shared.simulate(
                    snapshot: schematic.snapshot(),
                    settings: settings
                )
            } else {
                result = try await EngineClient.shared.simulate(
                    netlist: netlistText,
                    settings: settings
                )
            }
            simulationResult = result
        } catch {
            simulationError = error.localizedDescription
        }
        isSimulating = false
    }

    // MARK: - Persistence

    func makeFile() -> CircuitFile {
        CircuitFile(name: name, schematic: schematic.snapshot(), analysis: settings)
    }

    func load(_ file: CircuitFile) {
        name = file.name
        settings = file.analysis
        schematic.replaceContents(with: file.schematic)
        usesSchematic = true
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
        usesSchematic = false
        applyingImport = false
        refreshImportWarnings()
    }

    /// The SPICE netlist to hand to another tool: the projection when editing a
    /// schematic, otherwise the netlist text as entered.
    func netlistForExport() throws -> String {
        usesSchematic ? try SpiceNetlistBuilder.build(from: schematic) : netlistText
    }

    /// Imports either a KiCad schematic (`.kicad_sch`, macOS via `kicad-cli`) or
    /// a SPICE netlist file, loading the result into the netlist editor.
    ///
    /// Import never blocks on parse errors: the netlist text is loaded as-is and
    /// the diagnostics panel reports anything the engine cannot run.
    func importDesign(at url: URL) throws {
        let ext = url.pathExtension.lowercased()
        let source: ImportSource
        if KiCadInterchange.schematicExtensions.contains(ext) {
            let text = try KiCadInterchange.exportedNetlistText(at: url)
            source = ImportSource(fileName: url.lastPathComponent, kind: .kicadSchematic)
            importNetlist(text, source: source)
        } else if KiCadInterchange.netlistExtensions.contains(ext) {
            source = ImportSource(fileName: url.lastPathComponent, kind: .spiceNetlist)
            importNetlist(try KiCadInterchange.readNetlist(at: url), source: source)
        } else {
            throw KiCadInterchangeError.unsupportedFormat(url.lastPathComponent)
        }
        name = url.deletingPathExtension().lastPathComponent
    }

    private func refreshImportWarnings() {
        guard let parsed = try? SpiceNetlistParser.parse(netlistText) else {
            importWarnings = []
            return
        }
        importWarnings = parsed.warnings
    }

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
