// WaveformPlotPanel.swift
// A titled, exportable wrapper around `WaveformPlotView`.

import SwiftUI
import UniformTypeIdentifiers

struct WaveformPlotPanel: View {
    let title: String
    let series: [PlotSeries]
    let xLabel: String
    let yLabel: String
    var xScale: AxisScale = .linear
    var yScale: AxisScale = .linear
    var height: CGFloat = 260
    var showsLegend: Bool = true

    @State private var isExportingPNG = false
    @State private var isExportingCSV = false
    @State private var pngData: Data?
    @State private var exportError: String?

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Spacer()
                    Button {
                        pngData = PlotExport.pngData(
                            series: series,
                            xScale: xScale,
                            yScale: yScale,
                            xLabel: xLabel,
                            yLabel: yLabel
                        )
                        isExportingPNG = true
                    } label: {
                        Label("PNG", systemImage: "photo")
                    }
                    .help("Export the plot as a PNG image")

                    Button {
                        isExportingCSV = true
                    } label: {
                        Label("CSV", systemImage: "tablecells")
                    }
                    .help("Export the plotted data as CSV")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.caption)

                WaveformPlotView(
                    series: series,
                    xLabel: xLabel,
                    yLabel: yLabel,
                    xScale: xScale,
                    yScale: yScale,
                    height: height,
                    showsLegend: showsLegend
                )

                if let exportError {
                    Text(exportError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .fileExporter(
            isPresented: $isExportingPNG,
            document: PlotImageFileDocument(data: pngData ?? Data()),
            contentType: .png,
            defaultFilename: title
        ) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .fileExporter(
            isPresented: $isExportingCSV,
            document: PlotCSVFileDocument(text: PlotExport.csv(series: series, xLabel: xLabel, yLabel: yLabel)),
            contentType: .commaSeparatedText,
            defaultFilename: title
        ) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
    }
}
