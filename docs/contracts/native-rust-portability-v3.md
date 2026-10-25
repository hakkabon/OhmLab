# OhmLab native Rust portability contract v3

Contract v3 retains the v2 DC, AC, transient, DC-sweep, native-process,
schema-validation, provenance, and fail-closed guarantees. It adds the
[scale and numerical robustness contract](scale-and-numerical-robustness-v1.md).

The implementation identity is `rust-numeric-core-0.34.0-native.3`. It links
the Cargo-locked Rust-NumericCore 0.34.0 `nc-optimize` crate directly, applies
variable/equation scaling, certifies unscaled physical residuals, and advertises
`maximumDenseUnknowns: 512` in its manifest.

The native qualification contains ten cases, including a 1e12 impedance-ratio
solve and pre-solve dense-budget rejection. Cross-host qualification also
compares the mixed-scale result with the Swift-NumericCore adapter.
