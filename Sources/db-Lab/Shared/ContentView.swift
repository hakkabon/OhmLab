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
        .alert(
            "db-Lab",
            isPresented: Binding(
                get: { appState.lastError != nil },
                set: { if !$0 { appState.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { appState.lastError = nil }
        } message: {
            Text(appState.lastError ?? "")
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch appState.selectedSidebarItem {
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
            // ── Circuit simulations ──
            if !appState.circuitDocuments.isEmpty {
                Section("Circuits") {
                    ForEach(appState.circuitDocuments) { doc in
                        Label {
                            HStack {
                                Text(doc.name)
                                if doc.isDirty {
                                    Circle()
                                        .fill(.secondary)
                                        .frame(width: 6, height: 6)
                                }
                            }
                        } icon: {
                            Image(systemName: "cpu")
                        }
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
                    Button("Circuit", action: appState.newCircuit)
                    Button("Open…", action: appState.openDocument)
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
            Image(systemName: "cpu")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundStyle(.secondary)

            Text("db-Lab")
                .font(.largeTitle)
                .bold()

            Text("Electronic Circuit Simulator")
                .font(.title3)
                .foregroundStyle(.secondary)

            WelcomeActionCard(
                title: "Circuit Simulator",
                subtitle: "Design circuits and run SPICE analyses",
                icon: "cpu",
                action: appState.newCircuit
            )
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
            .frame(width: 240, height: 160)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
