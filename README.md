# db-Lab

**db-Lab** is an electronic circuit design and simulation application targeting macOS 14+ and iPadOS 17+. The first release focuses on a dependable **workflow spanning passives, a Shockley diode, and bipolar transistors**: draw a schematic, enter values, get feedback, run real DC, AC, and transient analyses, and trust that the plots came from the circuit you drew.

The Swift package builds and runs by itself — no Rust toolchain required. A future `audio-spice-core` (Rust/UniFFI) engine can be linked in behind the same interface, but it is not needed for the milestone.

## Architecture: The Four-Layer Model

Unlike traditional tools where the SPICE netlist is the source of truth (which loses geometry, wire shapes, and layout on every save), `db-Lab` uses a strictly separated four-layer architecture. The **Schematic is the document**, and the netlist is merely a projection of it.

### Layer 1: The Schematic Model (Source of Truth)
This layer represents the visual document that is saved to disk. It contains all geometric and visual context:
*   **Symbols:** Component references, grid-aligned positions, rotations, and mirroring.
*   **Wires:** Orthogonal, grid-aligned point arrays representing physical traces.
*   **Junctions & Labels:** Explicit connection dots and named net labels (e.g. `VCC`, `IN`).
*   **Parameters:** Typed SI values stored on each component instance, with engineering-unit labels shown in the editor.

### Layer 2: The Connectivity Model (The Graph)
Derived entirely from Layer 1, this layer answers the question: *"What is electrically connected to what?"*
*   **Union-Find Engine:** Evaluates connectivity by spatially hashing pin endpoints, wire vertices, and net labels onto a grid.
*   **Nets:** Disjoint sets of pins that share the same electrical node.
*   **Ground Detection:** Every ground symbol maps to SPICE node `0` reference.
*   *Note: Visual wire crossings without an explicit junction or endpoint-to-wire connection are intentionally ignored, preventing accidental shorts.*

### Layer 3: The Netlist Layer (The Projection)
This layer translates the Connectivity Model into a SPICE dialect (R, C, L, V, I, D, Q).
*   **Node Mapping:** Assigns node IDs/names (labels preserved) to nets.
*   **Value Parsing:** Converts strings like `4.7k` or `10u` into floating-point values.
*   **Import/Export:** A `.ac`-aware netlist reader lets you edit SPICE directly; the schematic projects back to a readable SPICE netlist.

### Layer 4: The Simulation Layer (The Engine)
The simulation layer is a **native Swift linear solver**:
*   **MNA Solver:** Builds and solves Modified Nodal Analysis matrices (`Complex` + partial-pivot Gaussian elimination).
*   **AC Analysis:** Decade, octave, or linear sweeps of complex node voltages and element currents → magnitude (dB) and phase over frequency.
*   **DC Operating Point:** Capacitors open, inductors short (0 V branch); node voltages plus per-element voltage and current.
*   **Transient Analysis:** Backward-Euler time stepping with companion models for C and L, seeded by the operating point at the start time. Sources support `PULSE`, `SIN`, and `PWL` shapes.
*   **Nonlinear Devices:** A Shockley diode (saturation current, emission coefficient, optional series resistance) and NPN/PNP bipolar transistors (simplified Ebers-Moll transport model: saturation current, forward/reverse beta; no Early effect). DC, operating-point, and transient solves run a damped Newton-Raphson iteration with junction-voltage limiting; AC analysis linearises once about the DC operating point (small-signal). The Newton machinery is generic over N-terminal devices, stamping each device's terminal currents and Jacobian block.
*   **Domain Agnostic:** The solver knows nothing about GUI coordinates, symbols, or layout — it only consumes the projected circuit.

## Key Frontend Features

*   **Custom Native Canvas:** Native Core Graphics drawing for the grid, wires, symbols, pin endpoints, junctions, and net labels, with pan, zoom, drag-to-move, and selection.
*   **Data-Driven Components:** Passive components and AC sources are defined in a `ComponentRegistry`, including pins, symbols, reference prefixes, and typed parameters.
*   **Real Analysis, Real Results:** The DC/AC/transient results shown in the UI are computed from the schematic (or the entered netlist). Plots are labelled as engine output, never as demonstration data. Node voltages and element currents are both plottable as Bode plots or time-domain waveforms, and results can be copied out as CSV.
*   **Diagnostics as Guidance:** The document is validated continuously — missing ground, duplicate/invalid references, invalid values, floating pins, and shorts are reported inline with the affected component named.
*   **Durable Documents:** Circuits serialize to versioned `.dblab` JSON, with open/save and crash recovery of unsaved edits.
*   **Undo / Redo:** Structural edits (place, move, rotate, delete, wire, label, value changes) are undoable.

## Supported elements (passive)

| Element | Symbol | Notes |
| --- | --- | --- |
| Resistor | R | ≥ 0 Ω (0 Ω rejected by the schematic compiler) |
| Capacitor | C | > 0 F |
| Inductor | L | > 0 H |
| Inductor + series resistance | L | Expanded to a series R and L |
| Voltage source | V | Independent DC magnitude, AC magnitude/phase, and optional transient shape (`PULSE`, `SIN`, `PWL`) |
| Current source | I | Independent DC magnitude, AC magnitude/phase, and optional transient shape (`PULSE`, `SIN`, `PWL`) |
| Diode | D | Shockley model: saturation current (`IS`), emission coefficient (`N`), optional series resistance (`RS`, netlist) |
| NPN transistor | Q | Ebers-Moll transport model: saturation current (`IS`), forward beta (`BF`), reverse beta (`BR`) |
| PNP transistor | Q | Same model, polarity reversed |
| Ground | GND | Maps to node 0 |

Other nonlinear devices (MOSFET, JFET), switches, transformers, and SPICE subcircuits are intentionally out of scope for this milestone and are reported rather than silently ignored.

## Project Structure

```text
Sources/db-Lab/
├── Shared/                       # App state, navigation, EngineClient facade
├── Schematic/                    # Layer 1 + Layer 2 + Layer 3
│   ├── Models.swift              # Schematic document, net labels, undo/redo
│   ├── ConnectivityBuilder.swift # Union-Find connectivity
│   ├── ComponentRegistry.swift   # Data-driven descriptors
│   ├── SpiceNetlistBuilder.swift # Schematic -> SPICE projection
│   └── Views/                    # Custom NSView/UIView canvas
├── Engine/                       # Layer 4 (native Swift)
│   ├── Complex.swift
│   ├── ComplexLinearSolver.swift
│   ├── LinearCircuit.swift       # MNA assembly, Newton-Raphson, DC/AC/transient solve
│   ├── TransientSolver.swift     # Backward-Euler time stepping
│   ├── Waveform.swift            # PULSE / SIN / PWL source shapes
│   ├── CircuitCompiler.swift     # Schematic -> LinearCircuit
│   └── SpiceNetlistParser.swift  # Netlist -> LinearCircuit
├── Diagnostics/                  # Pre-simulation validation
├── Persistence/                  # Versioned .dblab file format + recovery
└── Circuit/                      # Simulator UI and document model
```

## Quick Start

```bash
cd db-Lab
swift run
```

Create a circuit, place components (R, C, L, V, I, D, Q, ground), draw wires, and press **Run**. The DC operating point, AC magnitude/phase plots, and transient waveforms all come from the built-in solver.

## Workflows

### Schematic
1. Choose **Schematic**, pick a component from **Place Component**, and click the canvas to drop it.
2. Choose **Wire** and click two grid locations to connect them; component pins connect when they share a grid location. Use **Label** to name a net (e.g. `OUT`).
3. Select a placed component to edit its parameters or rotation. Drag a component to move it.
4. Review the **Diagnostics** and **Projected SPICE Netlist** panels.
5. Configure DC/AC/transient settings and click **Run**. Pick which nodes to plot and an optional input reference for a transfer-function view. Transient runs plot selected node voltages and element currents over time.

### Netlist
Enter or paste SPICE (R, C, L, V, I, D, Q with `.ac dec|oct|lin` and `.tran`), then **Run**. Sources keep separate `DC`, `AC`, and transient values (`V1 1 0 DC 5 AC 1`, `V1 1 0 PULSE(0 5 0 1n 1n 1 2)`, `SIN(...)`, `PWL(...)`). Diodes reference a `.model` card (`D1 2 0 DMOD` / `.model DMOD D(IS=1e-14 N=1 RS=10)`); a model's series resistance expands to an internal series resistor. Transistors use `Q<name> <collector> <base> <emitter> <model>` with a `.model QNPN NPN(IS=1e-15 BF=100 BR=1)` (or `PNP(...)`) card. Unsupported cards are reported rather than ignored.

## Document format

`.dblab` files are versioned JSON (`schemaVersion`) holding the schematic geometry, net labels, and analysis settings. Each open document mirrors its unsaved edits to its own recovery slot, so several drafts survive a crash and are offered on the next launch. `CircuitFileStore.migrate` upgrades older files in place — schema v2 splits a legacy source's single magnitude into separate DC and AC parameters. Future schema upgrades belong there too.

## Requirements
- macOS 14+
- iPadOS 17+
- Xcode 15+ / Swift 6

The Swift package declares macOS 14+ and iOS 17+ deployment targets. The iOS target is intended for iPadOS; the app uses SwiftUI's adaptive split navigation for tablet layouts.
