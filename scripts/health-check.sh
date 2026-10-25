#!/usr/bin/env bash
#
# health-check.sh — one command for the health status of the OhmLab codebase.
#
# Builds the Swift package, runs the unit + example-circuit test suites, then
# smoke-tests the `ohm` CLI against the shipped examples: every circuit, the analyses (Monte Carlo,
# corners, optimisation), the project bundle, and the sync engine.
#
# Exits non-zero if any step fails, so it is safe to wire into CI.

set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" || exit 1

pass=0
fail=0
log="$(mktemp)"
work="$(mktemp -d)"
trap 'rm -rf "$log" "$work"' EXIT

section() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
ok()      { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass + 1)); }
bad()     { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }

# run <label> <command...>  — pass when the command exits 0.
run() {
    local label="$1"; shift
    if "$@" >"$log" 2>&1; then
        ok "$label"
    else
        bad "$label"
        sed 's/^/        /' "$log" | tail -n 20
    fi
}

section "Build"
run "swift build" swift build

section "Tests"
run "swift test (units + example circuits)" swift test

ohm=".build/debug/ohm"
bundle="Examples/07-project-bundle.ohmlabproj"

section "Convergence contract"
run "engine capability matrix" "$ohm" engines --json

section "Production boundary"
run "OhmLab 2.2.0 version" bash -c 'test "$(.build/debug/ohm --version)" = "ohm 2.2.0"'
run "production readiness" "$ohm" doctor --json

section "Numerical trust"
run "analytical backend qualification" "$ohm" verify --json

section "Linear backend graduation"
run "linear-production qualification" "$ohm" qualify-linear --json

section "Nonlinear convergence"
run "nonlinear-production qualification" "$ohm" qualify-nonlinear --json

section "Portable simulation platform"
run "portable host manifest" "$ohm" platform manifest
run "portable request execution" bash -c '.build/debug/ohm platform run < Examples/portable-divider-request.json'
run "portable batch execution" bash -c '.build/debug/ohm platform batch --max-parallel 2 < Examples/portable-divider-batch.json'
run "portable protocol qualification" "$ohm" qualify-platform --json
run "extracted host qualification" "$ohm" qualify-host --json
run "native Rust host qualification" ./scripts/qualify-rust-host.sh

section "Example circuits — CLI runs"
for file in Examples/*.cir; do
    run "ohm $(basename "$file")" "$ohm" "$file" -f json
done

section "Project bundle"
run "project info"   "$ohm" project info "$bundle"
run "project pack"   "$ohm" project pack "$bundle" -o "$work/divider.ohmlabzip"
run "project unpack" "$ohm" project unpack "$work/divider.ohmlabzip" "$work/unpacked"

section "Analyses (on the bundle)"
run "monte-carlo" "$ohm" monte-carlo "$bundle" --probe 'v(2)' --samples 100 --seed 1 --default-tol 5% -f json
run "corner"      "$ohm" corner "$bundle" --probe 'v(2)' --default-tol 5% -f json
run "optimize"    "$ohm" optimize "$bundle" --var R2=500:2k --probe 'v(2)' --goal target=1.5 -f json

section "Interchange"
run "kicad export" "$ohm" kicad export "$bundle" "$work/kicad-export"

section "Sync"
mkdir -p "$work/local"
cp -R "$bundle" "$work/local/"
run "sync (first run)"     "$ohm" sync "$work/local" "$work/remote"
run "sync (idempotent)"    "$ohm" sync "$work/local" "$work/remote"

section "Result"
printf '  passed: %d   failed: %d\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
    printf '\n\033[31mHealth check FAILED\033[0m\n'
    exit 1
fi
printf '\n\033[32mHealth check passed\033[0m\n'
