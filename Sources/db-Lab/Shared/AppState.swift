// AppState.swift
// Top-level application state, document lifecycle, and navigation model.

import SwiftUI
import Combine

#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

enum SidebarItem: Hashable, Identifiable {
    case circuit(UUID)

    var id: Self { self }
}

@MainActor
final class AppState: ObservableObject {
    @Published var circuitDocuments: [CircuitDocument] = []
    @Published var selectedSidebarItem: SidebarItem?
    @Published var lastError: String?

    init() {
        restoreRecoveriesIfAvailable()
    }

    // MARK: – New document factories

    func newCircuit() {
        let doc = CircuitDocument()
        doc.autosaveRecoveryEnabled = true
        circuitDocuments.append(doc)
        selectedSidebarItem = .circuit(doc.id)
    }

    // MARK: – Lookup helpers

    func circuitDocument(id: UUID) -> CircuitDocument? {
        circuitDocuments.first { $0.id == id }
    }

    var selectedCircuitDocument: CircuitDocument? {
        guard case .circuit(let id) = selectedSidebarItem else { return nil }
        return circuitDocument(id: id)
    }

    // MARK: – Crash recovery

    private func restoreRecoveriesIfAvailable() {
        let recovered = CircuitFileStore.loadAllRecoveries()
        guard !recovered.isEmpty else { return }
        for file in recovered {
            let document = CircuitDocument.recovered(from: file)
            document.autosaveRecoveryEnabled = true
            circuitDocuments.append(document)
        }
        selectedSidebarItem = circuitDocuments.last.map { .circuit($0.id) }
    }

    // MARK: – Persistence

    func save(document: CircuitDocument) {
        if let url = document.fileURL {
            do {
                try document.save(to: url)
            } catch {
                lastError = error.localizedDescription
            }
            return
        }
        saveAs(document: document)
    }

    func saveAs(document: CircuitDocument) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.name
        if let type = UTType(filenameExtension: CircuitFileStore.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.save(to: url)
            document.name = url.deletingPathExtension().lastPathComponent
        } catch {
            lastError = error.localizedDescription
        }
        #else
        lastError = "Saving is available on macOS. Use automatic recovery on iPadOS."
        #endif
    }

    func openDocument() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: CircuitFileStore.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = try CircuitFileStore.read(from: url)
            let document = CircuitDocument()
            document.autosaveRecoveryEnabled = true
            document.load(file)
            document.fileURL = url
            document.name = url.deletingPathExtension().lastPathComponent
            document.isDirty = false
            circuitDocuments.append(document)
            selectedSidebarItem = .circuit(document.id)
        } catch {
            lastError = error.localizedDescription
        }
        #else
        lastError = "Opening files is available on macOS."
        #endif
    }
}
