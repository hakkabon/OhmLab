# Simulation result contract v1

Every `SimulationEngineBackend` returns `CircuitSimResult` contract version 1.
The engine facade validates the result before plugins or UI code receive it.

## Units and signs

- Node voltage is measured relative to reference node `0`, in volts.
- A component voltage is `V(terminal[0]) - V(terminal[1])`, in volts.
- Component current is positive when entering `terminal[0]`, in amperes.
- Voltage-source and inductor branch currents use the same terminal convention.
- AC magnitude is `20 log10(abs(quantity) / 1 unit)` in dB.
- AC phase is in degrees; frequency is in hertz.
- Transient time is in seconds. Sweep coordinates retain the SI unit of the
  swept source or parameter.

## Structural requirements

- Names are non-empty and unique case-insensitively within each result group.
- Axes are finite and strictly increasing.
- Every series has exactly the same number of samples as its axis.
- Numerical values are finite. A backend must throw a diagnostic error rather
  than use NaN or infinity to signal failure.
- Unsupported analyses and devices must fail explicitly; a backend must not
  return a successful partial result without a caller-visible warning.

The runtime definitions and validator live in `EngineContract.swift`.
