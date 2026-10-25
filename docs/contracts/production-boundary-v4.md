# OhmLab production boundary v4

OhmLab 2.0 advances the product boundary to v4 and adds portable-simulation
protocol v1. Circuit IR, simulation-result, capability, numerical-trust,
linear-graduation, nonlinear-convergence, and nonlinear-scope contracts retain
their version-one semantics.

Boundary v4 requires:

- a deterministic portable request/response representation;
- discovery of every production-qualified backend without mutating global
  engine selection;
- bounded input and explicit validation before execution;
- protocol-shaped, fail-closed errors rather than partial output; and
- executable qualification through `ohm qualify-platform --json`.

Native MNA remains the default and sole full-production backend. NumericCore
remains the sole scoped linear/nonlinear-production backend. Both are available
through portable protocol v1 according to their declared capabilities.

`ohm doctor`, `ohm verify`, `ohm qualify-linear`, `ohm qualify-nonlinear`, and
`ohm qualify-platform` must all report ready for a 2.0 release.
