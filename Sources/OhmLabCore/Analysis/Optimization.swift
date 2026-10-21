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
    public var objective: CircuitProbe
    public var goal: OptimizeGoal
    /// Samples per variable in the coarse grid pass.
    public var gridDivisions: Int
    /// Maximum Nelder–Mead iterations after the grid pass.
    public var maxIterations: Int
    public var libraries: [SpiceModelLibrary]

    public init(
        netlist: String,
        settings: AnalysisSettings = .default,
        variables: [OptimizeVariable],
        objective: CircuitProbe,
        goal: OptimizeGoal = .maximize,
        gridDivisions: Int = 5,
        maxIterations: Int = 200,
        libraries: [SpiceModelLibrary] = []
    ) {
        self.netlist = netlist
        self.settings = settings
        self.variables = variables
        self.objective = objective
        self.goal = goal
        self.gridDivisions = gridDivisions
        self.maxIterations = maxIterations
        self.libraries = libraries
    }
}

public struct OptimizeResult: Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        public var values: [String: Double]
        public var objective: Double
    }

    public let bestValues: [String: Double]
    public let bestObjective: Double
    public let evaluations: Int
    public let failures: Int
    public let history: [Step]
}

public enum Optimization {
    /// Cap on the coarse grid's total point count.
    static let maxGridPoints = 1000

    public static func run(_ request: OptimizeRequest) throws -> OptimizeResult {
        guard !request.variables.isEmpty else { throw AnalysisError.noVariables }
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
        let settings = request.settings.dcOnly()

        var evaluations = 0
        var failures = 0
        var history: [OptimizeResult.Step] = []

        func evaluate(_ x: [Double]) throws -> (values: [String: Double], objective: Double, cost: Double) {
            try Task.checkCancellation()
            var values: [String: Double] = [:]
            for (index, bound) in bounds.enumerated() {
                values[bound.designator] = x[index]
            }
            let text = NetlistValueRewriter.rewrite(request.netlist, values: values)
            evaluations += 1
            let result: CircuitSimResult
            do {
                result = try SimulationEngine.solve(
                    netlist: text, settings: settings, libraries: request.libraries
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures += 1
                return (values, .nan, .infinity)
            }
            guard let dc = result.dc,
                  let objective = request.objective.value(in: dc) else {
                failures += 1
                return (values, .nan, .infinity)
            }
            history.append(OptimizeResult.Step(values: values, objective: objective))
            return (values, objective, request.goal.cost(of: objective))
        }

        // Coarse grid.
        var divisions = max(2, request.gridDivisions)
        while Int(pow(Double(divisions), Double(dimension))) > maxGridPoints && divisions > 2 {
            divisions -= 1
        }
        var bestX: [Double] = bounds.map { ($0.min + $0.max) / 2 }
        var bestCost = Double.infinity
        var bestObjective = Double.nan

        for point in grid(bounds: bounds, divisions: divisions) {
            try Task.checkCancellation()
            let outcome = try evaluate(point)
            if outcome.cost < bestCost {
                bestCost = outcome.cost
                bestObjective = outcome.objective
                bestX = point
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
        try Task.checkCancellation()
        let final = try evaluate(refined)
        if final.cost < bestCost {
            bestCost = final.cost
            bestObjective = final.objective
            bestX = refined
        }

        var bestValues: [String: Double] = [:]
        for (index, bound) in bounds.enumerated() {
            bestValues[bound.designator] = bestX[index]
        }
        return OptimizeResult(
            bestValues: bestValues,
            bestObjective: bestObjective,
            evaluations: evaluations,
            failures: failures,
            history: history
        )
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
