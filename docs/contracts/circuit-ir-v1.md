# OhmLab Circuit IR v1

Circuit IR is the versioned boundary between OhmLab's frontends and numerical
backends. Schematics and SPICE are input languages; neither is the solver ABI.

The canonical Swift representation is `CircuitIR`. Its JSON form uses
`schemaVersion: 1` and is rejected when the version, topology, model, waveform,
or numerical configuration is invalid. Version 1 establishes these rules:

- Node index `0`, named `0`, is the reference node.
- Device names and node names are non-empty and unique case-insensitively.
- Two-terminal ordering is positive/anode, then negative/cathode.
- BJT terminals are collector/base/emitter.
- MOSFET terminals are drain/gate/source/bulk.
- JFET terminals are drain/gate/source.
- Source DC and AC values are separate; AC phase is in degrees.
- All stored quantities use SI units: ohms, farads, henries, volts, amperes,
  seconds, hertz, siemens, and degrees Celsius where explicitly named.
- Initial conditions and solver controls are part of the IR so a backend does
  not silently substitute its own defaults.

`CircuitIRCompiler` is the SPICE-to-IR entry point. `CircuitIR` can also be
created directly from OhmLab's compiled schematic circuit. Backends should
prefer the IR entry point and fail explicitly for unsupported device or
analysis capabilities.

An incompatible wire-format change requires `schemaVersion: 2`. Additive
fields may be introduced in v1 only when old decoders have a documented,
unambiguous default.
