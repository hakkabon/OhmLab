# OhmLab scale and numerical robustness contract v1

Contract v1 qualifies the Swift-NumericCore adapter and process-native
Rust-NumericCore host for numerically mixed-scale circuit execution.

Before nonlinear iteration, implementations derive finite positive voltage and
current scales from independent sources, initial conditions, passive devices,
and solver tolerances. Node-voltage and branch-current unknowns use those
scales; KCL rows use current scale and voltage-constraint rows use voltage
scale. Scaling is internal and never changes reported physical units.

Every published operating point must have a converged termination, finite
state and diagnostics, and finite unscaled residuals. KCL residuals must not
exceed `abstol + reltol * currentScale`; voltage-constraint residuals must not
exceed `vntol + reltol * voltageScale`. A violation fails closed instead of
returning a plausible-looking result. Every DC-sweep point is certified and a
certified point may warm-start only the next point.

The current NumericCore matrix backend is dense. Its qualified ceiling is 512
MNA unknowns, including non-reference node voltages and voltage-source or
inductor branch currents. Requests above that ceiling must be rejected before
the solve. Protocol-wide node and device ceilings are transport safety limits,
not evidence of sparse-solver scalability.

`ohm qualify-scale --json` is the executable release evidence. It covers
mixed-impedance and high-impedance dividers, a 128-section ladder, a 101-point
mixed-scale sweep, singular failure, and deterministic dense-budget rejection.
