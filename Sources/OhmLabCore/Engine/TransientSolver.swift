// TransientSolver.swift
// Time-domain analysis for linear circuits.
//
// The circuit is linear, so each time step only needs the reactive elements
// replaced by backward-Euler companion models (a conductance plus a history
// current source) and the resulting resistive network solved once. The initial
// condition is the operating point at the start time, which gives capacitors
// their initial charge and inductors their initial current.

import Foundation

public struct TransientSolver: Sendable {
    public struct Result: Sendable {
        public let times: [Double]
        /// Node voltage series in the same order as `LinearCircuit.nodeNames`.
        public let nodeSeries: [[Double]]
        /// Element current series in the same order as `LinearCircuit.elements`.
        public let componentSeries: [[Double]]
    }

    public let circuit: LinearCircuit
    public let timestep: Double

    public init(circuit: LinearCircuit, timestep: Double) {
        self.circuit = circuit
        self.timestep = timestep
    }

    public func run(
        startTime: Double,
        stopTime: Double,
        maxSteps: Int,
        initialConditions: InitialConditions = InitialConditions(),
        useInitialConditionsOnly: Bool = false
    ) throws -> Result {
        guard stopTime > startTime else {
            throw CircuitSolveError.invalidElement("Transient stop time")
        }
        // Compute the step count in the Double domain first: a tiny timestep or
        // a huge span can overflow `Int` before the range check runs, which
        // traps instead of throwing. Reject anything outside `maxSteps`.
        let rawStepCount = ((stopTime - startTime) / timestep).rounded(.up)
        guard rawStepCount.isFinite,
              rawStepCount >= 1,
              rawStepCount <= Double(maxSteps) else {
            throw CircuitSolveError.invalidElement("Transient step count")
        }
        let stepCount = Int(rawStepCount)

        // Initial condition: normally the DC operating point with sources at
        // `startTime`. `UIC` (use initial conditions) skips that solve and
        // starts from zero state, with any `.ic` overrides applied on top.
        let rawOperatingPoint: LinearCircuit.Solution
        if useInitialConditionsOnly {
            rawOperatingPoint = LinearCircuit.Solution(
                nodeVoltages: [Complex](repeating: .zero, count: circuit.nodeCount),
                sourceCurrents: [],
                isDC: true,
                elementCurrents: [Complex](repeating: .zero, count: circuit.elements.count)
            )
        } else {
            rawOperatingPoint = try circuit.solveOperatingPoint(atTime: startTime)
        }
        let operatingPoint = initialConditions.applied(to: rawOperatingPoint, in: circuit)
        var capacitorVoltage = [Double](repeating: 0, count: circuit.elements.count)
        var inductorCurrent = [Double](repeating: 0, count: circuit.elements.count)
        var nonlinearState = circuit.nonlinearState(from: operatingPoint)
        for (index, element) in circuit.elements.enumerated() {
            switch element.kind {
            case .capacitor:
                let voltage = operatingPoint.nodeVoltages[element.nodeA]
                    - operatingPoint.nodeVoltages[element.nodeB]
                capacitorVoltage[index] = voltage.re
            case .inductor:
                inductorCurrent[index] = operatingPoint.elementCurrents[index].re
            case .resistor, .voltageSource, .currentSource, .diode, .bjt, .mosfet, .jfet:
                break
            }
        }

        let nodeCount = circuit.nodeCount
        let elementCount = circuit.elements.count
        var times: [Double] = [startTime]
        var nodeSeries = [[Double]](repeating: [], count: nodeCount)
        var componentSeries = [[Double]](repeating: [], count: elementCount)

        func record(_ solution: LinearCircuit.Solution) {
            for node in 0..<nodeCount {
                nodeSeries[node].append(solution.nodeVoltages[node].re)
            }
            for index in 0..<elementCount {
                componentSeries[index].append(solution.elementCurrents[index].re)
            }
        }

        record(operatingPoint)

        for step in 1...stepCount {
            try SimulationExecutionDeadline.check()
            let time = startTime + Double(step) * timestep
            let solution = try circuit.solveTransientStep(
                timestep: timestep,
                time: time,
                capacitorVoltage: capacitorVoltage,
                inductorCurrent: inductorCurrent,
                nonlinearState: nonlinearState
            )
            nonlinearState = circuit.nonlinearState(from: solution)
            for (index, element) in circuit.elements.enumerated() {
                switch element.kind {
                case .capacitor:
                    let voltage = solution.nodeVoltages[element.nodeA]
                        - solution.nodeVoltages[element.nodeB]
                    capacitorVoltage[index] = voltage.re
                case .inductor:
                    inductorCurrent[index] = solution.elementCurrents[index].re
                case .resistor, .voltageSource, .currentSource, .diode, .bjt, .mosfet, .jfet:
                    break
                }
            }
            times.append(time)
            record(solution)
        }

        return Result(times: times, nodeSeries: nodeSeries, componentSeries: componentSeries)
    }
}
