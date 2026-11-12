# OhmLab production boundary v10

Production boundary v10 is the public compatibility boundary for OhmLab 4.1. It
adds the KiCad write-fidelity contract and leaves the numerical, portable, and
4.0 interop contracts at their previous versions.

## New in v10

| Contract | Version | Document |
| --- | --- | --- |
| KiCad write fidelity | 1 | [`kicad-write-fidelity-v1.md`](kicad-write-fidelity-v1.md) |

`ohm doctor --json` publishes it as `contracts.kicadWriteFidelity`, alongside
the unchanged values:

- production boundary `10`;
- capability contract `1`;
- Circuit IR `1`;
- simulation result `1`;
- numerical trust `1`;
- linear backend graduation `1`;
- nonlinear convergence `1`;
- portable simulation `1`;
- simulation host `1`;
- native Rust portability `3`;
- NumericCore feature completion `1`;
- scale and numerical robustness `1`;
- thermal analysis `1`;
- KiCad companion `1`.

## Additive guarantees

KiCad write fidelity v1 makes write-back non-destructive: exporting or syncing
into an existing KiCad project preserves untouched sheets byte-for-byte and
patches only the symbols, labels, wires, and sheet nodes that OhmLab owns.
Generation mode is unchanged, and no existing command gains a required
argument or changes its default output.

The `.kicad_sch`, `.ohmlab`, and `.ohmlabproj` formats are unchanged. Existing
backend maturity rules are unchanged: `native-mna` remains the default and sole
full-production backend, and `numeric-core` remains the sole scoped
linear/nonlinear-production backend.

## Evidence

The 4.1 release gate requires:

- `swift test`, including `KiCadWriteFidelityTests` and the preservation
  assertion in `KiCadCompanionTests`;
- an untouched `RC_Filter` round trip that is byte-identical across all three
  schematic files;
- a value edit that preserves every wire node and every unchanged symbol node,
  and whose read-back DC solution matches OhmLab's;
- `scripts/health-check.sh` and `scripts/release-check.sh`, which publish the
  v10 contract values;
- `ohm doctor --json` reporting `ready: true` with
  `contracts.kicadWriteFidelity = 1`.

## Non-claims

- v10 does not merge simultaneous KiCad and OhmLab edits; conflict handling is
  still whole-side (`--prefer kicad|ohmlab`).
- v10 does not promise a lossless round trip of constructs OhmLab cannot model,
  nor preservation of custom graphics on regenerated sheet instances.
- v10 does not change the KiCad companion digest algorithm, the Circuit IR, or
  any simulation result.
