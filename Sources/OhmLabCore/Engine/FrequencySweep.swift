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
            let intervals = max(1, Int((span * Double(count)).rounded(.up)))
            return intervals + 2
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
            let intervals = max(1, Int((span * Double(count)).rounded(.up)))
            var frequencies = (0...intervals).map { index in
                min(start * pow(base, Double(index) / Double(count)), stop)
            }
            if frequencies.last != stop { frequencies.append(stop) }
            return frequencies
        }
    }

    private static func base(for type: FrequencySweepType) -> Double {
        type == .oct ? 2 : 10
    }

    private static func isValid(start: Double, stop: Double, count: Int) -> Bool {
        start.isFinite && stop.isFinite && start > 0 && stop > start && count > 0
    }
}
