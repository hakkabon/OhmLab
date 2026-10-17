import Charts
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A flattened point for the DC sweep chart: one signal within one curve.
private struct SweepPlotPoint: Identifiable {
    let id = UUID()
    let x: Double
    let y: Double
    let series: String
}

struct CircuitSimulatorView: View {
    @ObservedObject var document: CircuitDocument
    @EnvironmentObject private var appState: AppState

    private enum ACQuantity: String, CaseIterable, Identifiable {
        case voltage
        case current

        var id: Self { self }
        var title: String { self == .voltage ? "Voltages" : "Currents" }
        var axisLabel: String { self == .voltage ? "Magnitude (dB)" : "Current (dB)" }
    }

    @State private var acQuantity: ACQuantity = .voltage
    @State private var isImporting = false

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
                    exportPanel(result)
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

            Button {
                isImporting = true
            } label: {
                Label("Import", systemImage: "square.and.arrow.down.on.square")
            }
            .buttonStyle(.bordered)
            .help("Import a KiCad schematic (.kicad_sch) or a SPICE netlist (.cir, .net, .sp).")
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false,
                onCompletion: handleImport
            )

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

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            #if os(macOS)
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            #endif
            do {
                try document.importDesign(at: url)
            } catch {
                document.simulationError = error.localizedDescription
            }
        case .failure(let error):
            document.simulationError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var editor: some View {
        if document.usesSchematic {
            SchematicEditorView(document: document.schematic)
                .frame(minHeight: 380)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            GroupBox("SPICE Netlist") {
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
                Toggle("Transient", isOn: $document.settings.runTransient)
                if document.settings.runTransient {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Step (s)")
                            TextField("Step", value: $document.settings.tranStep, format: .number)
                                .frame(maxWidth: 160)
                        }
                        GridRow {
                            Text("Stop (s)")
                            TextField("Stop", value: $document.settings.tranStop, format: .number)
                                .frame(maxWidth: 160)
                        }
                        GridRow {
                            Text("Start (s)")
                            TextField("Start", value: $document.settings.tranStart, format: .number)
                                .frame(maxWidth: 160)
                        }
                    }
                }
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
                Toggle("DC sweep of a source", isOn: $document.settings.runDCSweep)
                if document.settings.runDCSweep {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Source")
                            TextField("e.g. V1", text: $document.settings.dcSweepSource)
                                .frame(maxWidth: 160)
                        }
                        GridRow {
                            Text("Start")
                            TextField("Start", value: $document.settings.dcSweepStart, format: .number)
                                .frame(maxWidth: 160)
                        }
                        GridRow {
                            Text("Stop")
                            TextField("Stop", value: $document.settings.dcSweepStop, format: .number)
                                .frame(maxWidth: 160)
                        }
                        GridRow {
                            Text("Step")
                            TextField("Step", value: $document.settings.dcSweepStep, format: .number)
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
            if let sweep = result.sweep {
                sweepResults(sweep)
            }
            if let ac = result.ac {
                acResults(ac)
            }
            if let transient = result.transient {
                transientResults(transient)
            }
        }
    }

    private func transientResults(_ result: CircuitSimResult.TransientResult) -> some View {
        let activeSeries = transientSeries(result)
        let names = activeSeries.map(\.name)
        let selected = Set(document.settings.outputNetNames)
        let plotNames = selected.isEmpty ? Set(names) : selected.intersection(names)
        let yLabel = acQuantity == .voltage ? "Voltage (V)" : "Current (A)"

        return GroupBox("Transient Response") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Quantity", selection: $acQuantity) {
                        ForEach(ACQuantity.allCases) { quantity in
                            Text(quantity.title).tag(quantity)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)

                    Spacer()

                    Text("\(result.times.count) points from \(format(result.times.first ?? 0)) s to \(format(result.times.last ?? 0)) s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                netSelectionControls(names, showReference: false)

                Chart {
                    ForEach(activeSeries.filter { plotNames.contains($0.name) }, id: \.name) { item in
                        ForEach(Array(item.values.enumerated()), id: \.offset) { entry in
                            LineMark(
                                x: .value("Time (s)", result.times[entry.offset]),
                                y: .value(yLabel, entry.element)
                            )
                            .foregroundStyle(by: .value("Signal", item.name))
                        }
                    }
                }
                .chartXAxisLabel("Time (s)")
                .chartYAxisLabel(yLabel)
                .frame(height: 240)
            }
        }
    }

    private func transientSeries(_ result: CircuitSimResult.TransientResult) -> [(name: String, values: [Double])] {
        switch acQuantity {
        case .voltage:
            return result.nodes.map { ($0.name, $0.values) }
        case .current:
            return result.components.map { ($0.name, $0.values) }
        }
    }

    private func dcResults(_ result: CircuitSimResult.DCResult) -> some View {
        GroupBox("DC Operating Point\(result.converged ? "" : " — not converged")") {
            VStack(alignment: .leading, spacing: 12) {
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
                }

                if !result.components.isEmpty {
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                        GridRow {
                            Text("Component").fontWeight(.semibold)
                            Text("Voltage").fontWeight(.semibold)
                            Text("Current").fontWeight(.semibold)
                        }
                        ForEach(Array(result.components.enumerated()), id: \.offset) { entry in
                            GridRow {
                                Text(entry.element.name)
                                Text(String(format: "%.6g V", entry.element.voltage))
                                    .monospacedDigit()
                                Text(String(format: "%.6g A", entry.element.current))
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                if !result.sources.isEmpty {
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                        ForEach(Array(result.sources.enumerated()), id: \.offset) { entry in
                            GridRow {
                                Text("\(entry.element.name) current")
                                Text(String(format: "%.6g A", entry.element.current))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sweepResults(_ result: CircuitSimResult.SweepResult) -> some View {
        let names = sweepSignalNames(result)
        let selected = Set(document.settings.outputNetNames)
        let plotNames = selected.isEmpty ? Set(names) : selected.intersection(names)
        let xAxis = result.axes.last
        let xLabel = xAxis?.name ?? "Sweep"
        let yLabel = acQuantity == .voltage ? "Voltage (V)" : "Current (A)"

        let plotPoints: [SweepPlotPoint] = result.points.flatMap { point -> [SweepPlotPoint] in
            guard xAxis != nil else { return [] }
            let xIndex = result.axes.count - 1
            let outer = point.coordinates.prefix(xIndex)
                .map { "\($0.name)=\(format($0.value))" }
                .joined(separator: ", ")
            return names.filter { plotNames.contains($0) }.compactMap { name in
                guard let y = sweepValue(point, name: name) else { return nil }
                let series = outer.isEmpty ? name : "\(name) (\(outer))"
                return SweepPlotPoint(x: point.coordinates[xIndex].value, y: y, series: series)
            }
        }

        return GroupBox("DC Sweep") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Quantity", selection: $acQuantity) {
                        ForEach(ACQuantity.allCases) { quantity in
                            Text(quantity.title).tag(quantity)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)

                    Spacer()

                    Text("\(result.points.count) operating points")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                netSelectionControls(names, showReference: false)

                Chart {
                    ForEach(plotPoints) { point in
                        LineMark(
                            x: .value(xLabel, point.x),
                            y: .value(yLabel, point.y)
                        )
                        .foregroundStyle(by: .value("Signal", point.series))
                    }
                }
                .chartXAxisLabel(xLabel)
                .chartYAxisLabel(yLabel)
                .frame(height: 240)
            }
        }
    }

    private func sweepSignalNames(_ result: CircuitSimResult.SweepResult) -> [String] {
        guard let first = result.points.first else { return [] }
        switch acQuantity {
        case .voltage: return first.nodes.map(\.name)
        case .current: return first.components.map(\.name)
        }
    }

    private func sweepValue(_ point: CircuitSimResult.SweepPoint, name: String) -> Double? {
        switch acQuantity {
        case .voltage: return point.nodes.first { $0.name == name }?.voltage
        case .current: return point.components.first { $0.name == name }?.current
        }
    }

    private func acResults(_ result: CircuitSimResult.ACResult) -> some View {
        let activeSeries = series(result)
        let names = activeSeries.map(\.name)
        let selected = Set(document.settings.outputNetNames)
        let plotNames = selected.isEmpty ? Set(names) : selected.intersection(names)
        let yLabel = document.settings.inputNetName == nil ? acQuantity.axisLabel : "Transfer (dB)"

        return GroupBox("AC Frequency Response") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Quantity", selection: $acQuantity) {
                        ForEach(ACQuantity.allCases) { quantity in
                            Text(quantity.title).tag(quantity)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)

                    Spacer()

                    Text("\(result.frequencies.count) points from \(format(result.frequencies.first ?? 0)) Hz to \(format(result.frequencies.last ?? 0)) Hz")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                netSelectionControls(names)

                Chart {
                    ForEach(activeSeries.filter { plotNames.contains($0.name) }, id: \.name) { item in
                        ForEach(item.response) { point in
                            LineMark(
                                x: .value("Frequency (Hz)", point.freqHz),
                                y: .value(yLabel, magnitude(activeSeries, signal: item.name, point: point))
                            )
                            .foregroundStyle(by: .value("Signal", item.name))
                        }
                    }
                }
                .chartXScale(type: document.settings.acSweepType == .lin ? .linear : .log)
                .chartXAxisLabel("Frequency (Hz)")
                .chartYAxisLabel(yLabel)
                .frame(height: 240)

                Chart {
                    ForEach(activeSeries.filter { plotNames.contains($0.name) }, id: \.name) { item in
                        ForEach(item.response) { point in
                            LineMark(
                                x: .value("Frequency (Hz)", point.freqHz),
                                y: .value("Phase (degrees)", phase(activeSeries, signal: item.name, point: point))
                            )
                            .foregroundStyle(by: .value("Signal", item.name))
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

    private func series(_ result: CircuitSimResult.ACResult) -> [(name: String, response: [FreqPoint])] {
        switch acQuantity {
        case .voltage:
            return result.nodes.map { ($0.name, $0.response) }
        case .current:
            return result.components.map { ($0.name, $0.response) }
        }
    }

    @ViewBuilder
    private func exportPanel(_ result: CircuitSimResult) -> some View {
        let csv = CircuitResultExport.csv(result)
        GroupBox("Export") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Copy CSV") { copyToPasteboard(csv) }
                    Text("\(max(0, csv.split(separator: "\n").count - 1)) data rows")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ScrollView([.horizontal, .vertical]) {
                    Text(csv)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
        }
    }

    private func copyToPasteboard(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    private func netSelectionControls(_ names: [String], showReference: Bool = true) -> some View {
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

                if showReference {
                    Picker("Reference", selection: $document.settings.inputNetName) {
                        Text("Absolute").tag(String?.none)
                        ForEach(names, id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                    .frame(maxWidth: 240)
                }
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

    private func magnitude(
        _ series: [(name: String, response: [FreqPoint])],
        signal: String,
        point: FreqPoint
    ) -> Double {
        guard let reference = document.settings.inputNetName,
              reference != signal,
              let referencePoint = referencePoint(in: series, named: reference, at: point.freqHz) else {
            return point.magnitudeDb
        }
        return point.magnitudeDb - referencePoint.magnitudeDb
    }

    private func phase(
        _ series: [(name: String, response: [FreqPoint])],
        signal: String,
        point: FreqPoint
    ) -> Double {
        guard let reference = document.settings.inputNetName,
              reference != signal,
              let referencePoint = referencePoint(in: series, named: reference, at: point.freqHz) else {
            return point.phaseDeg
        }
        var delta = point.phaseDeg - referencePoint.phaseDeg
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return delta
    }

    private func referencePoint(
        in series: [(name: String, response: [FreqPoint])],
        named name: String,
        at frequency: Double
    ) -> FreqPoint? {
        series.first { $0.name == name }?.response.first { $0.freqHz == frequency }
    }

    private func format(_ value: Double) -> String {
        String(format: "%.4g", value)
    }
}
