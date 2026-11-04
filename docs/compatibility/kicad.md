# KiCad interoperability scope

OhmLab 2.9.0 provides **KiCad Netlist Interop**: simulation interoperability
with KiCad projects, not lossless KiCad schematic round-tripping. The promise is
deliberately tiered so the documented claim matches what CI proves.

## Compatibility tiers

| Tier | Status in 2.9 | What it means |
|---|---|---|
| **KiCad Netlist Interop** | Supported | Import a SPICE netlist exported by KiCad, simulate it, and export a self-contained SPICE netlist KiCad/ngspice can read. |
| **KiCad Project Import** | Supported on macOS | Import a `.kicad_pro`, its top `.kicad_sch`, or any child sheet by resolving the root and invoking `kicad-cli sch export netlist --format spice`. |
| **KiCad Schematic Interop** | Not yet | Direct `.kicad_sch` parsing/writing with preserved geometry, UUIDs, fields, symbol identities, and hierarchy. This is the next interoperability phase. |

## Supported today

- On macOS, import a `.kicad_pro` or `.kicad_sch` with KiCad 9+ `kicad-cli`
  (tested with 10.0.7) and consume its SPICE export.
- Resolve a project's root sheet when it is not named after the `.kicad_pro`
  file, and walk from a child or grandchild sheet up to the root that
  references it.
- Import ordinary SPICE netlists without KiCad installed.
- Preserve the KiCad source paths and import time in an OhmLab project manifest.
- Inline `.include`/`.lib` content at import time, including model libraries
  referenced relative to the KiCad project, so the imported design is
  self-contained and remains runnable after the original files move.
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
| Import KiCad `.kicad_pro`/`.kicad_sch` | Yes, via `kicad-cli` | No |
| Direct `.kicad_sch` parsing/writing | Not yet | Not yet |

## Fixture evidence

`Tests/OhmLabTests/Fixtures/KiCad/RC_Filter` is a real KiCad 10 project:

- `RC_Filter.kicad_pro` and a root schematic;
- a child sheet (`filter.kicad_sch`) and a grandchild sheet
  (`load.kicad_sch`);
- sheet pins and hierarchical labels across the hierarchy;
- a simulation model library (`models/rc_models.lib`) referenced by a diode;
- a golden `expected.cir` produced by `kicad-cli sch export netlist --format
  spice`, with the model-library include path normalised for portability.

The fixture tests resolve the root from every entry point, assert the
`Sheetfile` reference tree, parse the golden netlist with its model library,
build an imported project bundle, and verify self-contained export. They do
**not** require `kicad-cli`, so the compatibility claim is exercised in CI on
every run.

## Not promised by 2.9

- Direct parsing or writing of KiCad's schematic S-expression format.
- Preservation of KiCad symbol-library identities, UUIDs, fields, geometry,
  page settings, annotations, or PCB associations.
- Lossless reconstruction of a KiCad hierarchy after `kicad-cli` has flattened
  it into SPICE.
- `.kicad_sch` import on iPadOS, where `kicad-cli` is unavailable.
- Simulation of connectors, mechanical symbols, or unsupported SPICE devices.
- Every KiCad version. The supported claim is KiCad 9+ with 10.0.7 exercised by
  the committed fixture; older or newer versions must be added to the fixture
  corpus before they are claimed.

Unsupported constructs are diagnosed rather than silently simulated. Future
direct KiCad synchronization must be version-aware and fixture-tested before
the compatibility claim is broadened.
