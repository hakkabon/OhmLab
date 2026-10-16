// AppState.swift
// Top-level application state and navigation model.

import SwiftUI
import Combine

enum SidebarItem: Hashable, Identifiable {
    case circuit(UUID)

    var id: Self { self }
}

@MainActor
final class AppState: ObservableObject {
    @Published var circuitDocuments: [CircuitDocument] = []
    @Published var selectedSidebarItem: SidebarItem?

    // MARK: – New document factories

    func newCircuit() {
        let doc = CircuitDocument()
        circuitDocuments.append(doc)
        selectedSidebarItem = .circuit(doc.id)
    }

    // MARK: – Lookup helpers

    func circuitDocument(id: UUID) -> CircuitDocument? {
        circuitDocuments.first { $0.id == id }
    }
}
