# OhmLab platform extraction contract v1

OhmLab 2.1 separates the portable simulation boundary into two public Swift
products:

- `OhmLabSimulationProtocol` is Foundation-only. It owns host policy,
  cancellation, deterministic JSON encoding, batch envelopes, schema IDs, and
  protocol constants. It does not link OhmLabCore, SwiftUI, NumericCore, or a
  numerical backend.
- `OhmLabSimulationHost` owns execution. It links OhmLabCore, implements
  request and result budgets, deadlines, cancellation, and ordered batch
  scheduling, and re-exports the protocol module.

The compatibility product `OhmLabSimulationPlatform` remains backed by
OhmLabCore for the 2.x source-compatibility window. New integrations should
depend on the protocol product when exchanging data only, and the host product
when embedding simulation.

## Execution policy

`SimulationExecutionPolicy` can narrow request bytes, result bytes, node and
device counts, set a positive timeout, and select one through 32 concurrent
batch workers. Global portable-protocol limits still apply. A host policy can
never make an otherwise invalid v1 request valid.

Cancellation is available through normal Swift task cancellation and the
thread-safe `SimulationCancellationToken`. Solver work always runs in a child
task, so a blocking solve never runs on the caller's executor.

A deadline is a wall-clock promise. When it expires the host cancels the solver
and waits for it to stop before returning, so no simulation work outlives the
response. Native and NumericCore solvers observe cancellation at their
cooperative checkpoints: Newton iterations, AC frequency points, transient
steps, DC-sweep points, and parameter-step points. A deadline therefore
interrupts real work rather than labelling an already-completed run as timed
out.

The host reports a deadline as the machine-readable `timeout` code and a
request, circuit, result, or backend-budget violation as `resource-limit`.
Explicit cancellation still uses `simulation-failed`. The response schema lists
all seven codes; clients that switch exhaustively over the older five should
treat an unknown code as a failure.

`ohm platform manifest` publishes both the protocol's global rejection ceilings
and a `backendLimits` entry for each qualified backend. The per-backend entry
states the executable dense-solver envelope (currently 512 MNA unknowns, 513
Circuit IR nodes, and the protocol device ceiling), so a 100,000-node protocol
ceiling is never mistaken for a promise that every backend can solve it. The
portable executor enforces that envelope before allocating a matrix and reports
`resource-limit` when it is exceeded.

## Batch contract

Batch v1 accepts at most 256 normal portable requests. Non-fail-fast batches
may execute concurrently but responses are restored to input order. Fail-fast
batches are sequential and represent every unexecuted item explicitly as
`skipped`; requests never disappear from the response.

The normative batch request and response schemas are
[`schemas/portable-simulation-batch-v1.schema.json`](schemas/portable-simulation-batch-v1.schema.json)
and
[`schemas/portable-simulation-batch-response-v1.schema.json`](schemas/portable-simulation-batch-response-v1.schema.json).

Run `ohm platform batch [--pretty] [--timeout-ms n] [--max-parallel n]` and
provide a batch envelope on standard input. Run `ohm qualify-host --json` for
the nine-case executable extraction contract, including per-backend limit
discovery, a resource-limit failure, and a deadline that interrupts a long
sweep.

Swift-NumericCore is consumed through its stable 1.x semantic-version range;
the resolved 1.1.0 package continues to provide the Rust-NumericCore binary
transport. OhmLab no longer pins a provisional NumericCore source revision.
