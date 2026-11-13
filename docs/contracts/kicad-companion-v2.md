# KiCad companion v2

KiCad companion v2 is the public contract for keeping a KiCad project hierarchy
and an OhmLab `.ohmlabproj` bundle aligned. It extends companion v1 with
three-way merge and non-mutating sync plans. The v1 digest, direction, and state
rules are unchanged.

## Manifest

`ohm kicad companion --json` publishes:

| Field | Value |
| --- | --- |
| `contractVersion` | `2` |
| `projectExtensions` | `["kicad_pro"]` |
| `schematicExtensions` | `["kicad_sch"]` |
| `digestExtensions` | `["kicad_pro", "kicad_sch", "kicad_sym", "kicad_mod", "lib"]` |
| `directions` | `["import", "export", "auto"]` |
| `preferences` | `["kicad", "ohmlab"]` |
| `stateFileName` | `.ohmlab-companion.json` |
| `baseFileName` | `.ohmlab-companion-base.json` |
| `capabilities.bidirectionalSync` | `true` |
| `capabilities.conflictDetection` | `true` |
| `capabilities.threeWayMerge` | `true` |
| `capabilities.dryRun` | `true` |

## Sync rules

- `auto` imports when only KiCad changed, exports when only OhmLab changed, and
  reports `up-to-date` when neither changed.
- When both changed, `auto` performs a three-way merge using the base recorded
  at the last successful sync. A whole-side preference is not required unless
  the merge finds a collision.
- `--prefer kicad|ohmlab` selects one side wholesale and remains the escape
  hatch for a collision.
- `--force` overwrites the other side without a merge when combined with an
  explicit `--direction`. With `auto`, changes on both sides still merge, and a
  same-field collision requires `--prefer`.
- With no companion state, an existing bundle requires an explicit direction; a
  fresh bundle is imported from KiCad.
- With a legacy state but no recorded base, a both-sides change fails closed
  with `conflictingChanges` rather than guessing.

## Base snapshot

Every successful import, export, or merge writes
`.ohmlab-companion-base.json` inside the bundle beside the state sidecar. It
records the agreed OhmLab-modelled snapshot:

```json
{
  "contractVersion": 1,
  "syncedAt": "…",
  "snapshot": { "schemaVersion": 2, "symbols": [], "wires": [], "netLabels": [], "sheets": [] }
}
```

The base is written with sorted keys and deterministic bytes. It is not part of
the bundle digest. If its contract version is newer than this build, the
companion fails closed.

## Three-way merge

Objects are matched by UUID.

| Base | KiCad | OhmLab | Result |
| --- | --- | --- | --- |
| — | added | — | add from KiCad |
| — | — | added | add from OhmLab |
| — | added | added, equal | add once |
| — | added | added, different | conflict |
| present | removed | unchanged | remove |
| present | unchanged | removed | remove |
| present | removed | modified | conflict |
| present | modified | removed | conflict |
| present | changed | unchanged | take KiCad |
| present | unchanged | changed | take OhmLab |
| present | changed | changed, equal | take the common change |
| present | changed | changed, different | field-level merge |

Field-level merge applies to `descriptorId`, `refDes`, `position`, `rotation`,
`sheetRef`, and each parameter key independently. A field that matches the base
on one side is taken from the other side. A same-field collision is reported and
the merge is not applied.

Child-sheet presence, `name`, and `ports` follow the same rules. The bundle's
sheet order is kept, then KiCad additions are appended, so repeated plans are
deterministic.

## Dry-run plan

`ohm kicad sync … --dry-run` returns a `KiCadSyncPlan` without writing the
bundle, the KiCad project, or the state sidecar. It contains:

- `direction`: `import`, `export`, `merge`, or `none`;
- `kicadChanged` and `bundleChanged`;
- `changes`: each added, updated, or removed symbol/sheet with `sheet`,
  `identifier`, `change`, `fields`, `source`, and `uuid`;
- `conflicts`: each same-field collision with both values;
- `warnings` and `applicable`.

`--json` emits the plan. A plan with conflicts or a missing base has
`applicable: false` and the command exits `2`.

## Ancillary behaviour

Import still preserves the bundle's analysis settings and non-volatile
metadata. Export still requires a schematic-backed document, writes under the
original KiCad project stem, and preserves the existing drawing under write
fidelity v1. Merge writes the merged bundle and then exports it to KiCad, so
both sides converge in one command.

`ohm kicad status` reports `merge` when both sides changed and a base snapshot
is present, `conflict` when both changed without a base, and the existing
`import`/`export`/`up-to-date` values otherwise. The recommendation describes
the next action; `--dry-run` still reports whether that merge is applicable.

## Non-claims

- v2 does not merge KiCad-only objects such as wires, junctions, graphics, or
  unsupported symbols. They remain in the drawing and are not part of the
  three-way decision.
- v2 does not merge analysis settings, netlist text, or model-library edits.
  Analysis and metadata stay with the OhmLab bundle; KiCad model libraries are
  copied or preserved by write fidelity.
- v2 does not watch the filesystem or run a background daemon.
- v2 does not make an arbitrary KiCad project round-trip losslessly; the
  modelled subset is what the merge and simulation understand.
- A collision is never resolved silently. `--prefer` or a manual edit is
  required.

## Evidence

The 4.2 release gate requires:

- `KiCadCompanionTests.threeWayMergeCombinesNonConflictingChanges`, covering an
  OhmLab edit on the root sheet and a KiCad edit on a child sheet, with both
  reaching the bundle and the KiCad drawing;
- `KiCadCompanionTests.conflictingChangesRequireAPreference`, covering a
  same-field collision, a non-applicable plan, refusal, and `--prefer`;
- `KiCadCompanionTests.legacyStateWithoutABaseCannotMerge`, covering the
  fail-closed rule;
- `KiCadCompanionTests.dryRunPlanReportsChangesWithoutWriting`, covering the
  change list and the no-write guarantee;
- the v1 digest, status, import, export, preservation, and idempotence tests,
  which remain in the suite.
