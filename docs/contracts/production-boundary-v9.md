# OhmLab production boundary v9

Production boundary v9 is the public compatibility boundary for OhmLab 4.0. It
adds two contract surfaces and leaves the existing numerical and portable
contracts at their previous versions.

## New in v9

| Contract | Version | Document |
| --- | --- | --- |
| Thermal analysis | 1 | [`thermal-analysis-v1.md`](thermal-analysis-v1.md) |
| KiCad companion | 1 | [`kicad-companion-v1.md`](kicad-companion-v1.md) |

`ohm doctor --json` publishes both as `contracts.thermalAnalysis` and
`contracts.kicadCompanion`, alongside the unchanged values:

- production boundary `9`;
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
- scale and numerical robustness `1`.

## Additive guarantees

Thermal analysis v1 adds a result contract for steady-state junction
temperatures derived from a converged DC operating point. It is opt-in: the
existing simulation commands and their defaults are unchanged, and no existing
result payload gains new required fields.

The KiCad companion v1 adds deterministic project and bundle digests, a
`.ohmlab-companion.json` sidecar, and sync/status commands. It builds on the
existing native reader and writer; it does not change the `.kicad_sch`,
`.ohmlab`, or `.ohmlabproj` formats.

Existing backend maturity rules are unchanged: `native-mna` remains the default
and sole full-production backend, and `numeric-core` remains the sole scoped
linear/nonlinear-production backend.

## Evidence

The 4.0 release gate requires:

- `swift test`, including `ThermalAnalysisTests` and `KiCadCompanionTests`;
- `scripts/health-check.sh`, including companion and thermal smoke tests;
- `scripts/release-check.sh`, which publishes `ohm doctor` contracts and checks
  that the build is ready;
- `ohm doctor --json` reporting `ready: true` with the v9 contract values.

## Non-claims

- v9 does not change Circuit IR, simulation-result, capability, portable,
  host, or Rust-portability versions.
- Thermal analysis is steady-state and one-shot; it does not model thermal
  transients or temperature-dependent electrical parameters.
- The companion detects changes but does not merge them; conflicting edits
  require an explicit preference or force.
- The companion covers the OhmLab-modelled KiCad subset, not arbitrary KiCad
  projects.
