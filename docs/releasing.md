# Releasing OhmLab 1.x

Every release candidate must pass `scripts/release-check.sh`. The gate tests the
standard Swift product, exercises application workflows, validates frozen
contracts, checks Rust with rustfmt and Clippy, and runs Swift again with the
Rust transport linked.

For OhmLab 1.1 and later, `ohm verify --json` must also report `ready: true`.
This is the deterministic analytical qualification for every linked numerical
backend; `ohm doctor` alone is necessary but no longer sufficient.

For OhmLab 1.2 and later, `ohm qualify-linear --json` must report `ready: true`.
This freezes the scoped `numeric-core` graduation evidence. Rust-linked builds
must additionally expose standalone `ohm-core` as deprecated with removal
version 1.3.0 throughout the one-release compatibility window.

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

Compatibility rules for the 1.x line:

- Do not change production-boundary, Circuit IR, result, capability, or Rust
  transport versions in a patch release.
- Production boundary v2 is required for 1.2 because the new maturity and
  lifecycle values are semantic additions; the other wire contracts remain v1.
- Do not change document or project schemas without an immutable legacy
  fixture and an explicit migration.
- Never weaken `ohm doctor` or `ohm verify`; `ready: false` blocks a release.
- Keep `native-mna` the default and sole full-production backend.
- Keep `numeric-core` as the sole linear-production backend until a later
  contract explicitly graduates another implementation.
