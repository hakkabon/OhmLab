# db-Lab

**db-Lab** is an electronic circuit design and simulation application targeting macOS 14+ and iPadOS 17+. It combines a native Swift graphical frontend with a platform-agnostic Rust simulation core.

## Architecture: The Four-Layer Model

Unlike traditional tools where the SPICE netlist is the source of truth (which loses geometry, wire shapes, and layout on every save), `db-Lab` uses a strictly separated four-layer architecture. The **Schematic is the document**, and the netlist is merely a projection of it.

### Layer 1: The Schematic Model (Source of Truth)
This layer represents the visual document that is saved to disk. It contains all geometric and visual context:
*   **Symbols:** Component references, grid-aligned positions, rotations, and mirroring.
*   **Wires:** Orthogonal, grid-aligned point arrays representing physical traces.
*   **Junctions & Labels:** Explicit connection dots and named net labels (e.g., `VCC`, `IN`).
*   **Parameters:** Typed SI values stored on each component instance, with engineering-unit labels shown in the editor.

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

*   **Custom Native Canvas:** Uses native Core Graphics drawing for the grid, wires, and symbols, with pan and zoom on both macOS and iPadOS.
*   **Data-Driven Components:** Passive components and AC sources are defined in a `ComponentRegistry`, including pins, symbols, reference prefixes, and typed parameters.
*   **Schematic Editor:** Place and rotate components, edit their values, draw orthogonal wires, and project connected components to a SPICE netlist.
*   **Constraints as Diagnostics:** Instead of blocking the user mid-gesture, the Rules Engine runs in the background to detect floating pins, missing grounds, or singular matrices, presenting them as inline diagnostics.

## Crossover Mode (Domain Layer)

The Loudspeaker Crossover Designer remains a **domain model** containing drivers, filter stages, and compensation networks. It is intentionally not synchronized with the standalone schematic document while the crossover-to-circuit boundary is being evaluated. The current crossover results use demonstration data; the Rust engine is not yet connected.

Supported low-pass and high-pass stages can be converted to a temporary passive SPICE ladder circuit for preview and analysis preparation. The generated netlist is not a second editable document. Band-pass stages, measured driver impedance/acoustic files, and real circuit solving are not yet supported by this adapter.

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

The app compiles and runs with demonstration data — no Rust build needed. Circuit analysis results are synthetic mock data and do not solve the entered SPICE netlist.

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
1. Choose **Netlist** to enter SPICE directly, or **Schematic** to place R, C, L, AC voltage/current sources, and ground.
2. In schematic mode, choose a component and click the canvas to place it. Choose **Wire** and click two grid locations to connect them; component pins connect when they share a grid location.
3. Select a placed component to edit its parameters or rotation.
4. Configure analysis types (DC, AC, TRAN) and click **Run**.
5. View Bode plot, DC operating point, or transient waveforms.

The schematic netlist projection validates reference designators and positive component values. Inductors with series resistance are emitted as a series resistor and inductor. Simulation results remain mock data until the Rust engine is connected.

## Supported Filter Topologies
- Butterworth 1st–4th order
- Linkwitz-Riley 2nd, 4th, 6th, 8th order
- Bessel 2nd, 3rd, 4th order

## Requirements
- macOS 14+
- iPadOS 17+
- Xcode 15+ / Swift 6
- For Rust build: Rust stable, `cargo install uniffi-bindgen`

The Swift package declares macOS 14+ and iOS 17+ deployment targets. The iOS target is intended for iPadOS; the app uses SwiftUI's adaptive split navigation for tablet layouts.
