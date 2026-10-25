# OhmLab production boundary v8

Production boundary v8 adds scale-and-numerical-robustness contract v1 and
advances native Rust portability to v3. Existing Circuit IR, result,
capability, portable-protocol, simulation-host, and NumericCore feature-
completion versions remain unchanged.

An OhmLab 2.4 release must scale NumericCore variables and equations, certify
unscaled physical residuals, and reject models above 512 dense MNA unknowns
before solving on both the Swift and native Rust paths. The Swift
`qualify-scale` report and ten-case native Rust qualification are mandatory
release evidence.

This boundary does not claim sparse-matrix scalability. Native MNA remains the
default and sole full-production backend; Swift-NumericCore remains the sole
scoped nonlinear-production backend; the Rust host remains an external
portable-protocol implementation.
