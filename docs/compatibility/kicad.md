# KiCad interoperability scope

OhmLab 3.2.0 provides **KiCad Schematic Interop** for reading and writing,
plus **KiCad Netlist Interop** for simulation. Writing is supported for the
OhmLab-modelled subset of KiCad and preserves the identities and values that
matter for editing and simulation. It is not a lossless reproduction of an
arbitrary KiCad project: wire geometry, page settings, and unsupported symbols
are not carried through. The promise is deliberately tiered so the documented
claim matches what CI proves.

## Compatibility tiers

| Tier | Status in 3.2 | What it means |
|---|---|---|
| **KiCad Netlist Interop** | Supported | Import a SPICE netlist exported by KiCad, simulate it, and export a self-contained SPICE netlist KiCad/ngspice can read. |
| **KiCad Project Import** | Supported | Import a `.kicad_pro`, its top `.kicad_sch`, or any child sheet by resolving the root and reading the hierarchy directly. |
| **KiCad Schematic Read** | Supported | Parse `.kicad_sch` natively, preserving UUIDs, references, values, hierarchy, sheet pins, and model-library references, and derive connectivity from KiCad wires, junctions, labels, and pins. |
| **KiCad Schematic Write** | Supported | Emit a complete `.kicad_sch` project (per-sheet schematics, symbol library, model library, `sym-lib-table`, and `.kicad_pro`) for the OhmLab-modelled subset, preserving UUIDs, references, values, hierarchy, ports, rotations, and model parameters. |

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

Symbols are placed at their OhmLab positions with KiCad's 1 grid cell =
1.27 mm scale, and each sheet becomes a KiCad `sheet` node with its ports as
sheet pins. Connectivity is emitted as a label on every pin plus a ground
symbol on every ground net, so the generated project does not depend on
reproducing KiCad wire routing. Ground nets are labelled `"0"` and carry a
power symbol. Subcircuit instances are normalised to rotation 0 and their
original OhmLab position is stored in `OhmLab.Position`.

The writer emits `OhmLab.Descriptor`, `OhmLab.Parameters`,
`OhmLab.Reference`, `OhmLab.Rotation`, `OhmLab.Position`, and
`OhmLab.SheetRef` properties so a subsequent read reconstructs the exact
OhmLab model. Library symbols also carry `Sim.Device`, `Sim.Type`, and
`Sim.Pins` for KiCad's simulator. The diode symbol follows KiCad's convention
(pin 1 = `K`, pin 2 = `A`), and voltage/current sources use KiCad's vertical
orientation (pin 1 = `+` at the top, pin 2 = `-` at the bottom). These choices
make `kicad-cli sch export netlist` emit the same node order as OhmLab.

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

## Not promised by 3.1

- A lossless round-trip of an arbitrary KiCad project. Only the
  OhmLab-modelled subset is written back.
- Preservation of KiCad wire geometry, page settings, annotations, or PCB
  associations. Connectivity is re-emitted as labels on pins.
- Preservation of subcircuit-instance rotation; instances are written
  unrotated and their original position is kept in `OhmLab.Position`.
- Simulation of connectors, mechanical symbols, or unsupported SPICE devices.
- Every KiCad version. The supported claim is KiCad 9+ with 10.0.7 exercised by
  the committed fixture; older or newer versions must be added to the fixture
  corpus before they are claimed.
- Bit-identical KiCad net names. OhmLab uses sheet-local node names (`OUT`)
  where `kicad-cli` emits hierarchical paths (`/Filter/OUT`); the electrical
  solution is compared instead.

Unsupported constructs are diagnosed rather than silently simulated. Future
direct KiCad writing changes must remain version-aware and fixture-tested before
the compatibility claim is broadened.
