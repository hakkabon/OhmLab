# OhmLab native Rust portability contract v2

Contract v2 retains every native-process, schema-validation, resource-limit,
provenance, and fail-closed guarantee from v1. It extends the host analysis
surface from DC/AC to DC, AC, transient, and single-source DC sweep.

The host implementation identity is
`rust-numeric-core-0.34.0-native.2`. It continues to link the Cargo-locked
Rust-NumericCore 0.34.0 `nc-optimize` crate directly and has no Swift,
Foundation, UniFFI, or XCFramework runtime dependency.

Transient execution uses Rust-NumericCore's consistent DAE initialization,
adaptive integration, source breakpoints, and output interpolation. DC sweep
execution rebuilds an isolated model for each source coordinate and may use
the previous solution only as a numerical warm start. No state is shared
between requests.

The supported device and waveform scope is defined by
[NumericCore feature completion v1](numeric-core-feature-completion-v1.md).
All existing host ceilings remain in force, including the 100,000-sample and
two-million projected-result-value limits.

