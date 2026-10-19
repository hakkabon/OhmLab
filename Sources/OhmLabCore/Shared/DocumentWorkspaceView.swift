// DocumentWorkspaceView.swift
// Bridges SwiftUI's FileDocument lifecycle to the in-memory CircuitDocument.
//
// A `CircuitFileDocument` is just the persisted snapshot; the editor works on a
// `CircuitDocument`. This view creates the latter from the former, sets the file
// URL so the window title tracks the document, and mirrors every content change
// back into the `FileDocument` binding so the DocumentGroup autosaves it.

import SwiftUI

public struct DocumentWorkspaceView: View {
    @Binding var file: CircuitFileDocument
    @StateObject private var document: CircuitDocument

    public init(configuration: FileDocumentConfiguration<CircuitFileDocument>) {
        _file = configuration.$document

        let document = CircuitDocument()
        document.load(configuration.document.file)
        document.fileURL = configuration.fileURL
        if let url = configuration.fileURL {
            document.name = url.deletingPathExtension().lastPathComponent
        }
        // Autosave/recovery is handled by the document lifecycle now.
        document.autosaveRecoveryEnabled = false
        document.isDirty = false
        _document = StateObject(wrappedValue: document)
    }

    public var body: some View {
        CircuitSimulatorView(document: document, onSave: persist)
            .onChange(of: document.contentVersion) { _, _ in persist() }
            .onChange(of: document.name) { _, _ in persist() }
    }

    /// Copies the editor's current state into the bound file document. SwiftUI
    /// then writes it to disk (locally or in iCloud) automatically.
    private func persist() {
        file.file = document.makeFile()
    }
}
