# OhmLab

**OhmLab** is an electronic circuit design and simulation application targeting macOS 14+ and iPadOS 17+. The first release focuses on a dependable **workflow spanning passives, a Shockley diode, bipolar transistors, MOSFETs, and JFETs**: draw a schematic, enter values, get feedback, run real DC, AC, and transient analyses, and trust that the plots came from the circuit you drew.

The Swift package builds and runs by itself — no Rust toolchain required. Simulation goes through a pluggable **engine façade**, so an optional Rust `ohm-core` (`audio-spice-core`) MNA engine can be linked behind the same interface; the built-in pure-Swift engine remains the default and the reference.

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
This layer translates the Connectivity Model into a SPICE dialect (R, C, L, V, I, D, Q, M, J).
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
*   **Fourier Analysis:** `.four <freq> <var…>` (e.g. `.four 1k v(2) i(V1)`) reports the DC component and the first nine harmonics of a transient signal over the last full period, with each harmonic's magnitude, phase, normalized magnitude/phase, and total harmonic distortion (THD). Because the transient trace is piecewise linear, every harmonic is integrated in closed form on each segment (no resampling grid), so there is no interpolation error. Results appear in the UI and in the CSV export.
*   **Nonlinear Devices:** A Shockley diode (saturation current, emission coefficient, optional series resistance), NPN/PNP bipolar transistors (simplified Ebers-Moll transport model: saturation current, forward/reverse beta; no Early effect), and N-MOS/P-MOS field-effect transistors (Level 1 Shichman-Hodges: threshold voltage, transconductance parameter `KP`, channel-length modulation `LAMBDA`, body effect `GAMMA`, surface potential `PHI`), plus N-JFET/P-JFET junction field-effect transistors (Shichman-Hodges square law with a gate-junction Shockley current). DC, operating-point, and transient solves run a damped Newton-Raphson iteration with junction-voltage limiting; AC analysis linearises once about the DC operating point (small-signal). The Newton machinery is generic over N-terminal devices, stamping each device's terminal currents and Jacobian block (4×4 for the MOSFET, 3×3 for the JFET). Convergence is judged on both the terminal-voltage and device-current updates. Every model carries SPICE's temperature parameters (`XTI`, `EG` for diodes/transistors, `XTB` for transistor betas, `BEX`/`TCV` for MOSFETs and JFETs).
*   **Solver Options & Temperature:** `.options reltol⏐abstol⏐vntol⏐gmin⏐itl1⏐temp⏐tnom` are honoured: the tolerances drive the Newton convergence test, `itl1` caps the iteration count, `gmin` is the junction/channel leakage conductance that keeps cutoff non-singular, and the operating temperature (`temp`, from a `.temp` card or `.options`) scales each device model. Temperature dependence follows SPICE: diode/BJT saturation current and thermal voltage (`IS(T)` from `IS`, `XTI`, `EG`), BJT betas (`XTB`), and MOSFET level-1 `KP(T)` (`BEX`) and `VTO(T)` (`TCV`). Non-physical values fall back to their defaults.
*   **Domain Agnostic:** The solver knows nothing about GUI coordinates, symbols, or layout — it only consumes the projected circuit.

## Engine Façade & the Optional Rust Core

Simulation is reached through `SimulationEngine`, a façade that dispatches to a registered `SimulationEngineBackend`:

*   **`NativeMNAEngine`** (identifier `"native-mna"`) is the built-in Swift engine and the default backend — the full DC/AC/transient/DC-sweep/`.four` feature set described above.
*   **Backends are swappable at runtime** with `SimulationEngine.register(_:makeDefault:)` and `SimulationEngine.resetToDefaultBackend()`. Because the façade is the single entry point (`EngineClient` and the CLI both call it), no call site changes when a backend changes. The schematic entry point has a default implementation that projects a snapshot to a netlist, so a foreign backend only has to implement the netlist solve.
*   **`ohm-core`** (Rust) is an optional alternative backend, `rust/ohm-core`, exposed over a tiny JSON C ABI (`ohm_engine_version`, `ohm_solve`, `ohm_free_string`) — no generated bindings required. It is dependency-free and covers DC operating points and AC sweeps for linear R/C/L/V/I circuits; unsupported analyses (transient, DC sweeps, model libraries, nonlinear devices) are reported as warnings. `RustEngineBackend.swift` bridges it behind the façade.
*   **Opt-in build.** Nothing Rust-related is compiled unless you ask: `RustEngineBackend` is gated on `#if canImport(CCOhmCore)`. To enable it, run `scripts/build-rust-core.sh` (which runs `cargo test` and builds `libohm_core.a`) and follow the "Enabling the Rust core" block in `Package.swift`.

## Key Frontend Features

*   **Custom Native Canvas:** Native Core Graphics drawing for the grid, wires, symbols, pin endpoints, junctions, and net labels, with pan, zoom, drag-to-move, and selection.
*   **Data-Driven Components:** Passive components and AC sources are defined in a `ComponentRegistry`, including pins, symbols, reference prefixes, and typed parameters.
*   **Real Analysis, Real Results:** The DC/AC/transient/DC-sweep results shown in the UI are computed from the schematic (or the entered netlist). Plots are labelled as engine output, never as demonstration data. Node voltages and element currents are both plottable as Bode plots, time-domain waveforms, or DC transfer curves, and results can be copied out as CSV.
*   **Interactive Waveform Viewer:** Every result panel is drawn by a custom plot view with drag-to-pan, pinch/wheel zoom, double-tap (or **Fit**) auto-scaling, and two draggable vertical cursors with Δx/Δy readouts. AC plots show magnitude (dB) and phase; DC-sweep and transient panels support a logarithmic x-axis where appropriate.
*   **Transient FFT:** A dedicated spectrum panel runs a radix-2 FFT over the transient trace with selectable windows (Rectangular, Hann, Hamming, Blackman), a linear/dB toggle, and a log-frequency axis — distinct from the closed-form `.four`/THD analysis.
*   **Plot Export:** Any plot can be exported as a PNG image or a long-format CSV directly from its panel.
*   **Multi-run Overlays:** A **Runs** list keeps the last several simulation results; toggle any of them to overlay on the live plots (transient, AC, DC sweep, and FFT), or clear the list.
*   **Diagnostics as Guidance:** The document is validated continuously — missing ground, duplicate/invalid references, invalid values, floating pins, and shorts are reported inline with the affected component named. **Every sheet** is checked, with child-sheet findings tagged by sheet name (top-level-only checks such as "needs a ground" are skipped inside subcircuits); unbound subcircuit ports, missing sheets, and bus range mistakes are flagged too.
*   **KiCad / ngspice Interchange:** Import a SPICE netlist (or, on macOS, a KiCad `.kicad_sch` via `kicad-cli`); export a netlist KiCad and ngspice accept.
*   **Document-Based Lifecycle:** The app is built on a SwiftUI `DocumentGroup`, so documents open in place, autosave to their own location (including iCloud Drive), and get the standard New/Open/Save/Save As/Revert commands on macOS and iPadOS.
*   **Hierarchical Sheets:** A document holds named sheets (the root plus any number of subcircuits). A subcircuit-instance symbol references a sheet, exposes its ports as pins, and can be double-clicked to descend into it; a breadcrumb walks back up. Simulation and export flatten the tree.
*   **Buses:** `DATA[7:0]` declares a bus, a thick blue bus wire carries its labels, and member labels (`DATA[3]`) tap individual bits. Members merge by name and expand to ordinary nets at simulation/export; bus-declaration labels are names only and carry no conduction.
*   **Netlist → Schematic:** **Draw Schematic** on the netlist editor auto-lays out any supported SPICE netlist as an editable schematic — components on a grid, orthogonal wires routed from connectivity, nets labelled, and `.subckt` blocks reconstructed as subcircuit-instance symbols referencing generated sheets.
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
| N-JFET | J | Shichman-Hodges junction FET: threshold voltage (`VTO`, negative), transconductance parameter (`BETA`), channel-length modulation (`LAMBDA`), gate-junction saturation current (`IS`); three terminals drain/gate/source |
| P-JFET | J | Same model, polarity reversed (`VTO` is positive) |
| Ground | GND | Maps to node 0 |

Switches, controlled sources, and transformers are intentionally out of scope for this milestone and are reported rather than silently ignored.

### Subcircuits (netlist)

`.subckt <name> <ports…> [params: k=v …]` … `.ends` definitions are expanded when instantiated by an `X<name> <nodes…> <subckt> [k=v …]` element. Expansion is a flattening pass: each instance's internal nodes are given a private, instance-scoped name so parallel instances never share nodes, and element names are prefixed with the instance (e.g. `X1.R1`). Definitions may nest, and `{…}` expressions over parameters (`{R/2}`, `{R + R}`) are evaluated per instance; instance values override `.subckt` defaults. Unknown subcircuits, port-count mismatches, and recursion are reported as errors. This same expansion flattens the schematic sheet hierarchy below.

### Sheets & subcircuit instances (schematic)

Subcircuits are also a first-class drawing feature. A document holds a list of **sheets**; the first is the root and the rest are named subcircuits, each with its own symbols, wires, labels, and **ports**. Place a **Subcircuit** symbol to instantiate a sheet: its pins are the sheet's ports (inputs down the left edge, the rest down the right) and bind by name to same-named net labels inside the sheet. Double-click an instance (macOS) or double-tap (iOS) to descend into its sheet; the breadcrumb at the top of the editor navigates back up to the root. Adding a port is done from the sheet inspector.

Simulation and export **flatten** the hierarchy by projecting the snapshot to a `.subckt`/`X` netlist and reusing the parser's expansion, so a flat schematic still takes the direct, geometry-based compile path and all existing behaviour is unchanged. Recursive and missing-sheet references are reported as errors.

### Buses

A label of the form `DATA[7:0]` **declares** a bus with that bit range; a label of the form `DATA[3]` is a **member** (bit-select) that names a single bit. Bus **wires** (drawn distinctly, in blue) bundle the members and only route; they carry no conduction of their own. Member nets merge globally by name — every `DATA[3]` tap is the same net — and expand to ordinary labelled nets when projected to SPICE, so a bus round-trips through the netlist dialect as `DATA[3]` node names. Declaration labels are names only and are dropped from connectivity. Diagnostics flag member labels with no declaration and members outside a declared range.

### Netlist dialect & analysis cards

Beyond elements, the reader understands a useful subset of control cards:

*   **`.param NAME=expr …`** — global parameters, substituted into `{…}` expressions, bare value tokens, and source specifications everywhere (including inside subcircuits). Caller-supplied overrides (used by `.step`) take precedence over a `.param` card.
*   **`.ic V(node)=value …` / `.ic I(element)=value …`** — starting conditions for a transient run.
*   **`.dc <src> <start> <stop> <step> [<src2> …]`** — a (nested) DC sweep of independent sources.
*   **`.step param <name> list <v…>` / `.step param <name> <start> <stop> <step>`** — repeat the DC analysis per parameter value by re-parsing. `.step temp <start> <stop> <step>` / `.step temp list <v…>` sweeps the operating temperature instead; other `.step` forms are reported and skipped.
*   **`.include <file>` / `.lib <file>`** — inlined through a pluggable `SpiceIncludeResolver`; without a resolver (or when a file is missing) the card is skipped and a note is recorded. Quoted paths (`"./models.lib"`) are unquoted.
*   **`.options reltol=… abstol=… vntol=… gmin=… itl1=… temp=… tnom=…`** — honoured by the solver (unknown options are accepted and ignored). **`.temp <value>`** sets the operating temperature that drives the devices' temperature-dependent model parameters.
*   **`.four <freq> <var…>`** — Fourier analysis of the transient result: the DC component and the first nine harmonics of a chosen fundamental frequency, taken over the last full period, with THD. Signals are `v(node)`, `i(element)`, or a bare node name; an unknown signal or a missing `.tran` is reported as a note.
*   **KiCad/ngspice control cards** — `.title`, `.date`, `.rev`, `.company`, `.width`, `.plot`, `.print`, `.save`, `.probe`, and `.backanno` are tolerated silently so exported netlists round-trip; `.nodeset`, `.noise`, `.disto`, and `.sens` are accepted with a note, since they would change results in ways the engine does not model.

Non-fatal notes (skipped includes, ignored directives, aliased grounds) travel with the parsed netlist and are surfaced in the results panel.

### KiCad interchange

Interchange is netlist-level: OhmLab does not parse `.kicad_sch` itself, it borrows KiCad's exporter.

*   **Import** — the **Import** button in the simulator header (or dragging a file onto the window) accepts a `.cir`/`.net`/`.sp`/`.spi`/`.ckt`/`.txt` netlist, or (macOS) a `.kicad_sch` schematic, which is converted with `kicad-cli sch export netlist --format spice` (`KiCadCLIClient` finds the CLI via an explicit path, the standard app-bundle locations, then `PATH`). The resulting SPICE text is loaded into the netlist editor and can be run directly; anything the engine cannot model is reported in **Diagnostics** rather than blocking the import. A banner records where the netlist came from and lists non-fatal parser notes; editing the netlist by hand clears it.
*   **Draw Schematic** — the button in the netlist editor header runs the auto-layout importer (`SchematicImporter`), turning the current netlist into an editable schematic: devices are placed on a grid, each pin is routed orthogonally to a per-net rail, nets are labelled with their original node names, and `.subckt` blocks become child sheets with `X` instances drawn as subcircuit symbols. The router never lets crossing wires merge (connectivity forms only at shared vertices), and the original netlist text is retained so nothing is lost if a drawing does not round-trip perfectly.
*   **Export** — the **Projected SPICE Netlist** panel produces a plain SPICE netlist KiCad and ngspice accept as-is, and the **Export** button writes it to a `.cir` file through the system save/share sheet on both macOS and iPadOS.
*   **Clipboard** — **Copy**/**Paste** on the netlist editor move netlists to and from the system pasteboard.

Known limits: a `.kicad_sch` that contains only connectors/mechanical symbols exports single-node elements OhmLab does not support, so it is reported as an unsupported element rather than simulated.

## Project Structure

```text
Sources/
├── OhmLabCore/                   # Shared, platform-agnostic core library
│   ├── Shared/                   # EngineClient facade; plot model/views/panels
│   ├── Schematic/                # Layer 1 + Layer 2 + Layer 3
│   │   ├── Models.swift              # Schematic document (multi-sheet), buses, undo/redo
│   │   ├── SubcircuitSupport.swift   # Subcircuit instances + sheet catalog
│   │   ├── ConnectivityBuilder.swift # Union-Find connectivity (bus-aware)
│   │   ├── ComponentRegistry.swift   # Data-driven descriptors
│   │   ├── SpiceNetlistBuilder.swift # Schematic -> SPICE projection (hierarchy-aware)
│   │   ├── SchematicImporter.swift   # SPICE netlist -> auto-laid-out schematic
│   │   └── Views/                    # Custom NSView/UIView canvas
│   ├── Engine/                   # Layer 4 (native Swift) + backend façade
│   │   ├── Complex.swift
│   │   ├── ComplexLinearSolver.swift
│   │   ├── LinearCircuit.swift       # MNA assembly, Newton-Raphson, DC/AC/transient solve
│   │   ├── TransientSolver.swift     # Backward-Euler time stepping
│   │   ├── FourierAnalysis.swift     # `.four` harmonics and THD
│   │   ├── SpectrumAnalyzer.swift    # Transient FFT + window functions
│   │   ├── Waveform.swift            # PULSE / SIN / PWL source shapes
│   │   ├── CircuitCompiler.swift     # Schematic -> LinearCircuit
│   │   ├── ModelLibrary.swift        # Vendor `.model`/`.subckt` import + registry
│   │   ├── SpiceNetlistParser.swift  # Netlist -> LinearCircuit
│   │   └── RustEngineBackend.swift   # Optional ohm-core bridge (CCOhmCore-gated)
│   ├── Diagnostics/              # Pre-simulation validation
│   ├── Persistence/              # Versioned .ohmlab file format + lifecycle
│   │   ├── CircuitFile.swift         # File format, migration, crash-recovery slots
│   │   ├── CircuitFileDocument.swift # FileDocument for the DocumentGroup scene
│   │   └── CloudDocumentStore.swift  # Optional iCloud ubiquity-container access
│   ├── Interop/                  # KiCad/ngspice interchange (kicad-cli bridge)
│   └── Circuit/                  # Simulator UI and document model
├── OhmLab/                       # SwiftUI app shell (OhmLabApp.swift — the @main scene)
└── CCOhmCore/                    # systemLibrary module map + header for the Rust core
rust/ohm-core/                    # Optional Rust engine crate (C ABI + cargo tests)
scripts/build-rust-core.sh        # Builds/stages libohm_core.a for the optional core
```

The result plots live under `OhmLabCore/Shared/Plot/`: `PlotModel.swift` (pure scales, viewport, transforms, ticks), `WaveformPlotView.swift` (the interactive canvas with cursors/pan/zoom), `WaveformPlotPanel.swift` (titled, exportable panel), and `PlotExport.swift` (PNG/CSV export documents). App wiring is `OhmLabApp.swift` (the `DocumentGroup` scene) and `OhmLabCore/Shared/DocumentWorkspaceView.swift` (bridges the `FileDocument` to the in-memory `CircuitDocument`). The `OhmLab` app target is a thin shell over `OhmLabCore`.

## Quick Start

```bash
cd OhmLab
swift run
```

Create a circuit, place components (R, C, L, V, I, D, Q, M, ground), draw wires, and press **Run**. The DC operating point, AC magnitude/phase plots, and transient waveforms all come from the built-in solver.

## Workflows

### Schematic
1. Choose **Schematic**, pick a component from **Place Component**, and click the canvas to drop it.
2. Choose **Wire** and click two grid locations to connect them; component pins connect when they share a grid location. Use **Label** to name a net (e.g. `OUT`), or **Bus** and a name like `DATA[7:0]` to bundle bits (tap one with a `DATA[3]` label).
3. Select a placed component to edit its parameters or rotation. Drag a component to move it.
4. Use the **Subcircuit** menu to create a sheet and place an instance of it. Add **ports** from the sheet inspector, descend into a sheet by double-clicking its instance (or the breadcrumb), and go back with **Root**/**Up**.
5. Review the **Diagnostics** and **Projected SPICE Netlist** panels.
6. Configure DC/AC/transient settings and click **Run**. Pick which nodes to plot and an optional input reference for a transfer-function view. Transient runs plot selected node voltages and element currents over time.
7. Interact with any result plot: drag to pan, pinch/scroll to zoom, double-tap or press **Fit** to auto-scale, and enable **Cursors** for two draggable markers with Δx/Δy readouts. Use each panel's **Export** menu for PNG or CSV, and the **Runs** list to overlay earlier results.

### Netlist
Enter or paste SPICE (R, C, L, V, I, D, Q, M, J with `.ac dec|oct|lin`, `.tran`, `.dc`, `.step param`, and `.four`), or use **Import** to load a SPICE netlist (or a KiCad `.kicad_sch` on macOS), then **Run**. Vendor model files can be loaded as libraries so their `.model`/`.subckt` cards are visible without an explicit `.include` (cards written in the netlist itself still take precedence). Sources keep separate `DC`, `AC`, and transient values (`V1 1 0 DC 5 AC 1`, `V1 1 0 PULSE(0 5 0 1n 1n 1 2)`, `SIN(...)`, `PWL(...)`). Diodes reference a `.model` card (`D1 2 0 DMOD` / `.model DMOD D(IS=1e-14 N=1 RS=10)`); a model's series resistance expands to an internal series resistor. Transistors use `Q<name> <collector> <base> <emitter> <model>` with a `.model QNPN NPN(IS=1e-15 BF=100 BR=1)` (or `PNP(...)`) card. MOSFETs use `M<name> <drain> <gate> <source> <bulk> <model>` with a `.model MNMOS NMOS(VTO=1 KP=1m LAMBDA=0.02)` (or `PMOS(...)`) card. JFETs use `J<name> <drain> <gate> <source> <model>` with a `.model JNJF NJF(VTO=-2 BETA=1m LAMBDA=0)` (or `PJF(...)`) card. Subcircuits use a `.subckt <name> <ports…> … .ends` block with `X` instances, optionally parameterised (`X2 in out DIV RA=2k`). Parameter (`.param`/`{…}`), include (`.include`/`.lib`), and initial-condition (`.ic`) cards are supported; unsupported cards are reported rather than ignored. Device models accept SPICE's temperature parameters (`XTI`, `EG`, `XTB` for diodes/transistors; `BEX`, `TCV` for MOSFETs and JFETs) and the operating temperature is set with `.temp` or `.options temp=…`. Press **Draw Schematic** to auto-layout the netlist as an editable schematic (with `.subckt` blocks reconstructed as subcircuit-instance symbols).

## Document format

`.ohmlab` files are versioned JSON (`schemaVersion`) holding the schematic geometry, net labels, analysis settings, the netlist editor's text and active editor, and any imported model libraries (stored as raw text and re-scanned on open). `CircuitFileStore.migrate` upgrades older files in place — schema v2 splits a legacy source's single magnitude into separate DC and AC parameters, and v3 adds the netlist/editor/library fields (absent fields decode to defaults). The embedded schematic geometry carries its own `schemaVersion`: v2 adds the child-sheet hierarchy (each sheet's symbols, wires, labels, and ports) and bus wire/label metadata, so a multi-sheet drawing round-trips losslessly. Future schema upgrades belong there too.

Documents are managed by a SwiftUI `DocumentGroup` (`CircuitFileDocument` + `DocumentWorkspaceView`), which gives open-in-place, automatic saving to the document's own location, iCloud Drive support, and the standard File menu. `CloudDocumentStore` is an optional helper for reaching an iCloud ubiquity container explicitly; it needs an iCloud entitlement (which a Swift package cannot declare) and degrades to a no-op when unavailable, so the app otherwise relies on the document lifecycle's local/iCloud storage. The older per-document crash-recovery slots (`CircuitFileStore.saveRecovery`/`loadRecovery`) remain available for callers that want them.

## Requirements
- macOS 14+
- iPadOS 17+
- Xcode 15+ / Swift 6
- KiCad 9+ (optional) — enables importing `.kicad_sch` schematics via its `kicad-cli`
- Rust toolchain (optional) — only needed to build and link the optional `ohm-core` engine (`scripts/build-rust-core.sh`)

The Swift package declares macOS 14+ and iOS 17+ deployment targets. The iOS target is intended for iPadOS; the app uses a SwiftUI `DocumentGroup`, so circuits are real documents that open in place and autosave (including to iCloud Drive when the host app is entitled).
