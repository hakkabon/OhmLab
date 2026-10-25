#!/usr/bin/env bash
# Reproducible release gate for the stable production and numerical contracts.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

./scripts/health-check.sh

version="$(.build/debug/ohm --version)"
if [[ "$version" != "ohm 2.1.0" ]]; then
    printf 'release version mismatch: %s\n' "$version" >&2
    exit 1
fi

trust_report="$(mktemp)"
graduation_report="$(mktemp)"
nonlinear_report="$(mktemp)"
platform_report="$(mktemp)"
host_report="$(mktemp)"
report="$(mktemp)"
artifacts="$(mktemp -d)"
trap 'rm -f "$report" "$trust_report" "$graduation_report" "$nonlinear_report" "$platform_report" "$host_report"; rm -rf "$artifacts"' EXIT
.build/debug/ohm verify --json >"$trust_report"
if ! rg -q '"ready"[[:space:]]*:[[:space:]]*true' "$trust_report"; then
    printf 'numerical trust report is not ready\n' >&2
    cat "$trust_report" >&2
    exit 1
fi

.build/debug/ohm qualify-platform --json >"$platform_report"
if ! rg -q '"ready"[[:space:]]*:[[:space:]]*true' "$platform_report" \
    || ! rg -q '"protocolVersion"[[:space:]]*:[[:space:]]*1' "$platform_report"; then
    printf 'portable platform qualification is not ready\n' >&2
    cat "$platform_report" >&2
    exit 1
fi

.build/debug/ohm qualify-host --json >"$host_report"
if ! rg -q '"ready"[[:space:]]*:[[:space:]]*true' "$host_report"; then
    printf 'extracted simulation host is not ready\n' >&2
    cat "$host_report" >&2
    exit 1
fi

.build/debug/ohm qualify-linear --json >"$graduation_report"
if ! rg -q '"ready"[[:space:]]*:[[:space:]]*true' "$graduation_report" \
    || ! rg -q '"maturity"[[:space:]]*:[[:space:]]*"nonlinear-production"' "$graduation_report"; then
    printf 'linear backend graduation report is not ready\n' >&2
    cat "$graduation_report" >&2
    exit 1
fi

.build/debug/ohm qualify-nonlinear --json >"$nonlinear_report"
if ! rg -q '"ready"[[:space:]]*:[[:space:]]*true' "$nonlinear_report" \
    || ! rg -q '"level1-nmos-body-tied"' "$nonlinear_report" \
    || ! rg -q '"shockley-diode"' "$nonlinear_report"; then
    printf 'nonlinear convergence report is not ready\n' >&2
    cat "$nonlinear_report" >&2
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

printf 'OhmLab %s release gate passed\n' "${version#ohm }"
