# Releasing OhmLab 2.x

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
fail-closed protocol negotiation.

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

Compatibility rules for the 2.x line:

- Do not change production-boundary, Circuit IR, result, capability, or
  nonlinear-convergence, or portable-simulation versions in a patch release.
- Production boundary v4 is required for 2.0 because the portable process
  contract is a new public compatibility boundary.
- Do not change document or project schemas without an immutable legacy
  fixture and an explicit migration.
- Never weaken `ohm doctor`, `ohm verify`, `ohm qualify-linear`,
  `ohm qualify-nonlinear`, or `ohm qualify-platform`; `ready: false` blocks a
  release.
- Keep `native-mna` the default and sole full-production backend.
- Keep `numeric-core` as the sole linear/nonlinear-production backend until a
  later contract explicitly graduates another implementation.
