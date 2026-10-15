import Charts
import SwiftUI

struct CircuitSimulatorView: View {
    @ObservedObject var document: CircuitDocument

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    TextField("Circuit name", text: $document.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)

                    Spacer()

                    Button {
                        Task { await document.runSimulation() }
                    } label: {
                        if document.isSimulating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Run", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(document.isSimulating)
                }

                GroupBox("SPICE Netlist") {
                    TextEditor(text: $document.netlistText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 180)
                }

                analysisSettings

                if let error = document.simulationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }

                if let result = document.simulationResult {
                    if result.isMock {
                        Label(
                            "Demonstration data only — the SPICE netlist is not being solved yet.",
                            systemImage: "info.circle"
                        )
                        .foregroundStyle(.secondary)
                    }
                    if let dc = result.dc {
                        dcResults(dc)
                    }
                    if let ac = result.ac {
                        acResults(ac)
                    }
                    if let transient = result.tran {
                        transientResults(transient)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(document.name)
    }

    private var analysisSettings: some View {
        GroupBox("Analysis") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("DC operating point", isOn: $document.runDC)
                Toggle("AC frequency sweep", isOn: $document.runAC)
                if document.runAC {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Start frequency (Hz)")
                            TextField("Start frequency", value: $document.acFStart, format: .number)
                                .frame(maxWidth: 160)
                        }
                        GridRow {
                            Text("Stop frequency (Hz)")
                            TextField("Stop frequency", value: $document.acFStop, format: .number)
                                .frame(maxWidth: 160)
                        }
                        GridRow {
                            Text("Points per decade")
                            TextField("Points per decade", value: $document.acPointsPerDecade, format: .number)
                                .frame(maxWidth: 160)
                        }
                    }
                }
                Toggle("Transient analysis", isOn: $document.runTRAN)
                if document.runTRAN {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Stop time (s)")
                            TextField("Stop time", value: $document.tranTStop, format: .number)
                                .frame(maxWidth: 160)
                        }
                        GridRow {
                            Text("Time step (s)")
                            TextField("Time step", value: $document.tranTStep, format: .number)
                                .frame(maxWidth: 160)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        GroupBox("AC Frequency Response") {
            VStack(alignment: .leading) {
                Text("\(result.frequencies.count) frequency points")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Chart {
                    ForEach(result.nodes, id: \.name) { node in
                        ForEach(node.response) { point in
                            LineMark(
                                x: .value("Frequency (Hz)", point.freqHz),
                                y: .value("Magnitude (dB)", point.magnitudeDb)
                            )
                            .foregroundStyle(by: .value("Node", node.name))
                        }
                    }
                }
                .chartXScale(type: .log)
                .chartXAxisLabel("Frequency (Hz)")
                .chartYAxisLabel("Magnitude (dB)")
                .frame(height: 260)

                Chart {
                    ForEach(result.nodes, id: \.name) { node in
                        ForEach(node.response) { point in
                            LineMark(
                                x: .value("Frequency (Hz)", point.freqHz),
                                y: .value("Phase (degrees)", point.phaseDeg)
                            )
                            .foregroundStyle(by: .value("Node", node.name))
                        }
                    }
                }
                .chartXScale(type: .log)
                .chartXAxisLabel("Frequency (Hz)")
                .chartYAxisLabel("Phase (degrees)")
                .frame(height: 220)
            }
        }
    }

    private func transientResults(_ result: CircuitSimResult.TRANResult) -> some View {
        GroupBox("Transient Response") {
            Chart {
                ForEach(result.nodes, id: \.name) { node in
                    ForEach(Array(result.timePoints.enumerated()), id: \.offset) { entry in
                        if entry.offset < node.waveform.count {
                            LineMark(
                                x: .value("Time (s)", entry.element),
                                y: .value("Voltage (V)", node.waveform[entry.offset])
                            )
                            .foregroundStyle(by: .value("Node", node.name))
                        }
                    }
                }
            }
            .chartXAxisLabel("Time (s)")
            .chartYAxisLabel("Voltage (V)")
            .frame(height: 260)
        }
    }
}
