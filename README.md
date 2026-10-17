# OhmLab

**OhmLab** is an electronic circuit design and simulation application targeting macOS 14+ and iPadOS 17+. The first release focuses on a dependable **workflow spanning passives, a Shockley diode, bipolar transistors, and MOSFETs**: draw a schematic, enter values, get feedback, run real DC, AC, and transient analyses, and trust that the plots came from the circuit you drew.

The Swift package builds and runs by itself — no Rust toolchain required. A future `audio-spice-core` (Rust/UniFFI) engine can be linked in behind the same interface, but it is not needed for the milestone.

## Architecture: The Four-Layer Model

Unlike traditional tools where the SPICE netlist is the source of truth (which loses geometry, wire shapes, and layout on every save), `OhmLab` uses a strictly separated four-layer architecture. The **Schematic is the document**, and the netlist is merely a projection of it.

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
This layer translates the Connectivity Model into a SPICE dialect (R, C, L, V, I, D, Q, M).
*   **Node Mapping:** Assigns node IDs/names (labels preserved) to nets. `gnd`, `ground`, and `agnd` are normalized to node `0` (a note is recorded), and node names are trimmed of stray whitespace.
*   **Value Parsing:** Converts strings like `4.7k` or `10u` into floating-point values, and evaluates `{…}` expressions over `.param` values.
*   **Import/Export:** A `.ac`- and `.dc`-aware netlist reader lets you edit SPICE directly; the schematic projects back to a readable SPICE netlist.

### Layer 4: The Simulation Layer (The Engine)
The simulation layer is a **native Swift linear solver**:
*   **MNA Solver:** Builds and solves Modified Nodal Analysis matrices (`Complex` + partial-pivot Gaussian elimination).
*   **AC Analysis:** Decade, octave, or linear sweeps of complex node voltages and element currents → magnitude (dB) and phase over frequency.
*   **DC Operating Point:** Capacitors open, inductors short (0 V branch); node voltages plus per-element voltage and current.
*   **Transient Analysis:** Backward-Euler time stepping with companion models for C and L, seeded by the operating point at the start time (a `.ic` card may override starting node voltages and inductor currents). Sources support `PULSE`, `SIN`, and `PWL` shapes.
*   **DC Sweep:** `.dc <src> <start> <stop> <step>` sweeps an independent source (nested sweeps are supported); `.step param <name> list <v…>` / `.step param <name> <start> <stop> <step>` re-parses the netlist per value. Each operating point is returned with its sweep coordinates, plotted, and exported to CSV.
*   **Nonlinear Devices:** A Shockley diode (saturation current, emission coefficient, optional series resistance), NPN/PNP bipolar transistors (simplified Ebers-Moll transport model: saturation current, forward/reverse beta; no Early effect), and N-MOS/P-MOS field-effect transistors (Level 1 Shichman-Hodges: threshold voltage, transconductance parameter `KP`, channel-length modulation `LAMBDA`, body effect `GAMMA`, surface potential `PHI`). DC, operating-point, and transient solves run a damped Newton-Raphson iteration with junction-voltage limiting; AC analysis linearises once about the DC operating point (small-signal). The Newton machinery is generic over N-terminal devices, stamping each device's terminal currents and Jacobian block (4×4 for the MOSFET).
*   **Domain Agnostic:** The solver knows nothing about GUI coordinates, symbols, or layout — it only consumes the projected circuit.

## Key Frontend Features

*   **Custom Native Canvas:** Native Core Graphics drawing for the grid, wires, symbols, pin endpoints, junctions, and net labels, with pan, zoom, drag-to-move, and selection.
*   **Data-Driven Components:** Passive components and AC sources are defined in a `ComponentRegistry`, including pins, symbols, reference prefixes, and typed parameters.
*   **Real Analysis, Real Results:** The DC/AC/transient/DC-sweep results shown in the UI are computed from the schematic (or the entered netlist). Plots are labelled as engine output, never as demonstration data. Node voltages and element currents are both plottable as Bode plots, time-domain waveforms, or DC transfer curves, and results can be copied out as CSV.
*   **Diagnostics as Guidance:** The document is validated continuously — missing ground, duplicate/invalid references, invalid values, floating pins, and shorts are reported inline with the affected component named.
*   **KiCad / ngspice Interchange:** Import a SPICE netlist (or, on macOS, a KiCad `.kicad_sch` via `kicad-cli`); export a netlist KiCad and ngspice accept.
*   **Durable Documents:** Circuits serialize to versioned `.ohmlab` JSON, with open/save and crash recovery of unsaved edits.
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
| N-MOSFET | M | Level 1 Shichman-Hodges: threshold voltage (`VTO`), transconductance parameter (`KP`), channel-length modulation (`LAMBDA`), body effect (`GAMMA`), surface potential (`PHI`); four terminals drain/gate/source/bulk |
| P-MOSFET | M | Same model, polarity reversed (`VTO` is negative) |
| Ground | GND | Maps to node 0 |

Other nonlinear devices (JFET), switches, and transformers are intentionally out of scope for this milestone and are reported rather than silently ignored.

### Subcircuits (netlist)

`.subckt <name> <ports…> [params: k=v …]` … `.ends` definitions are expanded when instantiated by an `X<name> <nodes…> <subckt> [k=v …]` element. Expansion is a flattening pass, not a schematic feature: each instance's internal nodes are given a private, instance-scoped name so parallel instances never share nodes, and element names are prefixed with the instance (e.g. `X1.R1`). Definitions may nest, and `{…}` expressions over parameters (`{R/2}`, `{R + R}`) are evaluated per instance; instance values override `.subckt` defaults. Unknown subcircuits, port-count mismatches, and recursion are reported as errors.

### Netlist dialect & analysis cards

Beyond elements, the reader understands a useful subset of control cards:

*   **`.param NAME=expr …`** — global parameters, substituted into `{…}` expressions, bare value tokens, and source specifications everywhere (including inside subcircuits). Caller-supplied overrides (used by `.step`) take precedence over a `.param` card.
*   **`.ic V(node)=value …` / `.ic I(element)=value …`** — starting conditions for a transient run.
*   **`.dc <src> <start> <stop> <step> [<src2> …]`** — a (nested) DC sweep of independent sources.
*   **`.step param <name> list <v…>` / `.step param <name> <start> <stop> <step>`** — repeat the DC analysis per parameter value by re-parsing; `.step temp` and non-`param` forms are reported and skipped (temperature-dependent models are not modelled yet).
*   **`.include <file>` / `.lib <file>`** — inlined through a pluggable `SpiceIncludeResolver`; without a resolver (or when a file is missing) the card is skipped and a note is recorded. Quoted paths (`"./models.lib"`) are unquoted.
*   **`.options …`** — accepted and ignored; **`.temp`** is reported and ignored.
*   **KiCad/ngspice control cards** — `.title`, `.date`, `.rev`, `.company`, `.width`, `.plot`, `.print`, `.save`, `.probe`, and `.backanno` are tolerated silently so exported netlists round-trip; `.four`, `.nodeset`, `.noise`, `.disto`, and `.sens` are accepted with a note, since they would change results in ways the engine does not model.

Non-fatal notes (skipped includes, ignored directives, aliased grounds) travel with the parsed netlist and are surfaced in the results panel.

### KiCad interchange

Interchange is netlist-level: OhmLab does not parse `.kicad_sch` itself, it borrows KiCad's exporter.

*   **Import** — the **Import** button (or **File ▸ Import Netlist or KiCad Schematic…**, ⇧⌘I, or dragging a file onto the window) accepts a `.cir`/`.net`/`.sp`/`.spi`/`.ckt`/`.txt` netlist, or (macOS) a `.kicad_sch` schematic, which is converted with `kicad-cli sch export netlist --format spice` (`KiCadCLIClient` finds the CLI via an explicit path, the standard app-bundle locations, then `PATH`). The resulting SPICE text is loaded into the netlist editor and can be run directly; anything the engine cannot model is reported in **Diagnostics** rather than blocking the import. A banner records where the netlist came from and lists non-fatal parser notes; editing the netlist by hand clears it.
*   **Export** — the **Projected SPICE Netlist** panel produces a plain SPICE netlist KiCad and ngspice accept as-is, and **Export SPICE Netlist…** (**File ▸ …**, ⇧⌘E on macOS; the system share sheet on iPadOS) writes it to a `.cir` file.
*   **Clipboard** — **Copy**/**Paste** on the netlist editor move netlists to and from the system pasteboard.

Known limits: a `.kicad_sch` that contains only connectors/mechanical symbols exports single-node elements OhmLab does not support, so it is reported as an unsupported element rather than simulated.

## Project Structure

```text
Sources/OhmLab/
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
├── Persistence/                  # Versioned .ohmlab file format + recovery
├── Interop/                      # KiCad/ngspice interchange (kicad-cli bridge)
└── Circuit/                      # Simulator UI and document model
```

## Quick Start

```bash
cd OhmLab
swift run
```

Create a circuit, place components (R, C, L, V, I, D, Q, M, ground), draw wires, and press **Run**. The DC operating point, AC magnitude/phase plots, and transient waveforms all come from the built-in solver.

## Workflows

### Schematic
1. Choose **Schematic**, pick a component from **Place Component**, and click the canvas to drop it.
2. Choose **Wire** and click two grid locations to connect them; component pins connect when they share a grid location. Use **Label** to name a net (e.g. `OUT`).
3. Select a placed component to edit its parameters or rotation. Drag a component to move it.
4. Review the **Diagnostics** and **Projected SPICE Netlist** panels.
5. Configure DC/AC/transient settings and click **Run**. Pick which nodes to plot and an optional input reference for a transfer-function view. Transient runs plot selected node voltages and element currents over time.

### Netlist
Enter or paste SPICE (R, C, L, V, I, D, Q, M with `.ac dec|oct|lin`, `.tran`, `.dc`, and `.step param`), or use **Import** to load a SPICE netlist (or a KiCad `.kicad_sch` on macOS), then **Run**. Sources keep separate `DC`, `AC`, and transient values (`V1 1 0 DC 5 AC 1`, `V1 1 0 PULSE(0 5 0 1n 1n 1 2)`, `SIN(...)`, `PWL(...)`). Diodes reference a `.model` card (`D1 2 0 DMOD` / `.model DMOD D(IS=1e-14 N=1 RS=10)`); a model's series resistance expands to an internal series resistor. Transistors use `Q<name> <collector> <base> <emitter> <model>` with a `.model QNPN NPN(IS=1e-15 BF=100 BR=1)` (or `PNP(...)`) card. MOSFETs use `M<name> <drain> <gate> <source> <bulk> <model>` with a `.model MNMOS NMOS(VTO=1 KP=1m LAMBDA=0.02)` (or `PMOS(...)`) card. Subcircuits use a `.subckt <name> <ports…> … .ends` block with `X` instances, optionally parameterised (`X2 in out DIV RA=2k`). Parameter (`.param`/`{…}`), include (`.include`/`.lib`), and initial-condition (`.ic`) cards are supported; unsupported cards are reported rather than ignored.

## Document format

`.ohmlab` files are versioned JSON (`schemaVersion`) holding the schematic geometry, net labels, and analysis settings. Each open document mirrors its unsaved edits to its own recovery slot, so several drafts survive a crash and are offered on the next launch. `CircuitFileStore.migrate` upgrades older files in place — schema v2 splits a legacy source's single magnitude into separate DC and AC parameters. Future schema upgrades belong there too.

## Requirements
- macOS 14+
- iPadOS 17+
- Xcode 15+ / Swift 6
- KiCad 9+ (optional) — enables importing `.kicad_sch` schematics via its `kicad-cli`

The Swift package declares macOS 14+ and iOS 17+ deployment targets. The iOS target is intended for iPadOS; the app uses SwiftUI's adaptive split navigation for tablet layouts.
