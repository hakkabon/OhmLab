#!/usr/bin/env bash
# Reproducible release gate for the OhmLab 1.0 production boundary.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

./scripts/health-check.sh

version="$(.build/debug/ohm --version)"
if [[ "$version" != "ohm 1.0.0" ]]; then
    printf 'release version mismatch: %s\n' "$version" >&2
    exit 1
fi

report="$(mktemp)"
artifacts="$(mktemp -d)"
trap 'rm -f "$report"; rm -rf "$artifacts"' EXIT
.build/debug/ohm doctor --json >"$report"
if ! rg -q '"ready"[[:space:]]*:[[:space:]]*true' "$report"; then
    printf 'production readiness report is not ready\n' >&2
    cat "$report" >&2
    exit 1
fi

./scripts/package-release.sh "$artifacts"
(cd "$artifacts" && shasum -a 256 -c ./*.sha256)

if command -v cargo >/dev/null 2>&1; then
    cargo fmt --manifest-path rust/ohm-core/Cargo.toml -- --check
    cargo clippy --manifest-path rust/ohm-core/Cargo.toml --all-targets -- -D warnings
    ./scripts/build-rust-core.sh
    OHMLAB_RUST_CORE=1 swift test
fi

printf 'OhmLab %s release gate passed\n' "${version#ohm }"
