#!/usr/bin/env python3
"""OhmLab sync bridge for the KiCad IPC action plugin system.

KiCad launches this file as an ``exec`` runtime action. It reads a small JSON
configuration file, runs ``ohm kicad sync`` on the configured KiCad project and
OhmLab bundle, and relays stdout/stderr back to KiCad. It does not use the
KiCad IPC socket: the companion operates on files on disk, so save your work in
KiCad before running an action.

The plugin ships with ``ohmlab.example.json``. Copy it to ``ohmlab.json`` beside
this script and set ``kicad`` and ``bundle``.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

CONFIG_NAME = "ohmlab.json"
EXAMPLE_NAME = "ohmlab.example.json"
CONFIG_KEYS = {"kicad", "bundle", "direction", "prefer", "force", "ohm"}
DIRECTIONS = {"import", "export", "auto"}
PREFERENCES = {"kicad", "ohmlab"}


def message(text: str, *, error: bool = False) -> None:
    print(f"ohm-kicad: {text}", file=sys.stderr if error else sys.stdout, flush=True)


def fail(text: str, code: int = 64) -> int:
    message(text, error=True)
    return code


def resolve(base: Path, value: str) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = base / path
    return path.resolve()


def load_config(path: Path) -> dict:
    if not path.is_file():
        raise ValueError(
            f"configuration not found at {path}; copy {EXAMPLE_NAME} to {CONFIG_NAME} "
            "beside the plugin and set \"kicad\" and \"bundle\""
        )
    try:
        with path.open("r", encoding="utf-8") as handle:
            config = json.load(handle)
    except OSError as error:
        raise ValueError(f"could not read {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise ValueError(f"{path} is not valid JSON: {error}") from error
    if not isinstance(config, dict):
        raise ValueError(f"{path} must contain a JSON object")
    unknown = sorted(set(config) - CONFIG_KEYS)
    if unknown:
        raise ValueError(f"{path} has unknown keys: {', '.join(unknown)}")
    return config


def find_ohm(config: dict, base: Path) -> Path:
    configured = config.get("ohm") or os.environ.get("OHMLAB_BIN")
    if configured:
        configured = str(configured)
        looks_like_path = os.path.isabs(configured) or "/" in configured or "\\" in configured
        if looks_like_path:
            candidate = resolve(base, configured)
            if not candidate.is_file() or not os.access(candidate, os.X_OK):
                raise ValueError(f"ohm executable not found or not executable at {candidate}")
            return candidate
        found = shutil.which(configured)
        if found is not None:
            return Path(found)
        raise ValueError(
            f"could not find {configured!r} on PATH; set \"ohm\" in {CONFIG_NAME} "
            "to an absolute path (or set OHMLAB_BIN)"
        )
    found = shutil.which("ohm")
    if found is None:
        raise ValueError(
            "could not find the ohm executable on PATH; set \"ohm\" in "
            f"{CONFIG_NAME} to an absolute path (or set OHMLAB_BIN)"
        )
    return Path(found)


def build_command(config: dict, base: Path, *, dry_run: bool, json_output: bool) -> list[str]:
    kicad = config.get("kicad")
    bundle = config.get("bundle")
    if not isinstance(kicad, str) or not kicad.strip():
        raise ValueError("\"kicad\" must be a non-empty path to a .kicad_pro or project directory")
    if not isinstance(bundle, str) or not bundle.strip():
        raise ValueError("\"bundle\" must be a non-empty path to an .ohmlabproj bundle")

    kicad_path = resolve(base, kicad)
    bundle_path = resolve(base, bundle)
    if not kicad_path.exists():
        raise ValueError(f"KiCad project not found at {kicad_path}")

    direction = config.get("direction", "auto")
    if direction is None:
        direction = "auto"
    if direction not in DIRECTIONS:
        raise ValueError(f"\"direction\" must be one of {', '.join(sorted(DIRECTIONS))}")

    prefer = config.get("prefer")
    if prefer is not None and prefer not in PREFERENCES:
        raise ValueError(f"\"prefer\" must be null, kicad, or ohmlab")

    force = config.get("force", False)
    if not isinstance(force, bool):
        raise ValueError("\"force\" must be true or false")

    command = [
        str(find_ohm(config, base)),
        "kicad",
        "sync",
        str(kicad_path),
        str(bundle_path),
        "--direction",
        direction,
    ]
    if prefer is not None:
        command.extend(["--prefer", prefer])
    if force:
        command.append("--force")
    if dry_run:
        command.append("--dry-run")
    if json_output:
        command.append("--json")
    return command


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Run ohm kicad sync for the configured KiCad project and OhmLab bundle."
    )
    parser.add_argument(
        "--config",
        default=str(Path(__file__).with_name(CONFIG_NAME)),
        help=f"path to the plugin configuration (default: {CONFIG_NAME} beside this script)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="preview the companion plan without writing either side",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="ask ohm for machine-readable JSON output",
    )
    args = parser.parse_args(argv)

    config_path = Path(args.config).expanduser()
    if not config_path.is_absolute():
        config_path = Path.cwd() / config_path
    config_path = config_path.resolve()

    try:
        config = load_config(config_path)
        command = build_command(
            config,
            config_path.parent,
            dry_run=args.dry_run,
            json_output=args.json,
        )
    except ValueError as error:
        return fail(str(error))

    mode = "preview" if args.dry_run else "sync"

    def status(text: str) -> None:
        # Keep stdout clean for --json so KiCad or a script can parse it.
        print(f"ohm-kicad: {text}", file=sys.stderr if args.json else sys.stdout, flush=True)

    status(f"OhmLab {mode}: {command[3]} <-> {command[4]}")
    try:
        completed = subprocess.run(command, capture_output=True, text=True)
    except OSError as error:
        return fail(f"could not run {command[0]}: {error}")

    if completed.stdout.strip():
        print(completed.stdout.rstrip(), flush=True)
    if completed.stderr.strip():
        print(completed.stderr.rstrip(), file=sys.stderr, flush=True)

    if completed.returncode == 0:
        status("OhmLab sync complete." if not args.dry_run else "OhmLab preview complete.")
    elif completed.returncode == 2:
        status(
            "OhmLab did not apply the plan: there are conflicts, a base is "
            "missing, or the plan is not applicable. Resolve with --prefer "
            "kicad|ohmlab or --force."
        )
    else:
        status(f"ohm exited with status {completed.returncode}.")
    return completed.returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
