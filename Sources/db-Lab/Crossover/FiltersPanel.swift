// FiltersPanel.swift
// Panel for configuring filter stages and compensation networks.

import SwiftUI

struct FiltersPanel: View {
    @ObservedObject var document: CrossoverDocument
    @State private var selectedFilterID: UUID?
    @State private var selectedCompID: UUID?

    var body: some View {
        HSplitView {
            // ── Stages list ──────────────────────────────────────────────────
            VStack(spacing: 0) {
                stagesList
                Divider()
                stagesToolbar
            }
            .frame(minWidth: 220, maxWidth: 300)

            // ── Stage editor ─────────────────────────────────────────────────
            if let id = selectedFilterID,
               let idx = document.filters.firstIndex(where: { $0.id == id }) {
                FilterStageEditor(
                    filter: $document.filters[idx],
                    drivers: document.drivers,
                    onSynthesize: { document.synthesizeFilter(at: idx) }
                )
                .id(id)
            } else {
                ContentUnavailableView(
                    "No Stage Selected",
                    systemImage: "slider.horizontal.3",
                    description: Text("Select or add a filter stage.")
                )
            }
        }
    }

    // MARK: – List

    private var stagesList: some View {
        List(selection: $selectedFilterID) {
            Section("Filter Stages") {
                ForEach(document.filters) { filter in
                    FilterStageRow(filter: filter)
                        .tag(filter.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                document.filters.removeAll { $0.id == filter.id }
                            }
                        }
                }
                .onMove { from, to in document.filters.move(fromOffsets: from, toOffset: to) }
                .onDelete { document.filters.remove(atOffsets: $0) }
            }

            if !document.compensations.isEmpty {
                Section("Compensation Networks") {
                    ForEach(document.compensations) { comp in
                        HStack {
                            Image(systemName: "circle.hexagongrid").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(comp.kind.rawValue).font(.body)
                                Text(comp.driverName).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                document.compensations.removeAll { $0.id == comp.id }
                            }
                        }
                    }
                    .onDelete { document.compensations.remove(atOffsets: $0) }
                }
            }
        }
        .listStyle(.inset)
    }

    private var stagesToolbar: some View {
        HStack {
            Button {
                addFilterStage()
            } label: { Image(systemName: "plus") }
                .buttonStyle(.plain).frame(width: 28, height: 28)

            Button {
                removeSelectedFilter()
            } label: { Image(systemName: "minus") }
                .buttonStyle(.plain).frame(width: 28, height: 28)
                .disabled(selectedFilterID == nil)

            Divider().frame(height: 18)

            Menu("Add Compensation") {
                ForEach(CompensationKind.allCases) { kind in
                    Button(kind.rawValue) {
                        let driverName = document.drivers.first?.name ?? "Driver 1"
                        document.compensations.append(CompensationSpec(kind: kind, driverName: driverName))
                    }
                }
            }
            .menuStyle(.borderedButton)
            .controlSize(.small)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: – Actions

    private func addFilterStage() {
        let firstFree = document.drivers.first(where: { driver in
            !document.filters.contains { $0.driverName == driver.name }
        }) ?? document.drivers.first
        let stage = FilterStageModel(
            filterType: document.filters.isEmpty ? .lowPass : .highPass,
            topology: .linkwitzRiley4,
            frequencyHz: 2500,
            driverName: firstFree?.name ?? "Driver"
        )
        document.filters.append(stage)
        selectedFilterID = stage.id
    }

    private func removeSelectedFilter() {
        guard let id = selectedFilterID else { return }
        document.filters.removeAll { $0.id == id }
        selectedFilterID = nil
    }
}

// ─── List row ─────────────────────────────────────────────────────────────────

struct FilterStageRow: View {
    let filter: FilterStageModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: filterIcon)
                .foregroundStyle(filterColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(filter.filterType.rawValue).font(.body)
                Text("\(filter.driverName) · \(filter.topology.rawValue) · \(filterFreqText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var filterIcon: String {
        switch filter.filterType {
        case .lowPass:  return "arrow.down.right"
        case .highPass: return "arrow.up.right"
        case .bandPass: return "arrow.up.and.down"
        case .bandStop: return "minus"
        case .allPass:  return "arrow.right"
        }
    }

    private var filterColor: Color {
        switch filter.filterType {
        case .lowPass:  return .blue
        case .highPass: return .red
        case .bandPass: return .green
        default:        return .orange
        }
    }

    private var filterFreqText: String {
        if filter.frequencyHz >= 1000 {
            return String(format: "%.1fkHz", filter.frequencyHz / 1000)
        }
        return String(format: "%.0fHz", filter.frequencyHz)
    }
}

// ─── Filter stage editor ──────────────────────────────────────────────────────

struct FilterStageEditor: View {
    @Binding var filter: FilterStageModel
    let drivers: [DriverModel]
    let onSynthesize: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Form {
                    Section("Configuration") {
                        Picker("Driver", selection: $filter.driverName) {
                            ForEach(drivers) { d in Text(d.name).tag(d.name) }
                        }
                        Picker("Filter type", selection: $filter.filterType) {
                            ForEach(PassFilterType.allCases) { t in
                                Text(t.rawValue).tag(t)
                            }
                        }
                        Picker("Topology", selection: $filter.topology) {
                            ForEach(CrossoverTopology.allCases) { t in
                                Text(t.rawValue).tag(t)
                            }
                        }
                        LabeledContent("Crossover frequency") {
                            HStack {
                                Slider(value: $filter.frequencyHz, in: 100...15_000, step: 50)
                                    .frame(width: 180)
                                Text(freqText).frame(width: 70, alignment: .trailing).font(.body.monospacedDigit())
                            }
                        }
                    }

                    Section {
                        Button {
                            onSynthesize()
                        } label: {
                            Label("Calculate Component Values", systemImage: "function")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .formStyle(.grouped)

                // Component values table
                if !filter.components.isEmpty {
                    ComponentTable(components: filter.components, title: "Calculated Components")
                        .padding()
                }
            }
        }
    }

    private var freqText: String {
        if filter.frequencyHz >= 1000 {
            return String(format: "%.1fkHz", filter.frequencyHz / 1000)
        }
        return String(format: "%.0fHz", filter.frequencyHz)
    }
}

// ─── Component table ──────────────────────────────────────────────────────────

struct ComponentTable: View {
    let components: [ComponentValue]
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    Text("Type").font(.caption).foregroundStyle(.secondary)
                    Text("Value").font(.caption).foregroundStyle(.secondary)
                    Text("Tolerance").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                ForEach(components) { comp in
                    GridRow {
                        Text(comp.name).font(.body.monospaced())
                        Text(comp.kind.rawValue).foregroundStyle(.secondary)
                        Text(comp.displayString).font(.body.monospaced()).bold()
                        if let tol = comp.tolerance {
                            Text("±\(Int(tol * 100))%").foregroundStyle(.secondary)
                        } else {
                            Text("–").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(12)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
