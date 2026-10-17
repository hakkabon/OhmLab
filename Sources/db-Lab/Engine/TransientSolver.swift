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

    public func run(startTime: Double, stopTime: Double, maxSteps: Int) throws -> Result {
        guard stopTime > startTime else {
            throw CircuitSolveError.invalidElement("Transient stop time")
        }
        let stepCount = Int(((stopTime - startTime) / timestep).rounded(.up))
        guard stepCount > 0, stepCount <= maxSteps else {
            throw CircuitSolveError.invalidElement("Transient step count")
        }

        // Initial condition: DC operating point with sources at `startTime`.
        let operatingPoint = try circuit.solveOperatingPoint(atTime: startTime)
        var capacitorVoltage = [Double](repeating: 0, count: circuit.elements.count)
        var inductorCurrent = [Double](repeating: 0, count: circuit.elements.count)
        var diodeVoltage: [Int: Double] = [:]
        for (index, element) in circuit.elements.enumerated() {
            switch element.kind {
            case .capacitor:
                let voltage = operatingPoint.nodeVoltages[element.nodeA]
                    - operatingPoint.nodeVoltages[element.nodeB]
                capacitorVoltage[index] = voltage.re
            case .inductor:
                inductorCurrent[index] = operatingPoint.elementCurrents[index].re
            case .diode:
                let voltage = operatingPoint.nodeVoltages[element.nodeA]
                    - operatingPoint.nodeVoltages[element.nodeB]
                diodeVoltage[index] = voltage.re
            case .resistor, .voltageSource, .currentSource:
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
            let time = startTime + Double(step) * timestep
            let solution = try circuit.solveTransientStep(
                timestep: timestep,
                time: time,
                capacitorVoltage: capacitorVoltage,
                inductorCurrent: inductorCurrent,
                diodeBias: diodeVoltage
            )
            for (index, element) in circuit.elements.enumerated() {
                switch element.kind {
                case .capacitor:
                    let voltage = solution.nodeVoltages[element.nodeA]
                        - solution.nodeVoltages[element.nodeB]
                    capacitorVoltage[index] = voltage.re
                case .inductor:
                    inductorCurrent[index] = solution.elementCurrents[index].re
                case .diode:
                    let voltage = solution.nodeVoltages[element.nodeA]
                        - solution.nodeVoltages[element.nodeB]
                    diodeVoltage[index] = voltage.re
                case .resistor, .voltageSource, .currentSource:
                    break
                }
            }
            times.append(time)
            record(solution)
        }

        return Result(times: times, nodeSeries: nodeSeries, componentSeries: componentSeries)
    }
}
