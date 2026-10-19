// FourierAnalysis.swift
// Bounded-harmonic Fourier component analysis for a transient waveform.
//
// A `.four` card asks for the DC component and the harmonics of a chosen
// fundamental frequency, taken over the last period of a transient run. Because
// the transient trace is piecewise linear between samples, each harmonic's
// integral is evaluated in closed form on every segment instead of resampling
// the waveform onto a uniform grid, so no interpolation error is introduced.
//
// Convention (matches ngspice/Xyce): for a waveform v(t),
//     Cₙ = (1/T) ∫ v(t) e^{-j n ω₀ t} dt,
//     magnitudeₙ = 2|Cₙ|                    (n ≥ 1),
//     phaseₙ     = atan2(Im Cₙ, Re Cₙ) deg,
// so that v(t) ≈ DC + Σ magnitudeₙ cos(n ω₀ t + phaseₙ).

import Foundation

public enum FourierAnalysis {
    /// ngspice's default `nfreqs` (10) minus the DC term: the first nine harmonics.
    public static let defaultHarmonicCount = 9

    /// One harmonic of the fundamental, `number` starting at 1.
    public struct Harmonic: Sendable, Equatable {
        public let number: Int
        public let frequency: Double
        public let magnitude: Double
        public let phaseDegrees: Double
        /// Magnitude relative to the fundamental (1.0 for `number == 1`).
        public let normalizedMagnitude: Double
        /// Phase relative to the fundamental, wrapped to (−180, 180].
        public let normalizedPhaseDegrees: Double
    }

    public struct Result: Sendable, Equatable {
        public let fundamentalFrequency: Double
        /// Signed average (the n = 0 term).
        public let dcComponent: Double
        /// Harmonics 1…`harmonicCount`, ordered by increasing frequency.
        public let harmonics: [Harmonic]
        /// Total harmonic distortion in percent: √(Σ_{n≥2} magnitudeₙ²) / magnitude₁.
        public let totalHarmonicDistortion: Double
    }

    /// Analyzes `values` sampled at `times` over the last full period of
    /// `fundamentalFrequency`. Returns `nil` when the inputs are degenerate or
    /// the trace does not cover a full period.
    public static func analyze(
        times: [Double],
        values: [Double],
        fundamentalFrequency: Double,
        harmonicCount: Int = FourierAnalysis.defaultHarmonicCount
    ) -> Result? {
        guard fundamentalFrequency > 0, fundamentalFrequency.isFinite,
              harmonicCount > 0,
              times.count == values.count, times.count >= 3 else {
            return nil
        }
        let period = 1.0 / fundamentalFrequency
        guard let window = lastPeriod(times: times, values: values, period: period) else {
            return nil
        }
        let windowTimes = window.times
        let windowValues = window.values
        let duration = windowTimes[windowTimes.count - 1] - windowTimes[0]
        guard duration > 0 else { return nil }

        var dc = 0.0
        for index in 0..<(windowTimes.count - 1) {
            dc += 0.5 * (windowValues[index] + windowValues[index + 1])
                * (windowTimes[index + 1] - windowTimes[index])
        }
        dc /= duration

        let origin = windowTimes[0]
        var rawMagnitudes = [Double](repeating: 0, count: harmonicCount + 1)
        var rawPhases = [Double](repeating: 0, count: harmonicCount + 1)
        for n in 1...harmonicCount {
            let omega = 2.0 * Double.pi * Double(n) * fundamentalFrequency
            let coefficient = coefficient(
                times: windowTimes,
                values: windowValues,
                origin: origin,
                omega: omega
            )
            let real = coefficient.re / duration
            let imaginary = coefficient.im / duration
            rawMagnitudes[n] = 2.0 * (real * real + imaginary * imaginary).squareRoot()
            rawPhases[n] = atan2(imaginary, real) * 180.0 / Double.pi
        }

        let fundamental = rawMagnitudes[1]
        var overtones = 0.0
        if harmonicCount >= 2 {
            for n in 2...harmonicCount {
                overtones += rawMagnitudes[n] * rawMagnitudes[n]
            }
        }
        let thd = fundamental > 0 ? 100.0 * overtones.squareRoot() / fundamental : 0

        var harmonics: [Harmonic] = []
        for n in 1...harmonicCount {
            let normalizedPhase = wrap180(rawPhases[n] - rawPhases[1])
            harmonics.append(Harmonic(
                number: n,
                frequency: Double(n) * fundamentalFrequency,
                magnitude: rawMagnitudes[n],
                phaseDegrees: rawPhases[n],
                normalizedMagnitude: fundamental > 0 ? rawMagnitudes[n] / fundamental : 0,
                normalizedPhaseDegrees: n == 1 ? 0 : normalizedPhase
            ))
        }

        return Result(
            fundamentalFrequency: fundamentalFrequency,
            dcComponent: dc,
            harmonics: harmonics,
            totalHarmonicDistortion: thd
        )
    }

    // MARK: - Windowing

    /// Clips the trace to `[tEnd - period, tEnd]`, interpolating the endpoints.
    /// Returns `nil` when the trace is shorter than one period.
    private static func lastPeriod(
        times: [Double],
        values: [Double],
        period: Double
    ) -> (times: [Double], values: [Double])? {
        guard let first = times.first, let last = times.last, last > first else { return nil }
        let start = last - period
        guard start >= first - period * 1e-9 else { return nil }

        var windowTimes: [Double] = [start]
        var windowValues: [Double] = [sample(times: times, values: values, at: start)]
        for index in times.indices where times[index] > start && times[index] < last {
            windowTimes.append(times[index])
            windowValues.append(values[index])
        }
        windowTimes.append(last)
        windowValues.append(values[values.count - 1])
        return (windowTimes, windowValues)
    }

    private static func sample(times: [Double], values: [Double], at target: Double) -> Double {
        if target <= times[0] { return values[0] }
        if target >= times[times.count - 1] { return values[values.count - 1] }
        var low = 0
        var high = times.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if times[mid] <= target { low = mid } else { high = mid }
        }
        let span = times[high] - times[low]
        guard span > 0 else { return values[low] }
        let fraction = (target - times[low]) / span
        return values[low] + fraction * (values[high] - values[low])
    }

    // MARK: - Coefficient integration

    /// The complex Fourier integral ∫ v(t) e^{-jωt} dt over the window (the
    /// caller divides by the period), computed exactly on each piecewise-linear
    /// segment.
    private static func coefficient(
        times: [Double],
        values: [Double],
        origin: Double,
        omega: Double
    ) -> (re: Double, im: Double) {
        var totalRe = 0.0
        var totalIm = 0.0
        let omega2 = omega * omega
        for index in 0..<(times.count - 1) {
            let dt = times[index + 1] - times[index]
            guard dt > 0 else { continue }
            let v0 = values[index]
            let slope = (values[index + 1] - values[index]) / dt
            let theta = omega * dt
            let sinTheta = sin(theta)
            let cosTheta = cos(theta)

            // I0 = ∫ e^{-jωτ} dτ = (1 - e^{-jθ}) / (jω)
            let i0Re = sinTheta / omega
            let i0Im = -(1 - cosTheta) / omega
            // I1 = ∫ τ e^{-jωτ} dτ = [(cosθ + θ sinθ - 1) + j(θ cosθ - sinθ)] / ω²
            let i1Re = (cosTheta + theta * sinTheta - 1) / omega2
            let i1Im = (theta * cosTheta - sinTheta) / omega2

            let innerRe = v0 * i0Re + slope * i1Re
            let innerIm = v0 * i0Im + slope * i1Im

            // Multiply by e^{-jω(t_i - origin)}.
            let angle = omega * (times[index] - origin)
            let cosA = cos(angle)
            let sinA = sin(angle)
            totalRe += innerRe * cosA + innerIm * sinA
            totalIm += innerIm * cosA - innerRe * sinA
        }
        return (totalRe, totalIm)
    }

    private static func wrap180(_ angle: Double) -> Double {
        var wrapped = angle.truncatingRemainder(dividingBy: 360)
        if wrapped > 180 { wrapped -= 360 }
        if wrapped <= -180 { wrapped += 360 }
        return wrapped
    }
}
