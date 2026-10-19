// Tolerance.swift
// Component tolerances and a deterministic RNG for statistical analyses.

import Foundation

/// How a tolerance draws its variation.
public enum ToleranceDistribution: String, Codable, Sendable, CaseIterable {
    /// Uniform over ±1.
    case uniform
    /// Bell-shaped, truncated to ±1 (standard deviation ≈ 0.29).
    case normal
}

/// The tolerance of one component: a relative (± fraction of nominal) and/or
/// absolute (± amount) half-width, plus its distribution.
public struct ComponentTolerance: Codable, Equatable, Sendable {
    public var designator: String
    /// Relative half-width, e.g. `0.05` for ±5%. Applied multiplicatively.
    public var relative: Double
    /// Absolute half-width, added to the relative spread. Applied additively.
    public var absolute: Double
    public var distribution: ToleranceDistribution

    public init(
        designator: String,
        relative: Double = 0.05,
        absolute: Double = 0,
        distribution: ToleranceDistribution = .uniform
    ) {
        self.designator = designator
        self.relative = relative
        self.absolute = absolute
        self.distribution = distribution
    }

    /// A varied value for `nominal`, given a signed unit draw `u` in [-1, 1].
    public func value(nominal: Double, unit u: Double) -> Double {
        nominal * (1 + relative * u) + absolute * u
    }

    /// The minimum and maximum values a nominal value can take.
    public func range(nominal: Double) -> ClosedRange<Double> {
        let spread = abs(nominal * relative) + abs(absolute)
        let low = nominal - spread
        let high = nominal + spread
        return low <= high ? low...high : high...low
    }
}

/// A deterministic, seedable generator (SplitMix64) so Monte Carlo runs are
/// reproducible and comparable.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A signed unit draw in [-1, 1] for the given distribution.
    mutating func unitDraw(_ distribution: ToleranceDistribution) -> Double {
        switch distribution {
        case .uniform:
            return Double.random(in: -1...1, using: &self)
        case .normal:
            // Box-Muller, truncated to ±1 (σ ≈ 0.29 for the raw draw, then
            // clamped) so normal components still respect their ± spec.
            let u1 = max(Double.random(in: 0..<1, using: &self), .leastNormalMagnitude)
            let u2 = Double.random(in: 0..<1, using: &self)
            let z = (sqrt(-2 * log(u1)) * cos(2 * .pi * u2)) / 3.4
            return min(1, max(-1, z))
        }
    }
}
