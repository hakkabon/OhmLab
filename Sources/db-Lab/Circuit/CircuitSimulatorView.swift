import Charts
import SwiftUI

struct CircuitSimulatorView: View {
    @ObservedObject var document: CircuitDocument
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                editor

                if document.usesSchematic {
                    projectionPanel
                    diagnosticsPanel
                }

                analysisSettings

                if let error = document.simulationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }

                if let result = document.simulationResult {
                    results(result)
                }
            }
            .padding()
        }
        .navigationTitle(document.name)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            TextField("Circuit name", text: $document.name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)

            if document.isDirty {
                Text("Unsaved changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            #if os(macOS)
            Button {
                appState.save(document: document)
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            #endif

            Picker("Editor", selection: $document.usesSchematic) {
                Text("Schematic").tag(true)
                Text("Netlist").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)

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
            .disabled(document.isSimulating || (document.usesSchematic && document.hasBlockingErrors))
        }
    }

    @ViewBuilder
    private var editor: some View {
        if document.usesSchematic {
            SchematicEditorView(document: document.schematic)
                .frame(minHeight: 380)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            GroupBox("SPICE Netlist (R, C, L, V, I)") {
                TextEditor(text: $document.netlistText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
            }
        }
    }

    // MARK: - Netlist projection (export)

    @ViewBuilder
    private var projectionPanel: some View {
        let projection = Result { try SpiceNetlistBuilder.build(from: document.schematic) }
        GroupBox("Projected SPICE Netlist") {
            switch projection {
            case .success(let text):
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView([.horizontal, .vertical]) {
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)

                    Button("Use in Netlist editor") {
                        document.netlistText = text
                        document.usesSchematic = false
                    }
                    .buttonStyle(.bordered)
                }
            case .failure(let error):
                Text(error.localizedDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Diagnostics

    @ViewBuilder
    private var diagnosticsPanel: some View {
        let diagnostics = document.diagnostics.filter { $0.severity != .info }
        if !diagnostics.isEmpty {
            GroupBox("Diagnostics") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(diagnostics) { diagnostic in
                        Label {
                            Text(diagnostic.message)
                                .font(.callout)
                        } icon: {
                            Image(systemName: icon(for: diagnostic.severity))
                                .foregroundStyle(color(for: diagnostic.severity))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func icon(for severity: Diagnostic.Severity) -> String {
        switch severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }

    private func color(for severity: Diagnostic.Severity) -> Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }

    // MARK: - Analysis settings

    private var analysisSettings: some View {
        GroupBox("Analysis") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("DC operating point", isOn: $document.settings.runDC)
                Toggle("AC frequency sweep", isOn: $document.settings.runAC)
                if document.settings.runAC {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Sweep")
                            Picker("Sweep", selection: $document.settings.acSweepType) {
                                Text("Log (decades)").tag(FrequencySweepType.dec)
                                Text("Log (octaves)").tag(FrequencySweepType.oct)
                                Text("Linear").tag(FrequencySweepType.lin)
                            }
                            .labelsHidden()
                            .frame(maxWidth: 160)
                        }
                        GridRow {
                            Text("Start frequency (Hz)")
                            TextField("Start frequency", value: $document.settings.acStartFrequency, format: .number)
                                .frame(maxWidth: 160)
                        }
                        GridRow {
                            Text("Stop frequency (Hz)")
                            TextField("Stop frequency", value: $document.settings.acStopFrequency, format: .number)
                                .frame(maxWidth: 160)
                        }
                        GridRow {
                            Text(pointsLabel)
                            TextField(pointsLabel, value: $document.settings.acPointsPerDecade, format: .number)
                                .frame(maxWidth: 160)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var pointsLabel: String {
        switch document.settings.acSweepType {
        case .dec: return "Points per decade"
        case .oct: return "Points per octave"
        case .lin: return "Points (total)"
        }
    }

    // MARK: - Results

    @ViewBuilder
    private func results(_ result: CircuitSimResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Solved by the db-Lab linear engine.", systemImage: "checkmark.seal")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(result.warnings.enumerated()), id: \.offset) { entry in
                Label(entry.element, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let dc = result.dc {
                dcResults(dc)
            }
            if let ac = result.ac {
                acResults(ac)
            }
        }
    }

    private func dcResults(_ result: CircuitSimResult.DCResult) -> some View {
        GroupBox("DC Operating Point\(result.converged ? "" : " — not converged")") {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow {
                    Text("Node").fontWeight(.semibold)
                    Text("Voltage").fontWeight(.semibold)
                }
                ForEach(Array(result.nodes.enumerated()), id: \.offset) { entry in
                    GridRow {
                        Text(entry.element.name)
                        Text(String(format: "%.6g V", entry.element.voltage))
                            .monospacedDigit()
                    }
                }
                ForEach(Array(result.sources.enumerated()), id: \.offset) { entry in
                    GridRow {
                        Text("\(entry.element.name) current")
                        Text(String(format: "%.6g A", entry.element.current))
                            .monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func acResults(_ result: CircuitSimResult.ACResult) -> some View {
        let names = result.nodes.map(\.name)
        let selected = document.settings.outputNetNames
        let plotNames = selected.isEmpty ? names : selected

        return GroupBox("AC Frequency Response") {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(result.frequencies.count) frequency points from \(format(result.frequencies.first ?? 0)) Hz to \(format(result.frequencies.last ?? 0)) Hz")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                netSelectionControls(names)

                Chart {
                    ForEach(result.nodes.filter { plotNames.contains($0.name) }, id: \.name) { node in
                        ForEach(node.response) { point in
                            LineMark(
                                x: .value("Frequency (Hz)", point.freqHz),
                                y: .value(magnitudeAxisLabel(result), magnitude(result, node: node.name, point: point))
                            )
                            .foregroundStyle(by: .value("Node", node.name))
                        }
                    }
                }
                .chartXScale(type: document.settings.acSweepType == .lin ? .linear : .log)
                .chartXAxisLabel("Frequency (Hz)")
                .chartYAxisLabel(magnitudeAxisLabel(result))
                .frame(height: 240)

                Chart {
                    ForEach(result.nodes.filter { plotNames.contains($0.name) }, id: \.name) { node in
                        ForEach(node.response) { point in
                            LineMark(
                                x: .value("Frequency (Hz)", point.freqHz),
                                y: .value("Phase (degrees)", phase(result, node: node.name, point: point))
                            )
                            .foregroundStyle(by: .value("Node", node.name))
                        }
                    }
                }
                .chartXScale(type: document.settings.acSweepType == .lin ? .linear : .log)
                .chartXAxisLabel("Frequency (Hz)")
                .chartYAxisLabel("Phase (degrees)")
                .frame(height: 200)
            }
        }
    }

    private func netSelectionControls(_ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Menu("Plotted nodes") {
                    ForEach(names, id: \.self) { name in
                        Toggle(name, isOn: outputBinding(name))
                    }
                }
                Button("All") { document.settings.outputNetNames = names }
                Button("None") { document.settings.outputNetNames = [] }

                Spacer()

                Picker("Reference", selection: $document.settings.inputNetName) {
                    Text("Absolute").tag(String?.none)
                    ForEach(names, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .frame(maxWidth: 240)
            }
            .font(.caption)
        }
    }

    private func outputBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { document.settings.outputNetNames.contains(name) },
            set: { isOn in
                var names = document.settings.outputNetNames
                if isOn {
                    if !names.contains(name) { names.append(name) }
                } else {
                    names.removeAll { $0 == name }
                }
                document.settings.outputNetNames = names
            }
        )
    }

    // MARK: - Plot helpers

    private func magnitudeAxisLabel(_ result: CircuitSimResult.ACResult) -> String {
        document.settings.inputNetName == nil ? "Magnitude (dB)" : "Transfer (dB)"
    }

    private func magnitude(_ result: CircuitSimResult.ACResult, node: String, point: FreqPoint) -> Double {
        guard let reference = document.settings.inputNetName,
              reference != node,
              let referenceNode = result.nodes.first(where: { $0.name == reference }),
              let referencePoint = referenceNode.response.first(where: { $0.freqHz == point.freqHz }) else {
            return point.magnitudeDb
        }
        return point.magnitudeDb - referencePoint.magnitudeDb
    }

    private func phase(_ result: CircuitSimResult.ACResult, node: String, point: FreqPoint) -> Double {
        guard let reference = document.settings.inputNetName,
              reference != node,
              let referenceNode = result.nodes.first(where: { $0.name == reference }),
              let referencePoint = referenceNode.response.first(where: { $0.freqHz == point.freqHz }) else {
            return point.phaseDeg
        }
        var delta = point.phaseDeg - referencePoint.phaseDeg
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return delta
    }

    private func format(_ value: Double) -> String {
        String(format: "%.4g", value)
    }
}
