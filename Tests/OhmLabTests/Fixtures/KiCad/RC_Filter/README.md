# RC_Filter KiCad fixture

A real KiCad 10 project used to prove OhmLab's netlist-level KiCad
interoperability in CI without requiring KiCad to be installed.

## Structure

```text
RC_Filter.kicad_pro          KiCad project
RC_Filter.kicad_sch          root sheet: V1, R1, and the Filter sheet
filter.kicad_sch             child sheet: C1, R2, and the Load sheet
load.kicad_sch               grandchild sheet: R3 and D1
models/rc_models.lib         simulation model library referenced by D1
expected.cir                 golden kicad-cli SPICE export
generate.py                  deterministic fixture generator
```

The hierarchy is intentionally three levels deep so root discovery is tested
from a project file, the root sheet, a child sheet, and a grandchild sheet.
`D1` carries `Sim.Name`, `Sim.Library`, and `Sim.Device` fields so the golden
netlist exercises model-library resolution.

## Regenerating

The committed schematics embed their symbol definitions and are self-contained.
Regeneration requires KiCad 10 (tested with 10.0.7):

```sh
python3 generate.py
```

The generator writes the project, all three schematics, the model library, and
`expected.cir`. It normalises the absolute `.include` path that `kicad-cli`
emits to the portable `models/rc_models.lib` form used by the tests.

If KiCad is installed somewhere other than `/Applications/KiCad/KiCad.app`,
pass `--symbols` and `--kicad-cli` explicitly.

## Tests

`Tests/OhmLabTests/KiCadFixtureTests.swift` uses this fixture to check:

- root resolution from every entry point;
- the `Sheetfile` reference tree;
- parsing the golden netlist and its model library;
- imported project-bundle construction;
- self-contained project and schematic export.
