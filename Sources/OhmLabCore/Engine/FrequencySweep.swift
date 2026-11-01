import Foundation

/// How an AC sweep spaces its sample points.
public enum FrequencySweepType: String, Codable, Sendable, CaseIterable {
    /// Logarithmically, `count` points per decade.
    case dec
    /// Logarithmically, `count` points per octave.
    case oct
    /// Linearly, `count` total points including both endpoints.
    case lin
}

/// Generates frequency sample points for AC analysis. Kept independent of the
/// engine so the parser, settings, and solver share one definition of a sweep.
public enum FrequencySweep {
    /// Hard cap on generated samples, matching the engine's guard.
    public static let maxPointCount = 200_000

    /// Number of points a sweep would produce, computed without allocating it,
    /// so callers can reject runaway sweeps before building the array.
    public static func pointCount(
        from start: Double,
        to stop: Double,
        count: Int,
        type: FrequencySweepType
    ) -> Int {
        guard isValid(start: start, stop: stop, count: count) else { return 0 }
        switch type {
        case .lin:
            return count
        case .dec, .oct:
            let span = log(stop / start) / log(base(for: type))
            guard let intervals = intervalCount(span: span, count: count) else { return 0 }
            // Signal an oversized sweep without overflowing `intervals + 2`;
            // callers compare the result against `maxPointCount`.
            return intervals >= maxPointCount ? maxPointCount + 1 : intervals + 2
        }
    }

    public static func points(
        from start: Double,
        to stop: Double,
        count: Int,
        type: FrequencySweepType
    ) -> [Double] {
        guard isValid(start: start, stop: stop, count: count) else { return [] }
        switch type {
        case .lin:
            guard count > 1 else { return [start] }
            let step = (stop - start) / Double(count - 1)
            return (0..<count).map { start + Double($0) * step }
        case .dec, .oct:
            let base = base(for: type)
            let span = log(stop / start) / log(base)
            guard let intervals = intervalCount(span: span, count: count),
                  intervals <= maxPointCount else { return [] }
            var frequencies = (0...intervals).map { index in
                min(start * pow(base, Double(index) / Double(count)), stop)
            }
            if frequencies.last != stop { frequencies.append(stop) }
            return frequencies
        }
    }

    /// Number of logarithmic intervals, or nil when the sweep is not
    /// representable. The span can be infinite when `stop / start` overflows,
    /// so it is validated before the `Int` conversion.
    private static func intervalCount(span: Double, count: Int) -> Int? {
        guard span.isFinite, count > 0 else { return nil }
        let scaled = (span * Double(count)).rounded(.up)
        guard scaled.isFinite, scaled >= 1 else { return nil }
        guard scaled < Double(Int.max) else { return Int.max }
        return Int(scaled)
    }

    private static func base(for type: FrequencySweepType) -> Double {
        type == .oct ? 2 : 10
    }

    private static func isValid(start: Double, stop: Double, count: Int) -> Bool {
        start.isFinite && stop.isFinite && start > 0 && stop > start && count > 0
    }
}
