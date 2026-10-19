// PlotExport.swift
// Export helpers for a waveform plot: long-format CSV and a PNG snapshot.
//
// The PNG is produced from the same `PlotCanvas` used on screen (no gestures),
// so an exported image matches what the viewer shows.

import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum PlotExport {
    /// Long-format CSV: one row per sample, with the series name repeated. This
    /// keeps overlaid runs (whose x grids may differ) lossless.
    static func csv(series: [PlotSeries], xLabel: String, yLabel: String) -> String {
        var lines = ["# \(yLabel) vs \(xLabel)"]
        lines.append("\(sanitize(xLabel)),series,\(sanitize(yLabel))")
        for curve in series where curve.isVisible {
            for point in curve.points {
                lines.append("\(fmt(point.x)),\(sanitize(curve.name)),\(fmt(point.y))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Renders the plot to PNG data at `size`.
    @MainActor
    static func pngData(
        series: [PlotSeries],
        xScale: AxisScale,
        yScale: AxisScale,
        xLabel: String,
        yLabel: String,
        size: CGSize = CGSize(width: 1000, height: 360),
        cursorA: Double? = nil,
        cursorB: Double? = nil
    ) -> Data? {
        let transform = PlotTransform(
            viewport: PlotViewport.autoFit(series: series, xScale: xScale, yScale: yScale),
            xScale: xScale,
            yScale: yScale
        )
        let content = PlotCanvas(
            series: series,
            transform: transform,
            xLabel: xLabel,
            yLabel: yLabel,
            cursorA: cursorA,
            cursorB: cursorB
        )
        .background(Color.white)
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        #if os(macOS)
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
        #else
        return renderer.uiImage?.pngData()
        #endif
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.12g", value)
    }

    private static func sanitize(_ value: String) -> String {
        value.contains(",") ? "\"\(value)\"" : value
    }
}

/// A `FileDocument` for exporting a PNG plot snapshot.
struct PlotImageFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// A `FileDocument` for exporting a plot's CSV data.
struct PlotCSVFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
