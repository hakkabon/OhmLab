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

## Additive model-depth fields (3.3)

OhmLab 3.3 adds optional device-model fields without changing
`schemaVersion: 1`:

- diode `junctionCapacitance`, `junctionPotential`, `gradingCoefficient`, and
  `transitTime` (`CJO`, `VJ`, `M`, `TT`);
- BJT `forwardEarlyVoltage`, `reverseEarlyVoltage`, the base-emitter and
  base-collector capacitances and potentials/gradings, and the forward/reverse
  transit times (`VAF`, `VAR`, `CJE`, `CJC`, `VJE`, `VJC`, `MJE`, `MJC`, `TF`,
  `TR`);
- MOSFET `gateSourceOverlapCapacitance`, `gateDrainOverlapCapacitance`,
  `gateBulkOverlapCapacitance`, `bulkDrainCapacitance`, and
  `bulkSourceCapacitance` (`CGSO`, `CGDO`, `CGBO`, `CBD`, `CBS`);
- JFET `gateSourceCapacitance` and `gateDrainCapacitance` (`CGS`, `CGD`);
- an optional top-level `nodeSet` map of `.nodeset` starting hints.

All of these are omitted from the encoding when they carry their historical
default, so a v1 document that does not use them is byte-stable. A decoder
that predates them ignores the optional keys; a backend that does not
implement them must fail closed rather than silently dropping the values.
