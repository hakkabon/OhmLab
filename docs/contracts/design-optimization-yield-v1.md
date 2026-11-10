# OhmLab design optimization and yield v1

Design optimization and yield v1 describes the analysis-aware metrics and
yield centring added in OhmLab 3.4. It is an analysis and front-end contract,
not a new production boundary, Circuit IR schema, result-contract, or
portable-protocol version.

## Scope

The optimiser in 3.3 accepted a DC probe (`CircuitProbe`) and a goal, searched
a coarse grid over named component ranges, and refined the best point with
Nelder–Mead. That covers operating-point objectives but not the AC and
transient behaviour design work usually cares about, and it has no notion of
component variation.

OhmLab 3.4 adds:

- an `OptimizeMetric` that reads a DC probe, an AC magnitude/dB/phase at a
  frequency, or a transient value at a time;
- `MetricLimit` bands that turn metrics into design specifications;
- a `YieldSpecification` that draws component and temperature tolerances and
  estimates the fraction of trials that satisfy every limit;
- a deterministic yield refinement that centres a nominal optimum on those
  limits.

A 3.4 optimisation request that supplies only a `CircuitProbe` objective
produces the same result as 3.3.

## Metric syntax

Metric text is stable and round-trips through `OptimizeMetric.parse` and
`OptimizeMetric.description`.

| Text | Reads |
| --- | --- |
| `v(out)` | DC node voltage |
| `i(R1)` | DC element current |
| `vi(R1)` | DC element voltage |
| `ac:v(out)@1k` | linear AC magnitude at 1 kHz |
| `acdb:v(out)@1k` | AC magnitude in dB at 1 kHz |
| `acph:v(out)@1k` | AC phase in degrees at 1 kHz |
| `tran:v(out)@1m` | transient value at 1 ms |

`ac`, `acdb`, and `acph` also accept an element current such as `ac:i(C1)@1k`.
`tran` accepts a node voltage or an element current. Coordinates use the SPICE
numeric literals accepted by `SpiceNumber` (`1k`, `1meg`, `1m`, `1e-3`, …).
Frequencies must be positive; transient times must be non-negative.

### Reading and interpolation

- **DC** reads the solved operating point directly. `vi(...)` is supported
  because the DC result carries both element voltage and current.
- **AC** finds the named node or component series and interpolates linearly in
  log-frequency. At an exact sweep point the solved value is returned.
  Magnitude is exposed as `10^(dB/20)`, dB as the solved value, and phase is
  interpolated across the shortest angular arc.
- **Transient** finds the named node or component series and interpolates
  linearly in time.

AC and transient results carry element current only, so `ac:vi(...)` and
`tran:vi(...)` are rejected. An AC frequency outside
`acStartFrequency...acStopFrequency`, or a transient time outside
`tranStart...tranStop`, is rejected before solving with
`AnalysisError.metricOutOfRange`. A malformed or unsupported coordinate is
rejected with `AnalysisError.invalidMetric`.

The optimiser enables exactly the analyses its metric needs: DC is always on,
and AC or transient is enabled for an AC or transient metric.

## Design limits and yield

A `MetricLimit` holds a metric plus optional minimum and maximum bounds. A
metric whose value cannot be read counts as a failure for that limit.

A `YieldSpecification` holds:

| Field | Default | Meaning |
| --- | --- | --- |
| `tolerances` | `[]` | per-designator relative/absolute tolerance, `normal` or `uniform` |
| `defaultTolerance` | `nil` | tolerance for every unlisted passive |
| `samples` | `64` | Monte Carlo draws per yield estimate |
| `seed` | `1` | deterministic generator seed |
| `temperature` | `nil` | nominal ambient temperature (°C) |
| `temperatureTolerance` | `nil` | ± ambient temperature tolerance (°C) |
| `limits` | `[]` | specifications every trial must satisfy |
| `refine` | `true` | refine the nominal optimum for yield |
| `gridDivisions` | `5` | coarse seed divisions per variable |
| `maxPasses` | `6` | coordinate pattern-search passes |

### Estimation semantics

Yield estimation reuses `MonteCarloAnalysis.resolveVariables`: explicit
tolerances are matched to editable devices case-insensitively, unknown
designators produce a warning and are ignored, and a default tolerance covers
every passive without an explicit one. Candidate component values are the
nominal values after the optimiser rewrites the design variables.

For each of `samples` trials the estimator draws every toleranced device in
sorted designator order, rewrites the netlist, optionally applies an ambient
temperature draw, and solves once with the analyses the metrics require. A
trial that fails to solve, or whose metric cannot be read, counts as a yield
loss. `YieldReport.overallYield` is the number of trials satisfying every limit
divided by `samples`, not by the number of successfully solved trials.

Each limit statistic reports the mean, minimum, maximum, and pass fraction over
`tolerances` × `samples`. A limit's minimum and maximum are `NaN` when no trial
produced a readable value.

### Common random numbers and determinism

The same seed is used for every candidate. Because draws are consumed in the
same sorted order, two candidates see the same tolerance perturbations, so
their yield estimates are directly comparable. Repeating an estimate with the
same netlist, values, seed, and specification produces an exactly equal
`YieldReport`.

### Refinement

When `refine` is true and the nominal optimum's yield is below 1, the
optimiser:

1. evaluates the nominal optimum;
2. evaluates the range midpoint;
3. evaluates a bounded coarse grid whose point count does not exceed
   `Optimization.maxYieldSeedPoints` (32), reducing `gridDivisions` until it
   fits;
4. repeatedly tries ± one step on each variable, halving the step after each
   pass until the step falls below `1e-4` of the range or `maxPasses` is
   reached.

Every candidate is clamped to the variable's declared range and scored with
the same seed. The search keeps the candidate with the highest overall yield
and stops early at 100 %. The returned design therefore never has a lower
yield than the nominal optimum. When refinement is disabled, or makes no
improvement, the returned design is the nominal optimum.

The final design is re-solved at its nominal values for the reported
`bestObjective`; that evaluation uses the metric's own analysis, not the
tolerance draws.

## Errors

| Error | Condition |
| --- | --- |
| `AnalysisError.noObjective` | neither `metric` nor `objective` was supplied |
| `AnalysisError.noVariables` | no optimization variables were supplied |
| `AnalysisError.unknownVariable` | a variable names no editable device |
| `AnalysisError.invalidRange` | a variable range is empty or inverted |
| `AnalysisError.noYieldLimits` | yield estimation has no limits |
| `AnalysisError.invalidYieldSamples` | `samples < 1` |
| `AnalysisError.invalidMetric` | a metric the result contract cannot represent |
| `AnalysisError.metricOutOfRange` | a metric outside the configured sweep |

## Guarantees and evidence

`Tests/OhmLabTests/DesignOptimizationYieldTests.swift` proves:

- metric text parses and round-trips for every supported form;
- malformed coordinates, zero/negative frequencies, and `vi(...)` AC/transient
  metrics are rejected;
- DC, AC magnitude/dB/phase, and transient values match their analytic
  expectations;
- an AC target optimization recovers the analytic RC design value;
- a transient target optimization recovers the analytic RC design value;
- a request with no objective fails with `noObjective`;
- yield estimates are equal across repeated runs with the same seed, use every
  requested trial, and keep per-limit fractions in `[0, 1]`;
- yield refinement moves an off-target design toward the specification and
  never reports a lower yield than the nominal optimum;
- missing limits and non-positive sample counts fail closed.

The existing DC optimiser, Monte Carlo, corner, example-circuit, portable, and
release suites continue to run unchanged.

## Non-claims

This contract does **not**:

- change production boundary v8, Circuit IR v1, the result contract, or any
  capability, convergence, or portability version;
- add AC/transient metric support to `MonteCarloAnalysis` or `CornerAnalysis`;
  those remain DC-probe analyses;
- add element-voltage probes to AC or transient results;
- model manufacturing distributions beyond independent per-component
  tolerance draws, nor claim that an estimated yield is a production yield;
- handle correlated tolerances, lot-to-lot variation, or per-trial model-card
  variation;
- change the NumericCore, portable-platform, or native Rust host device surface;
- promise a global optimum. Both the initial grid/Nelder–Mead search and the
  coordinate pattern search are deterministic local searches over the declared
  ranges.
