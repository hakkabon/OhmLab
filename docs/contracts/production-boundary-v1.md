# OhmLab production boundary v1

OhmLab 1.0 introduced separation between the product release and the formats
and engines that may evolve behind it. The production boundary,
backend-capability contract, Circuit IR, simulation-result contract, and Rust
transport each negotiate their own integer version.

The following compatibility promises apply for the 1.x product line:

- Circuit IR v1 and simulation-result v1 retain their documented units,
  terminal ordering, naming, and sign conventions.
- Unknown future contract versions fail closed. They are never interpreted as
  the current version.
- Additive fields require an unambiguous default for older decoders. A semantic
  or incompatible wire change requires a new contract version.
- Backend identifiers are stable lowercase names. A backend declaration must
  use the same identifier in its capability payload and declare at least one
  input, analysis, and device.
- A production-qualified backend must implement every analysis, device, and
  execution feature in the current capability contract and publish an
  implementation version. In 1.0, `native-mna` is the sole production backend.
- Preview backends are available only through explicit selection. NumericCore
  and Rust can advance without weakening the native production guarantee.
- Every raw result is validated at the engine boundary. Plugin-processed output
  is validated again before it reaches the UI, CLI, exporters, or persistence.

`ohm doctor --json` is the canonical readiness report. A release is ready only
when that command exits successfully with `ready: true`, the default backend is
`native-mna`, and the release gate completes without errors.
