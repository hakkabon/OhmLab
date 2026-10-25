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
thread-safe `SimulationCancellationToken`. Deadlines cancel the solver task;
native and NumericCore transient paths observe task cancellation at their
existing cooperative checkpoints. A cancellation or deadline returns the v1
`simulation-failed` envelope because protocol v1's frozen error-code set is not
expanded by the host contract.

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
the six-case executable extraction contract.

Swift-NumericCore is consumed through its stable 1.x semantic-version range;
the resolved 1.1.0 package continues to provide the Rust-NumericCore binary
transport. OhmLab no longer pins a provisional NumericCore source revision.
