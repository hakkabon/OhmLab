# OhmLab production boundary v3

OhmLab 1.5 advances the production boundary to v3. Circuit IR, simulation
result, capability, numerical-trust, and linear-graduation contracts remain at
v1.

Boundary v3 adds:

- `nonlinear-production`, a scope-qualified backend maturity;
- nonlinear scope contract v1 with explicit supported device variants;
- nonlinear-convergence contract v1 as executable release evidence; and
- removal of the standalone `rust/ohm-core` transport after its 1.2
  compatibility release and announced 1.3 removal date.

`native-mna` remains the default and sole full-production backend.
`numeric-core` is the sole linear- and nonlinear-production backend. Its
nonlinear promise is limited to Shockley diodes and body-tied Level-1 NMOS
devices, as defined by nonlinear-convergence v1. Rust-NumericCore remains the
numerical implementation reached through Swift-NumericCore; only OhmLab's
duplicate standalone Rust adapter and C ABI were removed.

`ohm doctor --json`, `ohm verify --json`, `ohm qualify-linear --json`, and
`ohm qualify-nonlinear --json` must all report ready for release.
