# db-Lab

SwiftUI frontend for the **db-Engine** audio-electrical network simulator.

## Architecture

```
db-Engine (Rust)                      db-Lab (Swift)
──────────────────────────────        ─────────────────────────────────────────
  crates/core    ←── MNA SPICE        EngineClient.swift
  crates/crossover ← XO design         └─ wraps real engine (UNIFFI_AVAILABLE)
  crates/circuit   ← project fmt         or mock data (for UI-only development)
  crates/ffi     ←── UniFFI bridge
         │
         ▼ build_xcframework.sh
  XCFrameworks/DbEngineFFI.xcframework
  Sources/DbEngineFFI/  ← generated Swift bindings
```

## Quick Start (UI development without Rust)

```bash
cd db-Lab
swift run
# or open in Xcode: File > Open > db-Lab (Package.swift)
```

The app compiles and runs with mock data — no Rust build needed.

## Connecting the Real Engine

1. **Build the XCFramework**
   ```bash
   cd db-Engine
   ./scripts/build_xcframework.sh
   ```
   This produces `db-Lab/XCFrameworks/DbEngineFFI.xcframework` and the
   generated Swift source files in `db-Lab/Sources/DbEngineFFI/`.

2. **Uncomment the binary target** in `db-Lab/Package.swift`:
   ```swift
   .target(name: "DbEngineFFI", …)
   .binaryTarget(name: "DbEngineFFIBinary", path: "XCFrameworks/…")
   ```

3. **Enable the UNIFFI_AVAILABLE flag** in Package.swift swiftSettings:
   ```swift
   .define("UNIFFI_AVAILABLE")
   ```

4. **Wire up EngineClient.swift**: replace the `mock*` calls with the real
   `CrossoverEngine` / `CircuitEngine` object calls under `#if UNIFFI_AVAILABLE`.

## Workflows

### Crossover Designer
1. Add drivers (woofer, tweeter, …) with electrical/Thiele-Small parameters
2. Configure filter stages (type, topology, crossover frequency)
3. Click **Synthesize** to calculate L/C/R values
4. Add compensation networks (Zobel, L-Pad, Notch, Baffle Step)
5. Click **Simulate** to run the full AC sweep
6. View frequency response + impedance charts in the Results panel

### Circuit Simulator
1. Enter or paste a SPICE netlist (R, C, L, V, I, Q, M, D elements)
2. Configure analysis types (DC, AC, TRAN) in Settings
3. Click **Run** to simulate
4. View Bode plot, DC operating point, or transient waveforms

## Supported Filter Topologies
- Butterworth 1st–4th order
- Linkwitz-Riley 2nd, 4th, 6th, 8th order
- Bessel 2nd, 3rd, 4th order

## Requirements
- macOS 14+
- Xcode 15+ / Swift 6
- For Rust build: Rust stable, `cargo install uniffi-bindgen`
