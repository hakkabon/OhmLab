# Releasing OhmLab 3.x

Every release candidate must pass `scripts/release-check.sh`. The gate tests the
standard Swift product, exercises application workflows, and validates frozen
and executable numerical contracts.

For OhmLab 1.1 and later, `ohm verify --json` must also report `ready: true`.
This is the deterministic analytical qualification for every linked numerical
backend; `ohm doctor` alone is necessary but no longer sufficient.

For OhmLab 1.2 and later, `ohm qualify-linear --json` must report `ready: true`.
This freezes the scoped `numeric-core` linear graduation evidence.

For OhmLab 1.5 and later, `ohm qualify-nonlinear --json` must report
`ready: true`. The declared scope must include both `shockley-diode` and
`level1-nmos-body-tied`, and every differential case must pass.

For OhmLab 2.0 and later, `ohm qualify-platform --json` must report
`ready: true`, and `ohm platform manifest` must publish portable protocol v1.
This gate covers deterministic native/NumericCore request execution and
fail-closed protocol negotiation. Patch releases must also keep the canonical
portable request/response fixtures byte-stable, validate the malformed-input
corpus, and ship the request JSON Schema in the release archive.

For OhmLab 2.1 and later, `ohm qualify-host --json` must report `ready: true`.
The package manifest must publish the separate `OhmLabSimulationProtocol` and
`OhmLabSimulationHost` products, and the release archive must include the batch
v1 schema and platform-extraction contract.

For OhmLab 2.2 and later, `scripts/qualify-rust-host.sh` must pass. The locked
Cargo graph must build `ohmlab-rust-host`, its native qualification must report
`ready: true`, and its DC/AC/transient/sweep results must agree with
Swift-NumericCore. The
release archive must contain `bin/ohmlab-rust-host`.

For OhmLab 2.4 and later, `ohm qualify-scale --json` must report `ready: true`
and publish `maximumDenseUnknowns: 512`. The native Rust manifest and
qualification must publish and exercise the same limit. Mixed-scale solves,
physical residual certification, singular failure, and pre-solve budget
rejection are release-blocking evidence.

For the 3.4 release, the product version is **3.4.0** everywhere:
`OhmLabRelease.version`, `ohm --version`, the Rust host's `PRODUCT_VERSION`,
`scripts/release-check.sh`, `scripts/health-check.sh`, and the packaged
`Info.plist` must agree. The production boundary remains **v8**; 3.4 adds
analysis-aware optimization metrics and yield-aware design centring, not a new
result, Circuit IR, or portable-protocol contract version.

The 3.4 release gate additionally requires:

- `OptimizeMetric` to parse and round-trip `v(out)`, `ac:v(out)@1k`,
  `acdb:v(out)@1k`, `acph:v(out)@1k`, and `tran:v(out)@1m`;
- AC and transient metrics to read the corresponding solved response, reject
  `vi(...)` probes those result contracts cannot represent, and reject
  coordinates outside the configured sweep;
- the optimiser to reach an AC target and a transient target from a coarse
  grid, with a DC `CircuitProbe` objective producing the same results as before;
- yield estimation to be deterministic for a fixed seed, to count failed or
  unreadable trials as yield loss, and to never return a refined design whose
  yield is lower than the nominal optimum's yield;
- `docs/contracts/design-optimization-yield-v1.md` to describe the metric
  syntax, yield semantics, evidence, and explicit non-claims.

The 3.3 release gate additionally requires:

- diode `CJO`/`VJ`/`M`/`TT`, BJT `VAF`/`VAR`/`CJE`/`CJC`/`TF`/`TR`, MOSFET
  overlap/bulk capacitances, and JFET `CGS`/`CGD` to be parsed, preserved
  through Circuit IR, and exercised in DC, AC, and transient analyses;
- circuits that omit those parameters to produce byte-stable Circuit IR and
  unchanged published results;
- `.nodeset` to parse without a warning, seed the native Newton iteration, and
  never override the solved operating point;
- repeated capacitive solves to be deterministic;
- `docs/contracts/device-model-depth-v1.md` to describe the scope, evidence,
  and explicit non-claims of the new model depth.

The 3.2 release gate also requires:

- sparse matrix assembly and sparse LU to agree with the dense solver on the
  existing DC/AC/transient corpus, including singular-matrix rejection;
- repeated sparse solves to be deterministic;
- the native backend to solve a circuit with more than 512 MNA unknowns,
  proving the dense envelope is no longer an internal limitation;
- schematic and netlist frontends to normalize through Circuit IR v1 before the
  native solve;
- `docs/contracts/sparse-circuit-core-v1.md` to describe the scope, evidence,
  and explicit non-claims of the sparse core.

The 3.1 release gate also requires:

- the committed KiCad fixture corpus under
  `Tests/OhmLabTests/Fixtures/KiCad/RC_Filter` to pass without `kicad-cli`;
- direct `.kicad_sch` reading to preserve hierarchy, UUIDs, references, values,
  and model-library references, and to derive connectivity from KiCad geometry;
- the direct reader's DC result to match the golden `kicad-cli` netlist for the
  fixture;
- project-bundle import from a directly read hierarchy and self-contained
  schematic export to be covered by tests;
- `.kicad_sch` writing to emit a complete project (per-sheet schematics, symbol
  library, model library, `sym-lib-table`, and `.kicad_pro`), preserve
  identities and parameters on round-trip, and produce deterministic bytes;
- the writer's diode and source pin conventions to be validated against a local
  `kicad-cli` when it is available, without making CI depend on it;
- `docs/compatibility/kicad.md` to describe the tiered claim that CI actually
  proves;
- an iOS/iPadOS Simulator build job in CI so the declared platform target is
  built, not just documented.

`scripts/package-release.sh [output-directory]` creates a host-architecture
macOS archive containing `OhmLab.app`, the `ohm` CLI, licence, README, contract
documents, release metadata, and a SHA-256 checksum. Without credentials it
uses an ad-hoc signature suitable for CI validation, not public distribution.

For a public build, set `OHMLAB_CODESIGN_IDENTITY` to a Developer ID
Application identity. If `OHMLAB_NOTARY_PROFILE` names a configured
`notarytool` keychain profile, the script submits the archive, waits for Apple,
staples the app, rebuilds the archive, and creates its final checksum.
Credentials belong in the release environment or CI secret store and must
never be committed.

The archive is architecture-specific. Build and test every intended
architecture separately until the project adopts a universal-binary build.

Compatibility rules for the 3.x line:

- The current product version is **3.4.0**. Keep the version string in
  `OhmLabRelease.version` and the release/health scripts in lockstep; the tag,
  CLI output, and packaged metadata must match.
- 3.4 does not introduce a new production boundary. Production boundary v8
  remains current until a later contract explicitly changes the numerical or
  portable execution guarantees. Analysis-aware optimization metrics and yield
  centring are additive front-end behaviour inside that boundary.
- 3.3 does not introduce a new production boundary. Production boundary v8
  remains current until a later contract explicitly changes the numerical or
  portable execution guarantees. Optional device parameters, device
  capacitances, and `.nodeset` are additive changes inside that boundary.
- Do not change production-boundary, Circuit IR, result, capability, or
  nonlinear-convergence, or portable-simulation versions in a patch release.
- Production boundary v4 is required for 2.0 because the portable process
  contract is a new public compatibility boundary.
- Production boundary v5 is required for 2.1 because execution policy and
  batching are a separately versioned public host boundary.
- Production boundary v6 is required for 2.2 because the process-native Rust
  host is a new independently built deployment boundary.
- Production boundary v7 is required for 2.3 because NumericCore transient and
  DC-sweep execution complete the portable analysis surface.
- Production boundary v8 is required for 2.4 because solver scaling, physical
  residual certification, and the dense-solver resource envelope are public
  execution guarantees.
- Do not change document or project schemas without an immutable legacy
  fixture and an explicit migration.
- Never weaken `ohm doctor`, `ohm verify`, `ohm qualify-linear`,
  `ohm qualify-nonlinear`, `ohm qualify-scale`, or `ohm qualify-platform`;
  `ready: false` blocks a release.
- Keep `native-mna` the default and sole full-production backend.
- Keep `numeric-core` as the sole linear/nonlinear-production backend until a
  later contract explicitly graduates another implementation.
