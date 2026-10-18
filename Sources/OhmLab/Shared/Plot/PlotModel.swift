// PlotModel.swift
// Pure data model for the interactive waveform viewer.
//
// Everything here is value-typed and free of UI frameworks so the zoom/pan
// arithmetic, axis ticks, and cursor sampling can be unit-tested directly. The
// SwiftUI layer (`WaveformPlotView`) only maps pixels to unit coordinates and
// back through `PlotTransform`.

import Foundation

/// How an axis maps values to screen space.
public enum AxisScale: String, Sendable, CaseIterable, Identifiable {
    case linear
    case logarithmic

    public var id: Self { self }
}

/// One sample of a curve.
public struct PlotPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A named curve. `id` is stable across updates so SwiftUI can diff it.
public struct PlotSeries: Sendable, Identifiable {
    public let id: String
    public var name: String
    public var points: [PlotPoint]
    public var isVisible: Bool

    public init(id: String, name: String, points: [PlotPoint], isVisible: Bool = true) {
        self.id = id
        self.name = name
        self.points = points
        self.isVisible = isVisible
    }

    /// Interpolated value at `x`, using the nearest two samples. Returns nil
    /// when the series is empty or `x` lies outside its extent (open ends are
    /// not extrapolated).
    public func value(atX x: Double) -> Double? {
        guard let first = points.first, let last = points.last else { return nil }
        if x < first.x || x > last.x { return nil }
        // Points are assumed sorted by x; binary search for the bracketing pair.
        var low = 0
        var high = points.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if points[mid].x <= x { low = mid } else { high = mid }
        }
        let a = points[low]
        let b = points[high]
        if b.x == a.x { return a.y }
        let fraction = (x - a.x) / (b.x - a.x)
        return a.y + (b.y - a.y) * fraction
    }
}

/// A closed, non-empty numeric interval.
public struct PlotDomain: Sendable, Equatable {
    public var lower: Double
    public var upper: Double

    public init(lower: Double, upper: Double) {
        self.lower = lower
        self.upper = upper
    }

    public var span: Double { upper - lower }

    public func contains(_ value: Double) -> Bool {
        value >= lower && value <= upper
    }

    /// Restricts this domain to values that are valid for the given scale
    /// (positive for a logarithmic axis).
    public func sanitized(for scale: AxisScale) -> PlotDomain {
        switch scale {
        case .linear:
            return self
        case .logarithmic:
            let lower = max(self.lower, PlotDomain.logMinimum)
            let upper = max(self.upper, lower * 1.000001)
            return PlotDomain(lower: lower, upper: upper)
        }
    }

    static let logMinimum = 1e-12
}

/// The visible window of a plot, in data coordinates.
public struct PlotViewport: Sendable, Equatable {
    public var x: PlotDomain
    public var y: PlotDomain

    public init(x: PlotDomain, y: PlotDomain) {
        self.x = x
        self.y = y
    }

    /// Zooms about a data-space anchor. `factor` below one zooms in, above one
    /// zooms out; the anchor point stays fixed on screen.
    public mutating func zoomX(by factor: Double, about anchor: Double) {
        x = PlotViewport.zoomed(x, by: factor, about: anchor)
    }

    public mutating func zoomY(by factor: Double, about anchor: Double) {
        y = PlotViewport.zoomed(y, by: factor, about: anchor)
    }

    /// Pans by a fraction of the current span along each axis.
    public mutating func translate(xByFraction xFraction: Double, yByFraction yFraction: Double) {
        let dx = x.span * xFraction
        let dy = y.span * yFraction
        x = PlotDomain(lower: x.lower + dx, upper: x.upper + dx)
        y = PlotDomain(lower: y.lower + dy, upper: y.upper + dy)
    }

    /// Clamps the viewport so it never escapes a bounded data region, keeping
    /// the span intact where possible.
    public mutating func clamp(x bounds: PlotDomain, y yBounds: PlotDomain) {
        x = PlotViewport.clamped(x, to: bounds)
        y = PlotViewport.clamped(y, to: yBounds)
    }

    private static func zoomed(_ domain: PlotDomain, by factor: Double, about anchor: Double) -> PlotDomain {
        let lower = anchor + (domain.lower - anchor) * factor
        let upper = anchor + (domain.upper - anchor) * factor
        if upper - lower < 1e-15 { return domain }
        return PlotDomain(lower: lower, upper: upper)
    }

    private static func clamped(_ domain: PlotDomain, to bounds: PlotDomain) -> PlotDomain {
        guard bounds.span > 0 else { return domain }
        if domain.span >= bounds.span { return bounds }
        if domain.lower < bounds.lower {
            let shift = bounds.lower - domain.lower
            return PlotDomain(lower: domain.lower + shift, upper: domain.upper + shift)
        }
        if domain.upper > bounds.upper {
            let shift = bounds.upper - domain.upper
            return PlotDomain(lower: domain.lower + shift, upper: domain.upper + shift)
        }
        return domain
    }

    /// A viewport that encloses every visible series with a little padding,
    /// expanded a hair when a dimension is degenerate (a flat or single-point
    /// curve).
    public static func autoFit(
        series: [PlotSeries],
        xScale: AxisScale = .linear,
        yScale: AxisScale = .linear,
        padding: Double = 0.08
    ) -> PlotViewport {
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        for curve in series where curve.isVisible {
            for point in curve.points {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
        }
        guard minX.isFinite, maxX.isFinite, minY.isFinite, maxY.isFinite else {
            return PlotViewport(
                x: PlotDomain(lower: 0, upper: 1),
                y: PlotDomain(lower: 0, upper: 1)
            )
        }
        return PlotViewport(
            x: padded(minX, maxX, padding: padding),
            y: padded(minY, maxY, padding: padding)
        ).withScales(xScale: xScale, yScale: yScale)
    }

    /// Applies scale-specific sanitisation (log axes need positive bounds).
    public func withScales(xScale: AxisScale, yScale: AxisScale) -> PlotViewport {
        PlotViewport(x: x.sanitized(for: xScale), y: y.sanitized(for: yScale))
    }

    private static func padded(_ lower: Double, _ upper: Double, padding: Double) -> PlotDomain {
        if upper - lower < 1e-12 {
            let center = (upper + lower) / 2
            let half = max(abs(center) * 0.05, 0.5)
            return PlotDomain(lower: center - half, upper: center + half)
        }
        let pad = (upper - lower) * padding
        return PlotDomain(lower: lower - pad, upper: upper + pad)
    }
}

/// Maps between data coordinates and normalised unit space ([0, 1] across the
/// plot). Handles linear and logarithmic axes.
public struct PlotTransform: Sendable {
    public let viewport: PlotViewport
    public let xScale: AxisScale
    public let yScale: AxisScale

    public init(viewport: PlotViewport, xScale: AxisScale, yScale: AxisScale) {
        self.viewport = viewport
        self.xScale = xScale
        self.yScale = yScale
    }

    /// Unit position of `x`, or nil when a log axis cannot represent it.
    public func unitX(_ x: Double) -> Double? {
        PlotTransform.normalize(x, in: viewport.x, scale: xScale)
    }

    /// Unit position of `y` (0 at the bottom of the domain), or nil for an
    /// invalid log value.
    public func unitY(_ y: Double) -> Double? {
        PlotTransform.normalize(y, in: viewport.y, scale: yScale)
    }

    public func dataX(unit: Double) -> Double {
        PlotTransform.denormalize(unit, in: viewport.x, scale: xScale)
    }

    public func dataY(unit: Double) -> Double {
        PlotTransform.denormalize(unit, in: viewport.y, scale: yScale)
    }

    private static func normalize(_ value: Double, in domain: PlotDomain, scale: AxisScale) -> Double? {
        switch scale {
        case .linear:
            guard domain.span != 0 else { return nil }
            return (value - domain.lower) / domain.span
        case .logarithmic:
            guard value > 0, domain.lower > 0, domain.upper > domain.lower else { return nil }
            let lower = log10(domain.lower)
            let upper = log10(domain.upper)
            return (log10(value) - lower) / (upper - lower)
        }
    }

    private static func denormalize(_ unit: Double, in domain: PlotDomain, scale: AxisScale) -> Double {
        switch scale {
        case .linear:
            return domain.lower + unit * domain.span
        case .logarithmic:
            let lower = log10(max(domain.lower, PlotDomain.logMinimum))
            let upper = log10(max(domain.upper, domain.lower * 1.000001))
            return pow(10, lower + unit * (upper - lower))
        }
    }
}

/// Axis tick generation for both linear and logarithmic axes.
public enum AxisTicks {
    public struct Tick: Sendable, Equatable {
        public let value: Double
        public let label: String
    }

    /// Up to `target` "nice" ticks across a linear domain.
    public static func linear(_ domain: PlotDomain, target: Int = 6) -> [Tick] {
        guard domain.span > 0, target > 1 else { return [] }
        let rawStep = domain.span / Double(target)
        let magnitude = pow(10, floor(log10(rawStep)))
        let normalized = rawStep / magnitude
        let niceNormalized: Double
        if normalized <= 1 { niceNormalized = 1 }
        else if normalized <= 2 { niceNormalized = 2 }
        else if normalized <= 5 { niceNormalized = 5 }
        else { niceNormalized = 10 }
        let step = niceNormalized * magnitude

        var ticks: [Tick] = []
        var value = ceil(domain.lower / step) * step
        while value <= domain.upper + step * 1e-9 {
            ticks.append(Tick(value: value, label: format(value)))
            value += step
        }
        return ticks
    }

    /// Decade ticks (with generational sub-ticks folded into the label) for a
    /// logarithmic domain.
    public static func logarithmic(_ domain: PlotDomain) -> [Tick] {
        let lower = max(domain.lower, PlotDomain.logMinimum)
        let upper = max(domain.upper, lower * 10)
        let first = Int(floor(log10(lower)))
        let last = Int(ceil(log10(upper)))
        var ticks: [Tick] = []
        for exponent in first...last {
            for mantissa in [1.0, 2.0, 5.0] {
                let value = mantissa * pow(10, Double(exponent))
                if value < lower || value > upper { continue }
                ticks.append(Tick(value: value, label: mantissa == 1 ? format(value) : ""))
            }
        }
        return ticks
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.4g", value)
    }
}
