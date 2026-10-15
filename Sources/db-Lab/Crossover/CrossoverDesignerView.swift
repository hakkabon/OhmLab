// CrossoverDesignerView.swift
// Main container for the crossover design workflow.
// Three panels: Drivers | Filters | Results.

import SwiftUI

struct CrossoverDesignerView: View {
    @ObservedObject var document: CrossoverDocument

    enum Panel: String, CaseIterable, Identifiable {
        case drivers = "Drivers"
        case filters  = "Filters"
        case results  = "Results"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .drivers: return "speaker.wave.2"
            case .filters: return "slider.horizontal.3"
            case .results: return "chart.line.uptrend.xyaxis"
            }
        }
    }

    @State private var selectedPanel: Panel = .drivers

    var body: some View {
        VStack(spacing: 0) {
            // ── Toolbar ──────────────────────────────────────────────────────
            designerToolbar

            Divider()

            // ── Panel picker ─────────────────────────────────────────────────
            HStack(spacing: 0) {
                ForEach(Panel.allCases) { panel in
                    PanelTab(title: panel.rawValue, icon: panel.icon, isSelected: selectedPanel == panel) {
                        selectedPanel = panel
                    }
                }
                Spacer()
            }
            .padding(.horizontal)
            .background(.bar)

            Divider()

            // ── Content ──────────────────────────────────────────────────────
            Group {
                switch selectedPanel {
                case .drivers:
                    DriversPanel(document: document)
                case .filters:
                    FiltersPanel(document: document)
                case .results:
                    ResultsPanel(document: document)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(document.name)
    }

    // MARK: – Toolbar

    @ViewBuilder
    private var designerToolbar: some View {
        HStack {
            // Document name
            TextField("Design name", text: $document.name)
                .textFieldStyle(.plain)
                .font(.headline)
                .frame(maxWidth: 280)

            Spacer()

            // Template picker
            Menu("Templates") {
                Button("2-Way Crossover") { document.applyTwoWayTemplate() }
                Button("3-Way Crossover") { document.applyThreeWayTemplate() }
            }

            // Synthesize all
            Button {
                document.synthesizeAllFilters()
            } label: {
                Label("Synthesize", systemImage: "function")
            }
            .buttonStyle(.bordered)
            .help("Calculate component values for all filter stages")

            // Run simulation
            Button {
                Task { await document.runSimulation() }
            } label: {
                if document.isSimulating {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Simulate", systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(document.isSimulating || document.drivers.isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// ─── Panel tab button ─────────────────────────────────────────────────────────

struct PanelTab: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).imageScale(.small)
                Text(title)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? Color.accentColor.opacity(0.15) : .clear)
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}
