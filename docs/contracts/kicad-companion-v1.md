# OhmLab KiCad companion v1

The KiCad companion contract v1, introduced in OhmLab 4.0, defines the
capability manifest, content digests, state sidecar, and sync semantics used to
keep a KiCad project hierarchy and an OhmLab `.ohmlabproj` bundle aligned. It is
part of production boundary v9. It does not change Circuit IR, the electrical
result contract, or the KiCad writer/reader formats.

## Capability manifest

`ohm kicad companion --json` publishes `KiCadCompanionManifest`:

| Field | Value |
| --- | --- |
| `contractVersion` | `1` |
| `productVersion` | `OhmLabRelease.version` |
| `productionBoundary` | `9` |
| `projectExtensions` | `["kicad_pro"]` |
| `schematicExtensions` | `["kicad_sch"]` |
| `digestExtensions` | `["kicad_pro", "kicad_sch", "kicad_sym", "kicad_mod", "lib"]` |
| `directions` | `["import", "export", "auto"]` |
| `preferences` | `["kicad", "ohmlab"]` |
| `stateFileName` | `.ohmlab-companion.json` |
| `capabilities` | native read/write, bidirectional sync, conflict detection |

## Digests

Both digests are SHA-256 over deterministic, ordered content. They never depend
on dictionary iteration order or absolute paths.

**KiCad digest.** Every regular file whose extension is in `digestExtensions`,
under the project directory, sorted by relative path. The digest input is
`relativePath`, NUL, byte count, NUL, bytes, NUL for each file. Non-project
files (README, `.cir`, `.txt`, hidden files) do not participate. A directory
argument is resolved to its `.kicad_pro` (or root `.kicad_sch`) for import, but
the digest always covers the whole directory.

**Bundle digest.** The manifest name, then for each sheet sorted by id: sheet
id, sheet name, canonical analysis JSON, and canonical netlist. Schematic
documents use the deterministic `SpiceNetlistBuilder.export` projection;
netlist documents use their stored netlist text. Volatile import metadata
(`importedAt`, `resolvedNetlistText`, and `importBaseDirectory`) is excluded,
as are the state sidecar and other bundle files.

## State sidecar

A successful sync writes `.ohmlab-companion.json` inside the bundle:

```json
{
  "contractVersion": 1,
  "kicadDigest": "…",
  "bundleDigest": "…",
  "syncedAt": "2026-11-11T00:00:00Z",
  "direction": "import"
}
```

The sidecar records the digests observed immediately after the sync. It is not
part of the bundle digest and is ignored by bundle reads. A sidecar with a
newer contract version or invalid JSON fails closed with
`KiCadCompanionError.invalidState`.

## Sync semantics

`ohm kicad status <kicad> <bundle>` compares both sides and recommends
`import`, `export`, `conflict`, or `up-to-date`. With no state it recommends
`unknown`.

`ohm kicad sync <kicad> <bundle> [--direction import|export|auto]
[--prefer kicad|ohmlab] [--force]`:

- `auto` with no state and no bundle imports from KiCad.
- `auto` with no state and an existing bundle fails closed with
  `directionRequired`; pass an explicit direction.
- `auto` with state imports when only KiCad changed, exports when only the
  bundle changed, and reports `none` when both match.
- Both changed is a conflict. `auto` requires `--prefer kicad` (import) or
  `--prefer ohmlab` (export).
- An explicit direction performs that operation. If a baseline exists and the
  target changed since the last sync, it fails closed unless the matching
  `--prefer` agrees or `--force` is given.
- Import preserves the existing bundle's saved analysis settings and
  non-volatile metadata where possible.
- Export requires a schematic-backed document and uses the original KiCad
  project stem recorded in `kicadSource`, or the bundle name when no source is
  recorded.

A successful operation recomputes both digests and writes the sidecar. No-op
syncs do not rewrite the sidecar, so repeated runs are byte-idempotent.

## CLI

```sh
ohm kicad companion [--json]
ohm kicad status <kicadPath> <bundle> [--json]
ohm kicad sync <kicadPath> <bundle> [--direction import|export|auto] [--prefer kicad|ohmlab] [--force] [--json]
```

`<kicadPath>` may be a `.kicad_pro`, a top or child `.kicad_sch`, or the project
directory.

## Evidence

`Tests/OhmLabTests/KiCadCompanionTests.swift` covers the manifest, deterministic
and content-sensitive digests, volatile-metadata exclusion, fresh-bundle
import, idempotent sync, KiCad-only import, bundle-only export, conflict
refusal and preference resolution, the no-state direction rule, schematic-
backed export, corrupt-state rejection, and JSON round-trips. The committed
`RC_Filter` fixture supplies a real KiCad hierarchy without requiring KiCad in
CI.

## Non-claims

- The companion synchronises the OhmLab-modelled subset described in
  [`docs/compatibility/kicad.md`](../compatibility/kicad.md); it is not a
  lossless mirror of arbitrary KiCad projects.
- It does not watch the filesystem, run as a daemon, or resolve edit conflicts
  automatically. Conflicts always require an explicit preference or force.
- Digests detect change, not authorship; a changed digest cannot say who made
  the change or merge two edits.
- Export replaces the named project files in the target directory. Unrelated
  files in that directory are left alone but still participate in the digest.
