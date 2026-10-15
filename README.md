# db-Lab

**db-Lab** is a cross-platform (macOS and iPadOS) electronic circuit design and simulation application. It combines a native, high-performance Swift graphical frontend with a platform-agnostic Rust simulation core.

## Architecture: The Four-Layer Model

Unlike traditional tools where the SPICE netlist is the source of truth (which loses geometry, wire shapes, and layout on every save), `db-Lab` uses a strictly separated four-layer architecture. The **Schematic is the document**, and the netlist is merely a projection of it.

### Layer 1: The Schematic Model (Source of Truth)
This layer represents the visual document that is saved to disk. It contains all geometric and visual context:
*   **Symbols:** Component references, grid-aligned positions, rotations, and mirroring.
*   **Wires:** Orthogonal, grid-aligned point arrays representing physical traces.
*   **Junctions & Labels:** Explicit connection dots and named net labels (e.g., `VCC`, `IN`).
*   **Parameters:** Raw user strings (e.g., `4.7k`, `10uF`) preserving the exact text the user typed.

### Layer 2: The Connectivity Model (The Graph)
Derived entirely from Layer 1, this layer answers the question: *"What is electrically connected to what?"*
*   **Union-Find Engine:** Evaluates connectivity by spatially hashing pin endpoints and wire vertices onto a grid.
*   **Nets:** Disjoint sets of pins that share the same electrical node.
*   **Ground Detection:** Automatically identifies the `Node 0` reference based on Ground symbols.
*   *Note: Visual wire crossings without an explicit junction or endpoint-to-wire connection are intentionally ignored, preventing accidental shorts.*

### Layer 3: The Netlist Layer (The Projection)
This layer acts as an emitter that translates the Connectivity Model into standard SPICE dialects (e.g., ngspice).
*   **Node Mapping:** Assigns integer node IDs to Nets.
*   **Value Parsing:** Converts user strings like `4.7k` or `10u` into floating-point values.
*   **Round-Trip Preservation:** Unknown or vendor-specific SPICE directives are stored as opaque cards and written back verbatim to avoid destroying user data.

### Layer 4: The Simulation Layer (The Engine)
The actual numerical analysis is handled by **`audio-spice-core`**, a pure-Rust library exposed via UniFFI.
*   **MNA Solver:** Builds and solves Modified Nodal Analysis matrices for linear AC networks.
*   **Frequency Sweeps:** Calculates complex node voltages and source currents across logarithmic frequency decades.
*   **Domain Agnostic:** The Rust core knows nothing about GUI coordinates, symbols, or layout—it only consumes the projected netlist.

---

## Key Frontend Features

*   **Custom Native Canvas (`NSView` / `UIView`):** Bypasses SwiftUI `Canvas` limitations for large graphs. Uses native `CGContext` drawing for the grid, wires, and symbols, with hardware-accelerated pan and zoom.
*   **Data-Driven Components:** Components are defined in a `ComponentRegistry` rather than a hardcoded class hierarchy. Adding a new symbol (like a custom op-amp or transformer) requires only data, not new code.
*   **Constraints as Diagnostics:** Instead of blocking the user mid-gesture, the Rules Engine runs in the background to detect floating pins, missing grounds, or singular matrices, presenting them as inline diagnostics.

## Crossover Mode (Domain Layer)

The Loudspeaker Crossover Designer is built as a **Domain Layer** over the same schematic core. 
*   Presets (e.g., 2nd Order Linkwitz-Riley) programmatically generate standard `SymbolInstance` objects (Inductors, Capacitors, Zobels) and place them into the schematic document.
*   The standard Connectivity Builder and Netlist Emitter take over automatically.
*   Users can seamlessly transition between "Crossover Mode" and "Schematic Mode" to tweak component values manually.

## Project Structure

```text
Sources/db-Lab/
├── Shared/                       # App state, engine client (UniFFI bindings)
├── Schematic/                    # Four-layer architecture
│   ├── Models.swift              # Layer 1: Schematic Document
│   ├── ConnectivityBuilder.swift # Layer 2: Union-Find
│   ├── ComponentRegistry.swift   # Data-driven descriptors
│   └── Views/                    # Custom NSView/UIView Canvas
├── Circuit/                      # General circuit simulator UI
└── Crossover/                    # Loudspeaker domain UI
```

## Quick Start (UI development without Rust)

```bash
cd db-Lab
swift run
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
