#!/usr/bin/env python3
"""Regenerate the KiCad 7/8/9 format-tolerance corpus entries.

The real project lives in ``RC_Filter`` (KiCad 10). Each variant reuses its
electrical content, project file, model library, and golden netlist, and changes
only the schematic format header and the way UUID tokens are written. These are
format-tolerance fixtures, not byte-level reproductions of each KiCad release.

Usage:
    python3 generate_version_variants.py
"""

from __future__ import annotations

import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "RC_Filter"

# directory, schematic format version, generator version, quote UUIDs
VARIANTS = [
    ("RC_Filter_KiCad7", 20230121, "7.0", False),
    ("RC_Filter_KiCad8", 20231120, "8.0", True),
    ("RC_Filter_KiCad9", 20250114, "9.0", True),
]

SCHEMATICS = ["RC_Filter.kicad_sch", "filter.kicad_sch", "load.kicad_sch"]


def convert(text: str, version: int, generator_version: str, quote_uuids: bool) -> str:
    text = re.sub(r"\(version \d+\)", f"(version {version})", text, count=1)
    generator = '(generator "eeschema")' if quote_uuids else "(generator eeschema)"
    text = re.sub(r"\(generator [^)]+\)", generator, text, count=1)
    text = re.sub(
        r'\(generator_version "[^"]*"\)',
        f'(generator_version "{generator_version}")',
        text,
        count=1,
    )
    if not quote_uuids:
        text = re.sub(r'\(uuid "([^"]+)"\)', r"(uuid \1)", text)
    return text


def main() -> None:
    for name, version, generator_version, quote_uuids in VARIANTS:
        destination = ROOT / name
        destination.mkdir(parents=True, exist_ok=True)

        shutil.copy2(SOURCE / "RC_Filter.kicad_pro", destination / "RC_Filter.kicad_pro")
        shutil.copy2(SOURCE / "expected.cir", destination / "expected.cir")
        models = destination / "models"
        if models.exists():
            shutil.rmtree(models)
        shutil.copytree(SOURCE / "models", models)

        for schematic in SCHEMATICS:
            source_text = (SOURCE / schematic).read_text(encoding="utf-8")
            (destination / schematic).write_text(
                convert(source_text, version, generator_version, quote_uuids),
                encoding="utf-8",
            )
        print(f"wrote {destination.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
