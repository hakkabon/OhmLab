# Rust circuit transport v1

Rust circuit transport is the ABI envelope between OhmLab's Swift engine
facade and a Rust numerical backend. It carries normalized Circuit IR rather
than SPICE text, so parsing, model resolution, and schematic lowering remain
frontend responsibilities.

The JSON request contains three independently versioned pieces:

- `transportVersion: 1` identifies this envelope.
- `circuit.schemaVersion: 1` identifies Circuit IR.
- the response `contractVersion: 1` identifies the simulation-result contract.

The `analysis` object contains `runDC` and an optional AC sweep. Its sweep type
is `dec`, `oct`, or `lin`; frequencies are in hertz. Circuit values and source
data use the units and terminal ordering defined by Circuit IR v1.

The Rust decoder validates the envelope, Circuit IR topology, solver controls,
initial-condition references, device values, and analysis settings before it
constructs a solver model. Version 1 accepts only linear R/C/L/V/I devices.
Unsupported or malformed input produces a result envelope with a non-empty
`errors` array and no caller-visible partial result.

The response also contains the Rust engine identifier, warnings, and the DC/AC
sections from simulation-result contract v1. Swift checks all three version
numbers and validates the result before plugins or UI code can observe it.

## ABI

`ohm_solve_circuit_ir(const char *request_json, char **out_json)` accepts UTF-8
JSON and returns an owned UTF-8 JSON response. The caller releases the response
with `ohm_free_string`. Status codes are reserved for ABI failures such as null
pointers, invalid UTF-8, or inability to allocate a C string; model and solver
failures are represented structurally in `errors`.

`ohm_solve` remains available for compatibility with existing netlist clients,
but OhmLab's Rust backend does not use it internally.
