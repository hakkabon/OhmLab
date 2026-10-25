# OhmLab production boundary v5

Production boundary v5 adds the OhmLab 2.1 extracted simulation-host contract
without changing Circuit IR v1, portable simulation v1, or simulation-result
v1.

A release is ready only when all earlier numerical and portable qualifications
pass and `ohm qualify-host --json` reports `ready: true`. The release package
must expose the Foundation-only protocol product, the host-runtime product,
and the batch v1 JSON Schema.

The legacy `OhmLabSimulationPlatform` product remains available throughout the
2.x compatibility window. Its removal is not authorized by this contract.
