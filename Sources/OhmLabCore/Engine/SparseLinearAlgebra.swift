// SparseLinearAlgebra.swift
// A dependency-free sparse matrix and sparse LU solver for the native MNA engine.
//
// OhmLab's nodal matrices are extremely sparse: every two-terminal device
// touches at most two rows and columns, and a transistor touches at most four.
// The historical dense assembly therefore did O(n^3) work for a problem whose
// non-zero count is O(n). This core keeps assembly in coordinate form and
// performs Gaussian elimination directly on sparse rows with partial pivoting.
//
// The public surface is generic over `SparseScalar`, so both the real and the
// complex MNA systems share one implementation. Elimination order and row
// traversal are deterministic, which keeps simulation output reproducible.

import Foundation

/// Scalar requirements for the sparse linear algebra core.
///
/// Conformances are provided for `Double` and `Complex`, the two scalar types
/// used by OhmLab's circuit equations.
public protocol SparseScalar: Equatable, Sendable {
    static var zero: Self { get }
    static var one: Self { get }
    static func + (lhs: Self, rhs: Self) -> Self
    static func - (lhs: Self, rhs: Self) -> Self
    static func * (lhs: Self, rhs: Self) -> Self
    static func / (lhs: Self, rhs: Self) -> Self
    /// Absolute value, used for pivoting and singularity checks.
    var magnitude: Double { get }
    var isFinite: Bool { get }
}

extension Double: SparseScalar {
    public static var one: Double { 1 }
}

extension Complex: SparseScalar {
    public var isFinite: Bool { re.isFinite && im.isFinite }
}

/// An `rows × columns` sparse matrix assembled from coordinate stamps.
///
/// Entries are coalesced as they are added, so the stored non-zero count is
/// exactly the number of distinct positions with a non-zero value. Build the
/// matrix through ``add(_:row:column:)`` or the subscript, then hand it to
/// ``SparseLinearSolver``.
public struct SparseMatrix<Scalar: SparseScalar>: Sendable {
    public let rows: Int
    public let columns: Int

    /// Keyed by `row * columns + column`. A dictionary keeps incremental
    /// assembly O(1); determinism comes from sorting keys when the matrix is
    /// consumed, never from dictionary iteration order.
    private var entries: [Int: Scalar]

    public init(rows: Int, columns: Int) {
        precondition(rows >= 0 && columns >= 0, "SparseMatrix dimensions must be non-negative")
        self.rows = rows
        self.columns = columns
        self.entries = [:]
    }

    public init(
        rows: Int,
        columns: Int,
        coordinateEntries: [(row: Int, column: Int, value: Scalar)]
    ) {
        self.init(rows: rows, columns: columns)
        for entry in coordinateEntries {
            add(entry.value, row: entry.row, column: entry.column)
        }
    }

    /// Number of stored non-zero entries.
    public var nonZeroCount: Int { entries.count }

    /// The value at `row, column`, or zero when the position is not stored.
    public subscript(row: Int, column: Int) -> Scalar {
        get {
            precondition(isValid(row: row, column: column), "SparseMatrix index out of bounds")
            return entries[key(row, column)] ?? .zero
        }
        set {
            precondition(isValid(row: row, column: column), "SparseMatrix index out of bounds")
            let slot = key(row, column)
            if newValue == .zero {
                entries.removeValue(forKey: slot)
            } else {
                entries[slot] = newValue
            }
        }
    }

    /// Adds `value` to the entry at `row, column`, coalescing duplicates.
    public mutating func add(_ value: Scalar, row: Int, column: Int) {
        guard value != .zero else { return }
        precondition(isValid(row: row, column: column), "SparseMatrix index out of bounds")
        let slot = key(row, column)
        let updated = (entries[slot] ?? .zero) + value
        if updated == .zero {
            entries.removeValue(forKey: slot)
        } else {
            entries[slot] = updated
        }
    }

    /// Multiplies this matrix by a dense vector, in deterministic row order.
    public func applying(to vector: [Scalar]) -> [Scalar] {
        precondition(vector.count == columns, "SparseMatrix vector dimension mismatch")
        var result = [Scalar](repeating: .zero, count: rows)
        for (slot, value) in entries.sorted(by: { $0.key < $1.key }) {
            let row = slot / columns
            let column = slot % columns
            result[row] = result[row] + value * vector[column]
        }
        return result
    }

    /// The matrix as one column-sorted dictionary per row.
    func rowDictionaries() -> [[Int: Scalar]] {
        var result = [[Int: Scalar]](repeating: [:], count: rows)
        for slot in entries.keys.sorted() {
            let row = slot / columns
            let column = slot % columns
            result[row][column] = entries[slot]
        }
        return result
    }

    private func isValid(row: Int, column: Int) -> Bool {
        row >= 0 && row < rows && column >= 0 && column < columns
    }

    private func key(_ row: Int, _ column: Int) -> Int {
        row * columns + column
    }
}

/// Sparse LU with partial pivoting.
///
/// The implementation keeps the matrix in row-dictionary form and eliminates
/// one column at a time. A column-incidence index records which rows currently
/// hold a non-zero in each column, so pivoting and elimination touch only the
/// entries that exist (plus fill-in), not every row. A banded ladder therefore
/// stays close to O(n) instead of O(n^3).
///
/// Pivoting follows the same convention as the historical dense solver: the row
/// with the largest magnitude in the current column wins, ties keep the earliest
/// row, and a pivot at or below `pivotThreshold` is reported as singular.
public enum SparseLinearSolver {
    /// Absolute pivot floor. Matches the dense solver so singular circuits are
    /// rejected at the same point.
    public static let pivotThreshold = 1e-18

    public static func solve<Scalar: SparseScalar>(
        _ matrix: SparseMatrix<Scalar>,
        _ rhs: [Scalar]
    ) throws -> [Scalar] {
        let dimension = matrix.rows
        guard matrix.columns == dimension, rhs.count == dimension else {
            throw LinearSolveError.dimensionMismatch
        }
        guard dimension > 0 else { return [] }

        var rows = matrix.rowDictionaries()
        var b = rhs
        // columnRows[c] holds the row positions that currently have a non-zero
        // in column c. It is updated as pivots swap rows and fill-in appears.
        var columnRows = [Set<Int>](repeating: [], count: dimension)
        for (rowIndex, row) in rows.enumerated() {
            for column in row.keys {
                columnRows[column].insert(rowIndex)
            }
        }

        for column in 0..<dimension {
            // Partial pivot among the rows that actually carry this column.
            var pivotRow = -1
            var pivotMagnitude = 0.0
            for candidate in columnRows[column] where candidate >= column {
                guard let value = rows[candidate][column] else { continue }
                let magnitude = value.magnitude
                if magnitude > pivotMagnitude
                    || (magnitude == pivotMagnitude && (pivotRow == -1 || candidate < pivotRow)) {
                    pivotMagnitude = magnitude
                    pivotRow = candidate
                }
            }

            guard pivotRow != -1, pivotMagnitude > pivotThreshold else {
                throw LinearSolveError.singularMatrix
            }

            if pivotRow != column {
                // Moving the pivot row changes its row position, so every
                // column that either row touches must be re-indexed.
                let displaced = Array(rows[column].keys)
                let incoming = Array(rows[pivotRow].keys)
                rows.swapAt(pivotRow, column)
                b.swapAt(pivotRow, column)
                for affected in Set(displaced).union(incoming) {
                    columnRows[affected].remove(column)
                    columnRows[affected].remove(pivotRow)
                    if rows[column][affected] != nil { columnRows[affected].insert(column) }
                    if rows[pivotRow][affected] != nil { columnRows[affected].insert(pivotRow) }
                }
            }

            let pivot = rows[column][column]!
            let pivotEntries = rows[column]
            // Sorted traversal keeps floating-point accumulation deterministic.
            let pivotColumns = pivotEntries.keys.sorted()
            let victims = columnRows[column].filter { $0 > column }.sorted()

            for row in victims {
                guard let candidate = rows[row][column] else {
                    columnRows[column].remove(row)
                    continue
                }
                let factor = candidate / pivot
                guard factor != .zero else {
                    rows[row].removeValue(forKey: column)
                    columnRows[column].remove(row)
                    continue
                }
                for k in pivotColumns {
                    let existing = rows[row][k]
                    let updated = (existing ?? .zero) - factor * pivotEntries[k]!
                    if updated == .zero {
                        rows[row].removeValue(forKey: k)
                        columnRows[k].remove(row)
                    } else {
                        rows[row][k] = updated
                        if existing == nil { columnRows[k].insert(row) }
                    }
                }
                // The eliminated column is exactly zero by construction; remove
                // any floating-point residue so it cannot re-enter pivoting.
                rows[row].removeValue(forKey: column)
                columnRows[column].remove(row)
                b[row] = b[row] - factor * b[column]
            }
        }

        // Back substitution over the upper-triangular rows.
        var x = [Scalar](repeating: .zero, count: dimension)
        for row in stride(from: dimension - 1, through: 0, by: -1) {
            var sum = b[row]
            for column in rows[row].keys.sorted() where column > row {
                sum = sum - rows[row][column]! * x[column]
            }
            let diagonal = rows[row][row] ?? .zero
            guard diagonal.magnitude > pivotThreshold else {
                throw LinearSolveError.singularMatrix
            }
            x[row] = sum / diagonal
        }
        return x
    }
}
