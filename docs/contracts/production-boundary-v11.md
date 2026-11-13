# OhmLab production boundary v11

Production boundary v11 is the public compatibility boundary for OhmLab 4.2. It
advances the KiCad companion contract to v2 with three-way merge and sync plans.
The numerical, write-fidelity, thermal, and portable contracts keep their
previous versions.

## New in v11

| Contract | Version | Document |
| --- | --- | --- |
| KiCad companion | 2 | [`kicad-companion-v2.md`](kicad-companion-v2.md) |

`ohm doctor --json` publishes it as `contracts.kicadCompanion`, alongside the
unchanged values:

- production boundary `11`;
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
- KiCad write fidelity `1`.

## Additive guarantees

Companion v2 turns a both-sides change from an immediate conflict into a
three-way merge. The companion records the agreed modelled snapshot at each
successful sync, combines edits made to different objects or different fields,
and reports only genuine same-field collisions. `ohm kicad sync --dry-run`
publishes the same decision without writing anything.

Whole-side `--prefer` still works. `--force` still overwrites when paired with
an explicit `--direction`. The digest algorithm, the state schema, the
`.kicad_sch` format, and the `.ohmlabproj` format are unchanged. Generation and
preservation write modes are unchanged.

## Evidence

The 4.2 release gate requires:

- `swift test`, including the three-way merge, conflict, legacy-base, and
  dry-run tests;
- the committed KiCad 7, 8, and 9 format corpus to read, preserve an untouched
  project byte-for-byte, and patch only the edited value;
- `scripts/health-check.sh` and `scripts/release-check.sh`, which publish the
  v11 contract values and companion contract `2`;
- `scripts/check-kicad-plugin.sh` to validate the launchable KiCad 11+ action
  plugin metadata and executable entrypoint;
- `ohm doctor --json` reporting `ready: true` with
  `contracts.kicadCompanion = 2` and `contracts.kicadWriteFidelity = 1`;
- an end-to-end merge in which an OhmLab edit and a KiCad edit on different
  objects both reach the bundle and the KiCad drawing, and the next status is
  `up-to-date`.

## Non-claims

- v11 does not merge KiCad-only drawing objects. Wires, junctions, graphics, and
  unsupported symbols stay in the KiCad source and are preserved verbatim.
- v11 does not merge analysis settings or model-library edits; those remain
  bundle-owned or are copied by write fidelity.
- v11 does not change Circuit IR, any simulation result, or any analysis
  default.
- v11 does not promise a lossless round trip of an arbitrary KiCad project.
