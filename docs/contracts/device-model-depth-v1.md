# OhmLab device model depth v1

Device model depth v1 describes the optional native-model parameters added in
OhmLab 3.3. It is a model-scope contract for the native MNA backend, not a new
production boundary, Circuit IR schema, or portable-protocol version.

## Scope

Before 3.3 the native device models covered the DC transport behaviour of
diodes, BJTs, MOSFETs, and JFETs but had no reactive model beyond explicit
`C`/`L` elements. AC and transient analyses therefore ignored the junction,
overlap, and transit-time capacitances that dominate real small-signal and
switching behaviour, and the BJT had no Early effect. OhmLab 3.3 adds those
parameters while keeping every historical default unchanged.

## Parameters

### Diode

| Parameter | Meaning | Default |
| --- | --- | --- |
| `CJO` | zero-bias junction capacitance (F) | 0 |
| `VJ` | built-in potential (V) | 1 |
| `M` | grading coefficient | 0.5 |
| `TT` | transit time (s) | 0 |

The depletion capacitance is
`CJO · (1 − min(V, FC·VJ)/VJ)^(−M)` with `FC = 0.5`, so the capacitance stays
finite in strong forward bias. The transit-time term is `TT · gd`, where `gd`
is the junction conductance at the bias point.

### BJT

| Parameter | Meaning | Default |
| --- | --- | --- |
| `VAF` | forward Early voltage (V) | 0 (disabled) |
| `VAR` | reverse Early voltage (V) | 0 (disabled) |
| `CJE`, `CJC` | zero-bias base-emitter / base-collector capacitance (F) | 0 |
| `VJE`, `VJC` | built-in potentials (V) | 0.75 |
| `MJE`, `MJC` | grading coefficients | 0.33 |
| `TF`, `TR` | forward / reverse transit time (s) | 0 |

The transport current is scaled by
`1 − Vbc/VAF − Vbe/VAR`, clamped to a small positive floor. Base currents keep
the historical Ebers-Moll form; the Early effect is applied to the transport
current only. `CJE`/`TF` load the base-emitter junction and `CJC`/`TR` load the
base-collector junction.

### MOSFET

| Parameter | Meaning | Default |
| --- | --- | --- |
| `CGSO`, `CGDO`, `CGBO` | gate-source / gate-drain / gate-bulk overlap capacitance (F) | 0 |
| `CBD`, `CBS` | zero-bias bulk-drain / bulk-source capacitance (F) | 0 |

These are constant capacitances in v1. Voltage-dependent area junction
capacitances (`CJ`, `CJSW`, grading coefficients) are not part of this scope.

### JFET

| Parameter | Meaning | Default |
| --- | --- | --- |
| `CGS`, `CGD` | gate-source / gate-drain capacitance (F) | 0 |

These are constant capacitances in v1.

## Analysis behaviour

- **DC and operating point:** every device capacitance is open; the Early
  effect changes the DC collector current when `VAF`/`VAR` are non-zero.
- **AC:** device capacitances are evaluated at the DC bias point and stamped as
  `jωC`. Nonlinear devices are still linearised once about that bias.
- **Transient:** device capacitances use the same backward-Euler companion
  model as explicit capacitors: `C/Δt` conductance plus a history current from
  the previous terminal voltage. Capacitance values are evaluated at the
  current Newton iterate; the history voltage is the previous time step.

## Newton starting hints

`.nodeset V(node)=value` is parsed into an optional Circuit IR `nodeSet` map.
It seeds the first Newton linearisation for every nonlinear device whose
terminal node is named. It is not an initial condition: unlike `.ic`, it never
overrides a solved operating point or a transient initial state, and it is
ignored by linear circuits.

## Guarantees and evidence

`Tests/OhmLabTests/DeviceModelDepthTests.swift` proves:

- every new parameter is parsed from `.model` cards;
- diode junction capacitance changes the AC attenuation;
- BJT collector capacitance rolls off AC gain;
- MOSFET and JFET gate capacitances change the AC response;
- `VAF` raises the collector current at higher `VCE` by the expected ratio;
- diode junction capacitance slows a transient fall;
- `.nodeset` survives a Circuit IR round-trip and used circuits still solve;
- all new model parameters survive a Circuit IR round-trip;
- circuits without the new parameters encode no new IR keys;
- repeated capacitive AC solves are bitwise deterministic.

The existing diode, BJT, MOSFET, JFET, convergence, example-circuit, portable,
and KiCad suites also run with the new defaults, so historical results are
unchanged.

## Non-claims

This contract does **not**:

- change production boundary v8, Circuit IR v1, the result contract, or any
  capability, nonlinear-convergence, or portability version;
- implement `.noise`, `.disto`, or `.sens`;
- implement voltage-dependent MOSFET/JFET area capacitances, gate resistance,
  high-level injection, quasi-saturation, or full Gummel-Poon charge storage;
- claim that the added capacitances are charge-conserving nonlinear elements;
  they are evaluated at the current bias/iterate for AC and backward-Euler
  transient analysis;
- claim support for the new parameters in NumericCore, the Swift portable
  platform, or the native Rust host. Those scoped backends keep their existing
  device surface and fail closed when new optional model fields reach a
  decoder that does not implement them.
