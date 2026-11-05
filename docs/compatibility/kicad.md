# KiCad interoperability scope

OhmLab 3.0.0 provides **KiCad Schematic Interop** for reading, plus **KiCad
Netlist Interop** for simulation. It is not yet a lossless KiCad schematic
round-trip: writing `.kicad_sch` is not supported. The promise is deliberately
tiered so the documented claim matches what CI proves.

## Compatibility tiers

| Tier | Status in 3.0 | What it means |
|---|---|---|
| **KiCad Netlist Interop** | Supported | Import a SPICE netlist exported by KiCad, simulate it, and export a self-contained SPICE netlist KiCad/ngspice can read. |
| **KiCad Project Import** | Supported | Import a `.kicad_pro`, its top `.kicad_sch`, or any child sheet by resolving the root and reading the hierarchy directly. |
| **KiCad Schematic Read** | Supported | Parse `.kicad_sch` natively, preserving UUIDs, references, values, hierarchy, sheet pins, and model-library references, and derive connectivity from KiCad wires, junctions, labels, and pins. |
| **KiCad Schematic Write** | Not yet | Emit `.kicad_sch` with preserved geometry, fields, and symbol identities. Export remains SPICE-level. |

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

## Platform matrix

| Capability | macOS | iPadOS |
|---|---|---|
| Import ordinary SPICE netlist | Yes | Yes |
| Export self-contained SPICE netlist | Yes | Yes |
| Read KiCad `.kicad_pro`/`.kicad_sch` | Yes, native | Yes, native |
| macOS `kicad-cli` fallback | Yes | n/a |
| Write `.kicad_sch` | Not yet | Not yet |

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

## Fixture evidence

`Tests/OhmLabTests/Fixtures/KiCad/RC_Filter` is a real KiCad 10 project:

- `RC_Filter.kicad_pro` and a root schematic;
- a child sheet (`filter.kicad_sch`) and a grandchild sheet
  (`load.kicad_sch`);
- sheet pins and hierarchical labels across the hierarchy;
- a simulation model library (`models/rc_models.lib`) referenced by a diode;
- a golden `expected.cir` produced by `kicad-cli sch export netlist --format
  spice`, with the model-library include path normalised for portability.

`Tests/OhmLabTests/KiCadDirectReaderTests.swift` exercises the direct reader
against that fixture:

- resolves the whole hierarchy from the project, the root, and any child sheet;
- asserts KiCad UUIDs, references, values, and model-library references survive;
- derives the expected nets from wires, junctions, labels, and pins;
- runs the generated netlist and the golden `kicad-cli` netlist through the
  native engine and asserts their DC solutions agree;
- imports a schematic-backed project bundle and re-exports it self-contained;
- checks unsupported symbols produce warnings and malformed input is rejected.

These tests do **not** require `kicad-cli`, so the compatibility claim is
exercised in CI on every run.

## Not promised by 3.0

- Writing `.kicad_sch`, or any lossless KiCad schematic round-trip.
- Preservation of KiCad wire geometry, page settings, annotations, or PCB
  associations.
- Simulation of connectors, mechanical symbols, or unsupported SPICE devices.
- Every KiCad version. The supported claim is KiCad 9+ with 10.0.7 exercised by
  the committed fixture; older or newer versions must be added to the fixture
  corpus before they are claimed.
- Bit-identical KiCad net names. OhmLab uses sheet-local node names (`OUT`)
  where `kicad-cli` emits hierarchical paths (`/Filter/OUT`); the electrical
  solution is compared instead.

Unsupported constructs are diagnosed rather than silently simulated. Future
direct KiCad writing must be version-aware and fixture-tested before the
compatibility claim is broadened.
