# OhmLab nonlinear convergence contract v1

OhmLab 1.5 graduates the NumericCore adapter to a scoped
`nonlinear-production` maturity. The promise covers Shockley diodes and
body-tied N-channel Level-1 MOSFETs with zero body-effect coefficient in DC
operating-point, AC small-signal, and transient analyses at nominal
temperature. Linear R/C/L/V/I support from linear-backend-graduation v1 remains
part of the minimum.

`ohm qualify-nonlinear --json` is the executable evidence. It independently
solves seven circuits with native MNA and Swift-NumericCore/Rust-NumericCore:

- forward- and reverse-biased diode DC, including current;
- diode AC linearization and pulse transient;
- NMOS DC bias, including drain current;
- NMOS AC linearization and pulse transient.

Every result must satisfy simulation-result contract v1 and every measured
voltage, current, magnitude, phase, and final transient sample must remain
within its published tolerance. The report records implementation identity,
scope, expected/actual values, errors, and pass/fail verdicts.

BJT, JFET, PMOS, non-body-tied or body-effect MOSFETs, non-nominal nonlinear
temperature operation, sweeps, and Fourier analysis are outside v1 and fail
closed in NumericCore. Native MNA remains the full-production default for those
features. Expanding this device promise requires a new scope/qualification
contract rather than silently broadening the v1 claim.
