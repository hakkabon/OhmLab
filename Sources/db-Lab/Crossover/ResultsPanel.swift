// ResultsPanel.swift
// Simulation results: frequency response, impedance, and component summary.

import SwiftUI
import Charts

struct ResultsPanel: View {
    @ObservedObject var document: CrossoverDocument

    enum ResultTab: String, CaseIterable, Identifiable {
        case frequency  = "Frequency Response"
        case impedance  = "Impedance"
        case components = "Components"
        var id: String { rawValue }
    }

    @State private var selectedTab: ResultTab = .frequency
    @State private var showDriverCurves: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            if let error = document.simulationError {
                ErrorBanner(message: error)
            }

            if document.simulationResult != nil {
                Label(
                    "Demonstration data only — the generated circuit is not being solved yet.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 6)
            }

            if document.isSimulating {
                ProgressView("Simulating…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result = document.simulationResult {
                resultView(result)
            } else {
                ContentUnavailableView(
                    "No Results Yet",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("Hit ⌘↩ or click Simulate to run the simulation.")
                )
            }
        }
    }

    @ViewBuilder
    private func resultView(_ result: CrossoverSimResult) -> some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack {
                ForEach(ResultTab.allCases) { tab in
                    PanelTab(title: tab.rawValue, icon: "", isSelected: selectedTab == tab) {
                        selectedTab = tab
                    }
                }
                Spacer()
                if selectedTab == .frequency {
                    Toggle("Show individual drivers", isOn: $showDriverCurves)
                        #if os(macOS)
                        .toggleStyle(.checkbox)
                        #endif
                        .font(.caption)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            // Content
            switch selectedTab {
            case .frequency:
                FrequencyResponseChart(result: result, showDriverCurves: showDriverCurves)
            case .impedance:
                ImpedanceChart(result: result)
            case .components:
                ComponentSummaryView(document: document)
            }
        }
    }
}

// ─── Frequency response chart ─────────────────────────────────────────────────

struct FrequencyResponseChart: View {
    let result: CrossoverSimResult
    let showDriverCurves: Bool

    // dB axis range (±6dB around nominal with some headroom)
    private var dbRange: ClosedRange<Double> {
        let allDb = result.summedAcoustic.map(\.magnitudeDb)
        let min = allDb.min() ?? -40
        let max = allDb.max() ?? 10
        return (min - 3)...(max + 3)
    }

    private let driverColors: [Color] = [.blue, .red, .green, .orange, .purple, .pink]

    var body: some View {
        Chart {
            // Summed response
            ForEach(result.summedAcoustic) { pt in
                LineMark(
                    x: .value("Frequency", pt.freqHz),
                    y: .value("Level (dB)", pt.magnitudeDb),
                    series: .value("Curve", "Sum")
                )
                .foregroundStyle(.primary)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
                .interpolationMethod(.catmullRom)
            }

            // Per-driver curves
            if showDriverCurves {
                ForEach(Array(result.driverResults.enumerated()), id: \.element.id) { idx, dr in
                    ForEach(dr.acousticResponse) { pt in
                        LineMark(
                            x: .value("Frequency", pt.freqHz),
                            y: .value("Level (dB)", pt.magnitudeDb),
                            series: .value("Curve", dr.driverId)
                        )
                        .foregroundStyle(driverColors[idx % driverColors.count])
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .interpolationMethod(.catmullRom)
                    }
                }
            }

            // 0 dB reference
            RuleMark(y: .value("0 dB", 0))
                .foregroundStyle(.secondary.opacity(0.4))
                .lineStyle(StrokeStyle(dash: [3, 3]))
        }
        .chartXScale(type: .log)
        .chartXAxis {
            AxisMarks(values: [20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000]) { v in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let hz = v.as(Int.self) {
                        Text(hz >= 1000 ? "\(hz/1000)k" : "\(hz)").font(.caption)
                    }
                }
            }
        }
        .chartYScale(domain: dbRange)
        .chartYAxis {
            AxisMarks(values: .stride(by: 3)) { v in
                AxisGridLine()
                AxisTick()
                AxisValueLabel { if let db = v.as(Double.self) { Text("\(Int(db))dB").font(.caption) } }
            }
        }
        .chartXAxisLabel("Frequency (Hz)")
        .chartYAxisLabel("Level (dB)")
        .chartLegend(position: .topTrailing)
        .padding()
    }
}

// ─── Impedance chart ──────────────────────────────────────────────────────────

struct ImpedanceChart: View {
    let result: CrossoverSimResult

    var body: some View {
        Chart {
            ForEach(result.systemImpedance) { pt in
                LineMark(
                    x: .value("Frequency", pt.freqHz),
                    y: .value("Impedance (Ω)", pow(10, pt.magnitudeDb / 20))
                )
                .foregroundStyle(.blue)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }

            // 4Ω minimum impedance line
            RuleMark(y: .value("4Ω", 4))
                .foregroundStyle(.red.opacity(0.5))
                .lineStyle(StrokeStyle(dash: [4, 3]))
                .annotation(position: .top, alignment: .trailing) {
                    Text("4Ω min").font(.caption2).foregroundStyle(.red)
                }
        }
        .chartXScale(type: .log)
        .chartXAxis {
            AxisMarks(values: [20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000]) { v in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let hz = v.as(Int.self) { Text(hz >= 1000 ? "\(hz/1000)k" : "\(hz)").font(.caption) }
                }
            }
        }
        .chartYAxisLabel("Impedance (Ω)")
        .chartXAxisLabel("Frequency (Hz)")
        .padding()
    }
}

// ─── Component summary ────────────────────────────────────────────────────────

struct ComponentSummaryView: View {
    let document: CrossoverDocument

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(document.filters) { filter in
                    if !filter.components.isEmpty {
                        ComponentTable(
                            components: filter.components,
                            title: "\(filter.filterType.rawValue) — \(filter.driverName)"
                        )
                    }
                }
                ForEach(document.compensations) { comp in
                    if !comp.components.isEmpty {
                        ComponentTable(
                            components: comp.components,
                            title: "\(comp.kind.rawValue) — \(comp.driverName)"
                        )
                    }
                }

                if document.filters.allSatisfy({ $0.components.isEmpty }) &&
                   document.compensations.allSatisfy({ $0.components.isEmpty }) {
                    ContentUnavailableView(
                        "No Components Yet",
                        systemImage: "gear",
                        description: Text("Click 'Synthesize' in the Filters panel to calculate component values.")
                    )
                }
            }
            .padding()
        }
    }
}

// ─── Error banner ─────────────────────────────────────────────────────────────

struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message).font(.callout)
            Spacer()
        }
        .padding(10)
        .background(Color.red.opacity(0.1))
    }
}
