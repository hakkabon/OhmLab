// LinearCircuit.swift
// A dependency-free Modified Nodal Analysis (MNA) engine for linear circuits.
//
// Supported elements: resistor, capacitor, inductor, independent voltage source,
// and independent current source. Nonlinear devices are deliberately out of
// scope for the first milestone and are reported as unsupported elsewhere.
//
// Node indexing convention: node `0` is the ground reference. Matrix rows and
// columns 0..<n-1 correspond to circuit nodes 1...n-1. Voltage source branch
// currents occupy the remaining rows/columns.

import Foundation

public enum CircuitSolveError: LocalizedError {
    case noGround
    case noNodes
    case invalidElement(String)
    case unsupportedElement(String)

    public var errorDescription: String? {
        switch self {
        case .noGround:
            return "The circuit has no ground (node 0) reference."
        case .noNodes:
            return "The circuit contains no nodes to solve."
        case .invalidElement(let name):
            return "Element \(name) has an invalid or non-positive value."
        case .unsupportedElement(let name):
            return "Element \(name) is not supported by the linear solver yet."
        }
    }
}

public struct LinearCircuit: Sendable {
    public enum ElementKind: String, Sendable {
        case resistor
        case capacitor
        case inductor
        case voltageSource
        case currentSource
    }

    public struct Element: Sendable {
        public var kind: ElementKind
        public var nodeA: Int
        public var nodeB: Int
        /// Resistance, capacitance, inductance, or a source's fallback magnitude.
        public var value: Double
        public var phaseDegrees: Double
        /// DC magnitude for a source. When nil the source uses `value` for DC.
        public var dcValue: Double?
        /// AC magnitude for a source. When nil the source uses `value` for AC.
        public var acValue: Double?
        /// Time-domain shape for a source, used by transient analysis. When nil
        /// the source is constant at its DC magnitude.
        public var transient: Waveform?
        public var name: String

        public init(
            kind: ElementKind,
            nodeA: Int,
            nodeB: Int,
            value: Double,
            phaseDegrees: Double = 0,
            dcValue: Double? = nil,
            acValue: Double? = nil,
            transient: Waveform? = nil,
            name: String
        ) {
            self.kind = kind
            self.nodeA = nodeA
            self.nodeB = nodeB
            self.value = value
            self.phaseDegrees = phaseDegrees
            self.dcValue = dcValue
            self.acValue = acValue
            self.transient = transient
            self.name = name
        }

        /// Magnitude used for the given analysis. A source with a single value
        /// (the common case) uses that value for both DC and AC.
        func magnitude(isDC: Bool) -> Double {
            isDC ? (dcValue ?? value) : (acValue ?? value)
        }

        /// Source value at a point in time. A source without an explicit
        /// waveform is constant at its DC magnitude.
        func transientValue(at time: Double) -> Double {
            if let transient { return transient.value(at: time) }
            return dcValue ?? value
        }
    }

    /// Node names indexed by node number; index 0 is always the ground reference.
    public var nodeNames: [String]
    public var elements: [Element]

    public init(nodeNames: [String], elements: [Element]) {
        self.nodeNames = nodeNames
        self.elements = elements
    }

    public var nodeCount: Int { nodeNames.count }

    public struct Solution: Sendable {
        /// Complex node voltage indexed by node number (index 0 is ground = 0).
        public var nodeVoltages: [Complex]
        /// Branch current flowing from node A to node B through each voltage source.
        public var sourceCurrents: [(name: String, current: Complex)]
        /// True for DC solves, where every value is real.
        public var isDC: Bool
        /// Optional per-element current, in the same order as `elements`.
        public var elementCurrents: [Complex]

        public func voltage(node: Int) -> Complex {
            guard node >= 0, node < nodeVoltages.count else { return .zero }
            return nodeVoltages[node]
        }
    }

    // MARK: - Analysis modes

    /// How an assembly pass interprets reactive elements.
    private enum AnalysisMode {
        /// Capacitors open, inductors short; sources use their DC magnitude.
        case dc
        /// DC topology, but sources take their value at `time` from their
        /// transient waveform. Used for the transient initial condition.
        case operatingPoint(time: Double)
        case ac(omega: Double)
        case transient(
            timestep: Double,
            time: Double,
            capacitorVoltage: [Double],
            inductorCurrent: [Double]
        )

        /// Whether inductors are ideal shorts (a 0 V branch) and capacitors are
        /// open circuits.
        var usesDCStamps: Bool {
            switch self {
            case .dc, .operatingPoint: return true
            case .ac, .transient: return false
            }
        }

        var isDC: Bool {
            if case .dc = self { return true }
            return false
        }
    }

    // MARK: - DC operating point

    public func solveDC() throws -> Solution {
        try validate()
        return try assemble(mode: .dc)
    }

    /// DC topology (capacitors open, inductors short) with time-domain source
    /// values. This is the initial condition for a transient run.
    public func solveOperatingPoint(atTime time: Double) throws -> Solution {
        try validate()
        return try assemble(mode: .operatingPoint(time: time))
    }

    // MARK: - AC solve at a single frequency

    public func solveAC(frequencyHz: Double) throws -> Solution {
        try validate()
        guard frequencyHz > 0, frequencyHz.isFinite else {
            throw CircuitSolveError.invalidElement("AC frequency")
        }
        return try assemble(mode: .ac(omega: 2 * .pi * frequencyHz))
    }

    // MARK: - Transient step

    /// Advance the circuit one time step using backward Euler companion models.
    /// `capacitorVoltage` and `inductorCurrent` hold the previous state, indexed
    /// by `elements`; callers update them from the returned solution.
    func solveTransientStep(
        timestep: Double,
        time: Double,
        capacitorVoltage: [Double],
        inductorCurrent: [Double]
    ) throws -> Solution {
        try validate()
        guard timestep > 0, timestep.isFinite else {
            throw CircuitSolveError.invalidElement("Transient timestep")
        }
        return try assemble(mode: .transient(
            timestep: timestep,
            time: time,
            capacitorVoltage: capacitorVoltage,
            inductorCurrent: inductorCurrent
        ))
    }

    private func validate() throws {
        guard nodeCount > 1 else { throw CircuitSolveError.noNodes }
        for element in elements {
            switch element.kind {
            case .resistor, .capacitor, .inductor:
                guard element.value.isFinite, element.value > 0 else {
                    throw CircuitSolveError.invalidElement(element.name)
                }
            case .voltageSource, .currentSource:
                guard element.value.isFinite,
                      element.dcValue?.isFinite ?? true,
                      element.acValue?.isFinite ?? true else {
                    throw CircuitSolveError.invalidElement(element.name)
                }
            }
        }
    }

    // MARK: - Matrix assembly

    private struct Branch {
        var element: Element
        /// Index into `elements`, so the solved branch current can be attached
        /// to the originating element.
        var elementIndex: Int
        var voltage: Complex
    }

    private func assemble(mode: AnalysisMode) throws -> Solution {
        let nodeCount = nodeNames.count
        let nodeRows = nodeCount - 1

        func sourceMagnitude(_ element: Element) -> Double {
            switch mode {
            case .dc:
                return element.magnitude(isDC: true)
            case .operatingPoint(let time), .transient(_, let time, _, _):
                return element.transientValue(at: time)
            case .ac:
                return element.magnitude(isDC: false)
            }
        }

        func sourcePhase(_ element: Element) -> Double {
            mode.isDC ? 0 : element.phaseDegrees
        }

        // Collect voltage-source-like branches. At DC (and for the transient
        // initial condition) an inductor behaves as a zero-volt source (an ideal
        // short); in AC and transient it is stamped as an admittance.
        var branches: [Branch] = []
        for (index, element) in elements.enumerated() {
            switch element.kind {
            case .voltageSource:
                branches.append(Branch(
                    element: element,
                    elementIndex: index,
                    voltage: Complex.fromPolar(
                        magnitude: sourceMagnitude(element),
                        phaseDegrees: sourcePhase(element)
                    )
                ))
            case .inductor where mode.usesDCStamps:
                branches.append(Branch(element: element, elementIndex: index, voltage: .zero))
            default:
                break
            }
        }

        let dimension = nodeRows + branches.count
        guard dimension > 0 else { throw CircuitSolveError.noNodes }

        var matrix = [[Complex]](repeating: [Complex](repeating: .zero, count: dimension), count: dimension)
        var rhs = [Complex](repeating: .zero, count: dimension)

        func row(_ node: Int) -> Int? {
            node == 0 ? nil : node - 1
        }

        func stampAdmittance(a: Int, b: Int, y: Complex) {
            if let i = row(a) { matrix[i][i] = matrix[i][i] + y }
            if let j = row(b) { matrix[j][j] = matrix[j][j] + y }
            if let i = row(a), let j = row(b) {
                matrix[i][j] = matrix[i][j] - y
                matrix[j][i] = matrix[j][i] - y
            }
        }

        func stampCurrentSource(a: Int, b: Int, current: Complex) {
            if let i = row(a) { rhs[i] = rhs[i] - current }
            if let j = row(b) { rhs[j] = rhs[j] + current }
        }

        for (index, element) in elements.enumerated() {
            switch element.kind {
            case .resistor:
                stampAdmittance(a: element.nodeA, b: element.nodeB, y: Complex(1 / element.value, 0))
            case .capacitor:
                switch mode {
                case .ac(let omega):
                    stampAdmittance(a: element.nodeA, b: element.nodeB, y: Complex(0, omega * element.value))
                case .transient(let timestep, _, let capacitorVoltage, _):
                    // Backward Euler: i = G·v − G·v_prev, with G = C/Δt.
                    let conductance = element.value / timestep
                    stampAdmittance(a: element.nodeA, b: element.nodeB, y: Complex(conductance, 0))
                    let history = -conductance * capacitorVoltage[index]
                    stampCurrentSource(a: element.nodeA, b: element.nodeB, current: Complex(history, 0))
                case .dc, .operatingPoint:
                    break // open circuit
                }
            case .inductor:
                switch mode {
                case .ac(let omega):
                    let admittance = Complex(1, 0) / Complex(0, omega * element.value)
                    stampAdmittance(a: element.nodeA, b: element.nodeB, y: admittance)
                case .transient(let timestep, _, _, let inductorCurrent):
                    // Backward Euler: i = G·v + i_prev, with G = Δt/L.
                    let conductance = timestep / element.value
                    stampAdmittance(a: element.nodeA, b: element.nodeB, y: Complex(conductance, 0))
                    stampCurrentSource(a: element.nodeA, b: element.nodeB, current: Complex(inductorCurrent[index], 0))
                case .dc, .operatingPoint:
                    break // handled as a 0 V branch
                }
            case .voltageSource:
                break // stamped below with its branch unknown
            case .currentSource:
                stampCurrentSource(
                    a: element.nodeA,
                    b: element.nodeB,
                    current: Complex.fromPolar(
                        magnitude: sourceMagnitude(element),
                        phaseDegrees: sourcePhase(element)
                    )
                )
            }
        }

        for (offset, branch) in branches.enumerated() {
            let k = nodeRows + offset
            if let i = row(branch.element.nodeA) {
                matrix[i][k] = matrix[i][k] + .one
                matrix[k][i] = matrix[k][i] + .one
            }
            if let j = row(branch.element.nodeB) {
                matrix[j][k] = matrix[j][k] - .one
                matrix[k][j] = matrix[k][j] - .one
            }
            rhs[k] = branch.voltage
        }

        let x = try ComplexLinearSolver.solve(matrix, rhs)

        var nodeVoltages = [Complex](repeating: .zero, count: nodeCount)
        for node in 1..<nodeCount {
            nodeVoltages[node] = x[node - 1]
        }

        // Branch currents are only known after the solve, so attach them to the
        // elements that own each branch (voltage sources, plus DC inductor
        // shorts). Passives are computed from the node voltages below.
        var elementCurrents = computeElementCurrents(
            nodeVoltages: nodeVoltages,
            mode: mode,
            sourceMagnitude: sourceMagnitude,
            sourcePhase: sourcePhase
        )
        var sourceCurrents: [(name: String, current: Complex)] = []
        for (offset, branch) in branches.enumerated() {
            elementCurrents[branch.elementIndex] = x[nodeRows + offset]
            // Only report true voltage sources; DC inductor shorts are internal.
            if branch.element.kind == .voltageSource {
                sourceCurrents.append((branch.element.name, x[nodeRows + offset]))
            }
        }

        return Solution(
            nodeVoltages: nodeVoltages,
            sourceCurrents: sourceCurrents,
            isDC: mode.isDC,
            elementCurrents: elementCurrents
        )
    }

    private func computeElementCurrents(
        nodeVoltages: [Complex],
        mode: AnalysisMode,
        sourceMagnitude: (Element) -> Double,
        sourcePhase: (Element) -> Double
    ) -> [Complex] {
        func voltage(_ node: Int) -> Complex {
            node >= 0 && node < nodeVoltages.count ? nodeVoltages[node] : .zero
        }
        return elements.enumerated().map { index, element in
            let v = voltage(element.nodeA) - voltage(element.nodeB)
            switch element.kind {
            case .resistor:
                return v / Complex(element.value, 0)
            case .capacitor:
                switch mode {
                case .ac(let omega):
                    return v * Complex(0, omega * element.value)
                case .transient(let timestep, _, let capacitorVoltage, _):
                    let conductance = element.value / timestep
                    return v * Complex(conductance, 0) + Complex(-conductance * capacitorVoltage[index], 0)
                case .dc, .operatingPoint:
                    return .zero
                }
            case .inductor:
                switch mode {
                case .ac(let omega):
                    return v / Complex(0, omega * element.value)
                case .transient(let timestep, _, _, let inductorCurrent):
                    let conductance = timestep / element.value
                    return v * Complex(conductance, 0) + Complex(inductorCurrent[index], 0)
                case .dc, .operatingPoint:
                    return .zero
                }
            case .currentSource:
                // The current through an ideal current source is its own value.
                return Complex.fromPolar(
                    magnitude: sourceMagnitude(element),
                    phaseDegrees: sourcePhase(element)
                )
            case .voltageSource:
                // Overwritten in `assemble` from the solved branch current.
                return .zero
            }
        }
    }
}
