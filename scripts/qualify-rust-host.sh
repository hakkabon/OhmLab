#!/usr/bin/env bash
# Build and differentially qualify the native Rust-NumericCore host.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

manifest="rust/ohmlab-rust-host/Cargo.toml"
cargo build --locked --manifest-path "$manifest"
rust_host="rust/ohmlab-rust-host/target/debug/ohmlab-rust-host"
swift_host=".build/debug/ohm"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

"$rust_host" manifest >"$work/manifest.json"
jq -e '.nativeRust == true and .protocolVersion == 1 and .rustNumericCoreVersion == "0.34.0"' \
    "$work/manifest.json" >/dev/null

"$rust_host" qualify >"$work/qualification.json"
jq -e '.ready == true and (.cases | length) >= 6 and
    ([.cases[].identifier] | index("shockley-diode") != null) and
    ([.cases[].identifier] | index("level1-nmos-body-tied") != null)' \
    "$work/qualification.json" >/dev/null

jq '.backend = "numeric-core"' Examples/portable-divider-request.json \
    | "$swift_host" platform run >"$work/swift.json"
jq '.backend = "rust-numeric-core"' Examples/portable-divider-request.json \
    | "$rust_host" run >"$work/rust.json"

jq -s -e '
  .[0].status == "success" and .[1].status == "success" and
  (([.[0].result.dc.nodes[], .[1].result.dc.nodes[]]
    | map(select(.name == "out") | .value) | .[0] - .[1]) | fabs) <= 1e-12
' "$work/swift.json" "$work/rust.json" >/dev/null

jq '.backend = "numeric-core" |
    .analysis.ac = {"type":"lin","startFrequency":1000,"stopFrequency":1001,"points":2}' \
    Examples/portable-divider-request.json | "$swift_host" platform run >"$work/swift-ac.json"
jq '.backend = "rust-numeric-core" |
    .analysis.ac = {"type":"lin","startFrequency":1000,"stopFrequency":1001,"points":2}' \
    Examples/portable-divider-request.json | "$rust_host" run >"$work/rust-ac.json"

jq -s -e '
  (([.[0].result.ac.nodes[], .[1].result.ac.nodes[]]
    | map(select(.name == "out") | .values[0].magnitudeDB) | .[0] - .[1]) | fabs) <= 1e-10
' "$work/swift-ac.json" "$work/rust-ac.json" >/dev/null

printf 'OhmLab native Rust host qualification passed\n'
