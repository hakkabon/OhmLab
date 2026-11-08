import Foundation
import Testing
@testable import OhmLabCore

@Suite("Sparse circuit core and shared Circuit IR")
struct SparseCircuitCoreTests {
    // MARK: - Sparse matrix assembly

    @Test func sparseMatrixCoalescesStampsAndDropsCancelledEntries() {
        var matrix = SparseMatrix<Double>(rows: 3, columns: 3)
        matrix.add(1, row: 0, column: 0)
        matrix.add(1, row: 0, column: 0)
        #expect(matrix[0, 0] == 2)
        #expect(matrix.nonZeroCount == 1)

        matrix.add(-2, row: 0, column: 0)
        #expect(matrix[0, 0] == 0)
        #expect(matrix.nonZeroCount == 0)

        matrix[1, 2] = 5
        #expect(matrix[1, 2] == 5)
        matrix[1, 2] = 0
        #expect(matrix.nonZeroCount == 0)
    }

    @Test func sparseMatrixApplyMatchesDenseMultiplication() {
        let matrix = SparseMatrix<Double>(
            rows: 3,
            columns: 3,
            coordinateEntries: [
                (0, 0, 2), (0, 1, -1),
                (1, 0, -1), (1, 1, 2), (1, 2, -1),
                (2, 1, -1), (2, 2, 2),
            ]
        )
        let vector = [1.0, 2.0, 3.0]
        #expect(matrix.applying(to: vector) == [0, 0, 4])
    }

    // MARK: - Sparse solver

    @Test func solvesARealTridiagonalSystem() throws {
        let dimension = 8
        var entries: [(row: Int, column: Int, value: Double)] = []
        for row in 0..<dimension {
            entries.append((row, row, 4))
            if row + 1 < dimension {
                entries.append((row, row + 1, -1))
                entries.append((row + 1, row, -1))
            }
        }
        let matrix = SparseMatrix<Double>(rows: dimension, columns: dimension, coordinateEntries: entries)
        let rhs = (0..<dimension).map { Double($0 + 1) }
        let solution = try SparseLinearSolver.solve(matrix, rhs)

        let dense = Self.denseMatrix(entries: entries, dimension: dimension)
        let expected = try ComplexLinearSolver.solve(dense, rhs.map { Complex($0, 0) })
        #expect(solution.count == expected.count)
        for (actual, reference) in zip(solution, expected) {
            #expect(abs(actual - reference.re) < 1e-12)
        }
    }

    @Test func solvesAComplexSystemAndMatchesDenseElimination() throws {
        let dimension = 6
        var entries: [(row: Int, column: Int, value: Complex)] = []
        for row in 0..<dimension {
            entries.append((row, row, Complex(6, 2)))
            if row + 1 < dimension {
                entries.append((row, row + 1, Complex(-1, 0.5)))
                entries.append((row + 1, row, Complex(-2, -0.25)))
            }
        }
        let matrix = SparseMatrix<Complex>(rows: dimension, columns: dimension, coordinateEntries: entries)
        let rhs = (0..<dimension).map { Complex(Double($0 + 1), -Double($0)) }
        let solution = try SparseLinearSolver.solve(matrix, rhs)

        let dense = Self.denseMatrix(
            entries: entries.map { ($0.row, $0.column, $0.value) },
            dimension: dimension
        )
        let expected = try ComplexLinearSolver.solve(dense, rhs)
        for (actual, reference) in zip(solution, expected) {
            #expect((actual - reference).magnitude < 1e-12)
        }
    }

    @Test func rejectsASingularMatrix() {
        let matrix = SparseMatrix<Double>(
            rows: 2,
            columns: 2,
            coordinateEntries: [(0, 0, 1), (1, 1, 0)]
        )
        #expect(throws: LinearSolveError.self) {
            _ = try SparseLinearSolver.solve(matrix, [1, 1])
        }
    }

    @Test func rejectsMismatchedDimensions() {
        let matrix = SparseMatrix<Double>(rows: 2, columns: 3)
        #expect(throws: LinearSolveError.self) {
            _ = try SparseLinearSolver.solve(matrix, [1, 2])
        }
    }

    @Test func repeatedSolvesAreBitwiseDeterministic() throws {
        let dimension = 32
        var entries: [(row: Int, column: Int, value: Complex)] = []
        for row in 0..<dimension {
            entries.append((row, row, Complex(4, 1)))
            if row + 1 < dimension {
                entries.append((row, row + 1, Complex(-1, 0.25)))
                entries.append((row + 1, row, Complex(-1, -0.25)))
            }
            if row + 7 < dimension {
                entries.append((row, row + 7, Complex(0.5, 0)))
            }
        }
        let rhs = (0..<dimension).map { Complex(Double($0 % 5), Double($0 % 3)) }
        let first = try SparseLinearSolver.solve(
            SparseMatrix(rows: dimension, columns: dimension, coordinateEntries: entries),
            rhs
        )
        let second = try SparseLinearSolver.solve(
            SparseMatrix(rows: dimension, columns: dimension, coordinateEntries: entries),
            rhs
        )
        #expect(first == second)
    }

    // MARK: - Native engine scaling

    @Test func nativeEngineSolvesAChainPastTheDenseUnknownCeiling() throws {
        // N series resistors produce N non-reference nodes plus one source
        // branch, so N = 768 is well past the published 512-unknown dense
        // envelope. A sparse assembly must still produce the analytic ramp.
        let sectionCount = 768
        let result = try NativeMNAEngine().solve(
            netlist: Self.seriesChain(sectionCount: sectionCount),
            settings: Self.dcSettings,
            libraries: []
        )
        let dc = try #require(result.dc)
        #expect(dc.nodes.count == sectionCount)
        #expect(dc.nodes.count > ScaleAndNumericalRobustness.maximumDenseUnknowns)

        for probe in [1, sectionCount / 2, sectionCount - 1] {
            let node = try #require(dc.nodes.first { $0.name == "n\(probe)" })
            let expected = 1 - Double(probe) / Double(sectionCount)
            #expect(abs(node.voltage - expected) < 1e-9, "n\(probe) = \(node.voltage), expected \(expected)")
        }
    }

    @Test func nativeEngineIsDeterministicOnTheSparsePath() throws {
        let netlist = Self.seriesChain(sectionCount: 96)
        let first = try NativeMNAEngine().solve(netlist: netlist, settings: Self.dcSettings, libraries: [])
        let second = try NativeMNAEngine().solve(netlist: netlist, settings: Self.dcSettings, libraries: [])
        let firstDC = try #require(first.dc)
        let secondDC = try #require(second.dc)
        #expect(firstDC.nodes.count == secondDC.nodes.count)
        for (left, right) in zip(firstDC.nodes, secondDC.nodes) {
            #expect(left.name == right.name)
            #expect(left.voltage == right.voltage)
        }
        #expect(firstDC.components.count == secondDC.components.count)
        for (left, right) in zip(firstDC.components, secondDC.components) {
            #expect(left.name == right.name)
            #expect(left.voltage == right.voltage)
            #expect(left.current == right.current)
        }
    }

    // MARK: - Shared Circuit IR

    @Test func circuitIRRoundTripPreservesACombinedDcAndAcSolution() throws {
        let netlist = """
        V1 in 0 DC 5 AC 1
        R1 in out 1k
        R2 out 0 1k
        C1 out 0 1u
        D1 out 0 DM
        .model DM D(IS=1e-14 N=1)
        .end
        """
        let parsed = try SpiceNetlistParser.parse(netlist)
        let ir = try CircuitIR(linearCircuit: parsed.circuit, initialConditions: parsed.initialConditions)
        let rebuilt = try ir.makeLinearCircuit()

        let directDC = try parsed.circuit.solveDC()
        let roundTripDC = try rebuilt.solveDC()
        try Self.expectSame(directDC, roundTripDC)

        let directAC = try parsed.circuit.solveAC(frequencyHz: 1_000)
        let roundTripAC = try rebuilt.solveAC(frequencyHz: 1_000)
        try Self.expectSame(directAC, roundTripAC)
    }

    @Test func circuitIRCompilerLowersSchematicAndNetlistToTheSameModel() throws {
        let netlist = """
        V1 in 0 DC 5
        R1 in out 1k
        R2 out 0 1k
        .end
        """
        let imported = SchematicImporter.importNetlist(netlist)
        let direct = try CircuitCompiler.compile(snapshot: imported.snapshot)
        let shared = try CircuitIRCompiler.compile(snapshot: imported.snapshot).makeLinearCircuit()

        #expect(direct.nodeNames == shared.nodeNames)
        #expect(direct.elements.map(\.name) == shared.elements.map(\.name))
        try Self.expectSame(try direct.solveDC(), try shared.solveDC())
    }

    @Test func nativeNetlistAndCircuitIRInputsAgree() throws {
        let netlist = """
        V1 in 0 DC 4 AC 1
        R1 in out 2.2k
        C1 out 0 10n
        .end
        """
        let settings = AnalysisSettings(
            runDC: true,
            runAC: true,
            acStartFrequency: 10,
            acStopFrequency: 10_000,
            acPointsPerDecade: 3
        )
        let fromNetlist = try NativeMNAEngine().solve(netlist: netlist, settings: settings, libraries: [])
        let fromIR = try NativeMNAEngine().solve(
            circuit: CircuitIRCompiler.compile(netlist: netlist),
            settings: settings
        )

        let lhs = try #require(fromNetlist.dc)
        let rhs = try #require(fromIR.dc)
        #expect(lhs.nodes.count == rhs.nodes.count)
        for (left, right) in zip(lhs.nodes, rhs.nodes) {
            #expect(left.name == right.name)
            #expect(left.voltage == right.voltage)
        }
        #expect(lhs.components.count == rhs.components.count)
        for (left, right) in zip(lhs.components, rhs.components) {
            #expect(left.name == right.name)
            #expect(left.voltage == right.voltage)
            #expect(left.current == right.current)
        }

        let lhsAC = try #require(fromNetlist.ac)
        let rhsAC = try #require(fromIR.ac)
        #expect(lhsAC.frequencies == rhsAC.frequencies)
        #expect(lhsAC.nodes.map(\.name) == rhsAC.nodes.map(\.name))
        for (left, right) in zip(lhsAC.nodes, rhsAC.nodes) {
            #expect(left.response.count == right.response.count)
            for (a, b) in zip(left.response, right.response) {
                #expect(a.freqHz == b.freqHz)
                #expect(a.magnitudeDb == b.magnitudeDb)
                #expect(a.phaseDeg == b.phaseDeg)
            }
        }
    }

    // MARK: - Helpers

    private static var dcSettings: AnalysisSettings {
        var settings = AnalysisSettings.default
        settings.runDC = true
        settings.runAC = false
        settings.runTransient = false
        settings.runDCSweep = false
        return settings
    }

    /// A source-driven chain of `sectionCount` equal series resistors.
    /// Every internal node `nK` sits at `1 - K/N` volts.
    private static func seriesChain(sectionCount: Int) -> String {
        var lines = ["V1 in 0 DC 1"]
        var previous = "in"
        for index in 1...sectionCount {
            let node = index == sectionCount ? "0" : "n\(index)"
            lines.append("R\(index) \(previous) \(node) 1")
            previous = node
        }
        lines.append(".end")
        return lines.joined(separator: "\n")
    }

    private static func denseMatrix(
        entries: [(row: Int, column: Int, value: Double)],
        dimension: Int
    ) -> [[Complex]] {
        var matrix = [[Complex]](repeating: [Complex](repeating: .zero, count: dimension), count: dimension)
        for entry in entries {
            matrix[entry.row][entry.column] = Complex(entry.value, 0)
        }
        return matrix
    }

    private static func denseMatrix(
        entries: [(row: Int, column: Int, value: Complex)],
        dimension: Int
    ) -> [[Complex]] {
        var matrix = [[Complex]](repeating: [Complex](repeating: .zero, count: dimension), count: dimension)
        for entry in entries {
            matrix[entry.row][entry.column] = entry.value
        }
        return matrix
    }

    private static func expectSame(
        _ lhs: LinearCircuit.Solution,
        _ rhs: LinearCircuit.Solution,
        tolerance: Double = 1e-9
    ) throws {
        #expect(lhs.nodeVoltages.count == rhs.nodeVoltages.count)
        for (left, right) in zip(lhs.nodeVoltages, rhs.nodeVoltages) {
            #expect((left - right).magnitude <= tolerance)
        }
        #expect(lhs.elementCurrents.count == rhs.elementCurrents.count)
        for (left, right) in zip(lhs.elementCurrents, rhs.elementCurrents) {
            #expect((left - right).magnitude <= tolerance)
        }
    }
}
