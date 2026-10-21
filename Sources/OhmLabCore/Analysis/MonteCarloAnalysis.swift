// MonteCarloAnalysis.swift
// Tolerance-driven Monte Carlo: sample component values (and optionally
// temperature) from their tolerances, solve each trial's DC operating point, and
// summarise the distribution of the chosen probes.

import Foundation

public struct MonteCarloRequest: Sendable {
    public var netlist: String
    public var settings: AnalysisSettings
    /// Per-component tolerances. Designators not found in the netlist are
    /// reported and ignored.
    public var tolerances: [ComponentTolerance]
    /// A tolerance applied to every passive (R/L/C) device not listed above.
    public var defaultTolerance: ComponentTolerance?
    public var samples: Int
    public var seed: UInt64
    /// Nominal ambient temperature in °C (sets a `.temp` card). Defaults to the
    /// netlist's own value, or 27 °C when a temperature tolerance is requested.
    public var temperature: Double?
    /// ± °C ambient temperature tolerance, added as another random variable.
    public var temperatureTolerance: Double?
    public var probes: [CircuitProbe]
    public var limits: [ProbeLimit]
    public var libraries: [SpiceModelLibrary]

    public init(
        netlist: String,
        settings: AnalysisSettings = .default,
        tolerances: [ComponentTolerance] = [],
        defaultTolerance: ComponentTolerance? = nil,
        samples: Int = 1000,
        seed: UInt64 = 1,
        temperature: Double? = nil,
        temperatureTolerance: Double? = nil,
        probes: [CircuitProbe] = [],
        limits: [ProbeLimit] = [],
        libraries: [SpiceModelLibrary] = []
    ) {
        self.netlist = netlist
        self.settings = settings
        self.tolerances = tolerances
        self.defaultTolerance = defaultTolerance
        self.samples = samples
        self.seed = seed
        self.temperature = temperature
        self.temperatureTolerance = temperatureTolerance
        self.probes = probes
        self.limits = limits
        self.libraries = libraries
    }
}

public struct MonteCarloResult: Sendable, Equatable {
    public struct Statistic: Sendable, Equatable {
        public let probe: CircuitProbe
        public let nominal: Double
        public let mean: Double
        public let standardDeviation: Double
        public let minimum: Double
        public let maximum: Double
        public let values: [Double]
        /// Fraction of trials within the probe's limit, when one was given.
        public let yield: Double?
    }

    public let statistics: [Statistic]
    public let trials: Int
    public let failures: Int
    public let seed: UInt64
    public let warnings: [String]
}

public enum MonteCarloAnalysis {
    public static func run(_ request: MonteCarloRequest) throws -> MonteCarloResult {
        guard !request.probes.isEmpty else { throw AnalysisError.noProbes }
        guard request.samples >= 1 else { throw AnalysisError.allTrialsFailed(0) }

        let devices = NetlistValueRewriter.devices(in: request.netlist)
        let nominals = Dictionary(devices.map { ($0.designator, $0.value) }, uniquingKeysWith: { first, _ in first })
        var warnings: [String] = []

        // Resolve the effective tolerance for each variable, sorted by name so
        // the random draw order — and hence the run — is reproducible.
        var variables: [String: ComponentTolerance] = [:]
        for tolerance in request.tolerances {
            guard let designator = matchDesignator(tolerance.designator, in: devices) else {
                warnings.append("No editable component named \(tolerance.designator); its tolerance was ignored.")
                continue
            }
            variables[designator] = tolerance
        }
        if let fallback = request.defaultTolerance {
            for device in devices where device.kind.isPassive && variables[device.designator] == nil {
                variables[device.designator] = ComponentTolerance(
                    designator: device.designator,
                    relative: fallback.relative,
                    absolute: fallback.absolute,
                    distribution: fallback.distribution
                )
            }
        }
        let orderedVariables = variables.keys.sorted()
        if orderedVariables.isEmpty {
            warnings.append("No components carry a tolerance; every trial is the nominal circuit.")
        }

        let settings = request.settings.dcOnly()
        let nominalTemperature = request.temperature
            ?? (request.temperatureTolerance != nil ? 27 : nil)

        // The nominal operating point, validating the probes up front.
        let nominalNetlist = nominalNetlist(request.netlist, temperature: nominalTemperature)
        let nominalDC = try solveDC(nominalNetlist, settings: settings, libraries: request.libraries)
        let nominalValues = try request.probes.map { try $0.requiredValue(in: nominalDC) }

        var samples = [[Double]](repeating: [], count: request.probes.count)
        var failures = 0
        var generator = SeededGenerator(seed: request.seed)

        for _ in 0..<request.samples {
            try Task.checkCancellation()
            var values: [String: Double] = [:]
            for designator in orderedVariables {
                let tolerance = variables[designator]!
                let unit = generator.unitDraw(tolerance.distribution)
                values[designator] = tolerance.value(nominal: nominals[designator] ?? 0, unit: unit)
            }
            var text = NetlistValueRewriter.rewrite(request.netlist, values: values)
            if let tolerance = request.temperatureTolerance {
                let base = nominalTemperature ?? 27
                let temperature = base + generator.unitDraw(.uniform) * tolerance
                text = NetlistTemperature.setting(temperature, in: text)
            } else if let temperature = request.temperature {
                text = NetlistTemperature.setting(temperature, in: text)
            }

            guard let dc = try? solveDC(text, settings: settings, libraries: request.libraries) else {
                failures += 1
                continue
            }
            for (index, probe) in request.probes.enumerated() {
                if let value = probe.value(in: dc) {
                    samples[index].append(value)
                } else {
                    failures += 1
                }
            }
        }

        guard failures < request.samples || !samples.allSatisfy({ $0.isEmpty }) else {
            throw AnalysisError.allTrialsFailed(request.samples)
        }

        let statistics = request.probes.enumerated().map { index, probe -> MonteCarloResult.Statistic in
            let values = samples[index]
            let limit = request.limits.first { $0.probe == probe }
            let passed = limit.map { bound in values.filter(bound.contains).count }
            return MonteCarloResult.Statistic(
                probe: probe,
                nominal: nominalValues[index],
                mean: statisticsMean(values),
                standardDeviation: statisticsStandardDeviation(values),
                minimum: values.min() ?? .nan,
                maximum: values.max() ?? .nan,
                values: values,
                yield: limit == nil ? nil : Double(passed ?? 0) / Double(max(values.count, 1))
            )
        }

        return MonteCarloResult(
            statistics: statistics,
            trials: request.samples,
            failures: failures,
            seed: request.seed,
            warnings: warnings
        )
    }

    // MARK: - Helpers

    private static func nominalNetlist(_ netlist: String, temperature: Double?) -> String {
        guard let temperature else { return netlist }
        return NetlistTemperature.setting(temperature, in: netlist)
    }

    private static func solveDC(
        _ netlist: String,
        settings: AnalysisSettings,
        libraries: [SpiceModelLibrary]
    ) throws -> CircuitSimResult.DCResult {
        let result = try SimulationEngine.solve(netlist: netlist, settings: settings, libraries: libraries)
        guard let dc = result.dc else {
            throw CircuitSimulationError.noAnalysisSelected
        }
        return dc
    }

    /// The canonical designator for `name` in `devices` (case-insensitive).
    static func matchDesignator(_ name: String, in devices: [NetlistDevice]) -> String? {
        devices.first { $0.designator.caseInsensitiveCompare(name) == .orderedSame }?.designator
    }

    static func statisticsMean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        return values.reduce(0, +) / Double(values.count)
    }

    static func statisticsStandardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = statisticsMean(values)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }
}
