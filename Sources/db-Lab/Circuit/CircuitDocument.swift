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

    init(id: UUID = UUID()) {
        self.id = id

        schematic.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.schematicDidChange() }
            }
            .store(in: &cancellables)

        $netlistText
            .dropFirst()
            .sink { [weak self] _ in self?.contentDidChange() }
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

    private func schematicDidChange() {
        contentDidChange()
    }

    private func contentDidChange() {
        isDirty = true
        simulationResult = nil
        simulationError = nil
        refreshDiagnostics()
        scheduleAutosave()
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

    var availableOutputNets: [String] {
        if let ac = simulationResult?.ac { return ac.nodes.map(\.name) }
        if let dc = simulationResult?.dc { return dc.nodes.map(\.name) }
        return schematic.nets.filter { !$0.isGround }.map(\.name)
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
        refreshDiagnostics()
        // Loading mutates the schematic, which schedules change notifications.
        // Clear the dirty flag once those deferred notifications have drained.
        Task { @MainActor [weak self] in
            self?.autosaveTask?.cancel()
            self?.isDirty = false
        }
    }

    func save(to url: URL) throws {
        try CircuitFileStore.write(makeFile(), to: url)
        fileURL = url
        lastSavedAt = Date()
        isDirty = false
        CircuitFileStore.clearRecovery()
    }

    static func recovered(from file: CircuitFile) -> CircuitDocument {
        let document = CircuitDocument()
        document.load(file)
        document.name = file.name + " (Recovered)"
        Task { @MainActor [weak document] in
            document?.isDirty = true
        }
        return document
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            CircuitFileStore.saveRecovery(self.makeFile())
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
