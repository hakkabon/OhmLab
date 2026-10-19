// WaveformPlotView.swift
// Interactive SwiftUI chart: pan, pinch-zoom, dual cursors, and delta readouts.
//
// The heavy geometry lives in `PlotModel`; this file owns only the pixel
// mapping, gesture handling, and drawing. The same `PlotCanvas` drawing is
// reused for image export (see `PlotExport`).

import SwiftUI

/// Palette cycled across series, stable for a given series index.
enum PlotPalette {
    static let colors: [Color] = [
        .blue, .red, .green, .orange, .purple,
        .teal, .pink, .brown, .cyan, .indigo,
    ]

    static func color(for index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}

/// The static drawing of a plot. Used both on screen and for export.
struct PlotCanvas: View {
    let series: [PlotSeries]
    let transform: PlotTransform
    let xLabel: String
    let yLabel: String
    var cursorA: Double?
    var cursorB: Double?

    private let leadingInset: CGFloat = 62
    private let trailingInset: CGFloat = 16
    private let topInset: CGFloat = 16
    private let bottomInset: CGFloat = 30

    var body: some View {
        Canvas { context, size in
            let plot = CGRect(
                x: leadingInset,
                y: topInset,
                width: max(0, size.width - leadingInset - trailingInset),
                height: max(0, size.height - topInset - bottomInset)
            )
            guard plot.width > 1, plot.height > 1 else { return }

            drawBackground(context: context, plot: plot)
            drawGrid(context: context, plot: plot)
            drawSeries(context: context, plot: plot)
            drawCursors(context: context, plot: plot)
            drawBorder(context: context, plot: plot)
            drawAxisLabels(context: context, plot: plot)
        }
    }

    // MARK: - Drawing stages

    private func drawBackground(context: GraphicsContext, plot: CGRect) {
        context.fill(Path(plot), with: .color(.secondary.opacity(0.06)))
    }

    private func drawGrid(context: GraphicsContext, plot: CGRect) {
        var gridPath = Path()
        for tick in xTicks {
            guard let unit = transform.unitX(tick.value) else { continue }
            let x = pixelX(unit: unit, in: plot)
            gridPath.move(to: CGPoint(x: x, y: plot.minY))
            gridPath.addLine(to: CGPoint(x: x, y: plot.maxY))
        }
        for tick in yTicks {
            guard let unit = transform.unitY(tick.value) else { continue }
            let y = pixelY(unit: unit, in: plot)
            gridPath.move(to: CGPoint(x: plot.minX, y: y))
            gridPath.addLine(to: CGPoint(x: plot.maxX, y: y))
        }
        context.stroke(gridPath, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)

        for tick in xTicks where !tick.label.isEmpty {
            guard let unit = transform.unitX(tick.value) else { continue }
            drawText(tick.label, context: context, at: CGPoint(x: pixelX(unit: unit, in: plot), y: plot.maxY + 14))
        }
        for tick in yTicks where !tick.label.isEmpty {
            guard let unit = transform.unitY(tick.value) else { continue }
            drawText(
                tick.label,
                context: context,
                at: CGPoint(x: plot.minX - 8, y: pixelY(unit: unit, in: plot)),
                anchor: .trailing
            )
        }
    }

    private func drawSeries(context: GraphicsContext, plot: CGRect) {
        var clipped = context
        clipped.clip(to: Path(plot))
        for (index, curve) in series.enumerated() where curve.isVisible {
            guard curve.points.count > 0 else { continue }
            let stride = decimationStride(count: curve.points.count, width: plot.width)
            var path = Path()
            var started = false
            var pointIndex = 0
            while pointIndex < curve.points.count {
                let point = curve.points[pointIndex]
                guard let ux = transform.unitX(point.x), let uy = transform.unitY(point.y) else {
                    pointIndex += stride
                    continue
                }
                let pixel = CGPoint(x: pixelX(unit: ux, in: plot), y: pixelY(unit: uy, in: plot))
                if started {
                    path.addLine(to: pixel)
                } else {
                    path.move(to: pixel)
                    started = true
                }
                pointIndex += stride
            }
            clipped.stroke(path, with: .color(PlotPalette.color(for: index)), lineWidth: 1.5)
        }
    }

    private func drawCursors(context: GraphicsContext, plot: CGRect) {
        let cursors: [(Double?, Color)] = [(cursorA, .gray), (cursorB, .secondary)]
        for (value, color) in cursors {
            guard let value, let unit = transform.unitX(value) else { continue }
            let x = pixelX(unit: unit, in: plot)
            guard plot.minX...plot.maxX ~= x else { continue }
            var path = Path()
            path.move(to: CGPoint(x: x, y: plot.minY))
            path.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    private func drawBorder(context: GraphicsContext, plot: CGRect) {
        context.stroke(Path(plot), with: .color(.secondary.opacity(0.5)), lineWidth: 1)
    }

    private func drawAxisLabels(context: GraphicsContext, plot: CGRect) {
        if !xLabel.isEmpty {
            drawText(xLabel, context: context, at: CGPoint(x: plot.midX, y: plot.maxY + 22), color: .secondary)
        }
        if !yLabel.isEmpty {
            var rotated = context
            rotated.translateBy(x: plot.minX - 44, y: plot.midY)
            rotated.rotate(by: .degrees(-90))
            rotated.draw(Text(yLabel).font(.system(size: 10)).foregroundStyle(.secondary), at: .zero)
        }
    }

    // MARK: - Helpers

    private func drawText(
        _ string: String,
        context: GraphicsContext,
        at point: CGPoint,
        anchor: UnitPoint = .center,
        color: Color = .primary
    ) {
        let text = Text(string).font(.system(size: 9)).foregroundStyle(color)
        context.draw(text, at: point, anchor: anchor)
    }

    private func pixelX(unit: Double, in plot: CGRect) -> CGFloat {
        plot.minX + CGFloat(unit) * plot.width
    }

    private func pixelY(unit: Double, in plot: CGRect) -> CGFloat {
        plot.maxY - CGFloat(unit) * plot.height
    }

    private var xTicks: [AxisTicks.Tick] {
        transform.xScale == .logarithmic
            ? AxisTicks.logarithmic(transform.viewport.x)
            : AxisTicks.linear(transform.viewport.x)
    }

    private var yTicks: [AxisTicks.Tick] {
        transform.yScale == .logarithmic
            ? AxisTicks.logarithmic(transform.viewport.y)
            : AxisTicks.linear(transform.viewport.y)
    }

    private func decimationStride(count: Int, width: CGFloat) -> Int {
        let target = max(2, Int(width / 1.5))
        return max(1, count / target)
    }
}

/// An interactive plot with pan/zoom and dual cursors.
struct WaveformPlotView: View {
    let series: [PlotSeries]
    let xLabel: String
    let yLabel: String
    var xScale: AxisScale = .linear
    var yScale: AxisScale = .linear
    var height: CGFloat = 260
    /// Optional run overlays: when present the legend/toggles are shown.
    var showsLegend: Bool = true

    @State private var viewport: PlotViewport?
    @State private var cursorA: Double?
    @State private var cursorB: Double?
    @State private var showCursors = false
    @State private var panStart: PlotViewport?
    @State private var zoomStart: PlotViewport?

    private var effectiveViewport: PlotViewport {
        (viewport ?? PlotViewport.autoFit(series: series, xScale: xScale, yScale: yScale))
            .withScales(xScale: xScale, yScale: yScale)
    }

    private var transform: PlotTransform {
        PlotTransform(viewport: effectiveViewport, xScale: xScale, yScale: yScale)
    }

    private var seriesSignature: String {
        series.map { "\($0.id):\($0.points.count):\($0.isVisible)" }.joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
            GeometryReader { geometry in
                ZStack {
                    PlotCanvas(
                        series: series,
                        transform: transform,
                        xLabel: xLabel,
                        yLabel: yLabel,
                        cursorA: cursorA,
                        cursorB: cursorB
                    )
                    .contentShape(Rectangle())
                    .gesture(panGesture(plotSize: geometry.size))
                    .gesture(zoomGesture(plotSize: geometry.size))
                    .onTapGesture(count: 2) { resetToFit() }

                    if showCursors {
                        cursorHandles(plotSize: geometry.size)
                    }
                }
            }
            .frame(height: height)

            if showCursors {
                cursorReadout
            }
            if showsLegend && series.count > 1 {
                legend
            }
        }
        .task(id: seriesSignature) {
            if viewport == nil { viewport = PlotViewport.autoFit(series: series, xScale: xScale, yScale: yScale) }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { zoom(by: 0.7) }
            } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { zoom(by: 1.4) }
            } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { resetToFit() }
            } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Fit to data")

            Toggle(isOn: $showCursors) {
                Image(systemName: "scope")
            }
            .toggleStyle(.button)
            .help("Cursors")

            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.caption)
    }

    // MARK: - Legend

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(series.enumerated()), id: \.element.id) { index, curve in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(PlotPalette.color(for: index))
                            .frame(width: 8, height: 8)
                        Text(curve.name)
                            .font(.caption2)
                            .foregroundStyle(curve.isVisible ? .primary : .secondary)
                    }
                }
            }
        }
    }

    // MARK: - Cursors

    private func cursorHandles(plotSize: CGSize) -> some View {
        let plot = CGRect(
            x: 62,
            y: 16,
            width: max(0, plotSize.width - 62 - 16),
            height: max(0, plotSize.height - 16 - 30)
        )
        return ZStack {
            cursorHandle(id: 0, value: cursorA, color: .gray, plot: plot) { cursorA = $0 }
            cursorHandle(id: 1, value: cursorB, color: .secondary, plot: plot) { cursorB = $0 }
        }
    }

    private func cursorHandle(
        id: Int,
        value: Double?,
        color: Color,
        plot: CGRect,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        let unitX = value.flatMap { transform.unitX($0) } ?? cursorDefaultUnit(id: id)
        let pixelX = plot.minX + CGFloat(unitX) * plot.width
        return Group {
            if plot.width > 1 {
                ZStack {
                    Rectangle()
                        .fill(color.opacity(0.001))
                        .frame(width: 22, height: plot.height)
                    Image(systemName: "arrowtriangle.down.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(color)
                        .offset(y: -plot.height / 2 + 4)
                }
                .position(x: pixelX, y: plot.midY)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let x = min(max(drag.location.x, plot.minX), plot.maxX)
                            let unit = Double((x - plot.minX) / max(plot.width, 1))
                            onChange(transform.dataX(unit: unit))
                        }
                )
            }
        }
    }

    private func cursorDefaultUnit(id: Int) -> Double {
        id == 0 ? 0.33 : 0.66
    }

    private var cursorReadout: some View {
        let a = cursorA
        let b = cursorB
        let dx = (a != nil && b != nil) ? abs(b! - a!) : nil
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 16) {
                Label("A \(format(a))", systemImage: "scope")
                Label("B \(format(b))", systemImage: "scope")
                if let dx { Text("Δx \(format(dx))") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if a != nil || b != nil {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    GridRow {
                        Text("Signal").fontWeight(.semibold)
                        Text("A").fontWeight(.semibold)
                        Text("B").fontWeight(.semibold)
                        Text("Δ").fontWeight(.semibold)
                    }
                    ForEach(Array(series.enumerated()), id: \.element.id) { index, curve in
                        let va = a.flatMap { curve.value(atX: $0) }
                        let vb = b.flatMap { curve.value(atX: $0) }
                        GridRow {
                            HStack(spacing: 4) {
                                Circle().fill(PlotPalette.color(for: index)).frame(width: 6, height: 6)
                                Text(curve.name)
                            }
                            Text(format(va)).monospacedDigit()
                            Text(format(vb)).monospacedDigit()
                            Text(format(delta(va, vb))).monospacedDigit()
                        }
                        .font(.caption2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Gestures

    private func panGesture(plotSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { drag in
                let start = panStart ?? effectiveViewport
                if panStart == nil { panStart = start }
                let plotWidth = max(0, plotSize.width - 62 - 16)
                let plotHeight = max(0, plotSize.height - 16 - 30)
                guard plotWidth > 1, plotHeight > 1 else { return }
                var next = start
                next.translate(
                    xByFraction: -Double(drag.translation.width / plotWidth),
                    yByFraction: Double(drag.translation.height / plotHeight)
                )
                viewport = next.withScales(xScale: xScale, yScale: yScale)
            }
            .onEnded { _ in panStart = nil }
    }

    private func zoomGesture(plotSize: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = zoomStart ?? effectiveViewport
                if zoomStart == nil { zoomStart = start }
                let factor = 1 / max(value.magnification, 0.05)
                let plotWidth = max(0, plotSize.width - 62 - 16)
                let anchorUnitX = Double(value.startLocation.x / max(plotWidth, 1))
                let anchorUnitY = Double((plotSize.height - 30 - value.startLocation.y) / max(plotSize.height - 46, 1))
                var next = start
                next.zoomX(by: factor, about: next.x.lower + anchorUnitX * next.x.span)
                next.zoomY(by: factor, about: next.y.lower + anchorUnitY * next.y.span)
                viewport = next.withScales(xScale: xScale, yScale: yScale)
            }
            .onEnded { _ in zoomStart = nil }
    }

    private func zoom(by factor: Double) {
        var next = effectiveViewport
        next.zoomX(by: factor, about: (next.x.lower + next.x.upper) / 2)
        next.zoomY(by: factor, about: (next.y.lower + next.y.upper) / 2)
        viewport = next.withScales(xScale: xScale, yScale: yScale)
    }

    private func resetToFit() {
        viewport = PlotViewport.autoFit(series: series, xScale: xScale, yScale: yScale)
    }

    /// The cursors in data coordinates, exposed for export/readout.
    var cursorValues: (a: Double?, b: Double?) { (cursorA, cursorB) }

    private func delta(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b else { return nil }
        return b - a
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.4g", value)
    }
}
