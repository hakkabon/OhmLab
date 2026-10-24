//! Versioned Circuit IR transport shared with OhmLab's Swift engine facade.

use super::{AcDirective, Circuit, Cplx, Element, SweepType};
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet};

pub const TRANSPORT_VERSION: u32 = 1;
pub const CIRCUIT_SCHEMA_VERSION: u32 = 1;
pub const RESULT_CONTRACT_VERSION: u32 = 1;
const MAX_TRANSPORT_BYTES: usize = 64 * 1024 * 1024;
const MAX_CIRCUIT_ITEMS: usize = 200_000;
const MAX_AC_POINTS: usize = 200_000;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    transport_version: u32,
    circuit: CircuitIr,
    analysis: Analysis,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Analysis {
    #[serde(rename = "runDC")]
    run_dc: bool,
    ac: Option<AcSweep>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AcSweep {
    sweep_type: String,
    start_frequency: f64,
    stop_frequency: f64,
    point_count: usize,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CircuitIr {
    schema_version: u32,
    reference_node: usize,
    nodes: Vec<Node>,
    devices: Vec<Device>,
    solver: SolverConfiguration,
    initial_conditions: InitialConditions,
}

#[derive(Debug, Deserialize)]
struct Node {
    name: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Device {
    name: String,
    kind: String,
    terminals: Vec<usize>,
    value: Option<f64>,
    source: Option<Source>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Source {
    dc_value: f64,
    ac_magnitude: f64,
    ac_phase_degrees: f64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SolverConfiguration {
    relative_tolerance: f64,
    absolute_current_tolerance: f64,
    absolute_voltage_tolerance: f64,
    minimum_conductance: f64,
    maximum_iterations: usize,
    temperature_celsius: f64,
    nominal_temperature_celsius: f64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InitialConditions {
    node_voltages: BTreeMap<String, f64>,
    element_currents: BTreeMap<String, f64>,
}

impl Request {
    pub fn decode(json: &str) -> Result<Self, String> {
        if json.len() > MAX_TRANSPORT_BYTES {
            return Err("circuit transport request exceeds 64 MiB".into());
        }
        let request: Self = serde_json::from_str(json)
            .map_err(|error| format!("invalid circuit transport JSON: {error}"))?;
        request.validate()?;
        Ok(request)
    }

    pub fn run_dc(&self) -> bool {
        self.analysis.run_dc
    }

    pub fn into_circuit(self) -> Result<Circuit, String> {
        let node_names = self
            .circuit
            .nodes
            .iter()
            .map(|node| node.name.clone())
            .collect::<Vec<_>>();
        let mut elements = Vec::with_capacity(self.circuit.devices.len());
        for device in self.circuit.devices {
            let a = node_names[device.terminals[0]].clone();
            let b = node_names[device.terminals[1]].clone();
            let element = match device.kind.as_str() {
                "resistor" => Element::Resistor {
                    name: device.name,
                    a,
                    b,
                    value: device.value.expect("validated resistor value"),
                },
                "capacitor" => Element::Capacitor {
                    name: device.name,
                    a,
                    b,
                    value: device.value.expect("validated capacitor value"),
                },
                "inductor" => Element::Inductor {
                    name: device.name,
                    a,
                    b,
                    value: device.value.expect("validated inductor value"),
                },
                "voltage-source" | "current-source" => {
                    let source = device.source.expect("validated source");
                    let ac = Cplx::from_polar(source.ac_magnitude, source.ac_phase_degrees);
                    if device.kind == "voltage-source" {
                        Element::VoltageSource {
                            name: device.name,
                            a,
                            b,
                            dc: source.dc_value,
                            ac,
                        }
                    } else {
                        Element::CurrentSource {
                            name: device.name,
                            a,
                            b,
                            dc: source.dc_value,
                            ac,
                        }
                    }
                }
                _ => unreachable!("unsupported devices are rejected during validation"),
            };
            elements.push(element);
        }
        let ac = self.analysis.ac.map(|sweep| AcDirective {
            sweep: match sweep.sweep_type.as_str() {
                "dec" => SweepType::Decade,
                "oct" => SweepType::Octave,
                "lin" => SweepType::Linear,
                _ => unreachable!("validated sweep type"),
            },
            points: sweep.point_count,
            start: sweep.start_frequency,
            stop: sweep.stop_frequency,
        });
        Ok(Circuit {
            elements,
            ac,
            warnings: Vec::new(),
            node_order: Some(node_names),
        })
    }

    fn validate(&self) -> Result<(), String> {
        if self.transport_version != TRANSPORT_VERSION {
            return Err(format!(
                "unsupported circuit transport version {}",
                self.transport_version
            ));
        }
        if self.circuit.schema_version != CIRCUIT_SCHEMA_VERSION {
            return Err(format!(
                "unsupported Circuit IR schema version {}",
                self.circuit.schema_version
            ));
        }
        if self.circuit.reference_node != 0
            || self.circuit.nodes.first().map(|node| node.name.as_str()) != Some("0")
        {
            return Err("Circuit IR reference node must be node 0 named `0`".into());
        }
        if self.circuit.nodes.is_empty() {
            return Err("Circuit IR contains no nodes".into());
        }
        if self.circuit.nodes.len() > MAX_CIRCUIT_ITEMS
            || self.circuit.devices.len() > MAX_CIRCUIT_ITEMS
        {
            return Err("Circuit IR exceeds the 200,000-item limit".into());
        }
        let solver = &self.circuit.solver;
        if ![
            solver.relative_tolerance,
            solver.absolute_current_tolerance,
            solver.absolute_voltage_tolerance,
            solver.minimum_conductance,
            solver.temperature_celsius,
            solver.nominal_temperature_celsius,
        ]
        .iter()
        .all(|value| value.is_finite())
            || solver.relative_tolerance <= 0.0
            || solver.absolute_current_tolerance <= 0.0
            || solver.absolute_voltage_tolerance <= 0.0
            || solver.minimum_conductance <= 0.0
            || solver.maximum_iterations == 0
            || solver.temperature_celsius <= -273.15
            || solver.nominal_temperature_celsius <= -273.15
        {
            return Err("Circuit IR solver configuration is invalid".into());
        }
        let node_keys = self
            .circuit
            .nodes
            .iter()
            .map(|node| node.name.to_lowercase())
            .collect::<BTreeSet<_>>();
        if node_keys.len() != self.circuit.nodes.len()
            || self.circuit.nodes.iter().any(|node| node.name.is_empty())
        {
            return Err("Circuit IR node names must be non-empty and unique".into());
        }
        let device_keys = self
            .circuit
            .devices
            .iter()
            .map(|device| device.name.to_lowercase())
            .collect::<BTreeSet<_>>();
        if device_keys.len() != self.circuit.devices.len()
            || self
                .circuit
                .devices
                .iter()
                .any(|device| device.name.is_empty())
        {
            return Err("Circuit IR device names must be non-empty and unique".into());
        }
        for device in &self.circuit.devices {
            if device.terminals.len() != 2
                || device
                    .terminals
                    .iter()
                    .any(|index| *index >= self.circuit.nodes.len())
            {
                return Err(format!("device {} has invalid terminals", device.name));
            }
            match device.kind.as_str() {
                "resistor" | "capacitor" | "inductor" => {
                    if !device
                        .value
                        .is_some_and(|value| value.is_finite() && value > 0.0)
                    {
                        return Err(format!(
                            "device {} requires a positive finite value",
                            device.name
                        ));
                    }
                }
                "voltage-source" | "current-source" => {
                    let Some(source) = &device.source else {
                        return Err(format!("device {} has no source data", device.name));
                    };
                    if !source.dc_value.is_finite()
                        || !source.ac_magnitude.is_finite()
                        || !source.ac_phase_degrees.is_finite()
                    {
                        return Err(format!("device {} has non-finite source data", device.name));
                    }
                }
                _ => {
                    return Err(format!(
                        "device {} uses unsupported kind {}",
                        device.name, device.kind
                    ))
                }
            }
        }
        if self
            .circuit
            .initial_conditions
            .node_voltages
            .iter()
            .any(|(name, value)| !node_keys.contains(&name.to_lowercase()) || !value.is_finite())
            || self
                .circuit
                .initial_conditions
                .element_currents
                .iter()
                .any(|(name, value)| {
                    !device_keys.contains(&name.to_lowercase()) || !value.is_finite()
                })
        {
            return Err(
                "Circuit IR initial conditions reference an unknown name or non-finite value"
                    .into(),
            );
        }
        if !self.analysis.run_dc && self.analysis.ac.is_none() {
            return Err("the transport request selects no analysis".into());
        }
        if let Some(ac) = &self.analysis.ac {
            if !matches!(ac.sweep_type.as_str(), "dec" | "oct" | "lin")
                || !ac.start_frequency.is_finite()
                || !ac.stop_frequency.is_finite()
                || ac.start_frequency <= 0.0
                || ac.stop_frequency <= ac.start_frequency
                || ac.point_count == 0
            {
                return Err("invalid AC sweep configuration".into());
            }
            let generated = match ac.sweep_type.as_str() {
                "lin" => ac.point_count,
                "oct" => {
                    ((ac.stop_frequency / ac.start_frequency).log2() * ac.point_count as f64).ceil()
                        as usize
                        + 2
                }
                _ => {
                    ((ac.stop_frequency / ac.start_frequency).log10() * ac.point_count as f64)
                        .ceil() as usize
                        + 2
                }
            };
            if generated > MAX_AC_POINTS {
                return Err("AC sweep exceeds the 200,000-point limit".into());
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::{CStr, CString};

    const DIVIDER: &str = r#"{
        "transportVersion": 1,
        "analysis": {"runDC": true, "ac": null},
        "circuit": {
            "schemaVersion": 1,
            "referenceNode": 0,
            "nodes": [{"name":"0"},{"name":"in"},{"name":"out"}],
            "devices": [
                {"name":"V1","kind":"voltage-source","terminals":[1,0],"value":null,
                 "source":{"dcValue":5.0,"acMagnitude":0.0,"acPhaseDegrees":0.0,"transient":null},
                 "diode":null,"bjt":null,"mosfet":null,"jfet":null},
                {"name":"R1","kind":"resistor","terminals":[1,2],"value":1000.0,
                 "source":null,"diode":null,"bjt":null,"mosfet":null,"jfet":null},
                {"name":"R2","kind":"resistor","terminals":[2,0],"value":1000.0,
                 "source":null,"diode":null,"bjt":null,"mosfet":null,"jfet":null}
            ],
            "solver": {"relativeTolerance":0.001,"absoluteCurrentTolerance":1e-12,
                "absoluteVoltageTolerance":1e-6,"minimumConductance":1e-12,
                "maximumIterations":100,"temperatureCelsius":27.0,
                "nominalTemperatureCelsius":27.0},
            "initialConditions":{"nodeVoltages":{},"elementCurrents":{}}
        }
    }"#;

    #[test]
    fn decodes_and_solves_swift_circuit_ir_envelope() {
        let request = Request::decode(DIVIDER).expect("transport request");
        let run_dc = request.run_dc();
        let circuit = request.into_circuit().expect("circuit");
        let json =
            super::super::solve_to_json_selected(&circuit, run_dc, false, Some(TRANSPORT_VERSION))
                .0;
        assert!(json.contains("\"transportVersion\":1"));
        assert!(json.contains("\"contractVersion\":1"));
        assert!(json.contains("\"name\":\"out\",\"voltage\":2.5"));
        assert!(json.contains("\"errors\":[]"));
    }

    #[test]
    fn rejects_future_schema_and_unsupported_device_atomically() {
        let future = DIVIDER.replace("\"schemaVersion\": 1", "\"schemaVersion\": 2");
        assert!(Request::decode(&future)
            .unwrap_err()
            .contains("schema version 2"));
        let nonlinear = DIVIDER.replace("\"kind\":\"resistor\"", "\"kind\":\"diode\"");
        assert!(Request::decode(&nonlinear)
            .unwrap_err()
            .contains("unsupported kind diode"));
    }

    #[test]
    fn c_abi_returns_owned_versioned_result() {
        let request = CString::new(DIVIDER).expect("request CString");
        let mut output = std::ptr::null_mut();
        let status = unsafe { super::super::ohm_solve_circuit_ir(request.as_ptr(), &mut output) };
        assert_eq!(status, 0);
        assert!(!output.is_null());
        let result = unsafe { CStr::from_ptr(output) }
            .to_str()
            .expect("UTF-8 result")
            .to_owned();
        unsafe { super::super::ohm_free_string(output) };
        assert!(result.contains("\"transportVersion\":1"));
        assert!(result.contains("\"name\":\"out\",\"voltage\":2.5"));
    }
}
