# OhmLab sparse circuit core v1

Sparse circuit core v1 describes the native MNA backend's internal matrix
representation and linear solve. It is an implementation contract for the
`native-mna` backend, not a new production boundary, Circuit IR schema, or
portable-protocol version.

## Scope

The native engine's nodal equations are sparse by construction: a two-terminal
device stamps at most two rows and two columns, and a transistor stamps at most
four. Before 3.2 the engine materialised a dense `n × n` complex matrix and ran
Gaussian elimination over every position, which made a sparse problem cost
`O(n³)`. The sparse core replaces both the assembly and the elimination while
leaving the device models, Newton iteration, analysis pipeline, and published
results unchanged.

## Matrix representation

`SparseMatrix<Scalar>` (`Sources/OhmLabCore/Engine/SparseLinearAlgebra.swift`)
stores coordinate entries keyed by their row-major position. Stamps are added
incrementally with `add(_:row:column:)`:

- duplicate coordinates are coalesced on insertion;
- a coordinate that cancels to exactly zero is removed;
- iteration for solves and matrix-vector products sorts keys, so dictionary
  hashing never affects the result.

The scalar layer is generic over `SparseScalar`. `Double` and `Complex` provide
the real and complex systems used by the circuit equations; the MNA assembly
uses `Complex`.

## Sparse LU

`SparseLinearSolver.solve` performs Gaussian elimination directly on sparse row
dictionaries:

- the pivot is the largest-magnitude entry in the current column among the
  remaining rows, with ties keeping the earliest row (partial pivoting);
- elimination creates fill-in only where a row already has a non-zero in the
  pivot column;
- rows are traversed in sorted column order during elimination and back
  substitution, which makes repeated runs bitwise deterministic;
- a pivot at or below `1e-18` throws `LinearSolveError.singularMatrix`, matching
  the threshold of the previous dense solver.

A banded ladder therefore costs roughly `O(n)` rather than `O(n³)`. The solver
does not yet exploit symbolic reordering; symmetric reordering and reuse of a
factorization across sweep points are future work.

## Shared Circuit IR routing

Both native frontends now normalize through `CircuitIR` v1 before solving:

- `CircuitIRCompiler.compile(netlist:libraries:baseDirectory:)` lowers SPICE;
- `CircuitIRCompiler.compile(snapshot:)` lowers a schematic through the
  existing `CircuitCompiler`, then normalizes the result;
- `NativeMNAEngine` reconstructs its `LinearCircuit` with
  `CircuitIR.makeLinearCircuit()` for both entry points, so terminal
  conventions, node numbering, solver options, source waveforms, nonlinear
  models, and initial conditions take one validated path.

The IR schema, device unions, terminal ordering, and result contract are
unchanged. The change is internal: a schematic and an equivalent netlist now
produce the same normalized model before the solver runs.

## Guarantees and evidence

`Tests/OhmLabTests/SparseCircuitCoreTests.swift` proves:

- sparse and dense elimination agree on real and complex systems;
- duplicate stamps coalesce and cancelled entries disappear;
- singular and mismatched systems fail closed;
- repeated solves are bitwise deterministic;
- a native 768-section chain, with more than 512 MNA unknowns, matches the
  analytic ramp `1 - k/N`;
- a combined DC/AC diode circuit survives a Circuit IR round-trip with the same
  node voltages and element currents;
- schematic lowering through Circuit IR agrees with direct schematic
  compilation;
- netlist and Circuit IR entry points return the same native result.

The existing convergence, example-circuit, nonlinear, scale, portable, and
KiCad suites also run against the sparse path, so sparse assembly does not
change the published DC/AC/transient corpus.

## Non-claims

This contract does **not**:

- raise or remove the 512-unknown dense envelope published by NumericCore, the
  Swift portable platform, or the native Rust host;
- change production boundary v8, Circuit IR v1, the result contract, or any
  capability, nonlinear-convergence, or portability version;
- claim sparse scalability for NumericCore or the Rust host — those paths keep
  their dense solver and fail-closed budget;
- claim that arbitrary large circuits are fast. The native backend accepts
  larger sparse systems, but no maximum native circuit size or performance
  target is promised here.
