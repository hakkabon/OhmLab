# OhmLab production boundary v7

Production boundary v7 adds NumericCore feature-completion contract v1 and
advances the native Rust portability contract to v2. Circuit IR, simulation
result, capability, portable-protocol, and simulation-host contracts remain at
version 1.

An OhmLab 2.3 release must expose DC, AC, transient, and single-source DC sweep
through the Swift-NumericCore adapter and native Rust host. The release gate
requires the locked Rust-NumericCore dependency, the eight-case native
qualification report, cross-host differential evidence for all four analyses,
and a packaged, signed `ohmlab-rust-host` executable.

Native MNA remains the default and sole full-production backend.
Swift-NumericCore remains the sole scoped nonlinear-production backend. The
process-native Rust host remains an external portable-protocol implementation;
feature completion does not register it as an in-process Swift backend or
expand the qualified nonlinear device set.

