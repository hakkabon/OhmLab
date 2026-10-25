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
jq -e '.nativeRust == true and .protocolVersion == 1 and .hostContractVersion == 3 and
    .rustNumericCoreVersion == "0.34.0" and
    .maximumDenseUnknowns == 512 and
    (.supportedAnalyses | index("transient") != null) and
    (.supportedAnalyses | index("dc-sweep") != null)' \
    "$work/manifest.json" >/dev/null

"$rust_host" qualify >"$work/qualification.json"
jq -e '.ready == true and (.cases | length) >= 10 and
    ([.cases[].identifier] | index("shockley-diode") != null) and
    ([.cases[].identifier] | index("level1-nmos-body-tied") != null) and
    ([.cases[].identifier] | index("transient-initial-conditions") != null) and
    ([.cases[].identifier] | index("dc-source-sweep") != null) and
    ([.cases[].identifier] | index("scaled-mixed-impedance") != null) and
    ([.cases[].identifier] | index("dense-budget-fails-before-solve") != null)' \
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

jq '.analysis={"dcOperatingPoint":false,"transient":{"start":0,"step":0.001,"stop":0.002}} |
    .circuit.nodes=[{"name":"0"},{"name":"out"}] |
    .circuit.devices=[{"kind":"resistor","name":"R1","terminals":[1,0],"value":1000},
      {"kind":"capacitor","name":"C1","terminals":[1,0],"value":0.000001}] |
    .circuit.initialConditions.nodeVoltages={"out":1} | .backend="numeric-core"' \
    Examples/portable-divider-request.json | "$swift_host" platform run >"$work/swift-transient.json"
jq '.analysis={"dcOperatingPoint":false,"transient":{"start":0,"step":0.001,"stop":0.002}} |
    .circuit.nodes=[{"name":"0"},{"name":"out"}] |
    .circuit.devices=[{"kind":"resistor","name":"R1","terminals":[1,0],"value":1000},
      {"kind":"capacitor","name":"C1","terminals":[1,0],"value":0.000001}] |
    .circuit.initialConditions.nodeVoltages={"out":1} | .backend="rust-numeric-core"' \
    Examples/portable-divider-request.json | "$rust_host" run >"$work/rust-transient.json"
jq -s -e '
  .[0].status == "success" and .[1].status == "success" and
  ((.[0].result.transient.nodes[0].values[-1] - .[1].result.transient.nodes[0].values[-1]) | fabs) <= 1e-9
' "$work/swift-transient.json" "$work/rust-transient.json" >/dev/null

jq '.analysis={"dcOperatingPoint":false,"dcSweep":{"source":"V1","start":0,"stop":5,"step":2.5}} |
    .backend="numeric-core"' Examples/portable-divider-request.json \
    | "$swift_host" platform run >"$work/swift-sweep.json"
jq '.analysis={"dcOperatingPoint":false,"dcSweep":{"source":"V1","start":0,"stop":5,"step":2.5}} |
    .backend="rust-numeric-core"' Examples/portable-divider-request.json \
    | "$rust_host" run >"$work/rust-sweep.json"
jq -s -e '
  .[0].status == "success" and .[1].status == "success" and
  (.[0].result.sweep.points | length) == 3 and (.[1].result.sweep.points | length) == 3 and
  ((.[0].result.sweep.points[-1].nodes[1].value - .[1].result.sweep.points[-1].nodes[1].value) | fabs) <= 1e-12
' "$work/swift-sweep.json" "$work/rust-sweep.json" >/dev/null

jq '.backend="numeric-core" |
    .circuit.devices[0].source.dcValue=1000000 |
    .circuit.devices[1].value=1000000000 |
    .circuit.devices[2].value=0.001' Examples/portable-divider-request.json \
    | "$swift_host" platform run >"$work/swift-scaled.json"
jq '.backend="rust-numeric-core" |
    .circuit.devices[0].source.dcValue=1000000 |
    .circuit.devices[1].value=1000000000 |
    .circuit.devices[2].value=0.001' Examples/portable-divider-request.json \
    | "$rust_host" run >"$work/rust-scaled.json"
jq -s -e '
  .[0].status == "success" and .[1].status == "success" and
  (([.[0].result.dc.nodes[], .[1].result.dc.nodes[]]
    | map(select(.name == "out") | .value) | .[0] - .[1]) | fabs) <= 1e-12
' "$work/swift-scaled.json" "$work/rust-scaled.json" >/dev/null

printf 'OhmLab native Rust host qualification passed\n'
