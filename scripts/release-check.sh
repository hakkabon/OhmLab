#!/usr/bin/env bash
# Reproducible release gate for the stable production and numerical contracts.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

./scripts/health-check.sh

version="$(.build/debug/ohm --version)"
if [[ "$version" != "ohm 4.1.0" ]]; then
    printf 'release version mismatch: %s\n' "$version" >&2
    exit 1
fi

trust_report="$(mktemp)"
graduation_report="$(mktemp)"
nonlinear_report="$(mktemp)"
scale_report="$(mktemp)"
platform_report="$(mktemp)"
host_report="$(mktemp)"
companion_report="$(mktemp)"
thermal_report="$(mktemp)"
thermal_netlist="$(mktemp)"
report="$(mktemp)"
artifacts="$(mktemp -d)"
trap 'rm -f "$report" "$trust_report" "$graduation_report" "$nonlinear_report" "$scale_report" "$platform_report" "$host_report" "$companion_report" "$thermal_report" "$thermal_netlist"; rm -rf "$artifacts"' EXIT
.build/debug/ohm verify --json >"$trust_report"
if ! grep -Eq '"ready"[[:space:]]*:[[:space:]]*true' "$trust_report"; then
    printf 'numerical trust report is not ready\n' >&2
    cat "$trust_report" >&2
    exit 1
fi

.build/debug/ohm qualify-platform --json >"$platform_report"
if ! grep -Eq '"ready"[[:space:]]*:[[:space:]]*true' "$platform_report" \
    || ! grep -Eq '"protocolVersion"[[:space:]]*:[[:space:]]*1' "$platform_report"; then
    printf 'portable platform qualification is not ready\n' >&2
    cat "$platform_report" >&2
    exit 1
fi

.build/debug/ohm qualify-host --json >"$host_report"
if ! grep -Eq '"ready"[[:space:]]*:[[:space:]]*true' "$host_report"; then
    printf 'extracted simulation host is not ready\n' >&2
    cat "$host_report" >&2
    exit 1
fi

./scripts/qualify-rust-host.sh

.build/debug/ohm qualify-linear --json >"$graduation_report"
if ! grep -Eq '"ready"[[:space:]]*:[[:space:]]*true' "$graduation_report" \
    || ! grep -Eq '"maturity"[[:space:]]*:[[:space:]]*"nonlinear-production"' "$graduation_report"; then
    printf 'linear backend graduation report is not ready\n' >&2
    cat "$graduation_report" >&2
    exit 1
fi

.build/debug/ohm qualify-nonlinear --json >"$nonlinear_report"
if ! grep -Eq '"ready"[[:space:]]*:[[:space:]]*true' "$nonlinear_report" \
    || ! grep -Eq '"level1-nmos-body-tied"' "$nonlinear_report" \
    || ! grep -Eq '"shockley-diode"' "$nonlinear_report"; then
    printf 'nonlinear convergence report is not ready\n' >&2
    cat "$nonlinear_report" >&2
    exit 1
fi

.build/debug/ohm qualify-scale --json >"$scale_report"
if ! grep -Eq '"ready"[[:space:]]*:[[:space:]]*true' "$scale_report" \
    || ! grep -Eq '"maximumDenseUnknowns"[[:space:]]*:[[:space:]]*512' "$scale_report"; then
    printf 'scale and numerical robustness report is not ready\n' >&2
    cat "$scale_report" >&2
    exit 1
fi

.build/debug/ohm doctor --json >"$report"
if ! grep -Eq '"ready"[[:space:]]*:[[:space:]]*true' "$report" \
    || ! grep -Eq '"productionBoundary"[[:space:]]*:[[:space:]]*10' "$report" \
    || ! grep -Eq '"thermalAnalysis"[[:space:]]*:[[:space:]]*1' "$report" \
    || ! grep -Eq '"kicadCompanion"[[:space:]]*:[[:space:]]*1' "$report" \
    || ! grep -Eq '"kicadWriteFidelity"[[:space:]]*:[[:space:]]*1' "$report"; then
    printf 'production readiness report is not ready\n' >&2
    cat "$report" >&2
    exit 1
fi

.build/debug/ohm kicad companion --json >"$companion_report"
if ! grep -Eq '"contractVersion"[[:space:]]*:[[:space:]]*1' "$companion_report" \
    || ! grep -Eq '"productionBoundary"[[:space:]]*:[[:space:]]*10' "$companion_report" \
    || ! grep -Eq '"bidirectionalSync"[[:space:]]*:[[:space:]]*true' "$companion_report"; then
    printf 'KiCad companion manifest is not ready\n' >&2
    cat "$companion_report" >&2
    exit 1
fi

printf 'V1 in 0 DC 10\nR1 in out 1k\nR2 out 0 1k\n' >"$thermal_netlist"
.build/debug/ohm thermal "$thermal_netlist" --rja R1=100 --rja R2=50 -f json >"$thermal_report"
if ! grep -Eq '"converged"[[:space:]]*:[[:space:]]*true' "$thermal_report" \
    || ! grep -Eq '"contractVersion"[[:space:]]*:[[:space:]]*1' "$thermal_report"; then
    printf 'thermal analysis contract is not ready\n' >&2
    cat "$thermal_report" >&2
    exit 1
fi

./scripts/package-release.sh "$artifacts"
(cd "$artifacts" && shasum -a 256 -c ./*.sha256)

printf 'OhmLab %s release gate passed\n' "${version#ohm }"
