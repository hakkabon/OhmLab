# OhmLab NumericCore feature-completion contract v1

OhmLab 2.3 completes the analysis surface shared by the portable protocol,
Swift-NumericCore 1.1.0, and the native Rust-NumericCore 0.34.0 host. Both
NumericCore entry points execute:

- DC operating points;
- AC small-signal sweeps;
- adaptive DAE transient analysis sampled on the requested output grid; and
- one-dimensional sweeps of an independent voltage or current source.

Transient execution preserves Circuit IR node-voltage and branch-current
initial conditions. Qualified source waveforms are `PULSE` and undelayed,
undamped `SIN`. DC sweeps are case-insensitive by source name, include the
requested endpoint, and fail before execution if the target is not an
independent source.

The device boundary remains R/C/L/V/I, Shockley diodes at nominal temperature,
and body-tied zero-body-effect Level-1 NMOS. Parameter and multidimensional
sweeps, Fourier extraction, PWL sources, BJT, JFET, PMOS, body-effect MOSFETs,
and non-nominal nonlinear temperature models remain outside this contract and
fail explicitly.

`scripts/qualify-rust-host.sh` is the executable cross-host evidence. It checks
the native manifest and eight-case self-qualification report, then compares
Swift-NumericCore and native Rust DC, AC, transient, and DC-sweep results.

