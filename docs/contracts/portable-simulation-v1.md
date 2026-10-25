# OhmLab portable simulation protocol v1

OhmLab 2.0 defines a deterministic JSON boundary for running simulations from
another process or programming language. The protocol is exposed through the
public `OhmLabSimulationPlatform` package product and the `ohm platform`
command family. Its media type is
`application/vnd.ohmlab.simulation+json;version=1`.

## Request

A request contains:

- `protocolVersion` and a caller-supplied `requestID`;
- a backend name from the host manifest;
- Circuit IR v1; and
- an explicit analysis plan for DC operating point, AC small-signal,
  transient, and/or a single-source DC sweep.

The protocol does not accept schematic geometry, plugins, filesystem paths,
includes, or arbitrary SPICE text. Frontends lower those inputs to validated
Circuit IR before crossing the portable boundary. This keeps execution
independent of UI state and host filesystem policy.

## Response

Every complete input produces one response envelope. Success responses contain
the canonical backend identity, its implementation version, and a fully typed
simulation-result projection. Failure responses contain a stable error code and
human-readable message. Malformed JSON, unknown protocol versions, unknown
backends, invalid Circuit IR, and unsupported analysis/backend combinations
fail atomically; partial results are never returned.

JSON encoding uses sorted keys and SI values. Requests are limited to 16 MiB,
100,000 nodes, 200,000 devices, 100,000 requested analysis samples, 100,000
embedded waveform points, 1,024 UTF-8 bytes per circuit name, and 10,000
solver iterations. These are rejection ceilings, not performance claims. In
particular, the native backend's dense matrix implementation is intended for
interactive circuits rather than circuits near the node ceiling. Hosts should
set smaller deployment-specific limits when latency or memory budgets require
it. A host executes each request against an isolated backend instance and does
not mutate OhmLab's process-wide application backend.

The normative request and response schemas are
[`schemas/portable-simulation-request-v1.schema.json`](schemas/portable-simulation-request-v1.schema.json),
identified by `urn:ohmlab:schema:portable-simulation-request:1`, and
[`schemas/portable-simulation-response-v1.schema.json`](schemas/portable-simulation-response-v1.schema.json),
identified by `urn:ohmlab:schema:portable-simulation-response:1`. The manifest
publishes this identifier, the `json-sorted-keys-utf8` canonical encoding, and
the `sha-256` provenance digest. Checked-in canonical request and response
fixtures are exercised byte-for-byte by the test suite so non-Swift hosts can
verify their encoders independently.

Every successful response carries deterministic provenance: the OhmLab and
backend implementation versions, protocol media type, Circuit IR and result
contract versions, model source, and the SHA-256 digest of the canonical
request. Circuit IR v1 embeds its resolved model parameters, so the model
source is `embedded-circuit-ir`; execution never consults an unreported model
file or host search path.

## Discovery and qualification

`ohm platform manifest [--pretty]` reports the media type, limits, contract
versions, supported protocol analyses, and qualified backends.

`ohm platform run [--pretty]` reads exactly one request from standard input and
writes exactly one response to standard output. It exits zero for a successful
simulation and nonzero for a protocol or simulation failure.

OhmLab 2.1 also provides the Foundation-only `OhmLabSimulationProtocol`
product and the embeddable `OhmLabSimulationHost` product. Its execution
budgets, cancellation and deadline behavior, and ordered batch contract are
defined by [the platform extraction contract](platform-extraction-v1.md).

`ohm qualify-platform --json` is the executable release contract. It verifies
deterministic request/response round trips for native MNA and NumericCore,
nonlinear NumericCore transport, and fail-closed behavior for future protocol
versions, unknown backends, malformed JSON, and computationally amplified
analysis plans. The test suite additionally runs a checked-in malformed-input
corpus and deterministic byte-mutation smoke fuzzing.

Protocol v1 is portable at the data and process boundary. It does not claim
that the current GUI or prebuilt Swift-NumericCore binary runs on every
operating system. New host builds can implement this wire contract without
changing clients.

OhmLab 2.2 supplies the first non-Swift implementation: the Linux/macOS native
Rust host described by [native Rust portability v1](native-rust-portability-v1.md).
OhmLab 2.3 advances that host to
[native Rust portability v2](native-rust-portability-v2.md), completing the
protocol's DC, AC, transient, and single-source DC-sweep analysis plan through
the [NumericCore feature-completion contract](numeric-core-feature-completion-v1.md).
