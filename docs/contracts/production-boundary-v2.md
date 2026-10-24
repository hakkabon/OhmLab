# OhmLab production boundary v2

OhmLab 1.2 advances the production boundary from v1 to v2 because backend
maturity is no longer binary. Circuit IR, simulation-result, capability, and
Rust transport contracts remain at v1 and retain their existing compatibility
promises.

Production boundary v2 adds:

- `linear-production`, a scoped maturity for DC operating point, AC
  small-signal, and transient R/C/L/V/I simulation;
- backend lifecycle state independent of maturity; and
- required migration guidance and a removal version for deprecated backends.

`native-mna` remains the default and sole full-production backend.
`numeric-core` is the sole linear-production backend and must satisfy
linear-backend-graduation v1. Standalone `ohm-core` is deprecated in 1.2 with
removal version 1.3.0.

Unknown maturity or lifecycle values fail closed. `ohm doctor --json` is the
canonical declaration report; `ohm verify --json` and
`ohm qualify-linear --json` provide the executable numerical evidence. All
three reports must be ready for a release.
