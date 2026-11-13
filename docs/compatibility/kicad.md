# KiCad interoperability scope

OhmLab 4.2.0 provides **KiCad Schematic Interop** for reading and writing,
plus **KiCad Netlist Interop** for simulation and **KiCad Companion** sync.
Writing has two modes: generation draws a fresh project for the OhmLab-modelled
subset, and preservation patches an existing project in place, keeping every
KiCad object OhmLab does not own. Preservation is not a merge of simultaneous
edits, and only the modelled subset is simulated. The promise is deliberately
tiered so the documented claim matches what CI proves.

## Compatibility tiers

| Tier | Status in 4.2 | What it means |
|---|---|---|
| **KiCad Netlist Interop** | Supported | Import a SPICE netlist exported by KiCad, simulate it, and export a self-contained SPICE netlist KiCad/ngspice can read. |
| **KiCad Project Import** | Supported | Import a `.kicad_pro`, its top `.kicad_sch`, or any child sheet by resolving the root and reading the hierarchy directly. |
| **KiCad Schematic Read** | Supported | Parse `.kicad_sch` natively, preserving UUIDs, references, values, hierarchy, sheet pins, and model-library references, and derive connectivity from KiCad wires, junctions, labels, and pins. |
| **KiCad Schematic Write** | Supported | Emit a complete `.kicad_sch` project (per-sheet schematics, symbol library, model library, `sym-lib-table`, and `.kicad_pro`) for the OhmLab-modelled subset, preserving UUIDs, references, values, hierarchy, ports, rotations, and model parameters. |
| **KiCad Write Fidelity** | Supported | Patch an existing project in place: untouched sheets are byte-identical, untouched symbols and all non-modelled objects keep their source bytes, and only OhmLab-owned fields change. |
| **KiCad Companion** | Supported | Detect which side of a KiCad hierarchy and an `.ohmlabproj` bundle changed, import or export accordingly, and refuse conflicting edits unless a preference is given. |
| **KiCad IPC action plugin** | Available on KiCad 11+ | Register **OhmLab: Sync** and **OhmLab: Preview Sync** in the Schematic Editor and Project Manager as a thin wrapper over `ohm kicad sync`. Not shown by KiCad 9 or 10, which support IPC plugins only in the PCB Editor. |

## Supported today

- Read a `.kicad_pro` or `.kicad_sch` directly on macOS and iPadOS, with no
  KiCad installation required.
- On macOS, fall back to KiCad 9+ `kicad-cli` (tested with 10.0.7) only if the
  native reader cannot parse the project.
- Resolve a project's root sheet when it is not named after the `.kicad_pro`
  file, and walk from a child or grandchild sheet up to the root that
  references it.
- Walk the `Sheetfile` hierarchy and reconstruct child sheets with their ports
  as OhmLab subcircuit sheets.
- Preserve KiCad component UUIDs, reference designators, values, positions, and
  rotations for supported symbols.
- Preserve model-library references and import the referenced model text so the
  design remains runnable after the original files move.
- Derive connectivity from KiCad's own geometry: wire segments, junctions,
  local/global/hierarchical labels, and library pin positions transformed by
  the placed symbol's rotation.
- Import ordinary SPICE netlists without KiCad installed.
- Preserve the KiCad source paths and import time in an OhmLab project manifest.
- Convert supported flat SPICE and `.subckt` content into an editable OhmLab
  schematic.
- Export projected SPICE netlists per OhmLab sheet plus an active `top.cir` for
  KiCad/ngspice-oriented workflows. Exported schematic netlists are
  self-contained: they include a `.title` card, the document's enabled
  analysis cards (`.op`, `.ac`, `.tran`, `.dc`), and the text of imported model
  libraries, with duplicate `.end`/`.title` cards removed.
- Write a complete KiCad project under `<export>/KiCad/`: one `.kicad_sch` per
  OhmLab sheet, a project-local `OhmLab.kicad_sym`, a generated
  `models/ohmlab_models.lib`, a `sym-lib-table`, and a `.kicad_pro`.
- Round-trip KiCad component UUIDs, reference designators, values, positions,
  rotations, hierarchy, sheet ports, and model parameters for supported
  symbols.
- Emit KiCad's own pin conventions for diodes and sources so
  `kicad-cli sch export netlist` produces the same anode/cathode and
  positive/negative node order as OhmLab.
- Produce deterministic output: reading the same KiCad file twice, or exporting
  the same OhmLab project twice, yields byte-identical schematic, symbol, and
  model files.

## Platform matrix

| Capability | macOS | iPadOS |
|---|---|---|
| Import ordinary SPICE netlist | Yes | Yes |
| Export self-contained SPICE netlist | Yes | Yes |
| Read KiCad `.kicad_pro`/`.kicad_sch` | Yes, native | Yes, native |
| macOS `kicad-cli` fallback | Yes | n/a |
| Write `.kicad_sch` | Yes | Yes |
| Preserve an existing drawing on write-back | Yes | Yes |

## Symbol mapping

The direct reader maps common KiCad library symbols onto OhmLab descriptors:

| KiCad | OhmLab descriptor |
|---|---|
| `Device:R` | resistor |
| `Device:C` | capacitor |
| `Device:L` | inductor |
| `Device:D` / `Simulation_SPICE:D` | diode |
| `Device:Q*` / `Simulation_SPICE:Q*` | NPN/PNP transistor |
| `Device:M*` / `Simulation_SPICE:M*` | N-/P-MOSFET |
| `Device:J*` / `Simulation_SPICE:J*` | N-/P-JFET |
| `Simulation_SPICE:VDC` / `VAC` | voltage source |
| `Simulation_SPICE:IDC` / `IAC` | current source |
| `Simulation_SPICE:0` / `power:GND` | ground |

Pin roles come from `Sim.Pins` properties when present, otherwise from the
library pin names. Descriptor pins are matched to KiCad pin numbers so the
connectivity solver uses the same physical endpoints KiCad does. Symbols with
no OhmLab equivalent are skipped with a warning naming the reference.

The reader preserves component positions but attaches net labels directly to
OhmLab pins rather than copying KiCad wire geometry. That guarantees
connectivity and keeps the imported schematic editable; the original wire
routing is not reproduced.

## Writing

`KiCadSchematicWriter` writes a complete project for a schematic-backed OhmLab
document. The output directory contains:

- `<project>.kicad_sch` for the root sheet and one schematic per child sheet;
- `OhmLab.kicad_sym`, a self-contained symbol library;
- `models/ohmlab_models.lib`, deterministic `.model` cards derived from each
  semiconductor's OhmLab parameters;
- `sym-lib-table` pointing at the project-local symbol library;
- `<project>.kicad_pro`, a minimal project wrapper.

There are two write modes. **Generation** is used for a new project: symbols
are placed at their OhmLab positions with KiCad's 1 grid cell = 1.27 mm scale,
each sheet becomes a KiCad `sheet` node with its ports as sheet pins, and
connectivity is emitted as a label on every pin plus a ground symbol on every
ground net.

**Preservation** is used when writing back into an existing project (the
`ohm kicad export` source or the project targeted by `ohm kicad sync`). It
starts from the existing `.kicad_sch` files instead of redrawing them:

- a sheet that still matches what OhmLab imported is copied byte-for-byte;
- an unchanged symbol keeps its original node, including footprint, datasheet,
  custom fields, mirroring, pin UUIDs, and property layout;
- a changed symbol is patched in place (reference, value, model binding,
  `OhmLab.*` properties, and `at` only when it moved or rotated);
- new symbols, wires, and child-sheet instances are appended; deleted symbols
  are removed;
- wires, junctions, labels, graphics, text, title blocks, paper settings, and
  unsupported symbols keep their exact source bytes;
- the source project's model and symbol libraries are copied alongside when
  exporting to a new directory.

Preservation keeps the source's own library symbol (`Device:R`, for example)
unless the component type changes, and it only rewrites a semiconductor's
KiCad simulation binding when the device parameters actually changed. An
untouched project round-trips byte-identically; a value edit changes only that
value.

Subcircuit instances are normalised to rotation 0 and their original OhmLab
position is stored in `OhmLab.Position`. The writer emits
`OhmLab.Descriptor`, `OhmLab.Parameters`, `OhmLab.Reference`,
`OhmLab.Rotation`, `OhmLab.Position`, and `OhmLab.SheetRef` properties so a
subsequent read reconstructs the exact OhmLab model. Library symbols also
carry `Sim.Device`, `Sim.Type`, and `Sim.Pins` for KiCad's simulator. The
diode symbol follows KiCad's convention (pin 1 = `K`, pin 2 = `A`), and
voltage/current sources use KiCad's vertical orientation (pin 1 = `+` at the
top, pin 2 = `-` at the bottom). These choices make
`kicad-cli sch export netlist` emit the same node order as OhmLab.

The full contract is in
[`docs/contracts/kicad-write-fidelity-v1.md`](../contracts/kicad-write-fidelity-v1.md).

## Fixture evidence

`Tests/OhmLabTests/Fixtures/KiCad/RC_Filter` is a real KiCad 10 project:

- `RC_Filter.kicad_pro` and a root schematic;
- a child sheet (`filter.kicad_sch`) and a grandchild sheet
  (`load.kicad_sch`);
- sheet pins and hierarchical labels across the hierarchy;
- a simulation model library (`models/rc_models.lib`) referenced by a diode;
- a golden `expected.cir` produced by `kicad-cli sch export netlist --format
  spice`, with the model-library include path normalised for portability.

`Tests/OhmLabTests/KiCadWriterTests.swift` exercises the writer against the
same fixture:

- writes the complete project layout and checks every schematic and library
  file is a balanced S-expression;
- asserts the diode and source pin conventions, `Sim.*` properties, and
  generated model cards;
- reads the generated project back and asserts component UUIDs, references,
  values, parameters, hierarchy, and ports survive;
- runs the original and round-tripped schematics through the native engine and
  asserts their DC solutions agree;
- writes twice and asserts byte-identical output;
- optionally validates the generated root with a locally installed
  `kicad-cli` and checks `V1 /IN 0 DC 5` and the diode's node order.

These tests do **not** require `kicad-cli`, so the compatibility claim is
exercised in CI on every run. The `kicad-cli` check is skipped when the tool is
not installed.

`RC_Filter_KiCad7`, `RC_Filter_KiCad8`, and `RC_Filter_KiCad9` repeat the same
hierarchy with each release's format header and generator conventions, including
KiCad 7's unquoted UUIDs. Their tests read the hierarchy, preserve an untouched
project byte-for-byte, and patch one value without rewriting wires or unchanged
child sheets. They are format-tolerance fixtures derived from the KiCad 10
project, not byte-level reproductions of each release.

## Companion sync

OhmLab 4.2 keeps a KiCad project hierarchy and an OhmLab bundle aligned:

```sh
ohm kicad status <kicadPath> <bundle>
ohm kicad sync <kicadPath> <bundle> [--direction import|export|auto] \
    [--prefer kicad|ohmlab] [--force] [--dry-run] [--json]
```

The companion stores the digests observed at the last sync in
`.ohmlab-companion.json` and the agreed snapshot in
`.ohmlab-companion-base.json`, both inside the bundle. `auto` imports when only
KiCad changed, exports when only the bundle changed, and reports `up-to-date`
when neither changed. When both changed it performs a three-way merge: an object
that only one side changed is taken from that side, and only a same-field
collision is reported. `--prefer kicad|ohmlab` still selects a whole side, and
`--force` overwrites with an explicit `--direction`. With no companion state, an
existing bundle requires an explicit direction; a new bundle is imported from
KiCad.

`--dry-run` returns the same plan without writing the bundle, the KiCad project,
or the state sidecar. It lists each added, updated, or removed symbol and sheet,
the changed fields, the source side, and any unresolved conflicts; with `--json`
the plan is machine-readable.

The merge covers OhmLab-modelled symbols and sheet structure. KiCad-only objects
(wires, junctions, graphics, and unsupported symbols) stay in the drawing and
are not part of the three-way decision.

Both digests are deterministic. The KiCad digest covers the project files with
the `kicad_pro`, `kicad_sch`, `kicad_sym`, `kicad_mod`, and `lib` extensions,
sorted by relative path. The bundle digest covers sheet names, canonical
netlists, and analysis settings, and ignores volatile import metadata. Import
preserves the bundle's saved analysis settings and non-volatile metadata;
export requires a schematic-backed document and writes under the original KiCad
project stem.

The companion does not watch the filesystem and does not make an arbitrary KiCad
project round-trip losslessly. See
[`docs/contracts/kicad-companion-v2.md`](../contracts/kicad-companion-v2.md) for
the full contract and non-claims.

## KiCad IPC action plugin

[`integrations/kicad/`](../../integrations/kicad/README.md) contains a KiCad IPC
action plugin that exposes the companion from the Schematic Editor and Project
Manager. It uses the `exec` runtime rather than the Python runtime, so it needs
neither a KiCad-managed virtual environment nor `kicad-python`. The two actions
invoke the same installed `ohm` executable:

```sh
ohm kicad sync <kicad> <bundle> --direction auto
ohm kicad sync <kicad> <bundle> --direction auto --dry-run
```

The project and bundle paths, direction, and optional preference live in
`ohmlab.json` beside the plugin. The preview action writes nothing and exits `2`
when the plan contains a conflict or a missing base, exactly like the CLI.

KiCad 9 and 10 support IPC API plugins only in the PCB Editor; the Schematic
Editor and Project Manager actions require KiCad 11 or newer. The plugin is
therefore a convenience wrapper for KiCad 11+ and is not a way to add schematic
sync to older KiCad releases.

The plugin runs on the files on disk. Save in KiCad before running an action;
unsaved editor state is not visible to `ohm`. The action does not use the
KiCad IPC socket, does not trigger a reload after writing, and does not merge
KiCad-only objects. See the
[plugin README](../../integrations/kicad/README.md) for installation,
configuration, and limitations.

## Not promised by the KiCad tiers

- A lossless round-trip of an arbitrary KiCad project. Preservation mode keeps
  every node OhmLab does not own, but the OhmLab-modelled subset is what gets
  simulated and rewritten.
- Automatic resolution of a same-field collision. Three-way merge handles edits
  to different objects and different fields; a collision still requires
  `--prefer` (or a manual edit).
- Merging changes to objects OhmLab does not model. Wires, graphics, and
  unsupported symbols stay in the KiCad drawing outside the merge decision.
- Removing wires or sheet-box graphics that referred to a symbol or instance
  deleted in OhmLab; those are left for the user to tidy in KiCad.
- Preservation of subcircuit-instance rotation when that instance is
  regenerated; an unchanged instance keeps its source node.
- Preservation of custom graphics on a child-sheet instance that was renamed or
  whose ports changed, because that sheet node is regenerated.
- Simulation of connectors, mechanical symbols, or unsupported SPICE devices.
- KiCad 7, 8, and 9 as fully reproduced projects. Their committed fixtures are
  derived from the KiCad 10 project to exercise format-header tolerance and
  KiCad 7 unquoted UUIDs; KiCad 10 remains the end-to-end fixture validated with
  `kicad-cli` 10.0.7. Older or newer versions must be added to the fixture
  corpus before they are claimed.
- Running the action plugin inside KiCad 9 or 10. Those releases support IPC
  API plugins only in the PCB Editor; Schematic Editor and Project Manager
  actions require KiCad 11 or newer.
- Reading unsaved KiCad editor state or forcing KiCad to reload files after the
  action plugin writes them; the plugin operates on saved files on disk.
- Bit-identical KiCad net names. OhmLab uses sheet-local node names (`OUT`)
  where `kicad-cli` emits hierarchical paths (`/Filter/OUT`); the electrical
  solution is compared instead.

Unsupported constructs are diagnosed rather than silently simulated. Future
direct KiCad writing changes must remain version-aware and fixture-tested before
the compatibility claim is broadened.
