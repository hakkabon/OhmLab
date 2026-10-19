// ComplexLinearSolver.swift
// Dense complex Gaussian elimination with partial pivoting.
//
// The circuit sizes targeted by the first milestone (a handful of nodes) make a
// straightforward O(n^3) dense solve entirely adequate, and it keeps the engine
// dependency-free and easy to reason about.

import Foundation

public enum LinearSolveError: LocalizedError {
    case singularMatrix
    case dimensionMismatch

    public var errorDescription: String? {
        switch self {
        case .singularMatrix:
            return "The circuit equations are singular. Check for a floating node, a missing ground reference, or a shorted voltage source."
        case .dimensionMismatch:
            return "Internal solver error: matrix dimensions do not match."
        }
    }
}

public enum ComplexLinearSolver {
    /// Solve `A x = b` for `x`. `A` is consumed and modified.
    public static func solve(_ matrix: [[Complex]], _ rhs: [Complex]) throws -> [Complex] {
        let n = matrix.count
        guard n == rhs.count else { throw LinearSolveError.dimensionMismatch }
        guard n > 0 else { return [] }

        var a = matrix
        var b = rhs

        for column in 0..<n {
            // Partial pivot: pick the row with the largest magnitude in this column.
            var pivotRow = column
            var pivotMagnitude = a[column][column].magnitude
            if column + 1 < n {
                for row in (column + 1)..<n {
                    let candidate = a[row][column].magnitude
                    if candidate > pivotMagnitude {
                        pivotMagnitude = candidate
                        pivotRow = row
                    }
                }
            }

            guard pivotMagnitude > 1e-18 else { throw LinearSolveError.singularMatrix }

            if pivotRow != column {
                a.swapAt(pivotRow, column)
                b.swapAt(pivotRow, column)
            }

            let pivot = a[column][column]
            for row in (column + 1)..<n {
                let factor = a[row][column] / pivot
                guard factor != .zero else { continue }
                for k in column..<n {
                    a[row][k] = a[row][k] - factor * a[column][k]
                }
                b[row] = b[row] - factor * b[column]
            }
        }

        // Back substitution.
        var x = [Complex](repeating: .zero, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            if row + 1 < n {
                for k in (row + 1)..<n {
                    sum = sum - a[row][k] * x[k]
                }
            }
            x[row] = sum / a[row][row]
        }
        return x
    }
}
