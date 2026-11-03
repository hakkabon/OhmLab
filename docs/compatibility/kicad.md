# KiCad interoperability scope

OhmLab 0.8 provides **simulation interoperability with KiCad**, not lossless
KiCad schematic round-tripping.

## Supported today

- On macOS, import a `.kicad_sch` or `.kicad_pro` by invoking KiCad 9+
  `kicad-cli` and consuming its SPICE export.
- Resolve a project's root sheet when it is not named after the `.kicad_pro`
  file, and walk from a child sheet up to the root that references it.
- Import ordinary SPICE netlists without KiCad installed.
- Preserve the KiCad source paths and import time in an OhmLab project manifest.
- Convert supported flat SPICE and `.subckt` content into an editable OhmLab
  schematic.
- Export projected SPICE netlists per OhmLab sheet plus an active `top.cir` for
  KiCad/ngspice-oriented workflows. Exported schematic netlists are
  self-contained: they include a `.title` card, the document's enabled
  analysis cards (`.op`, `.ac`, `.tran`, `.dc`), and the text of imported model
  libraries, with duplicate `.end`/`.title` cards removed.

## Not promised by 0.8

- Direct parsing or writing of KiCad's schematic S-expression format.
- Preservation of KiCad symbol-library identities, UUIDs, fields, geometry,
  page settings, annotations, or PCB associations.
- Lossless reconstruction of a KiCad hierarchy after `kicad-cli` has flattened
  it into SPICE.
- `.kicad_sch` import on iPadOS, where `kicad-cli` is unavailable.
- Simulation of connectors, mechanical symbols, or unsupported SPICE devices.

Unsupported constructs are diagnosed rather than silently simulated. Future
direct KiCad synchronization must be version-aware and fixture-tested before
the compatibility claim is broadened.
