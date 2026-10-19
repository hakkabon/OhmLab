import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct CircuitSimulatorView: View {
    @ObservedObject var document: CircuitDocument
    /// Explicit save request from the host document window. When nil (e.g.
    /// previews) the Save control is hidden.
    var onSave: (() -> Void)? = nil

    private enum ACQuantity: String, CaseIterable, Identifiable {
        case voltage
        case current

        var id: Self { self }
        var title: String { self == .voltage ? "Voltages" : "Currents" }
        var axisLabel: String { self == .voltage ? "Magnitude (dB)" : "Current (dB)" }
    }

    @State private var acQuantity: ACQuantity = .voltage
    @State private var fftWindow: SpectrumWindow = .hann
    @State private var fftDecibels = true
    @State private var isImporting = false
    @State private var isExportingNetlist = false
    @State private var isDropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                importBanner
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
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .fileExporter(
            isPresented: $isExportingNetlist,
            document: NetlistFileDocument(text: (try? document.netlistForExport()) ?? document.netlistText),
            contentType: .spiceNetlist,
            defaultFilename: document.name
        ) { result in
            if case .failure(let error) = result {
                document.simulationError = error.localizedDescription
            }
        }
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
            if let onSave {
                Button {
                    onSave()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }
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
            GroupBox {
                TextEditor(text: $document.netlistText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
            } label: {
                HStack {
                    Text("SPICE Netlist")
                    Spacer()
                    Button("Draw Schematic") {
                        document.importSchematic(document.netlistText, source: document.importSource)
                    }
                    .disabled(document.netlistText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Auto-layout this netlist as an editable schematic.")
                    Button("Paste") { pasteNetlist() }
                    Button("Clear") { document.netlistText = "" }
                    Button("Copy") { copyToPasteboard(document.netlistText) }
                    Button("Export…") { exportNetlist() }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }

    // MARK: - Import provenance

    @ViewBuilder
    private var importBanner: some View {
        if let source = document.importSource {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Label(
                            "Imported \(source.kind == .kicadSchematic ? "KiCad schematic" : "SPICE netlist")",
                            systemImage: "square.and.arrow.down"
                        )
                        Text(source.fileName)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .font(.callout)

                    if !document.importWarnings.isEmpty {
                        Text("\(document.importWarnings.count) note\(document.importWarnings.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(document.importWarnings, id: \.self) { warning in
                            Text("• \(warning)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func handleDrop(_ urls: [URL]) -> Bool {
        guard let url = urls.first else { return false }
        #if os(macOS)
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        #endif
        do {
            try document.importDesign(at: url)
            return true
        } catch {
            document.simulationError = error.localizedDescription
            return false
        }
    }

    private func exportNetlist() {
        isExportingNetlist = true
    }

    private func pasteNetlist() {
        #if os(macOS)
        if let text = NSPasteboard.general.string(forType: .string) {
            document.netlistText = text
        }
        #else
        if let text = UIPasteboard.general.string {
            document.netlistText = text
        }
        #endif
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

                    HStack {
                        Button("Use in Netlist editor") {
                            document.netlistText = text
                            document.usesSchematic = false
                        }
                        Button("Export Netlist…") { exportNetlist() }
                        Button("Copy") { copyToPasteboard(text) }
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
            Label("Solved by the OhmLab linear engine.", systemImage: "checkmark.seal")
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
                fftResults(transient)
            }
            if !result.fourier.isEmpty {
                fourierResults(result.fourier)
            }

            runHistoryPanel
        }
    }

    // MARK: - Run history / overlays

    @ViewBuilder
    private var runHistoryPanel: some View {
        if !document.runHistory.isEmpty {
            GroupBox("Runs") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Overlay completed runs on every plot.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") { document.clearRuns() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                    ForEach(document.runHistory) { run in
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { run.isOverlaid },
                                set: { _ in document.toggleRunOverlay(id: run.id) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            Text(run.label)
                                .font(.callout)
                            Spacer()
                            Button {
                                document.removeRun(id: run.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func fourierResults(_ results: [CircuitSimResult.FourierResult]) -> some View {
        GroupBox("Fourier Analysis") {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(results.enumerated()), id: \.offset) { entry in
                    let spectrum = entry.element.spectrum
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(entry.element.variable) @ \(format(entry.element.fundamentalFrequency)) Hz")
                            .fontWeight(.semibold)
                        Text("DC \(format(spectrum.dcComponent))  ·  THD \(String(format: "%.4g", spectrum.totalHarmonicDistortion))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                            GridRow {
                                Text("Harmonic").fontWeight(.semibold)
                                Text("Frequency").fontWeight(.semibold)
                                Text("Magnitude").fontWeight(.semibold)
                                Text("Rel.").fontWeight(.semibold)
                                Text("Phase").fontWeight(.semibold)
                            }
                            ForEach(Array(spectrum.harmonics.enumerated()), id: \.offset) { harmonic in
                                GridRow {
                                    Text("\(harmonic.element.number)")
                                    Text(String(format: "%.6g Hz", harmonic.element.frequency))
                                        .monospacedDigit()
                                    Text(String(format: "%.6g", harmonic.element.magnitude))
                                        .monospacedDigit()
                                    Text(String(format: "%.4g", harmonic.element.normalizedMagnitude))
                                        .monospacedDigit()
                                    Text(String(format: "%.4g°", harmonic.element.phaseDegrees))
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                    if entry.offset < results.count - 1 {
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func transientResults(_ result: CircuitSimResult.TransientResult) -> some View {
        let names = transientNames(result)
        let selected = Set(document.settings.outputNetNames)
        let plotNames = selected.isEmpty ? Set(names) : selected.intersection(names)
        let yLabel = acQuantity == .voltage ? "Voltage (V)" : "Current (A)"

        var series: [PlotSeries] = []
        for name in names where plotNames.contains(name) {
            series.append(PlotSeries(
                id: "live|\(name)",
                name: name,
                points: zip(result.times, transientValues(result, name: name)).map { PlotPoint(x: $0, y: $1) }
            ))
        }
        for run in document.overlaidRuns {
            guard let overlay = run.result.transient else { continue }
            for name in names where plotNames.contains(name) {
                series.append(PlotSeries(
                    id: "\(run.id)|\(name)",
                    name: "\(run.label) · \(name)",
                    points: zip(overlay.times, transientValues(overlay, name: name)).map { PlotPoint(x: $0, y: $1) }
                ))
            }
        }

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                quantityPicker
                Spacer()
                Text("\(result.times.count) points from \(format(result.times.first ?? 0)) s to \(format(result.times.last ?? 0)) s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            netSelectionControls(names, showReference: false)
            WaveformPlotPanel(
                title: "Transient Response",
                series: series,
                xLabel: "Time (s)",
                yLabel: yLabel
            )
        }
    }

    private func transientNames(_ result: CircuitSimResult.TransientResult) -> [String] {
        switch acQuantity {
        case .voltage: return result.nodes.map(\.name)
        case .current: return result.components.map(\.name)
        }
    }

    private func transientValues(_ result: CircuitSimResult.TransientResult, name: String) -> [Double] {
        switch acQuantity {
        case .voltage: return result.nodes.first { $0.name == name }?.values ?? []
        case .current: return result.components.first { $0.name == name }?.values ?? []
        }
    }

    private var quantityPicker: some View {
        Picker("Quantity", selection: $acQuantity) {
            ForEach(ACQuantity.allCases) { quantity in
                Text(quantity.title).tag(quantity)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 240)
    }

    // MARK: - FFT

    private func fftResults(_ transient: CircuitSimResult.TransientResult) -> some View {
        let series = fftSeries(transient)
        let yLabel = fftDecibels ? "Magnitude (dB)" : "Magnitude"
        return Group {
            if !series.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Picker("Window", selection: $fftWindow) {
                            ForEach(SpectrumWindow.allCases) { window in
                                Text(window.title).tag(window)
                            }
                        }
                        .frame(maxWidth: 220)
                        Toggle("dB", isOn: $fftDecibels)
                            .toggleStyle(.switch)
                        Spacer()
                    }
                    .font(.caption)

                    WaveformPlotPanel(
                        title: "Spectrum (FFT)",
                        series: series,
                        xLabel: "Frequency (Hz)",
                        yLabel: yLabel,
                        xScale: .logarithmic,
                        yScale: fftDecibels ? .linear : .logarithmic
                    )
                }
            }
        }
    }

    private func fftSeries(_ transient: CircuitSimResult.TransientResult) -> [PlotSeries] {
        let names = transientNames(transient)
        let selected = Set(document.settings.outputNetNames)
        let plotNames = selected.isEmpty ? Set(names) : selected.intersection(names)

        var series: [PlotSeries] = []
        func appendSpectrum(id: String, name: String, times: [Double], values: [Double]) {
            guard let spectrum = SpectrumAnalyzer.analyze(times: times, values: values, window: fftWindow) else { return }
            let points = spectrum.frequencies.enumerated()
                .filter { $0.element > 0 }
                .map { offset, frequency in
                    PlotPoint(
                        x: frequency,
                        y: fftDecibels ? spectrum.magnitudesDb[offset] : spectrum.magnitudes[offset]
                    )
                }
            guard points.count > 1 else { return }
            series.append(PlotSeries(id: id, name: name, points: points))
        }

        for name in names where plotNames.contains(name) {
            appendSpectrum(id: "fft|\(name)", name: name, times: transient.times, values: transientValues(transient, name: name))
        }
        for run in document.overlaidRuns {
            guard let overlay = run.result.transient else { continue }
            for name in names where plotNames.contains(name) {
                appendSpectrum(
                    id: "\(run.id)|fft|\(name)",
                    name: "\(run.label) · \(name)",
                    times: overlay.times,
                    values: transientValues(overlay, name: name)
                )
            }
        }
        return series
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
        let xLabel = result.axes.last?.name ?? "Sweep"
        let yLabel = acQuantity == .voltage ? "Voltage (V)" : "Current (A)"

        var series: [PlotSeries] = []
        func appendSweep(prefix: String, idPrefix: String, sweep: CircuitSimResult.SweepResult) {
            guard sweep.axes.last != nil else { return }
            let xIndex = sweep.axes.count - 1
            for name in names where plotNames.contains(name) {
                let points = sweep.points.compactMap { point -> PlotPoint? in
                    guard let y = sweepValue(point, name: name) else { return nil }
                    return PlotPoint(x: point.coordinates[xIndex].value, y: y)
                }
                guard !points.isEmpty else { continue }
                let outer = sweep.points.first?.coordinates.prefix(xIndex)
                    .map { "\($0.name)=\(format($0.value))" }
                    .joined(separator: ", ") ?? ""
                let label = outer.isEmpty ? "\(prefix)\(name)" : "\(prefix)\(name) (\(outer))"
                series.append(PlotSeries(id: "\(idPrefix)|\(name)|\(outer)", name: label, points: points))
            }
        }
        appendSweep(prefix: "", idPrefix: "live", sweep: result)
        for run in document.overlaidRuns {
            guard let overlay = run.result.sweep else { continue }
            appendSweep(prefix: "\(run.label) · ", idPrefix: "\(run.id)", sweep: overlay)
        }

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                quantityPicker
                Spacer()
                Text("\(result.points.count) operating points")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            netSelectionControls(names, showReference: false)
            WaveformPlotPanel(title: "DC Sweep", series: series, xLabel: xLabel, yLabel: yLabel)
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
        let xScale: AxisScale = document.settings.acSweepType == .lin ? .linear : .logarithmic

        var magnitudeSeries: [PlotSeries] = []
        var phaseSeries: [PlotSeries] = []
        func appendAC(prefix: String, idPrefix: String, curves: [(name: String, response: [FreqPoint])]) {
            for item in curves where plotNames.contains(item.name) {
                let magnitudePoints = item.response.map {
                    PlotPoint(x: $0.freqHz, y: magnitude(curves, signal: item.name, point: $0))
                }
                let phasePoints = item.response.map {
                    PlotPoint(x: $0.freqHz, y: phase(curves, signal: item.name, point: $0))
                }
                magnitudeSeries.append(PlotSeries(id: "\(idPrefix)|mag|\(item.name)", name: "\(prefix)\(item.name)", points: magnitudePoints))
                phaseSeries.append(PlotSeries(id: "\(idPrefix)|phase|\(item.name)", name: "\(prefix)\(item.name)", points: phasePoints))
            }
        }
        appendAC(prefix: "", idPrefix: "live", curves: activeSeries)
        for run in document.overlaidRuns {
            guard let overlay = run.result.ac else { continue }
            appendAC(prefix: "\(run.label) · ", idPrefix: "\(run.id)", curves: series(overlay))
        }

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                quantityPicker
                Spacer()
                Text("\(result.frequencies.count) points from \(format(result.frequencies.first ?? 0)) Hz to \(format(result.frequencies.last ?? 0)) Hz")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            netSelectionControls(names)
            WaveformPlotPanel(
                title: "AC Magnitude",
                series: magnitudeSeries,
                xLabel: "Frequency (Hz)",
                yLabel: yLabel,
                xScale: xScale
            )
            WaveformPlotPanel(
                title: "AC Phase",
                series: phaseSeries,
                xLabel: "Frequency (Hz)",
                yLabel: "Phase (degrees)",
                xScale: xScale
            )
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
