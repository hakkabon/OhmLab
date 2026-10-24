# OhmLab linear backend graduation contract v1

OhmLab 1.2 introduces a scoped `linear-production` maturity. It is narrower
than full production: it promises DC operating point, AC small-signal, and
transient analysis for linear R/C/L/V/I circuits through SPICE netlist and
Circuit IR inputs, including source waveforms and initial conditions.

`numeric-core` is the required linear-production backend. Its implementation
version identifies both the pinned Swift-NumericCore revision and the bundled
Rust-NumericCore release. Native MNA remains the default and the only backend
qualified for the complete nonlinear and advanced-analysis surface.

`ohm qualify-linear --json` is the executable graduation report. A backend
graduates only when all of these conditions hold:

- its capability and maturity declarations satisfy the linear-production
  minimum;
- it passes the complete numerical-trust v1 analytical DC/AC corpus; and
- it passes at least six analytical RC transient cases spanning component
  decades, with explicit expected values, actual values, and tolerances.

The qualification domain intentionally excludes extreme time grids beneath the
supported integrator floor. The v1 transient cases use a 1 ms time constant,
200 requested intervals, resistances from 100 ohms through 100 kohms, and the
closed-form capacitor discharge value `exp(-1)` at one time constant.

The standalone `rust/ohm-core` backend is deprecated in 1.2. It remains linked
and covered by compatibility tests for this release, but new integrations must
select `numeric-core`, which reaches Rust-NumericCore through Swift-NumericCore.
The standalone backend is scheduled for removal in OhmLab 1.3.0.

The graduation report has its own contract version. Changes to maturity
semantics, required backend identity, or pass/fail criteria require a new
version. Adding cases within the declared domain is compatible.
