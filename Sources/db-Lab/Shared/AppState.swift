// AppState.swift
// Top-level application state and navigation model.

import SwiftUI
import Combine

enum SidebarItem: Hashable, Identifiable {
    case crossoverDesign(UUID)
    case circuit(UUID)

    var id: Self { self }
}

enum ActiveMode {
    case crossover
    case circuit
    case welcome
}

@MainActor
final class AppState: ObservableObject {
    @Published var crossoverDocuments: [CrossoverDocument] = []
    @Published var circuitDocuments: [CircuitDocument] = []
    @Published var selectedSidebarItem: SidebarItem?
    @Published var activeMode: ActiveMode = .welcome

    // MARK: – New document factories

    func newCrossoverDesign() {
        let doc = CrossoverDocument()
        crossoverDocuments.append(doc)
        selectedSidebarItem = .crossoverDesign(doc.id)
        activeMode = .crossover
    }

    func newCircuit() {
        let doc = CircuitDocument()
        circuitDocuments.append(doc)
        selectedSidebarItem = .circuit(doc.id)
        activeMode = .circuit
    }

    // MARK: – Lookup helpers

    func crossoverDocument(id: UUID) -> CrossoverDocument? {
        crossoverDocuments.first { $0.id == id }
    }

    func circuitDocument(id: UUID) -> CircuitDocument? {
        circuitDocuments.first { $0.id == id }
    }
}
