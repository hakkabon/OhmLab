#!/usr/bin/env bash
# Validate the committed KiCad IPC action plugin without launching KiCad.
#
# KiCad reads plugin.json before it launches an action, and requires the
# entrypoint to be executable. Keep this check dependency-free so it can run in
# every release gate.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
plugin="$root/integrations/kicad/plugin.json"
launcher="$root/integrations/kicad/ohmlab_sync.py"
example="$root/integrations/kicad/ohmlab.example.json"

test -f "$plugin"
test -x "$launcher"
test -f "$example"

grep -qF '"identifier": "com.ohmlab.kicad-sync"' "$plugin"
grep -qF '"type": "exec"' "$plugin"
grep -qF '"schematic"' "$plugin"
grep -qF '"preview"' "$plugin"
grep -qF -- '--dry-run' "$plugin"
grep -qF 'ohmlab_sync.py' "$plugin"
grep -qF '"kicad"' "$example"
grep -qF '"bundle"' "$example"

printf 'KiCad action plugin is launchable\n'
