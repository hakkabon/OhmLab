// DesignYield.swift
// Analysis-aware design metrics and yield estimation for the optimiser.
//
// A design metric names one scalar read from a solved circuit: a DC operating
// point, an AC response at a frequency, or a transient value at a time. Metric
// limits turn those scalars into design specifications, and a yield estimate
// samples component tolerances to measure how often a design satisfies every
// specification.

import Foundation

/// Which analysis an optimisation metric is read from.
public enum MetricAnalysis: String, Codable, Sendable, CaseIterable {
    case dc
    case ac
    case transient
}

/// Which part of an AC response a metric reads.
public enum ACMetric: String, Codable, Sendable, CaseIterable {
    /// Linear magnitude (`10^(dB/20)`).
    case magnitude
    /// Magnitude in decibels.
    case magnitudeDB
    /// Phase in degrees, interpolated across the shortest angular arc.
    case phaseDegrees
}

/// A scalar objective or design specification read from a solved circuit.
///
/// The text form is stable and round-trips through `parse`:
/// `v(out)` (DC), `ac:v(out)@1k` (linear magnitude), `acdb:v(out)@1k`,
/// `acph:v(out)@1k`, and `tran:v(out)@1m`.
public enum OptimizeMetric: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    case dc(CircuitProbe)
    case ac(CircuitProbe, frequencyHz: Double, quantity: ACMetric)
    case transient(CircuitProbe, time: Double)

    public var analysis: MetricAnalysis {
        switch self {
        case .dc: return .dc
        case .ac: return .ac
        case .transient: return .transient
        }
    }

    public var description: String {
        switch self {
        case .dc(let probe):
            return probe.description
        case .ac(let probe, let frequency, let quantity):
            let tag: String
            switch quantity {
            case .magnitude: tag = "ac"
            case .magnitudeDB: tag = "acdb"
            case .phaseDegrees: tag = "acph"
            }
            return "\(tag):\(probe)@\(Self.format(frequency))"
        case .transient(let probe, let time):
            return "tran:\(probe)@\(Self.format(time))"
        }
    }

    /// Parses the text form documented on `description`.
    public static func parse(_ text: String) -> OptimizeMetric? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let colon = trimmed.firstIndex(of: ":") else {
            guard let probe = CircuitProbe.parse(trimmed) else { return nil }
            return .dc(probe)
        }
        let tag = String(trimmed[trimmed.startIndex..<colon]).lowercased()
        let body = String(trimmed[trimmed.index(after: colon)...])
        switch tag {
        case "dc":
            guard let probe = CircuitProbe.parse(body) else { return nil }
            return .dc(probe)
        case "ac", "acdb", "acph", "acphase":
            guard let (probe, coordinate) = splitCoordinate(body),
                  let frequency = SpiceNumber.parse(coordinate),
                  frequency.isFinite, frequency > 0,
                  !isElementVoltage(probe) else {
                return nil
            }
            let quantity: ACMetric
            switch tag {
            case "acdb": quantity = .magnitudeDB
            case "acph", "acphase": quantity = .phaseDegrees
            default: quantity = .magnitude
            }
            return .ac(probe, frequencyHz: frequency, quantity: quantity)
        case "tran", "transient":
            guard let (probe, coordinate) = splitCoordinate(body),
                  let time = SpiceNumber.parse(coordinate),
                  time.isFinite, time >= 0,
                  !isElementVoltage(probe) else {
                return nil
            }
            return .transient(probe, time: time)
        default:
            return nil
        }
    }

    /// Reads the metric from a solved circuit. Returns `nil` when the requested
    /// analysis is absent, the probe has no matching series, or the coordinate
    /// falls outside the generated sweep.
    public func value(in result: CircuitSimResult) -> Double? {
        switch self {
        case .dc(let probe):
            guard let dc = result.dc else { return nil }
            return probe.value(in: dc)

        case .ac(let probe, let frequency, let quantity):
            guard let ac = result.ac, let points = Self.acSeries(probe, in: ac), !points.isEmpty else {
                return nil
            }
            return Self.interpolateAC(points, frequency: frequency, quantity: quantity)

        case .transient(let probe, let time):
            guard let transient = result.transient,
                  let series = Self.transientSeries(probe, in: transient),
                  !series.values.isEmpty else {
                return nil
            }
            return Self.interpolateTransient(series, time: time)
        }
    }

    /// Rejects metrics the result contract cannot represent or that fall
    /// outside the configured sweep.
    func validate(settings: AnalysisSettings) throws {
        switch self {
        case .dc:
            break
        case .ac(let probe, let frequency, _):
            guard !Self.isElementVoltage(probe) else {
                throw AnalysisError.invalidMetric(
                    "\(description): AC results carry element current, not element voltage"
                )
            }
            guard frequency.isFinite, frequency > 0 else {
                throw AnalysisError.invalidMetric(description)
            }
            guard frequency >= settings.acStartFrequency,
                  frequency <= settings.acStopFrequency else {
                throw AnalysisError.metricOutOfRange(
                    "\(description) is outside the AC sweep "
                    + "\(Self.format(settings.acStartFrequency))–"
                    + "\(Self.format(settings.acStopFrequency)) Hz"
                )
            }
        case .transient(let probe, let time):
            guard !Self.isElementVoltage(probe) else {
                throw AnalysisError.invalidMetric(
                    "\(description): transient results carry element current, not element voltage"
                )
            }
            guard time.isFinite, time >= settings.tranStart, time <= settings.tranStop else {
                throw AnalysisError.metricOutOfRange(
                    "\(description) is outside the transient window "
                    + "\(Self.format(settings.tranStart))–"
                    + "\(Self.format(settings.tranStop)) s"
                )
            }
        }
    }

    // MARK: - Helpers

    private static func format(_ value: Double) -> String {
        String(format: "%.12g", value)
    }

    private static func isElementVoltage(_ probe: CircuitProbe) -> Bool {
        if case .elementVoltage = probe { return true }
        return false
    }

    private static func splitCoordinate(_ text: String) -> (CircuitProbe, String)? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        let probeText = String(text[text.startIndex..<at])
        let coordinate = String(text[text.index(after: at)...])
        guard let probe = CircuitProbe.parse(probeText), !coordinate.isEmpty else { return nil }
        return (probe, coordinate)
    }

    private static func acSeries(
        _ probe: CircuitProbe,
        in ac: CircuitSimResult.ACResult
    ) -> [FreqPoint]? {
        switch probe {
        case .nodeVoltage(let name):
            return ac.nodes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.response
        case .elementCurrent(let name):
            return ac.components.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.response
        case .elementVoltage:
            return nil
        }
    }

    private static func transientSeries(
        _ probe: CircuitProbe,
        in transient: CircuitSimResult.TransientResult
    ) -> (times: [Double], values: [Double])? {
        switch probe {
        case .nodeVoltage(let name):
            guard let series = transient.nodes.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else { return nil }
            return (transient.times, series.values)
        case .elementCurrent(let name):
            guard let series = transient.components.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else { return nil }
            return (transient.times, series.values)
        case .elementVoltage:
            return nil
        }
    }

    private static func interpolateAC(
        _ points: [FreqPoint],
        frequency: Double,
        quantity: ACMetric
    ) -> Double? {
        guard let first = points.first, let last = points.last,
              frequency >= first.freqHz, frequency <= last.freqHz else {
            return nil
        }
        guard points.count > 1 else { return value(of: first, quantity: quantity) }

        // Find the last sample at or below the requested frequency.
        var low = 0
        var high = points.count - 1
        while low + 1 < high {
            let middle = (low + high) / 2
            if points[middle].freqHz <= frequency {
                low = middle
            } else {
                high = middle
            }
        }
        let lower = points[low]
        let upper = points[high]
        let span = log(upper.freqHz) - log(lower.freqHz)
        let fraction = span > 0
            ? (log(frequency) - log(lower.freqHz)) / span
            : 0
        let lowValue = value(of: lower, quantity: quantity)
        let highValue = value(of: upper, quantity: quantity)
        if quantity == .phaseDegrees {
            var delta = (highValue - lowValue).truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            return lowValue + delta * fraction
        }
        return lowValue + (highValue - lowValue) * fraction
    }

    private static func value(of point: FreqPoint, quantity: ACMetric) -> Double {
        switch quantity {
        case .magnitude: return pow(10, point.magnitudeDb / 20)
        case .magnitudeDB: return point.magnitudeDb
        case .phaseDegrees: return point.phaseDeg
        }
    }

    private static func interpolateTransient(
        _ series: (times: [Double], values: [Double]),
        time: Double
    ) -> Double? {
        let times = series.times
        let values = series.values
        guard times.count == values.count, !times.isEmpty else { return nil }
        guard time >= times[0], time <= times[times.count - 1] else { return nil }
        guard times.count > 1 else { return values[0] }

        // Find the last sample at or below the requested time.
        var low = 0
        var high = times.count - 1
        while low + 1 < high {
            let middle = (low + high) / 2
            if times[middle] <= time {
                low = middle
            } else {
                high = middle
            }
        }
        let span = times[high] - times[low]
        let fraction = span > 0 ? (time - times[low]) / span : 0
        return values[low] + (values[high] - values[low]) * fraction
    }
}

/// An allowed range for a design metric. A `nil` bound is ignored, and a
/// metric whose value cannot be read counts as a failure.
public struct MetricLimit: Codable, Equatable, Sendable {
    public var metric: OptimizeMetric
    public var minimum: Double?
    public var maximum: Double?

    public init(metric: OptimizeMetric, minimum: Double? = nil, maximum: Double? = nil) {
        self.metric = metric
        self.minimum = minimum
        self.maximum = maximum
    }

    public func contains(_ value: Double) -> Bool {
        if let minimum, value < minimum { return false }
        if let maximum, value > maximum { return false }
        return true
    }

    /// Signed distance to the nearest active bound, positive inside the band.
    /// Returns `nil` when the limit has no bounds.
    public func margin(_ value: Double) -> Double? {
        var margins: [Double] = []
        if let minimum { margins.append(value - minimum) }
        if let maximum { margins.append(maximum - value) }
        return margins.min()
    }
}

/// Statistical variation applied to a candidate design when estimating yield.
public struct YieldSpecification: Sendable, Equatable {
    /// Per-component tolerances, relative to the candidate's component values.
    public var tolerances: [ComponentTolerance]
    /// A tolerance applied to every passive device not listed above.
    public var defaultTolerance: ComponentTolerance?
    /// Number of Monte Carlo draws per yield estimate.
    public var samples: Int
    /// Deterministic seed. The same seed is used for every candidate so yield
    /// comparisons share common random numbers.
    public var seed: UInt64
    /// Nominal ambient temperature in °C.
    public var temperature: Double?
    /// ± °C ambient temperature tolerance.
    public var temperatureTolerance: Double?
    /// Design specifications the design must satisfy.
    public var limits: [MetricLimit]
    /// Refine the nominal optimum for yield. When false, the optimiser only
    /// reports the yield of its nominal result.
    public var refine: Bool
    /// Coarse seed points per variable for the yield refinement.
    public var gridDivisions: Int
    /// Pattern-search passes after the seed points.
    public var maxPasses: Int

    public init(
        tolerances: [ComponentTolerance] = [],
        defaultTolerance: ComponentTolerance? = nil,
        samples: Int = 64,
        seed: UInt64 = 1,
        temperature: Double? = nil,
        temperatureTolerance: Double? = nil,
        limits: [MetricLimit] = [],
        refine: Bool = true,
        gridDivisions: Int = 5,
        maxPasses: Int = 6
    ) {
        self.tolerances = tolerances
        self.defaultTolerance = defaultTolerance
        self.samples = samples
        self.seed = seed
        self.temperature = temperature
        self.temperatureTolerance = temperatureTolerance
        self.limits = limits
        self.refine = refine
        self.gridDivisions = gridDivisions
        self.maxPasses = maxPasses
    }
}

/// The estimated yield of one design.
public struct YieldReport: Sendable, Equatable {
    public struct LimitStatistic: Sendable, Equatable {
        public let metric: OptimizeMetric
        public let mean: Double
        public let minimum: Double
        public let maximum: Double
        /// Fraction of trials that satisfied this limit. A trial whose metric
        /// could not be read counts as a failure.
        public let yield: Double
    }

    /// Fraction of trials that satisfied every limit.
    public let overallYield: Double
    public let statistics: [LimitStatistic]
    public let trials: Int
    public let failures: Int
    public let seed: UInt64
    public let warnings: [String]
}

// MARK: - Yield evaluation

enum YieldEvaluation {
    /// Estimates the yield of `values` against `specification.limits`.
    /// `values` must name every variable so the candidate design is fully
    /// specified.
    static func estimate(
        netlist: String,
        values: [String: Double],
        specification: YieldSpecification,
        baseSettings: AnalysisSettings,
        libraries: [SpiceModelLibrary],
        baseDirectory: URL?
    ) throws -> YieldReport {
        guard !specification.limits.isEmpty else { throw AnalysisError.noYieldLimits }
        guard specification.samples >= 1 else { throw AnalysisError.invalidYieldSamples }

        let metrics = specification.limits.map(\.metric)
        for metric in metrics { try metric.validate(settings: baseSettings) }
        let settings = settingsFor(metrics: metrics, base: baseSettings)

        let designNetlist = NetlistValueRewriter.rewrite(netlist, values: values)
        let devices = NetlistValueRewriter.devices(in: designNetlist)
        let nominals = Dictionary(
            devices.map { ($0.designator, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        let resolved = MonteCarloAnalysis.resolveVariables(
            devices: devices,
            tolerances: specification.tolerances,
            defaultTolerance: specification.defaultTolerance
        )
        var warnings = resolved.warnings
        if resolved.variables.isEmpty {
            warnings.append("No components carry a tolerance; every trial is the candidate circuit.")
        }
        let orderedVariables = resolved.variables.keys.sorted()

        let temperature = specification.temperature
        let nominalTemperature = temperature
            ?? (specification.temperatureTolerance != nil ? 27 : nil)

        var samples = [[Double]](repeating: [], count: metrics.count)
        var passed = [Int](repeating: 0, count: metrics.count)
        var overallPasses = 0
        var failures = 0
        var generator = SeededGenerator(seed: specification.seed)

        for _ in 0..<specification.samples {
            try SimulationExecutionDeadline.check()
            var trialValues: [String: Double] = [:]
            for designator in orderedVariables {
                let tolerance = resolved.variables[designator]!
                let unit = generator.unitDraw(tolerance.distribution)
                trialValues[designator] = tolerance.value(
                    nominal: nominals[designator] ?? 0,
                    unit: unit
                )
            }
            var text = NetlistValueRewriter.rewrite(designNetlist, values: trialValues)
            if let temperatureTolerance = specification.temperatureTolerance {
                let draw = generator.unitDraw(.uniform)
                let ambient = (nominalTemperature ?? 27) + draw * temperatureTolerance
                text = NetlistTemperature.setting(ambient, in: text)
            } else if let temperature {
                text = NetlistTemperature.setting(temperature, in: text)
            }

            let result: CircuitSimResult
            do {
                result = try SimulationEngine.solve(
                    netlist: text,
                    settings: settings,
                    libraries: libraries,
                    baseDirectory: baseDirectory
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures += 1
                continue
            }

            var trialPassed = true
            for (index, metric) in metrics.enumerated() {
                guard let value = metric.value(in: result) else {
                    failures += 1
                    trialPassed = false
                    continue
                }
                samples[index].append(value)
                if specification.limits[index].contains(value) {
                    passed[index] += 1
                } else {
                    trialPassed = false
                }
            }
            if trialPassed { overallPasses += 1 }
        }

        let statistics = metrics.enumerated().map { index, metric in
            let values = samples[index]
            let denominator = Double(specification.samples)
            return YieldReport.LimitStatistic(
                metric: metric,
                mean: MonteCarloAnalysis.statisticsMean(values),
                minimum: values.min() ?? .nan,
                maximum: values.max() ?? .nan,
                yield: Double(passed[index]) / denominator
            )
        }

        return YieldReport(
            overallYield: Double(overallPasses) / Double(specification.samples),
            statistics: statistics,
            trials: specification.samples,
            failures: failures,
            seed: specification.seed,
            warnings: warnings
        )
    }

    /// The analysis settings needed to evaluate every metric.
    static func settingsFor(
        metrics: [OptimizeMetric],
        base: AnalysisSettings
    ) -> AnalysisSettings {
        var settings = base
        settings.runDC = true
        settings.runAC = metrics.contains { $0.analysis == .ac }
        settings.runTransient = metrics.contains { $0.analysis == .transient }
        settings.runDCSweep = false
        return settings
    }
}
