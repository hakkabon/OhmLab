#!/usr/bin/env python3
"""Regenerate the RC_Filter KiCad fixture.

The fixture is a real KiCad 10 project. The committed `.kicad_sch` files embed
their symbol definitions so they do not depend on a local KiCad installation at
test time. Only this script needs KiCad installed, and only when the fixture is
being regenerated.

Usage:
    python3 generate.py
    python3 generate.py --symbols /path/to/kicad/symbols \
        --kicad-cli /path/to/kicad-cli
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import uuid
from pathlib import Path

DEFAULT_SYMBOLS = Path(
    "/Applications/KiCad/KiCad.app/Contents/SharedSupport/symbols"
)
DEFAULT_KICAD_CLI = Path("/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli")

ROOT_UUID = "11111111-1111-4111-8111-111111111111"
PROJECT_NAME = "RC_Filter"


def uid(key: str) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"ohmlab-kicad-fixture/{key}"))


def extract_symbol(symbols_dir: Path, library: str, name: str) -> str:
    """Return one top-level symbol block, renamed to `library:name`."""
    text = (symbols_dir / library).read_text(encoding="utf-8")
    needle = f'(symbol "{name}"'
    start = text.find(needle)
    if start < 0:
        raise SystemExit(f"missing symbol {name!r} in {library}")

    depth = 0
    index = start
    in_string = False
    escaped = False
    while index < len(text):
        char = text[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
        else:
            if char == '"':
                in_string = True
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    break
        index += 1

    block = text[start : index + 1]
    prefix = library.removesuffix(".kicad_sym")
    return block.replace(f'(symbol "{name}"', f'(symbol "{prefix}:{name}"', 1)


def indent(block: str, prefix: str) -> str:
    return "\n".join(prefix + line for line in block.splitlines())


def symbol(
    lib_id: str,
    at: tuple[float, float, int],
    reference: str,
    value: str,
    pins: list[str],
    extra_properties: str = "",
) -> str:
    x, y, rotation = at
    properties = f"""\t\t(property "Reference" "{reference}"
\t\t\t(at {x + 2.54} {y - 2.54} 0)
\t\t\t(effects (font (size 1.27 1.27)) (justify left))
\t\t)
\t\t(property "Value" "{value}"
\t\t\t(at {x + 2.54} {y + 2.54} 0)
\t\t\t(effects (font (size 1.27 1.27)) (justify left))
\t\t)
\t\t(property "Footprint" ""
\t\t\t(at {x} {y} 0)
\t\t\t(effects (font (size 1.27 1.27)) (hide yes))
\t\t)
\t\t(property "Datasheet" ""
\t\t\t(at {x} {y} 0)
\t\t\t(effects (font (size 1.27 1.27)) (hide yes))
\t\t)
\t\t(property "Description" ""
\t\t\t(at {x} {y} 0)
\t\t\t(effects (font (size 1.27 1.27)) (hide yes))
\t\t)
"""
    pin_text = "".join(
        f'\t\t(pin "{pin}"\n\t\t\t(uuid "{uid(reference + "/pin/" + pin)}")\n\t\t)\n'
        for pin in pins
    )
    return f"""\t(symbol
\t\t(lib_id "{lib_id}")
\t\t(at {x} {y} {rotation})
\t\t(unit 1)
\t\t(exclude_from_sim no)
\t\t(in_bom yes)
\t\t(on_board yes)
\t\t(dnp no)
\t\t(uuid "{uid(reference)}")
{properties}{extra_properties}{pin_text}\t\t(instances
\t\t\t(project "{PROJECT_NAME}"
\t\t\t\t(path "/{ROOT_UUID}"
\t\t\t\t\t(reference "{reference}")
\t\t\t\t\t(unit 1)
\t\t\t\t)
\t\t\t)
\t\t)
\t)
"""


def wire(x1: float, y1: float, x2: float, y2: float, key: str) -> str:
    return f"""\t(wire
\t\t(pts
\t\t\t(xy {x1} {y1}) (xy {x2} {y2})
\t\t)
\t\t(stroke (width 0) (type solid))
\t\t(uuid "{uid("wire/" + key)}")
\t)
"""


def label(name: str, x: float, y: float, rotation: int = 0) -> str:
    return f"""\t(label "{name}"
\t\t(at {x} {y} {rotation})
\t\t(effects (font (size 1.27 1.27)) (justify left bottom))
\t\t(uuid "{uid(f"label/{name}/{x}/{y}")}")
\t)
"""


def hierarchical_label(name: str, shape: str, x: float, y: float, rotation: int) -> str:
    return f"""\t(hierarchical_label "{name}"
\t\t(shape {shape})
\t\t(at {x} {y} {rotation})
\t\t(effects (font (size 1.27 1.27)) (justify left bottom))
\t\t(uuid "{uid(f"hlabel/{name}/{x}/{y}")}")
\t)
"""


def sheet(
    name: str,
    filename: str,
    at: tuple[float, float],
    size: tuple[float, float],
    pins: list[tuple[str, str, float, float, int]],
    page: str,
) -> str:
    x, y = at
    width, height = size
    pin_text = ""
    for pin_name, shape, pin_x, pin_y, rotation in pins:
        justify = "right" if rotation == 180 else "left"
        pin_text += f"""\t\t(pin "{pin_name}" {shape}
\t\t\t(at {pin_x} {pin_y} {rotation})
\t\t\t(effects (font (size 1.27 1.27)) (justify {justify}))
\t\t\t(uuid "{uid(f"sheetpin/{name}/{pin_name}")}")
\t\t)
"""
    return f"""\t(sheet
\t\t(at {x} {y})
\t\t(size {width} {height})
\t\t(fields_autoplaced yes)
\t\t(stroke (width 0.1524) (type solid))
\t\t(fill (color 0 0 0 0.0000))
\t\t(uuid "{uid("sheet/" + name)}")
\t\t(property "Sheetname" "{name}"
\t\t\t(at {x} {y - 0.7116} 0)
\t\t\t(effects (font (size 1.27 1.27)) (justify left bottom))
\t\t)
\t\t(property "Sheetfile" "{filename}"
\t\t\t(at {x} {y + height + 0.5884} 0)
\t\t\t(effects (font (size 1.27 1.27)) (justify left top))
\t\t)
{pin_text}\t\t(instances
\t\t\t(project "{PROJECT_NAME}"
\t\t\t\t(path "/{ROOT_UUID}"
\t\t\t\t\t(page "{page}")
\t\t\t\t)
\t\t\t)
\t\t)
\t)
"""


def schematic(key: str, body: str, lib_symbols: str) -> str:
    return f"""(kicad_sch
\t(version 20250114)
\t(generator "eeschema")
\t(generator_version "10.0")
\t(uuid "{uid(key)}")
\t(paper "A4")
\t(lib_symbols
{lib_symbols}
\t)
{body}
\t(sheet_instances
\t\t(path "/"
\t\t\t(page "1")
\t\t)
\t)
\t(embedded_fonts no)
)
"""


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--symbols", type=Path, default=DEFAULT_SYMBOLS)
    parser.add_argument("--kicad-cli", type=Path, default=DEFAULT_KICAD_CLI)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).resolve().parent,
        help="Fixture directory to write (defaults to this script's directory).",
    )
    args = parser.parse_args()

    if not args.symbols.is_dir():
        raise SystemExit(f"KiCad symbol directory not found: {args.symbols}")
    if not args.kicad_cli.is_file():
        raise SystemExit(f"kicad-cli not found: {args.kicad_cli}")

    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    (output / "models").mkdir(exist_ok=True)

    symbols = [
        extract_symbol(args.symbols, "Device.kicad_sym", "R"),
        extract_symbol(args.symbols, "Device.kicad_sym", "C"),
        extract_symbol(args.symbols, "Simulation_SPICE.kicad_sym", "VDC"),
        extract_symbol(args.symbols, "Simulation_SPICE.kicad_sym", "D"),
        extract_symbol(args.symbols, "Simulation_SPICE.kicad_sym", "0"),
    ]
    lib_symbols = "\n".join(indent(block, "        ") for block in symbols)

    root_body = "\n".join(
        [
            symbol(
                "Simulation_SPICE:VDC",
                (50.8, 80.01, 0),
                "V1",
                "5",
                ["1", "2"],
            ),
            symbol("Simulation_SPICE:0", (50.8, 85.09, 0), "#GND01", "0", ["1"]),
            symbol("Device:R", (50.8, 66.04, 0), "R1", "1k", ["1", "2"]),
            wire(50.8, 74.93, 50.8, 69.85, "root-v1-r1"),
            wire(50.8, 62.23, 50.8, 40, "root-r1-sheet"),
            label("IN", 50.8, 72, 90),
            label("MID", 50.8, 45, 90),
            sheet(
                "Filter",
                "filter.kicad_sch",
                (80, 30),
                (30, 20),
                [
                    ("MID", "input", 80, 40, 180),
                    ("OUT", "output", 110, 40, 0),
                ],
                "2",
            ),
            wire(50.8, 40, 80, 40, "root-to-filter"),
            label("MID", 60, 40),
        ]
    )

    child_body = "\n".join(
        [
            symbol("Device:C", (50, 60, 0), "C1", "1u", ["1", "2"]),
            symbol("Simulation_SPICE:0", (50, 63.81, 0), "#GND02", "0", ["1"]),
            symbol("Device:R", (70, 52.07, 0), "R2", "1k", ["1", "2"]),
            hierarchical_label("MID", "input", 50, 40, 180),
            hierarchical_label("OUT", "output", 100, 40, 0),
            wire(50, 40, 50, 48.26, "child-mid-c1"),
            wire(50, 56.19, 50, 48.26, "child-c1-mid"),
            wire(70, 48.26, 70, 40, "child-r2-mid"),
            wire(70, 40, 50, 40, "child-mid-label"),
            wire(70, 55.88, 70, 60, "child-r2-out"),
            wire(70, 60, 100, 60, "child-out-run"),
            wire(100, 60, 100, 40, "child-out-up"),
            sheet(
                "Load",
                "load.kicad_sch",
                (120, 30),
                (20, 20),
                [("OUT", "input", 120, 40, 180)],
                "3",
            ),
            wire(100, 40, 120, 40, "child-to-load"),
        ]
    )

    diode_properties = """\t\t(property "Sim.Device" "D"
\t\t\t(at 70 52.07 0)
\t\t\t(effects (font (size 1.27 1.27)) (hide yes))
\t\t)
\t\t(property "Sim.Name" "DMOD"
\t\t\t(at 70 52.07 0)
\t\t\t(effects (font (size 1.27 1.27)) (hide yes))
\t\t)
\t\t(property "Sim.Library" "models/rc_models.lib"
\t\t\t(at 70 52.07 0)
\t\t\t(effects (font (size 1.27 1.27)) (hide yes))
\t\t)
"""
    grandchild_body = "\n".join(
        [
            symbol("Device:R", (50, 52.07, 0), "R3", "2k", ["1", "2"]),
            symbol("Simulation_SPICE:0", (50, 55.88, 0), "#GND03", "0", ["1"]),
            symbol(
                "Simulation_SPICE:D",
                (70, 52.07, 0),
                "D1",
                "DMOD",
                ["1", "2"],
                diode_properties,
            ),
            symbol("Simulation_SPICE:0", (73.81, 52.07, 0), "#GND04", "0", ["1"]),
            hierarchical_label("OUT", "input", 50, 40, 180),
            wire(50, 40, 50, 48.26, "load-out-r3"),
            wire(50, 48.26, 66.19, 48.26, "load-out-diode"),
            wire(66.19, 48.26, 66.19, 52.07, "load-diode-down"),
        ]
    )

    (output / "RC_Filter.kicad_sch").write_text(
        schematic("root", root_body, lib_symbols), encoding="utf-8"
    )
    (output / "filter.kicad_sch").write_text(
        schematic("filter", child_body, lib_symbols), encoding="utf-8"
    )
    (output / "load.kicad_sch").write_text(
        schematic("load", grandchild_body, lib_symbols), encoding="utf-8"
    )
    (output / "RC_Filter.kicad_pro").write_text(
        """{
  "board": {},
  "meta": {"filename": "RC_Filter.kicad_pro", "version": 1},
  "schematic": {},
  "sheets": [["11111111-1111-4111-8111-111111111111", "Root"]]
}
""",
        encoding="utf-8",
    )
    (output / "models" / "rc_models.lib").write_text(
        ".model DMOD D(IS=1e-14 N=1 RS=0.01)\n", encoding="utf-8"
    )

    raw = output / "expected.raw.cir"
    subprocess.run(
        [
            str(args.kicad_cli),
            "sch",
            "export",
            "netlist",
            "--format",
            "spice",
            "-o",
            str(raw),
            str(output / "RC_Filter.kicad_sch"),
        ],
        cwd=output,
        check=True,
    )

    # kicad-cli writes an absolute .include path. Normalise it so the golden
    # netlist is portable and resolves against the fixture directory.
    netlist = raw.read_text(encoding="utf-8")
    lines = []
    for line in netlist.splitlines():
        if line.startswith('.include "') and line.endswith('/models/rc_models.lib"'):
            line = '.include "models/rc_models.lib"'
        lines.append(line)
    (output / "expected.cir").write_text("\n".join(lines) + "\n", encoding="utf-8")
    raw.unlink()
    # kicad-cli may create project-local editor state next to the project.
    for generated in (f"{PROJECT_NAME}.kicad_prl", "fp-info-cache"):
        path = output / generated
        if path.exists():
            path.unlink()

    print(f"Wrote fixture to {output}")
    print(f"Golden netlist: {output / 'expected.cir'}")


if __name__ == "__main__":
    main()
