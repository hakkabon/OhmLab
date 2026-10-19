// Complex.swift
// Minimal complex-number type used by the linear circuit solver.

import Foundation

public struct Complex: Equatable, Sendable {
    public var re: Double
    public var im: Double

    public init(_ re: Double = 0, _ im: Double = 0) {
        self.re = re
        self.im = im
    }

    public static let zero = Complex(0, 0)
    public static let one = Complex(1, 0)

    public var magnitude: Double { (re * re + im * im).squareRoot() }

    /// Phase angle in degrees.
    public var phaseDegrees: Double {
        guard re != 0 || im != 0 else { return 0 }
        return atan2(im, re) * 180 / .pi
    }

    /// Magnitude expressed in decibels, floored to keep plots finite.
    public var magnitudeDecibels: Double {
        let m = magnitude
        guard m > 0 else { return -300 }
        return max(-300, 20 * log10(m))
    }

    public static func fromPolar(magnitude: Double, phaseDegrees: Double) -> Complex {
        let radians = phaseDegrees * .pi / 180
        return Complex(magnitude * cos(radians), magnitude * sin(radians))
    }

    public static func + (lhs: Complex, rhs: Complex) -> Complex {
        Complex(lhs.re + rhs.re, lhs.im + rhs.im)
    }

    public static func - (lhs: Complex, rhs: Complex) -> Complex {
        Complex(lhs.re - rhs.re, lhs.im - rhs.im)
    }

    public static prefix func - (value: Complex) -> Complex {
        Complex(-value.re, -value.im)
    }

    public static func * (lhs: Complex, rhs: Complex) -> Complex {
        Complex(
            lhs.re * rhs.re - lhs.im * rhs.im,
            lhs.re * rhs.im + lhs.im * rhs.re
        )
    }

    public static func / (lhs: Complex, rhs: Complex) -> Complex {
        let denominator = rhs.re * rhs.re + rhs.im * rhs.im
        guard denominator != 0 else { return .zero }
        return Complex(
            (lhs.re * rhs.re + lhs.im * rhs.im) / denominator,
            (lhs.im * rhs.re - lhs.re * rhs.im) / denominator
        )
    }

    public static func * (lhs: Complex, rhs: Double) -> Complex {
        Complex(lhs.re * rhs, lhs.im * rhs)
    }
}
