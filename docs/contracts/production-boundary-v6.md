# OhmLab production boundary v6

Production boundary v6 adds native Rust portability contract v1 without
changing Circuit IR v1, simulation-result v1, portable simulation v1, or the
simulation-host contract.

An OhmLab 2.2 release must build `ohmlab-rust-host` from the locked Cargo
graph, pass its native qualification, and pass the Swift-NumericCore versus
native Rust DC/AC differential checks. CI builds the crate on macOS and Linux.
The macOS release archive includes the native Rust host beside the `ohm` CLI.

The native Rust host is an external process backend with a deliberately
narrower scope than the in-process `numeric-core` backend. Native Swift MNA
remains the default and sole full-production application backend;
Swift-NumericCore remains the sole scoped linear/nonlinear-production backend.
