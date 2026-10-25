# OhmLab native Rust portability contract v1

OhmLab 2.2 provides a standalone `ohmlab-rust-host` executable that consumes
portable simulation protocol v1 and links Rust-NumericCore directly. It has no
Swift, Foundation, SwiftUI, UniFFI, or XCFramework dependency. The same Cargo
package builds on macOS and Linux.

## Frozen scope

The host identifier is `rust-numeric-core`; its implementation identity is
`rust-numeric-core-0.34.0-native`. Cargo pins the published
Rust-NumericCore `v0.34.0` tag and records the resolved commit in `Cargo.lock`.

Contract v1 accepts Circuit IR v1 with:

- DC operating-point and AC small-signal analysis;
- resistors, capacitors, inductors, independent voltage/current sources;
- Shockley diodes at nominal temperature; and
- body-tied Level-1 NMOS devices with zero body effect at nominal temperature.

Transient analysis, DC/parameter sweeps, BJT, JFET, PMOS, non-body-tied or
body-effect MOSFETs, piecewise-linear sources, and non-nominal temperature are
outside this contract and return `unsupported-capability`. The Rust host does
not silently delegate unsupported work to Swift.

## Safety and interoperability

The decoder rejects unknown members, unsupported protocol or Circuit IR
versions, malformed topology, invalid solver controls, requests above 16 MiB,
more than 100,000 nodes, more than 200,000 devices, and AC plans above 100,000
samples. A host-specific two-million-value projection budget additionally
prevents valid individual dimensions from multiplying into an impractical AC
response. Successful responses use simulation-result contract v1 and carry a
SHA-256 digest of the canonical request.

`ohmlab-rust-host manifest` reports runtime identity and capability scope.
`ohmlab-rust-host qualify` runs the native DC, AC, and fail-closed evidence.
`scripts/qualify-rust-host.sh` additionally compares its divider DC and AC
results to Swift-NumericCore within the frozen tolerances. The release gate
requires all of this evidence.
