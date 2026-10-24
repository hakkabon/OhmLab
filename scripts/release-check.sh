#!/usr/bin/env bash
# Reproducible release gate for the stable production and numerical contracts.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

./scripts/health-check.sh

version="$(.build/debug/ohm --version)"
if [[ "$version" != "ohm 1.2.0" ]]; then
    printf 'release version mismatch: %s\n' "$version" >&2
    exit 1
fi

trust_report="$(mktemp)"
graduation_report="$(mktemp)"
report="$(mktemp)"
artifacts="$(mktemp -d)"
trap 'rm -f "$report" "$trust_report" "$graduation_report"; rm -rf "$artifacts"' EXIT
.build/debug/ohm verify --json >"$trust_report"
if ! rg -q '"ready"[[:space:]]*:[[:space:]]*true' "$trust_report"; then
    printf 'numerical trust report is not ready\n' >&2
    cat "$trust_report" >&2
    exit 1
fi

.build/debug/ohm qualify-linear --json >"$graduation_report"
if ! rg -q '"ready"[[:space:]]*:[[:space:]]*true' "$graduation_report" \
    || ! rg -q '"maturity"[[:space:]]*:[[:space:]]*"linear-production"' "$graduation_report"; then
    printf 'linear backend graduation report is not ready\n' >&2
    cat "$graduation_report" >&2
    exit 1
fi

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
    .build/debug/ohm verify --json >"$trust_report"
    if ! rg -q '"ready"[[:space:]]*:[[:space:]]*true' "$trust_report" \
        || ! rg -q '"identifier"[[:space:]]*:[[:space:]]*"ohm-core"' "$trust_report"; then
        printf 'Rust-linked numerical trust report is incomplete or not ready\n' >&2
        cat "$trust_report" >&2
        exit 1
    fi
    .build/debug/ohm doctor --json >"$report"
    if ! rg -q '"identifier"[[:space:]]*:[[:space:]]*"ohm-core"' "$report" \
        || ! rg -q '"removalVersion"[[:space:]]*:[[:space:]]*"1.3.0"' "$report"; then
        printf 'standalone Rust compatibility deprecation is missing\n' >&2
        cat "$report" >&2
        exit 1
    fi
fi

printf 'OhmLab %s release gate passed\n' "${version#ohm }"
