# OhmLab thermal analysis v1

Thermal analysis v1 is the steady-state electro-thermal contract introduced in
OhmLab 4.0. It derives dissipated power from a converged DC operating point and
solves a linear thermal-resistance network. It is a new result contract and part
of production boundary v9. It does not change Circuit IR, the electrical result
contract, or any portable-protocol version.

## Scope

`ThermalAnalysis.run` accepts a `ThermalRequest`:

| Field | Meaning |
| --- | --- |
| `netlist` | The same SPICE netlist the DC analyses accept. |
| `settings` | Analysis settings; thermal analysis forces a DC-only solve. |
| `specification` | Ambient, component thermal models, and shared heatsinks. |
| `libraries` | Optional model libraries for the electrical solve. |
| `baseDirectory` | Directory for relative `.include`/`.lib` paths. |

The electrical solve uses the existing DC operating-point path
(`SimulationEngine.solve` with `dcOnly()`). A missing or non-converged DC result
is rejected with `AnalysisError.noDCOperatingPoint`; no thermal result is
produced from a failed electrical solve.

## Power sources

Each `ThermalComponent` contributes heat at its junction node:

- when `powerWatts` is present, that value is used verbatim;
- otherwise the power is `abs(voltage * current)` for the DC operating-point
  component with the same name (case insensitive).

Power must be finite and non-negative. A component named by the thermal
specification but absent from the DC operating point is rejected with
`AnalysisError.unknownThermalComponent`. The default path is deliberately a
one-shot coupling: junction temperature does not feed back into the electrical
model in v1.

## Thermal network

Temperatures are solved as rises above `ambientCelsius`. Ambient is the fixed
zero node and is not part of the matrix.

- A component without `heatsink` connects its junction to ambient through
  `junctionToAmbient`, or through `defaultJunctionToAmbient` when the component
  omits it.
- A component with `heatsink` connects its junction to the named heatsink
  through `junctionToCase`; the heatsink connects to ambient through its own
  `thermalResistance`. Multiple components may share one heatsink.
- A missing path to ambient is rejected with
  `AnalysisError.missingThermalResistance`; resistances must be positive and
  finite.
- The sparse system `G T = P` is solved with the same deterministic sparse
  solver used by the native circuit engine. Node ordering is sorted, so a given
  specification produces byte-identical results run to run.

`ThermalResult` reports, for every listed component: power, absolute
temperature, rise, effective junction-to-ambient resistance (`rise / power`, or
zero at zero power), the attached heatsink, the optional limit, and whether the
limit was exceeded. Shared heatsinks report aggregated power, temperature, and
rise. `totalPowerWatts` sums the listed components.

## Errors

| Error | Condition |
| --- | --- |
| `noDCOperatingPoint` | The electrical solve did not return a converged DC result. |
| `noThermalComponents` | The specification lists no components. |
| `unknownThermalComponent` | A listed designator is absent from the DC result. |
| `missingThermalResistance` | A component has no direct or heatsink path. |
| `invalidThermalSpecification` | Duplicate names, unknown heatsinks, non-positive resistances, or invalid power/limits. |
| `thermalSolveFailed` | The assembled thermal matrix is singular. |

## CLI

```sh
ohm thermal <input> [options]

  --ambient T              ambient temperature in °C (default 25)
  --default-rja K/W        junction-to-ambient for unlisted components
  --rja NAME=K/W           junction-to-ambient for one component
  --power NAME=W           explicit dissipated power
  --max-temp NAME=C        junction-temperature limit
  --heatsink NAME=K/W      shared heatsink resistance to ambient
  --mount NAME=HS:K/W      mount a component on a heatsink
  -f, --format text|json   output format (default text)
```

The input may be a netlist, a `.ohmlab` document, or a `.ohmlabproj` bundle; the
document's saved analysis settings are used, but only the DC operating point is
solved.

## Evidence

The 4.0 gate runs `Tests/OhmLabTests/ThermalAnalysisTests.swift`, which covers:

- power derivation from a resistor divider (`abs(v * i)`);
- explicit power overrides;
- the default junction-to-ambient resistance;
- a shared heatsink with multiple components;
- junction-temperature limits;
- deterministic results and JSON round-trips;
- fail-closed handling of missing paths, unknown components, duplicate names,
  non-positive resistances, negative power, and unknown heatsinks.

`scripts/health-check.sh` also runs a thermal CLI smoke test.

## Non-claims

- v1 is steady-state only; it has no thermal capacitance, transient heating, or
  thermal runaway iteration.
- It does not model junction-to-board spreading, airflow, or temperature-
  dependent electrical parameters.
- Power is not re-derived after the thermal solve. Use `--power` when the DC
  component pair cannot represent the real dissipation (for example a device
  whose loss is dominated by switching).
- The thermal model is user-supplied. OhmLab does not invent thermal
  resistances for a device.
