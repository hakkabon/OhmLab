// CircuitSimulatorView.swift
// SPICE netlist editor + simulation results.

import SwiftUI
import Charts

struct CircuitSimulatorView: View {
    @ObservedObject var document: CircuitDocument

    enum CircuitPanel: String, CaseIterable, Identifiable {
        case netlist  = "Netlist"
        case settings = "Settings"
        case results  = "Results"
        var id: String { rawValue }
    }

    @State private var selectedPanel: CircuitPanel = .netlist

    var body: some View {
        VStack(spacing: 0) {
            circuitToolbar

            Divider()

            HStack(spacing: 0) {
                ForEach(CircuitPanel.allCases) { panel in
                    PanelTab(title: panel.rawValue, icon: panelIcon(panel), isSelected: selectedPanel == panel) {
                        selectedPanel = panel
                    }
                }
                Spacer()

                if let result = document.simulationResult {
                    resultBadges(result)
                }
            }
            .padding(.horizontal)
            .background(.bar)

            Divider()

            Group {
                switch selectedPanel {
                case .netlist:
                    NetlistEditorView(document: document)
                case .settings:
                    AnalysisSettingsView(document: document)
                case .results:
                    CircuitResultsView(document: document)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(document.name)
    }

    // MARK: – Toolbar

    @ViewBuilder
    private var circuitToolbar: some View {
        HStack {
            TextField("Circuit name", text: $document.name)
                .textFieldStyle(.plain)
                .font(.headline)
                .frame(maxWidth: 280)

            Spacer()

            Menu("Examples") {
                Button("RC Low-Pass Filter") { document.netlistText = rcFilterNetlist }
                Button("RLC Band-Pass Filter") { document.netlistText = rlcBandPassNetlist }
                Button("Voltage Divider") { document.netlistText = voltageDividerNetlist }
            }
            .menuStyle(.borderedButton)

            Button {
                Task { await document.runSimulation() }
            } label: {
                if document.isSimulating {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Run", systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(document.isSimulating || document.netlistText.trimmingCharacters(in: .whitespaces).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: – Helpers

    private func panelIcon(_ panel: CircuitPanel) -> String {
        switch panel {
        case .netlist:  return "doc.plaintext"
        case .settings: return "gearshape"
        case .results:  return "chart.xyaxis.line"
        }
    }

    @ViewBuilder
    private func resultBadges(_ result: CircuitSimResult) -> some View {
        HStack(spacing: 8) {
            if result.dc != nil {
                ResultBadge(label: "DC", color: .green)
            }
            if result.ac != nil {
                ResultBadge(label: "AC", color: .blue)
            }
            if result.tran != nil {
                ResultBadge(label: "TRAN", color: .orange)
            }
        }
        .padding(.horizontal, 8)
    }
}

struct ResultBadge: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// ─── Netlist editor ───────────────────────────────────────────────────────────

struct NetlistEditorView: View {
    @ObservedObject var document: CircuitDocument

    var body: some View {
        VStack(spacing: 0) {
            if let error = document.simulationError {
                ErrorBanner(message: error)
                Divider()
            }

            TextEditor(text: $document.netlistText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .padding(8)
        }
    }
}

// ─── Analysis settings ────────────────────────────────────────────────────────

struct AnalysisSettingsView: View {
    @ObservedObject var document: CircuitDocument

    var body: some View {
        ScrollView {
            Form {
                Section("DC Operating Point") {
                    Toggle("Run DC analysis", isOn: $document.runDC)
                }

                Section("AC Sweep") {
                    Toggle("Run AC analysis", isOn: $document.runAC)
                    if document.runAC {
                        LabeledContent("Start frequency (Hz)") {
                            DoubleField(value: $document.acFStart)
                        }
                        LabeledContent("Stop frequency (Hz)") {
                            DoubleField(value: $document.acFStop)
                        }
                        LabeledContent("Points per decade") {
                            Stepper("\(document.acPointsPerDecade)", value: $document.acPointsPerDecade, in: 5...100, step: 5)
                        }
                    }
                }

                Section("Transient") {
                    Toggle("Run transient analysis", isOn: $document.runTRAN)
                    if document.runTRAN {
                        LabeledContent("Stop time (s)") {
                            DoubleField(value: $document.tranTStop, format: .number.precision(.fractionLength(6)))
                        }
                        LabeledContent("Time step (s)") {
                            DoubleField(value: $document.tranTStep, format: .number.precision(.fractionLength(8)))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
        }
    }
}

// ─── Results view ─────────────────────────────────────────────────────────────

struct CircuitResultsView: View {
    @ObservedObject var document: CircuitDocument

    enum ResultSection: String, CaseIterable, Identifiable {
        case dc    = "DC"
        case ac    = "AC Bode"
        case tran  = "Transient"
        var id: String { rawValue }
    }

    @State private var section: ResultSection = .ac

    var body: some View {
        if let result = document.simulationResult {
            VStack(spacing: 0) {
                // Tab selector
                HStack {
                    ForEach(ResultSection.allCases) { s in
                        let available = isAvailable(s, result: result)
                        PanelTab(title: s.rawValue, icon: "", isSelected: section == s && available) {
                            section = s
                        }
                        .opacity(available ? 1 : 0.35)
                        .disabled(!available)
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
                Divider()

                switch section {
                case .dc:
                    if let dc = result.dc {
                        DcResultView(result: dc)
                    }
                case .ac:
                    if let ac = result.ac {
                        AcBodeView(result: ac)
                    }
                case .tran:
                    if let tran = result.tran {
                        TranWaveformView(result: tran)
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "No Results",
                systemImage: "chart.xyaxis.line",
                description: Text("Run the simulation first.")
            )
        }
    }

    private func isAvailable(_ s: ResultSection, result: CircuitSimResult) -> Bool {
        switch s {
        case .dc:   return result.dc != nil
        case .ac:   return result.ac != nil
        case .tran: return result.tran != nil
        }
    }
}

// ─── DC result table ──────────────────────────────────────────────────────────

struct DcResultView: View {
    let result: CircuitSimResult.DCResult

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Node Voltages").font(.headline)
                    Grid(horizontalSpacing: 24, verticalSpacing: 6) {
                        GridRow {
                            Text("Node").font(.caption).foregroundStyle(.secondary)
                            Text("Voltage").font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        ForEach(result.nodes, id: \.name) { node in
                            GridRow {
                                Text(node.name).font(.body.monospaced())
                                Text(String(format: "%.4f V", node.voltage))
                                    .font(.body.monospaced()).bold()
                            }
                        }
                    }
                    .padding(12)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if !result.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Source Currents").font(.headline)
                        Grid(horizontalSpacing: 24, verticalSpacing: 6) {
                            GridRow {
                                Text("Source").font(.caption).foregroundStyle(.secondary)
                                Text("Current").font(.caption).foregroundStyle(.secondary)
                            }
                            Divider()
                            ForEach(result.sources, id: \.name) { src in
                                GridRow {
                                    Text(src.name).font(.body.monospaced())
                                    Text(String(format: "%.4e A", src.current))
                                        .font(.body.monospaced()).bold()
                                }
                            }
                        }
                        .padding(12)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                HStack {
                    Image(systemName: result.converged ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.converged ? .green : .red)
                    Text(result.converged ? "Converged" : "Did not converge")
                }
                .font(.callout)
            }
            .padding()
        }
    }
}

// ─── AC Bode plot ─────────────────────────────────────────────────────────────

struct AcBodeView: View {
    let result: CircuitSimResult.ACResult

    private let nodeColors: [Color] = [.blue, .red, .green, .orange, .purple]

    var body: some View {
        VStack(spacing: 0) {
            // Magnitude
            Text("Magnitude").font(.caption).foregroundStyle(.secondary).padding(.top, 8)

            Chart {
                ForEach(Array(result.nodes.enumerated()), id: \.offset) { idx, node in
                    ForEach(node.response) { pt in
                        LineMark(
                            x: .value("Hz", pt.freqHz),
                            y: .value("dB", pt.magnitudeDb),
                            series: .value("Node", node.name)
                        )
                        .foregroundStyle(nodeColors[idx % nodeColors.count])
                        .interpolationMethod(.catmullRom)
                    }
                }
            }
            .chartXScale(type: .log)
            .chartXAxisLabel("Frequency (Hz)")
            .chartYAxisLabel("Magnitude (dB)")
            .chartLegend(position: .topTrailing)
            .frame(height: 220)
            .padding(.horizontal)

            Divider().padding(.vertical, 4)

            // Phase
            Text("Phase").font(.caption).foregroundStyle(.secondary)

            Chart {
                ForEach(Array(result.nodes.enumerated()), id: \.offset) { idx, node in
                    ForEach(node.response) { pt in
                        LineMark(
                            x: .value("Hz", pt.freqHz),
                            y: .value("°", pt.phaseDeg),
                            series: .value("Node", node.name)
                        )
                        .foregroundStyle(nodeColors[idx % nodeColors.count].opacity(0.7))
                        .lineStyle(StrokeStyle(dash: [4, 3]))
                        .interpolationMethod(.catmullRom)
                    }
                }
            }
            .chartXScale(type: .log)
            .chartXAxisLabel("Frequency (Hz)")
            .chartYAxisLabel("Phase (°)")
            .frame(height: 180)
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
    }
}

// ─── Transient waveform ───────────────────────────────────────────────────────

struct TranWaveformView: View {
    let result: CircuitSimResult.TRANResult

    private let colors: [Color] = [.blue, .red, .green, .orange]

    var body: some View {
        Chart {
            ForEach(Array(result.nodes.enumerated()), id: \.offset) { idx, node in
                ForEach(Array(zip(result.timePoints, node.waveform).enumerated()), id: \.offset) { _, pair in
                    LineMark(
                        x: .value("Time (s)", pair.0),
                        y: .value("Voltage (V)", pair.1),
                        series: .value("Node", node.name)
                    )
                    .foregroundStyle(colors[idx % colors.count])
                    .interpolationMethod(.catmullRom)
                }
            }
        }
        .chartXAxisLabel("Time (s)")
        .chartYAxisLabel("Voltage (V)")
        .chartLegend(position: .topTrailing)
        .padding()
    }
}

// ─── Example netlists ─────────────────────────────────────────────────────────

private let rcFilterNetlist = """
* RC Low-Pass Filter — fc ≈ 159 Hz
V1 1 0 AC 1 0
R1 1 2 1000
C1 2 0 1e-6
.AC DEC 20 1 100000
.END
"""

private let rlcBandPassNetlist = """
* RLC Band-Pass Filter — f0 = 1/(2*pi*sqrt(L*C))
V1 1 0 AC 1 0
R1 1 2 100
L1 2 3 10e-3
C1 3 0 100e-9
.AC DEC 20 100 100000
.END
"""

private let voltageDividerNetlist = """
* Voltage Divider
V1 1 0 DC 12
R1 1 2 10000
R2 2 0 10000
.DC
.END
"""
