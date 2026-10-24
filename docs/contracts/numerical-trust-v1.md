# OhmLab numerical trust contract v1

OhmLab 1.1 adds an executable numerical qualification layer without changing
Circuit IR v1 or simulation-result contract v1. `ohm verify --json` is the
canonical report.

The v1 corpus contains 32 deterministic analytical cases generated from a
reported 64-bit seed:

- 24 resistive DC dividers spanning source voltage and resistance decades.
- 8 RC low-pass AC cases spanning resistance, capacitance, frequency, and
  operation both below and above cutoff.

Expected values are calculated from closed-form equations, not from another
OhmLab backend. Every linked backend declaring Circuit IR, DC, and AC support
is exercised directly. Native MNA and Swift-NumericCore are required; the Rust
backend becomes required whenever it is linked.

Swift-NumericCore remains pinned to an exact reviewed revision while its
circuit API is provisional. That revision is part of the backend's reported
implementation version, and any revision change must pass this complete gate.

Each backend/case result records expected and actual measurements, absolute
error, tolerance, pass/fail state, any structured error description, and
elapsed wall-clock time. Timing is diagnostic and does not determine pass/fail.
The seed makes the sampled values reproducible; changing it creates another
deterministic qualification corpus.

A report is trusted only when:

- it contains at least 32 cases;
- every required backend is present; and
- every measurement from every required backend meets its declared absolute
  plus relative tolerance.

The numerical-trust contract has its own version. Changing its report meaning,
qualification rules, or tolerance semantics requires a new version; extending
the v1 corpus with additional cases is compatible.
