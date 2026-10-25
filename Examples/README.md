# Example circuits

Small, self-checking circuits that exercise the engine end to end. They serve
two purposes:

* **Documentation** — each file is a short SPICE netlist with a comment header
  explaining the circuit and its expected result.
* **Health check** — each file carries `@analysis` / `@check` directives in its
  header that the test suite and the `health-check.sh` script verify, so they
  catch regressions in the parser, engine, and CLI.

## The circuits

| File | Exercises | Expected result |
| --- | --- | --- |
| `01-voltage-divider.cir` | DC operating point, resistors | midpoint `v(2) = 5 V`, loop current `5 mA` |
| `02-rc-lowpass.cir` | AC sweep, capacitors | `-1.445 dB @ 1 kHz`, `-4.115 dB @ 2 kHz` |
| `03-rc-ramp.cir` | Transient solver, current source | linear ramp `v(1) = 1 V` at `1 ms` |
| `04-norton-source.cir` | Current sources, parallel loads | `v(1) = 1 V`, `1 mA` per resistor |
| `05-diode-drop.cir` | Nonlinear DC (Newton–Raphson) | forward drop `≈ 0.655 V` at `1 mA` |
| `06-subcircuit-attenuator.cir` | `.subckt` expansion | `v(2) = 2 V` from a `4 V` source |
| `07-project-bundle.ohmlabproj/` | Project-bundle format | a single-sheet bundle wrapping the divider |
| `portable-divider-request.json` | Portable protocol v1 | NumericCore returns `v(out) = 2.5 V` |

## Running them

With the CLI:

```sh
swift build
ohm Examples/01-voltage-divider.cir
ohm Examples/02-rc-lowpass.cir -f json
ohm monte-carlo Examples/07-project-bundle.ohmlabproj --probe 'v(2)' --default-tol 5%
ohm platform run --pretty < Examples/portable-divider-request.json
```

## Checking them

The `@check` directives are verified by `ExampleCircuitsTests` in
`Tests/OhmLabTests/ExampleCircuitsTests.swift`, so a normal `swift test` proves
every example:

```sh
swift test --filter ExampleCircuitsTests
```

For a full health check of the whole codebase (build, unit tests, examples,
portable protocol, and CLI smoke tests), run:

```sh
scripts/health-check.sh
```

## Directive format

Directives live in `*` comment lines and are ignored by the netlist parser:

```
* @analysis dc|ac|tran
* @check dc   <probe> = <value> [tol=<abs>] [rel=<rel>]
* @check ac   <probe> mag_db|mag|phase_deg @ <freq> = <value> [rel=<rel>]
* @check tran <probe> @ <time> = <value> [rel=<rel>]
```

`<probe>` is `v(node)`, `i(element)`, or `vi(element)`, and numbers accept SPICE
suffixes (`5m`, `1k`, `100n`). The default tolerance is `rel=1e-3`.
