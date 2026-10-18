// SolverOptions.swift
// Numerical controls for the simulation engine.
//
// These mirror the subset of SPICE `.options` the engine can honour, plus the
// operating temperature from a `.temp`/`.options TEMP=…` card. They drive the
// Newton-Raphson convergence criteria, the junction leakage (`gmin`) shunts and
// the device thermal voltage, so a netlist that asks for tighter tolerances or a
// different temperature gets a correspondingly different answer.

import Foundation

public struct SolverOptions: Sendable, Equatable {
    /// `RELTOL`: relative tolerance for the Newton convergence test.
    public var relativeTolerance: Double
    /// `ABSTOL`: absolute current tolerance for the Newton convergence test.
    public var absoluteCurrentTolerance: Double
    /// `VNTOL`: absolute voltage tolerance for the Newton convergence test.
    public var absoluteVoltageTolerance: Double
    /// `GMIN`: minimum conductance placed across nonlinear junctions / a MOSFET
    /// channel, keeping the nodal matrix non-singular in cutoff.
    public var minimumConductance: Double
    /// `ITL1`: maximum Newton-Raphson iterations per solve.
    public var maximumIterations: Int
    /// `TEMP`: operating temperature in degrees Celsius.
    public var temperatureCelsius: Double
    /// `TNOM`: temperature at which the device models' thermal voltage is
    /// quoted, in degrees Celsius.
    public var nominalTemperatureCelsius: Double

    public static let `default` = SolverOptions()

    public init(
        relativeTolerance: Double = 1e-3,
        absoluteCurrentTolerance: Double = 1e-12,
        absoluteVoltageTolerance: Double = 1e-6,
        minimumConductance: Double = 1e-12,
        maximumIterations: Int = 100,
        temperatureCelsius: Double = 27,
        nominalTemperatureCelsius: Double = 27
    ) {
        self.relativeTolerance = relativeTolerance
        self.absoluteCurrentTolerance = absoluteCurrentTolerance
        self.absoluteVoltageTolerance = absoluteVoltageTolerance
        self.minimumConductance = minimumConductance
        self.maximumIterations = maximumIterations
        self.temperatureCelsius = temperatureCelsius
        self.nominalTemperatureCelsius = nominalTemperatureCelsius
    }

    // MARK: - Temperature

    private static let boltzmannConstant = 1.380_649e-23
    private static let elementaryCharge = 1.602_176_634e-19

    /// Operating temperature in kelvin.
    public var temperatureKelvin: Double { temperatureCelsius + 273.15 }

    /// Model nominal temperature in kelvin.
    public var nominalTemperatureKelvin: Double { nominalTemperatureCelsius + 273.15 }

    /// Thermal voltage at the operating temperature (`k·T/q`).
    public var thermalVoltage: Double {
        SolverOptions.boltzmannConstant * temperatureKelvin / SolverOptions.elementaryCharge
    }

    /// Factor to scale a device's nominal thermal voltage by, since the thermal
    /// voltage is proportional to absolute temperature. Equals one when the
    /// operating temperature matches the nominal temperature.
    public var thermalScale: Double {
        let nominal = nominalTemperatureKelvin
        guard temperatureKelvin > 0, nominal > 0 else { return 1 }
        return temperatureKelvin / nominal
    }

    /// A copy with any non-physical values replaced by their defaults, so a
    /// malformed `.options` card cannot poison a solve.
    public func sanitized() -> SolverOptions {
        let fallback = SolverOptions.default
        var copy = self
        if !(copy.relativeTolerance.isFinite && copy.relativeTolerance > 0) {
            copy.relativeTolerance = fallback.relativeTolerance
        }
        if !(copy.absoluteCurrentTolerance.isFinite && copy.absoluteCurrentTolerance > 0) {
            copy.absoluteCurrentTolerance = fallback.absoluteCurrentTolerance
        }
        if !(copy.absoluteVoltageTolerance.isFinite && copy.absoluteVoltageTolerance > 0) {
            copy.absoluteVoltageTolerance = fallback.absoluteVoltageTolerance
        }
        if !(copy.minimumConductance.isFinite && copy.minimumConductance > 0) {
            copy.minimumConductance = fallback.minimumConductance
        }
        copy.maximumIterations = min(max(copy.maximumIterations, 1), 10_000)
        if !(copy.temperatureCelsius.isFinite && copy.temperatureKelvin > 0) {
            copy.temperatureCelsius = fallback.temperatureCelsius
        }
        if !(copy.nominalTemperatureCelsius.isFinite && copy.nominalTemperatureKelvin > 0) {
            copy.nominalTemperatureCelsius = fallback.nominalTemperatureCelsius
        }
        return copy
    }
}
