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
100,000 nodes, and 200,000 devices. Existing solver sample limits remain in
force. A host executes each request against an isolated backend instance and
does not mutate OhmLab's process-wide application backend.

## Discovery and qualification

`ohm platform manifest [--pretty]` reports the media type, limits, contract
versions, supported protocol analyses, and qualified backends.

`ohm platform run [--pretty]` reads exactly one request from standard input and
writes exactly one response to standard output. It exits zero for a successful
simulation and nonzero for a protocol or simulation failure.

`ohm qualify-platform --json` is the executable release contract. It verifies
deterministic request/response round trips for native MNA and NumericCore,
nonlinear NumericCore transport, and fail-closed behavior for future protocol
versions and unknown backends.

Protocol v1 is portable at the data and process boundary. It does not claim
that the current GUI or prebuilt Swift-NumericCore binary runs on every
operating system. New host builds can implement this wire contract without
changing clients.
