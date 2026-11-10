// Optimization.swift
// A small parameter optimiser for DC objectives: a coarse grid search over each
// variable's range, refined by Nelder–Mead. It reuses the value rewriter, so the
// variables are ordinary component designators.

import Foundation

public struct OptimizeVariable: Codable, Equatable, Sendable {
    public var designator: String
    public var minimum: Double
    public var maximum: Double

    public init(designator: String, minimum: Double, maximum: Double) {
        self.designator = designator
        self.minimum = minimum
        self.maximum = maximum
    }
}

public enum OptimizeGoal: Codable, Equatable, Sendable {
    case maximize
    case minimize
    case target(Double)

    /// The scalar to minimise: the objective itself for `minimize`, its negation
    /// for `maximize`, and the distance to the target for `target`.
    func cost(of objective: Double) -> Double {
        switch self {
        case .minimize: return objective
        case .maximize: return -objective
        case .target(let value): return abs(objective - value)
        }
    }
}

public struct OptimizeRequest: Sendable {
    public var netlist: String
    public var settings: AnalysisSettings
    public var variables: [OptimizeVariable]
    /// DC objective probe. Used when `metric` is absent; retained for callers
    /// that optimise a plain operating-point probe.
    public var objective: CircuitProbe?
    /// Analysis-aware objective. Takes precedence over `objective`.
    public var metric: OptimizeMetric?
    public var goal: OptimizeGoal
    /// Optional yield reporting and centring. When present, the nominal
    /// optimum is measured against the limits and optionally refined to
    /// maximise the fraction of toleranced trials that satisfy them.
    public var yield: YieldSpecification?
    /// Samples per variable in the coarse grid pass.
    public var gridDivisions: Int
    /// Maximum Nelder–Mead iterations after the grid pass.
    public var maxIterations: Int
    public var libraries: [SpiceModelLibrary]
    /// Directory used to resolve relative `.include`/`.lib` paths.
    public var baseDirectory: URL?

    public init(
        netlist: String,
        settings: AnalysisSettings = .default,
        variables: [OptimizeVariable],
        objective: CircuitProbe? = nil,
        metric: OptimizeMetric? = nil,
        goal: OptimizeGoal = .maximize,
        yield: YieldSpecification? = nil,
        gridDivisions: Int = 5,
        maxIterations: Int = 200,
        libraries: [SpiceModelLibrary] = [],
        baseDirectory: URL? = nil
    ) {
        self.netlist = netlist
        self.settings = settings
        self.variables = variables
        self.objective = objective
        self.metric = metric
        self.goal = goal
        self.yield = yield
        self.gridDivisions = gridDivisions
        self.maxIterations = maxIterations
        self.libraries = libraries
        self.baseDirectory = baseDirectory
    }
}

public struct OptimizeResult: Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        public var values: [String: Double]
        public var objective: Double
    }

    public let metric: OptimizeMetric
    public let bestValues: [String: Double]
    public let bestObjective: Double
    public let evaluations: Int
    public let failures: Int
    public let history: [Step]
    /// The nominal optimum before yield refinement.
    public let nominalBestValues: [String: Double]
    public let nominalBestObjective: Double
    /// Yield of the nominal optimum, when a yield specification was supplied.
    public let nominalYield: YieldReport?
    /// Yield of the returned design. Equal to `nominalYield` when refinement
    /// was disabled or made no improvement.
    public let yield: YieldReport?
}

public enum Optimization {
    /// Cap on the coarse grid's total point count.
    static let maxGridPoints = 1000
    /// Cap on the seed points evaluated during yield refinement.
    static let maxYieldSeedPoints = 32

    public static func run(_ request: OptimizeRequest) throws -> OptimizeResult {
        guard !request.variables.isEmpty else { throw AnalysisError.noVariables }
        let metric = try resolvedMetric(request)
        try metric.validate(settings: request.settings)
        if let yield = request.yield {
            for limit in yield.limits { try limit.metric.validate(settings: request.settings) }
        }

        let devices = NetlistValueRewriter.devices(in: request.netlist)

        var bounds: [(designator: String, min: Double, max: Double)] = []
        for variable in request.variables {
            guard let designator = MonteCarloAnalysis.matchDesignator(variable.designator, in: devices) else {
                throw AnalysisError.unknownVariable(variable.designator)
            }
            guard variable.minimum < variable.maximum else {
                throw AnalysisError.invalidRange(variable.designator)
            }
            bounds.append((designator, variable.minimum, variable.maximum))
        }
        let dimension = bounds.count
        let settings = YieldEvaluation.settingsFor(metrics: [metric], base: request.settings)

        var evaluations = 0
        var failures = 0
        var history: [OptimizeResult.Step] = []

        func values(for x: [Double]) -> [String: Double] {
            var result: [String: Double] = [:]
            for (index, bound) in bounds.enumerated() {
                result[bound.designator] = x[index]
            }
            return result
        }

        func evaluate(_ x: [Double]) throws -> (values: [String: Double], objective: Double, cost: Double) {
            try SimulationExecutionDeadline.check()
            let values = values(for: x)
            let text = NetlistValueRewriter.rewrite(request.netlist, values: values)
            evaluations += 1
            let result: CircuitSimResult
            do {
                result = try SimulationEngine.solve(
                    netlist: text,
                    settings: settings,
                    libraries: request.libraries,
                    baseDirectory: request.baseDirectory
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures += 1
                return (values, .nan, .infinity)
            }
            guard let objective = metric.value(in: result) else {
                failures += 1
                return (values, .nan, .infinity)
            }
            history.append(OptimizeResult.Step(values: values, objective: objective))
            return (values, objective, request.goal.cost(of: objective))
        }

        // Coarse grid.
        var divisions = max(2, request.gridDivisions)
        while pointCount(divisions: divisions, dimension: dimension, cap: maxGridPoints) > maxGridPoints
            && divisions > 2 {
            divisions -= 1
        }
        var bestX: [Double] = bounds.map { ($0.min + $0.max) / 2 }
        var bestCost = Double.infinity
        var bestObjective = Double.nan

        if pointCount(divisions: divisions, dimension: dimension, cap: maxGridPoints) <= maxGridPoints {
            for point in grid(bounds: bounds, divisions: divisions) {
                try SimulationExecutionDeadline.check()
                let outcome = try evaluate(point)
                if outcome.cost < bestCost {
                    bestCost = outcome.cost
                    bestObjective = outcome.objective
                    bestX = point
                }
            }
        }

        // Nelder–Mead refinement from the best grid point.
        let initialStep = bounds.map { ($0.max - $0.min) / 4 }
        let refined = nelderMead(
            start: bestX,
            bounds: bounds.map { ($0.min, $0.max) },
            step: initialStep,
            maxIterations: request.maxIterations
        ) { x in
            guard !Task.isCancelled else { return .infinity }
            return (try? evaluate(x).cost) ?? .infinity
        }
        try SimulationExecutionDeadline.check()
        let final = try evaluate(refined)
        if final.cost < bestCost {
            bestCost = final.cost
            bestObjective = final.objective
            bestX = refined
        }

        let nominalBestValues = values(for: bestX)
        var finalValues = nominalBestValues
        var finalObjective = bestObjective
        var nominalYield: YieldReport?
        var finalYield: YieldReport?

        if let specification = request.yield {
            let baseline = try YieldEvaluation.estimate(
                netlist: request.netlist,
                values: nominalBestValues,
                specification: specification,
                baseSettings: request.settings,
                libraries: request.libraries,
                baseDirectory: request.baseDirectory
            )
            nominalYield = baseline
            finalYield = baseline

            if specification.refine, baseline.overallYield < 1 {
                func yieldEstimate(_ x: [Double]) throws -> YieldReport {
                    try YieldEvaluation.estimate(
                        netlist: request.netlist,
                        values: values(for: x),
                        specification: specification,
                        baseSettings: request.settings,
                        libraries: request.libraries,
                        baseDirectory: request.baseDirectory
                    )
                }
                let centred = try refineForYield(
                    start: bestX,
                    bounds: bounds,
                    divisions: specification.gridDivisions,
                    maxPasses: specification.maxPasses,
                    report: yieldEstimate
                )
                if centred.x != bestX {
                    let outcome = try evaluate(centred.x)
                    finalValues = outcome.values
                    finalObjective = outcome.objective
                    finalYield = centred.report
                }
            }
        }

        return OptimizeResult(
            metric: metric,
            bestValues: finalValues,
            bestObjective: finalObjective,
            evaluations: evaluations,
            failures: failures,
            history: history,
            nominalBestValues: nominalBestValues,
            nominalBestObjective: bestObjective,
            nominalYield: nominalYield,
            yield: finalYield
        )
    }

    private static func resolvedMetric(_ request: OptimizeRequest) throws -> OptimizeMetric {
        if let metric = request.metric { return metric }
        if let objective = request.objective { return .dc(objective) }
        throw AnalysisError.noObjective
    }

    /// Seeds a yield search with the nominal optimum, the range midpoint, and
    /// a bounded coarse grid, then runs a deterministic pattern search with
    /// halving steps. Every candidate is scored with the same random seed, so
    /// yield comparisons use common random numbers.
    private static func refineForYield(
        start: [Double],
        bounds: [(designator: String, min: Double, max: Double)],
        divisions: Int,
        maxPasses: Int,
        report: ([Double]) throws -> YieldReport
    ) throws -> (x: [Double], report: YieldReport) {
        let dimension = bounds.count
        guard dimension > 0 else { return (start, try report(start)) }

        var bestX = start
        var best = try report(start)
        guard best.overallYield < 1 else { return (bestX, best) }

        var seeds: [[Double]] = [start, bounds.map { ($0.min + $0.max) / 2 }]
        var seedDivisions = max(2, divisions)
        while seedDivisions > 2
            && pointCount(divisions: seedDivisions, dimension: dimension, cap: maxYieldSeedPoints) > maxYieldSeedPoints {
            seedDivisions -= 1
        }
        if pointCount(divisions: seedDivisions, dimension: dimension, cap: maxYieldSeedPoints) <= maxYieldSeedPoints {
            seeds.append(contentsOf: grid(bounds: bounds, divisions: seedDivisions))
        }

        var seen = Set<[Double]>([start])
        for seed in seeds {
            guard seen.insert(seed).inserted else { continue }
            try SimulationExecutionDeadline.check()
            let candidate = try report(seed)
            if candidate.overallYield > best.overallYield {
                bestX = seed
                best = candidate
            }
            if best.overallYield >= 1 { return (bestX, best) }
        }

        var steps = bounds.map { ($0.max - $0.min) / 8 }
        let minimumSteps = bounds.map { ($0.max - $0.min) * 1e-4 }
        for _ in 0..<max(0, maxPasses) {
            for index in bounds.indices {
                for direction in [1.0, -1.0] {
                    var candidate = bestX
                    let moved = candidate[index] + direction * steps[index]
                    candidate[index] = min(max(moved, bounds[index].min), bounds[index].max)
                    guard candidate[index] != bestX[index] else { continue }
                    try SimulationExecutionDeadline.check()
                    let estimate = try report(candidate)
                    if estimate.overallYield > best.overallYield {
                        bestX = candidate
                        best = estimate
                    }
                    if best.overallYield >= 1 { return (bestX, best) }
                }
            }
            steps = zip(steps, minimumSteps).map { max($0 * 0.5, $1) }
            if zip(steps, minimumSteps).allSatisfy({ $0 <= $1 }) { break }
        }
        return (bestX, best)
    }

    /// The number of points a full-factorial grid would produce, capped so the
    /// count cannot overflow for high-dimensional searches.
    private static func pointCount(divisions: Int, dimension: Int, cap: Int) -> Int {
        var count = 1
        for _ in 0..<dimension {
            if count > cap / max(divisions, 1) { return cap + 1 }
            count *= divisions
        }
        return count
    }

    /// A full-factorial grid over the variable ranges.
    static func grid(
        bounds: [(designator: String, min: Double, max: Double)],
        divisions: Int
    ) -> [[Double]] {
        var points: [[Double]] = [[]]
        for bound in bounds {
            let samples = (0..<divisions).map { index -> Double in
                let fraction = divisions <= 1 ? 0 : Double(index) / Double(divisions - 1)
                return bound.min + (bound.max - bound.min) * fraction
            }
            points = points.flatMap { prefix in samples.map { prefix + [$0] } }
        }
        return points
    }

    /// Classic Nelder–Mead simplex minimisation, clamped to the bounds.
    static func nelderMead(
        start: [Double],
        bounds: [(min: Double, max: Double)],
        step: [Double],
        maxIterations: Int,
        cost: ([Double]) -> Double
    ) -> [Double] {
        let n = start.count
        guard n > 0 else { return start }

        func clamp(_ x: [Double]) -> [Double] {
            x.enumerated().map { index, value in
                min(max(value, bounds[index].min), bounds[index].max)
            }
        }

        var simplex: [[Double]] = [clamp(start)]
        for index in 0..<n {
            var point = start
            point[index] += step[index]
            simplex.append(clamp(point))
        }
        var values = simplex.map(cost)

        for _ in 0..<maxIterations {
            let order = (0...n).sorted { values[$0] < values[$1] }
            simplex = order.map { simplex[$0] }
            values = order.map { values[$0] }
            if values[n] - values[0] < 1e-12 { break }

            var centroid = [Double](repeating: 0, count: n)
            for i in 0..<n {
                for d in 0..<n { centroid[d] += simplex[i][d] }
            }
            for d in 0..<n { centroid[d] /= Double(n) }

            let worst = simplex[n]
            let reflected = clamp((0..<n).map { d in centroid[d] + (centroid[d] - worst[d]) })
            let reflectedValue = cost(reflected)

            if reflectedValue < values[0] {
                let expanded = clamp((0..<n).map { d in centroid[d] + 2 * (centroid[d] - worst[d]) })
                let expandedValue = cost(expanded)
                if expandedValue < reflectedValue {
                    simplex[n] = expanded; values[n] = expandedValue
                } else {
                    simplex[n] = reflected; values[n] = reflectedValue
                }
            } else if reflectedValue < values[n - 1] {
                simplex[n] = reflected; values[n] = reflectedValue
            } else {
                let contracted = clamp((0..<n).map { d in centroid[d] + 0.5 * (worst[d] - centroid[d]) })
                let contractedValue = cost(contracted)
                if contractedValue < values[n] {
                    simplex[n] = contracted; values[n] = contractedValue
                } else {
                    for i in 1...n {
                        simplex[i] = clamp((0..<n).map { d in simplex[0][d] + 0.5 * (simplex[i][d] - simplex[0][d]) })
                        values[i] = cost(simplex[i])
                    }
                }
            }
        }

        let finalOrder = (0...n).sorted { values[$0] < values[$1] }
        return simplex[finalOrder[0]]
    }
}
