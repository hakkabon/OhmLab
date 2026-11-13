# OhmLab KiCad action plugin

This directory is a KiCad IPC action plugin that runs `ohm kicad sync` from the
KiCad Schematic Editor or Project Manager. It uses KiCad's `exec` plugin
runtime, so it does not need a Python virtual environment and works with the
`ohm` executable you already use. The macOS release archive also includes this
directory under `integrations/kicad/`.

The plugin has two actions:

| Action | Command |
| --- | --- |
| **OhmLab: Sync** | `ohm kicad sync <kicad> <bundle> --direction <direction>` |
| **OhmLab: Preview Sync** | the same command with `--dry-run` |

Both actions use the companion's three-way merge. Preview writes nothing and is
the safe way to inspect changes before applying them.

## Requirements

- **KiCad 11 or newer.** KiCad 9 and 10 support IPC API plugins only in the PCB
  Editor; Schematic Editor and Project Manager actions were added in KiCad 11.
  The actions will not appear in KiCad 9 or 10.
- **OhmLab 4.2 or newer** on `PATH`, or an absolute path configured below.
- A KiCad project (`.kicad_pro` or its directory) and an OhmLab bundle
  (`.ohmlabproj`). The bundle does not have to exist yet: with no bundle, the
  companion imports the KiCad project and creates it.

## Install

1. Copy this whole directory to KiCad's plugin directory:

   - macOS: `~/Documents/KiCad/<version>/plugins/ohmlab-kicad-sync/`
   - Linux: `~/.local/share/KiCad/<version>/plugins/ohmlab-kicad-sync/`
   - Windows: `%USERPROFILE%\Documents\KiCad\<version>\plugins\ohmlab-kicad-sync\`

   `<version>` is the KiCad version directory, for example `11.0`.

2. Copy `ohmlab.example.json` to `ohmlab.json` in the same directory and edit
   the paths:

   ```json
   {
     "kicad": "/Users/me/projects/filter/filter.kicad_pro",
     "bundle": "/Users/me/projects/filter/filter.ohmlabproj",
     "direction": "auto",
     "prefer": null,
     "force": false,
     "ohm": "/usr/local/bin/ohm"
   }
   ```

   Relative paths in `kicad`, `bundle`, and `ohm` are resolved against the
   directory containing `ohmlab.json`. Set `"ohm"` to an absolute path when
   KiCad's GUI environment does not inherit your shell `PATH`.

3. Restart KiCad (or reload plugins) and open the Schematic Editor. The two
   OhmLab actions appear on the toolbar.

On Windows, change the `entrypoint` fields in `plugin.json` from
`ohmlab_sync.py` to `ohmlab_sync.cmd`, because KiCad launches the entrypoint as
an executable.

## Configuration

| Key | Required | Meaning |
| --- | --- | --- |
| `kicad` | yes | `.kicad_pro` file or project directory to sync. |
| `bundle` | yes | `.ohmlabproj` bundle path. Created on first import if absent. |
| `direction` | no | `auto` (default), `import`, or `export`. |
| `prefer` | no | `null` (default), `kicad`, or `ohmlab`; resolves a same-field collision wholesale. |
| `force` | no | `true` overwrites the other side without a merge. Defaults to `false`. |
| `ohm` | no | `ohm` command name searched on `PATH`, or a path resolved against this file; `OHMLAB_BIN` is also honoured. |

Unknown keys are rejected so a typo does not silently fall back to a default.

## Usage

1. Save your work in KiCad. The plugin runs on the files on disk; unsaved
   editor state is not visible to it.
2. Run **OhmLab: Preview Sync** to see additions, edits, removals, their source
   side, and any conflicts. Preview exits without writing.
3. Run **OhmLab: Sync** to apply the plan. If both sides changed the same field,
   the action fails closed and prints the collision. Resolve it with
   `prefer` in `ohmlab.json`, or run `ohm kicad sync` manually with
   `--prefer kicad|ohmlab` and then sync again.
4. If KiCad reports that the schematic changed on disk, reload it.

The plugin relays `ohm` stdout and stderr to KiCad. On KiCad 10.0.1 and newer,
action output appears in the editor's warning messages; plugin launch failures
are also visible in KiCad's trace log.

## Manual check

The plugin is a wrapper, so it can be tested without KiCad:

```sh
integrations/kicad/ohmlab_sync.py --config /path/to/ohmlab.json --dry-run
```

A successful preview exits `0`. A plan with conflicts or a missing base exits
`2`, matching `ohm kicad sync --dry-run`.

## Limitations

- The plugin is an action bridge, not an IPC API client. It does not read
  unsaved editor state, and it does not tell KiCad to reload a file after a
  write.
- It does not draw a settings dialog. Edit `ohmlab.json` instead.
- One `ohmlab.json` targets one project. For multiple projects, install a
  separate copy of the plugin per project, or edit the configuration between
  runs.
- The companion itself merges only OhmLab-modelled symbols and sheet structure.
  KiCad-only wires, junctions, graphics, and unsupported symbols remain in the
  drawing and are preserved by write fidelity, but they are not part of the
  three-way decision. See
  [`docs/contracts/kicad-companion-v2.md`](../../docs/contracts/kicad-companion-v2.md).
