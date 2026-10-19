// Waveform.swift
// Time-domain source shapes used by transient analysis. Each case evaluates to
// a real value at a given time, so the transient solver only needs to ask a
// source "what is your value now?" at each step.

import Foundation

public struct WaveformPoint: Sendable, Equatable {
    public let time: Double
    public let value: Double

    public init(time: Double, value: Double) {
        self.time = time
        self.value = value
    }
}

public enum Waveform: Sendable, Equatable {
    case pulse(
        initial: Double,
        pulsed: Double,
        delay: Double,
        riseTime: Double,
        fallTime: Double,
        pulseWidth: Double,
        period: Double
    )
    case sine(
        offset: Double,
        amplitude: Double,
        frequency: Double,
        delay: Double,
        damping: Double,
        phaseDegrees: Double
    )
    case pwl(points: [WaveformPoint])

    public func value(at time: Double) -> Double {
        switch self {
        case .pulse(let initial, let pulsed, let delay, let riseTime, let fallTime, let pulseWidth, let period):
            return Self.pulseValue(
                time: time,
                initial: initial,
                pulsed: pulsed,
                delay: delay,
                riseTime: riseTime,
                fallTime: fallTime,
                pulseWidth: pulseWidth,
                period: period
            )
        case .sine(let offset, let amplitude, let frequency, let delay, let damping, let phaseDegrees):
            return Self.sineValue(
                time: time,
                offset: offset,
                amplitude: amplitude,
                frequency: frequency,
                delay: delay,
                damping: damping,
                phaseDegrees: phaseDegrees
            )
        case .pwl(let points):
            return Self.pwlValue(time: time, points: points)
        }
    }

    private static func pulseValue(
        time: Double,
        initial: Double,
        pulsed: Double,
        delay: Double,
        riseTime: Double,
        fallTime: Double,
        pulseWidth: Double,
        period: Double
    ) -> Double {
        let shifted = time - delay
        if shifted < 0 { return initial }

        let cycle = period > 0 ? shifted.truncatingRemainder(dividingBy: period) : shifted
        let rise = max(0, riseTime)
        if rise > 0, cycle < rise {
            return initial + (pulsed - initial) * (cycle / rise)
        }
        let afterRise = cycle - rise
        if afterRise < pulseWidth { return pulsed }
        let fall = max(0, fallTime)
        let afterHigh = afterRise - pulseWidth
        if fall > 0, afterHigh < fall {
            return pulsed + (initial - pulsed) * (afterHigh / fall)
        }
        return initial
    }

    private static func sineValue(
        time: Double,
        offset: Double,
        amplitude: Double,
        frequency: Double,
        delay: Double,
        damping: Double,
        phaseDegrees: Double
    ) -> Double {
        let shifted = time - delay
        if shifted < 0 { return offset }
        let angle = 2 * Double.pi * frequency * shifted + phaseDegrees * .pi / 180
        let envelope = damping != 0 ? exp(-damping * shifted) : 1
        return offset + amplitude * envelope * sin(angle)
    }

    private static func pwlValue(time: Double, points: [WaveformPoint]) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }
        for index in 1..<points.count {
            let lower = points[index - 1]
            let upper = points[index]
            guard time <= upper.time else { continue }
            let span = upper.time - lower.time
            guard span > 0 else { return upper.value }
            let fraction = (time - lower.time) / span
            return lower.value + (upper.value - lower.value) * fraction
        }
        return last.value
    }
}
