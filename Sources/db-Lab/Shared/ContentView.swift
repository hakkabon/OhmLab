// ContentView.swift
// Root view: sidebar + detail split.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            detailView
        }
        #if os(macOS)
        .frame(minWidth: 1000, minHeight: 650)
        #endif
    }

    @ViewBuilder
    private var detailView: some View {
        switch appState.selectedSidebarItem {
        case .crossoverDesign(let id):
            if let doc = appState.crossoverDocument(id: id) {
                CrossoverDesignerView(document: doc)
            } else {
                WelcomeView()
            }
        case .circuit(let id):
            if let doc = appState.circuitDocument(id: id) {
                CircuitSimulatorView(document: doc)
            } else {
                WelcomeView()
            }
        case nil:
            WelcomeView()
        }
    }
}

// MARK: – Sidebar

struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List(selection: $appState.selectedSidebarItem) {
            // ── Crossover designs ──
            if !appState.crossoverDocuments.isEmpty {
                Section("Crossover Designs") {
                    ForEach(appState.crossoverDocuments) { doc in
                        Label(doc.name, systemImage: "waveform.path")
                            .tag(SidebarItem.crossoverDesign(doc.id))
                    }
                }
            }

            // ── Circuit simulations ──
            if !appState.circuitDocuments.isEmpty {
                Section("Circuits") {
                    ForEach(appState.circuitDocuments) { doc in
                        Label(doc.name, systemImage: "cpu")
                            .tag(SidebarItem.circuit(doc.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("db-Lab")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Crossover Design", action: appState.newCrossoverDesign)
                    Button("Circuit", action: appState.newCircuit)
                } label: {
                    Label("New", systemImage: "plus")
                }
            }
        }
    }
}

// MARK: – Welcome screen

struct WelcomeView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 32) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundStyle(.secondary)

            Text("db-Lab")
                .font(.largeTitle)
                .bold()

            Text("Audio-Electrical Network Simulator")
                .font(.title3)
                .foregroundStyle(.secondary)

            HStack(spacing: 24) {
                WelcomeActionCard(
                    title: "Crossover Designer",
                    subtitle: "Design passive speaker crossovers",
                    icon: "waveform.path",
                    action: appState.newCrossoverDesign
                )
                WelcomeActionCard(
                    title: "Circuit Simulator",
                    subtitle: "Run SPICE netlist simulations",
                    icon: "cpu",
                    action: appState.newCircuit
                )
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

struct WelcomeActionCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .foregroundStyle(Color.accentColor)

                Text(title)
                    .font(.headline)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(width: 200, height: 160)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
