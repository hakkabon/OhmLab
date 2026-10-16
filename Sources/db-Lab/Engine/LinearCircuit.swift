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
        public var name: String

        public init(
            kind: ElementKind,
            nodeA: Int,
            nodeB: Int,
            value: Double,
            phaseDegrees: Double = 0,
            dcValue: Double? = nil,
            acValue: Double? = nil,
            name: String
        ) {
            self.kind = kind
            self.nodeA = nodeA
            self.nodeB = nodeB
            self.value = value
            self.phaseDegrees = phaseDegrees
            self.dcValue = dcValue
            self.acValue = acValue
            self.name = name
        }

        /// Magnitude used for the given analysis. A source with a single value
        /// (the common case) uses that value for both DC and AC.
        func magnitude(isDC: Bool) -> Double {
            isDC ? (dcValue ?? value) : (acValue ?? value)
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

    // MARK: - DC operating point

    public func solveDC() throws -> Solution {
        try validate()
        return try assemble(omega: nil, isDC: true)
    }

    // MARK: - AC solve at a single frequency

    public func solveAC(frequencyHz: Double) throws -> Solution {
        try validate()
        guard frequencyHz > 0, frequencyHz.isFinite else {
            throw CircuitSolveError.invalidElement("AC frequency")
        }
        return try assemble(omega: 2 * .pi * frequencyHz, isDC: false)
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
        var voltage: Complex
    }

    private func assemble(omega: Double?, isDC: Bool) throws -> Solution {
        let nodeCount = nodeNames.count
        let nodeRows = nodeCount - 1

        // Collect voltage-source-like branches. At DC an inductor behaves as a
        // zero-volt source (an ideal short); in AC it is stamped as an admittance.
        var branches: [Branch] = []
        for element in elements {
            switch element.kind {
            case .voltageSource:
                branches.append(Branch(
                    element: element,
                    voltage: Complex.fromPolar(
                        magnitude: element.magnitude(isDC: isDC),
                        phaseDegrees: isDC ? 0 : element.phaseDegrees
                    )
                ))
            case .inductor where isDC:
                branches.append(Branch(element: element, voltage: .zero))
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

        for element in elements {
            switch element.kind {
            case .resistor:
                stampAdmittance(a: element.nodeA, b: element.nodeB, y: Complex(1 / element.value, 0))
            case .capacitor:
                guard !isDC, let omega else { break } // open circuit at DC
                stampAdmittance(a: element.nodeA, b: element.nodeB, y: Complex(0, omega * element.value))
            case .inductor:
                guard !isDC, let omega else { break } // handled as a 0 V branch at DC
                let admittance = Complex(1, 0) / Complex(0, omega * element.value)
                stampAdmittance(a: element.nodeA, b: element.nodeB, y: admittance)
            case .voltageSource:
                break // stamped below with its branch unknown
            case .currentSource:
                stampCurrentSource(
                    a: element.nodeA,
                    b: element.nodeB,
                    current: Complex.fromPolar(
                        magnitude: element.magnitude(isDC: isDC),
                        phaseDegrees: isDC ? 0 : element.phaseDegrees
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

        var sourceCurrents: [(name: String, current: Complex)] = []
        for (offset, branch) in branches.enumerated() {
            // Only report true voltage sources; DC inductor shorts are internal.
            guard branch.element.kind == .voltageSource else { continue }
            sourceCurrents.append((branch.element.name, x[nodeRows + offset]))
        }

        let elementCurrents = computeElementCurrents(nodeVoltages: nodeVoltages, omega: omega, isDC: isDC)

        return Solution(
            nodeVoltages: nodeVoltages,
            sourceCurrents: sourceCurrents,
            isDC: isDC,
            elementCurrents: elementCurrents
        )
    }

    private func computeElementCurrents(nodeVoltages: [Complex], omega: Double?, isDC: Bool) -> [Complex] {
        func voltage(_ node: Int) -> Complex {
            node >= 0 && node < nodeVoltages.count ? nodeVoltages[node] : .zero
        }
        return elements.map { element in
            let v = voltage(element.nodeA) - voltage(element.nodeB)
            switch element.kind {
            case .resistor:
                return v / Complex(element.value, 0)
            case .capacitor:
                guard !isDC, let omega else { return .zero }
                return v * Complex(0, omega * element.value)
            case .inductor:
                guard !isDC, let omega else { return .zero }
                return v / Complex(0, omega * element.value)
            case .voltageSource, .currentSource:
                return .zero
            }
        }
    }
}
