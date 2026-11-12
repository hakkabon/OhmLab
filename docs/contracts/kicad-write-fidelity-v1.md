# KiCad write fidelity v1

KiCad write fidelity v1 is the public contract for non-destructive write-back
into an existing KiCad project. It complements, and does not replace, the
KiCad companion v1 and the tiered interoperability claim in
[`docs/compatibility/kicad.md`](../compatibility/kicad.md).

## Modes

`KiCadSchematicWriter.writeProject(snapshot:name:to:preserving:)` has two
modes:

- **Generation mode** (`preserving: nil`): draws a fresh project from OhmLab's
  model. Connectivity is re-emitted as a label on every pin. This is the right
  behaviour for a new project.
- **Preservation mode** (`preserving:` an existing `.kicad_pro`, `.kicad_sch`,
  or project directory): starts from the existing schematic files and replaces
  only the objects OhmLab owns.

`ohm kicad export` enables preservation automatically when the bundle records
a KiCad source that still exists. `ohm kicad sync --direction export` (and
`auto` when only OhmLab changed) always preserves the project it writes into.

## Guarantees

Within the OhmLab-modelled subset, and when the KiCad project is the same one
the bundle was imported from:

1. **Unchanged sheets are byte-identical.** If a sheet's symbols, wires,
   labels, ports, and name still match what the reader would import from the
   current KiCad file, the file is copied unchanged.
2. **Unchanged symbols keep their exact source node.** A symbol that only moved
   is patched; a symbol whose value, parameters, reference, or rotation did not
   change keeps its original bytes, including property layout, footprint,
   datasheet, custom fields, mirroring, and pin UUIDs.
3. **Everything OhmLab does not own is preserved verbatim.** Wire and bus
   geometry, junctions, no-connects, labels, graphic shapes, text, title
   blocks, paper settings, embedded symbol definitions, sheet instances, and
   unsupported symbols keep their source bytes.
4. **Only owned fields are patched.** For a changed symbol OhmLab updates the
   KiCad `Reference`, `Value` (only when the component value/parameters or type
   changed), `Sim.Name`/`Sim.Library` when a concrete model is bound, and the
   `OhmLab.*` round-trip properties, plus `at` when the symbol moved or
   rotated. The source's library id is kept unless the component type changed.
5. **New objects are appended, deleted symbols are removed.** A symbol, wire,
   or child-sheet instance added in OhmLab is appended deterministically; a
   symbol deleted in OhmLab is removed from the sheet.
6. **Deterministic output.** Repeating the same preservation write produces
   byte-identical files.

## Merge rules

| Source node | OhmLab state | Result |
| --- | --- | --- |
| `symbol` | unchanged | source bytes |
| `symbol` | value/parameters/reference/rotation changed | patched in place |
| `symbol` | position changed | `at` patched; stale labels at the old pins removed and fresh labels written |
| `symbol` | type changed | library id and pin set replaced |
| `symbol` | new | generated and appended |
| `symbol` | deleted | removed |
| `symbol` | unsupported (no OhmLab descriptor) | source bytes |
| `sheet` | unchanged | source bytes |
| `sheet` | name/file/position changed or new | regenerated sheet node |
| `wire`, `bus`, junction, label, graphic, text, title block, paper | any | source bytes |
| `wire`, `bus` | new | generated and appended |
| `lib_symbols` | new or re-typed symbols | missing definitions appended; existing definitions untouched |

## Ancillary files

When exporting to a different directory, the source project's non-schematic
files (model libraries, symbol libraries, `sym-lib-table`, page layouts, and
the `.kicad_pro`) are copied before the merge. Existing files are never
overwritten except `models/ohmlab_models.lib`, which OhmLab owns. When writing
in place, those files are left untouched.

If the preservation source cannot be loaded, the writer falls back to
generation mode and reports a warning as the first entry of
`KiCadSchematicWriteResult.warnings`. Preservation is never allowed to fail
silently.

## Non-claims

- v1 does not merge simultaneous KiCad and OhmLab edits. The companion's
  conflict rule still requires `--prefer`; three-way merge is a later contract.
- Deleting a symbol does not delete the wires that connected it. The drawing is
  left for the user to tidy in KiCad.
- A regenerated child-sheet instance (renamed or retyped) does not preserve
  custom sheet-box graphics.
- Street-level KiCad constructs are preserved, not interpreted: OhmLab still
  simulates only its modelled subset, and unsupported symbols remain
  unsimulated.
- `kicad-cli` acceptance is validated on the committed fixture corpus, not on
  arbitrary projects.

## Evidence

The 4.1 release gate requires:

- `KiCadWriteFidelityTests`, covering byte-identical no-op writes, value edits
  with preserved wire geometry, deterministic repeated writes, appended
  symbols, a read-back DC-solution match, and the missing-source fallback;
- `KiCadCompanionTests.exportSyncPreservesTheDrawing`, covering the in-place
  companion export;
- `KiCadWriterTests`, unchanged from 4.0, covering fresh generation and
  `kicad-cli` acceptance.
