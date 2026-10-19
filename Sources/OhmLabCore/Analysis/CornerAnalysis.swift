// CornerAnalysis.swift
// Worst-case corner analysis: push every toleranced component (and optionally
// ambient temperature) to its minimum and maximum, evaluate every combination,
// and report the extreme value of each probe together with the corner that
// produced it.

import Foundation

public struct CornerRequest: Sendable {
    public var netlist: String
    public var settings: AnalysisSettings
    public var tolerances: [ComponentTolerance]
    public var defaultTolerance: ComponentTolerance?
    public var temperature: Double?
    public var temperatureTolerance: Double?
    public var probes: [CircuitProbe]
    /// Upper bound on the full-factorial corner count, to stop a run away.
    public var maxCorners: Int
    public var libraries: [SpiceModelLibrary]

    public init(
        netlist: String,
        settings: AnalysisSettings = .default,
        tolerances: [ComponentTolerance] = [],
        defaultTolerance: ComponentTolerance? = nil,
        temperature: Double? = nil,
        temperatureTolerance: Double? = nil,
        probes: [CircuitProbe] = [],
        maxCorners: Int = 4096,
        libraries: [SpiceModelLibrary] = []
    ) {
        self.netlist = netlist
        self.settings = settings
        self.tolerances = tolerances
        self.defaultTolerance = defaultTolerance
        self.temperature = temperature
        self.temperatureTolerance = temperatureTolerance
        self.probes = probes
        self.maxCorners = maxCorners
        self.libraries = libraries
    }
}

public struct CornerResult: Sendable, Equatable {
    public struct Extremes: Sendable, Equatable {
        public let probe: CircuitProbe
        public let minimum: Double
        public let maximum: Double
        /// The corner (designator → value; `TEMP` for temperature) at each extreme.
        public let minimumCorner: [String: Double]
        public let maximumCorner: [String: Double]
    }

    public let extremes: [Extremes]
    public let cornersEvaluated: Int
    public let failures: Int
    public let warnings: [String]
}

public enum CornerAnalysis {
    static let temperatureKey = "TEMP"

    public static func run(_ request: CornerRequest) throws -> CornerResult {
        guard !request.probes.isEmpty else { throw AnalysisError.noProbes }

        let devices = NetlistValueRewriter.devices(in: request.netlist)
        let nominals = Dictionary(devices.map { ($0.designator, $0.value) }, uniquingKeysWith: { first, _ in first })
        var warnings: [String] = []

        var variables: [String: ComponentTolerance] = [:]
        for tolerance in request.tolerances {
            guard let designator = MonteCarloAnalysis.matchDesignator(tolerance.designator, in: devices) else {
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

        // Each variable contributes a low/high corner; temperature adds two more.
        var cornerCount = 1
        for _ in orderedVariables { cornerCount *= 2 }
        let hasTemperature = request.temperatureTolerance != nil
        if hasTemperature { cornerCount *= 2 }
        guard cornerCount <= request.maxCorners else {
            throw AnalysisError.tooManyCorners(cornerCount)
        }

        let settings = request.settings.dcOnly()
        let nominalTemperature = request.temperature ?? (hasTemperature ? 27 : nil)

        // Precompute the two values per variable and the temperature pair.
        let valuePair: [String: (low: Double, high: Double)] = orderedVariables.reduce(into: [:]) { result, designator in
            let tolerance = variables[designator]!
            let range = tolerance.range(nominal: nominals[designator] ?? 0)
            result[designator] = (range.lowerBound, range.upperBound)
        }
        let temperaturePair: (low: Double, high: Double)? = hasTemperature
            ? ((nominalTemperature ?? 27) - request.temperatureTolerance!,
               (nominalTemperature ?? 27) + request.temperatureTolerance!)
            : nil

        var mins = [Double](repeating: .infinity, count: request.probes.count)
        var maxs = [Double](repeating: -.infinity, count: request.probes.count)
        var minCorner = [[String: Double]](repeating: [:], count: request.probes.count)
        var maxCorner = [[String: Double]](repeating: [:], count: request.probes.count)
        var failures = 0
        var evaluated = 0

        for corner in 0..<cornerCount {
            var bitIndex = 0
            var values: [String: Double] = [:]
            for designator in orderedVariables {
                let pair = valuePair[designator]!
                let useHigh = (corner >> bitIndex) & 1 == 1
                values[designator] = useHigh ? pair.high : pair.low
                bitIndex += 1
            }
            var temperature = nominalTemperature
            if let pair = temperaturePair {
                let useHigh = (corner >> bitIndex) & 1 == 1
                temperature = useHigh ? pair.high : pair.low
            }

            var text = NetlistValueRewriter.rewrite(request.netlist, values: values)
            if let temperature {
                text = NetlistTemperature.setting(temperature, in: text)
            }

            guard let dc = try? solveDC(text, settings: settings, libraries: request.libraries) else {
                failures += 1
                continue
            }
            evaluated += 1

            var assignment = values
            if let temperature { assignment[temperatureKey] = temperature }
            for (index, probe) in request.probes.enumerated() {
                guard let value = probe.value(in: dc) else { continue }
                if value < mins[index] {
                    mins[index] = value
                    minCorner[index] = assignment
                }
                if value > maxs[index] {
                    maxs[index] = value
                    maxCorner[index] = assignment
                }
            }
        }

        guard evaluated > 0 else { throw AnalysisError.allTrialsFailed(cornerCount) }

        let extremes = request.probes.enumerated().map { index, probe in
            CornerResult.Extremes(
                probe: probe,
                minimum: mins[index],
                maximum: maxs[index],
                minimumCorner: minCorner[index],
                maximumCorner: maxCorner[index]
            )
        }
        return CornerResult(
            extremes: extremes,
            cornersEvaluated: evaluated,
            failures: failures,
            warnings: warnings
        )
    }

    private static func solveDC(
        _ netlist: String,
        settings: AnalysisSettings,
        libraries: [SpiceModelLibrary]
    ) throws -> CircuitSimResult.DCResult {
        let result = try SimulationEngine.solve(netlist: netlist, settings: settings, libraries: libraries)
        guard let dc = result.dc else { throw CircuitSimulationError.noAnalysisSelected }
        return dc
    }
}
