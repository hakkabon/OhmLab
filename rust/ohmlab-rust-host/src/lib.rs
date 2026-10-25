use nc_optimize::{
    consistent_dae_initial_conditions, CircuitAcExcitation, CircuitDevice, CircuitModel,
    CircuitNode, CircuitOperatingPoint, CircuitSource, CircuitWaveform, NonlinearSystemOptions,
    NonlinearSystemTermination, TimeIntegrationOptions, TimeIntegrationTermination,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};

pub const PRODUCT_VERSION: &str = "2.4.0";
pub const IMPLEMENTATION_VERSION: &str = "rust-numeric-core-0.34.0-native.3";
pub const BACKEND: &str = "rust-numeric-core";
pub const PROTOCOL_VERSION: u32 = 1;
pub const HOST_CONTRACT_VERSION: u32 = 3;
pub const MEDIA_TYPE: &str = "application/vnd.ohmlab.simulation+json;version=1";
const MAX_REQUEST_BYTES: usize = 16 * 1024 * 1024;
const MAX_NODES: usize = 100_000;
const MAX_DEVICES: usize = 200_000;
const MAX_SAMPLES: usize = 100_000;
const MAX_PROJECTED_VALUES: usize = 2_000_000;
const MAX_DENSE_UNKNOWNS: usize = 512;

pub struct Execution {
    pub json: String,
    pub succeeded: bool,
}

pub fn manifest_json() -> String {
    serde_json::to_string(&json!({
        "backend": BACKEND,
        "canonicalEncoding": "json-sorted-keys-utf8",
        "circuitIRVersion": 1,
        "devices": ["capacitor", "current-source", "diode", "inductor", "mosfet", "resistor", "voltage-source"],
        "hostContractVersion": HOST_CONTRACT_VERSION,
        "implementationVersion": IMPLEMENTATION_VERSION,
        "mediaType": MEDIA_TYPE,
        "maximumDenseUnknowns": MAX_DENSE_UNKNOWNS,
        "nativeRust": true,
        "productVersion": PRODUCT_VERSION,
        "protocolVersion": PROTOCOL_VERSION,
        "rustNumericCoreVersion": "0.34.0",
        "simulationResultVersion": 1,
        "supportedAnalyses": ["ac-small-signal", "dc-operating-point", "dc-sweep", "transient"],
        "supportedFeatures": ["circuit-ir-input", "initial-conditions", "source-waveforms"]
    })).expect("static manifest is serializable")
}

pub fn qualification_json() -> Execution {
    let dc = execute(&divider_request(false));
    let ac = execute(&divider_request(true));
    let diode = execute(&nonlinear_request(true));
    let nmos = execute(&nonlinear_request(false));
    let transient = execute(&transient_request());
    let sweep = execute(&sweep_request());
    let scaled = execute(&scaled_request());
    let over_budget = execute(&over_budget_request());
    let malformed = execute(br#"{"protocolVersion":1,"unexpected":true}"#);
    let manifest: Value = serde_json::from_str(&manifest_json()).expect("manifest is JSON");
    let dc_json: Value = serde_json::from_str(&dc.json).expect("response is JSON");
    let ac_json: Value = serde_json::from_str(&ac.json).expect("response is JSON");
    let diode_json: Value = serde_json::from_str(&diode.json).expect("response is JSON");
    let nmos_json: Value = serde_json::from_str(&nmos.json).expect("response is JSON");
    let transient_json: Value = serde_json::from_str(&transient.json).expect("response is JSON");
    let sweep_json: Value = serde_json::from_str(&sweep.json).expect("response is JSON");
    let scaled_json: Value = serde_json::from_str(&scaled.json).expect("response is JSON");
    let cases = vec![
        qualification_case(
            "native-rust-runtime",
            manifest["nativeRust"] == true,
            "host links nc-optimize directly without Swift or an XCFramework",
        ),
        qualification_case(
            "dc-divider",
            dc.succeeded
                && numeric(&dc_json, &["result", "dc", "nodes", "1", "value"])
                    .is_some_and(|value| (value - 2.5).abs() <= 1e-12),
            "native Rust DC result",
        ),
        qualification_case(
            "ac-divider",
            ac.succeeded
                && numeric(
                    &ac_json,
                    &["result", "ac", "nodes", "1", "values", "0", "magnitudeDB"],
                )
                .is_some_and(|value| (value + 6.020_599_913_279_624).abs() <= 1e-10),
            "native Rust AC result",
        ),
        qualification_case(
            "fail-closed-decoder",
            !malformed.succeeded && malformed.json.contains("invalid-request"),
            "unknown protocol members are rejected",
        ),
        qualification_case(
            "shockley-diode",
            diode.succeeded
                && numeric(&diode_json, &["result", "dc", "nodes", "1", "value"])
                    .is_some_and(|value| value > 0.4 && value < 0.9),
            "Circuit IR diode maps into the native Rust model",
        ),
        qualification_case(
            "level1-nmos-body-tied",
            nmos.succeeded
                && numeric(&nmos_json, &["result", "dc", "nodes", "2", "value"])
                    .is_some_and(|value| value > 0.0 && value < 5.0),
            "Circuit IR body-tied NMOS maps into the native Rust model",
        ),
        qualification_case(
            "transient-initial-conditions",
            transient.succeeded
                && numeric(
                    &transient_json,
                    &["result", "transient", "nodes", "0", "values", "0"],
                )
                .is_some_and(|value| (value - 1.0).abs() <= 1e-9),
            "native DAE transient preserves Circuit IR initial conditions",
        ),
        qualification_case(
            "dc-source-sweep",
            sweep.succeeded
                && numeric(
                    &sweep_json,
                    &["result", "sweep", "points", "2", "nodes", "1", "value"],
                )
                .is_some_and(|value| (value - 2.5).abs() <= 1e-12),
            "native source sweep returns one operating point per coordinate",
        ),
        qualification_case(
            "scaled-mixed-impedance",
            scaled.succeeded
                && numeric(&scaled_json, &["result", "dc", "nodes", "1", "value"])
                    .is_some_and(|value| (value - 1e-6).abs() <= 1e-12),
            "variable and equation scaling preserve a 1e12 impedance ratio",
        ),
        qualification_case(
            "dense-budget-fails-before-solve",
            !over_budget.succeeded && over_budget.json.contains("dense unknowns"),
            "requests above 512 dense unknowns fail before numerical work",
        ),
    ];
    let ready = cases.iter().all(|case| case["passed"] == true);
    Execution {
        json: serde_json::to_string(&json!({
            "cases": cases,
            "contractVersion": HOST_CONTRACT_VERSION,
            "host": BACKEND,
            "productVersion": PRODUCT_VERSION,
            "ready": ready,
            "rustNumericCoreVersion": "0.34.0"
        }))
        .expect("qualification is serializable"),
        succeeded: ready,
    }
}

fn transient_request() -> Vec<u8> {
    let mut request: Value = serde_json::from_slice(&divider_request(false)).unwrap();
    request["requestID"] = json!("rust-transient");
    request["analysis"] = json!({
        "dcOperatingPoint": false,
        "transient": {"start": 0.0, "step": 0.001, "stop": 0.002}
    });
    request["circuit"]["devices"] = json!([
        {"kind":"resistor","name":"R1","terminals":[1,0],"value":1000},
        {"kind":"capacitor","name":"C1","terminals":[1,0],"value":0.000001}
    ]);
    request["circuit"]["nodes"] = json!([{"name":"0"},{"name":"out"}]);
    request["circuit"]["initialConditions"]["nodeVoltages"] = json!({"out": 1.0});
    serde_json::to_vec(&request).unwrap()
}

fn sweep_request() -> Vec<u8> {
    let mut request: Value = serde_json::from_slice(&divider_request(false)).unwrap();
    request["requestID"] = json!("rust-sweep");
    request["analysis"] = json!({
        "dcOperatingPoint": false,
        "dcSweep": {"source": "V1", "start": 0.0, "stop": 5.0, "step": 2.5}
    });
    serde_json::to_vec(&request).unwrap()
}

fn scaled_request() -> Vec<u8> {
    let mut request: Value = serde_json::from_slice(&divider_request(false)).unwrap();
    request["requestID"] = json!("rust-scaled");
    request["circuit"]["devices"][0]["source"]["dcValue"] = json!(1e6);
    request["circuit"]["devices"][1]["value"] = json!(1e9);
    request["circuit"]["devices"][2]["value"] = json!(1e-3);
    serde_json::to_vec(&request).unwrap()
}

fn over_budget_request() -> Vec<u8> {
    let mut request: Value = serde_json::from_slice(&divider_request(false)).unwrap();
    request["requestID"] = json!("rust-over-budget");
    request["circuit"]["nodes"] = Value::Array(
        (0..=MAX_DENSE_UNKNOWNS)
            .map(|index| json!({"name": if index == 0 { "0".to_string() } else { format!("n{index}") }}))
            .collect(),
    );
    request["circuit"]["devices"] = json!([
        {"kind":"voltage-source","name":"V1","source":{"acMagnitude":0,"acPhaseDegrees":0,"dcValue":1},"terminals":[1,0]}
    ]);
    serde_json::to_vec(&request).unwrap()
}

fn qualification_case(identifier: &str, passed: bool, detail: &str) -> Value {
    json!({"detail": detail, "identifier": identifier, "passed": passed})
}

fn numeric(value: &Value, path: &[&str]) -> Option<f64> {
    let mut current = value;
    for component in path {
        current = if let Ok(index) = component.parse::<usize>() {
            current.get(index)?
        } else {
            current.get(*component)?
        };
    }
    current.as_f64()
}

fn divider_request(ac: bool) -> Vec<u8> {
    let analysis = if ac {
        r#"{"ac":{"points":2,"startFrequency":1000,"stopFrequency":1001,"type":"lin"},"dcOperatingPoint":true}"#
    } else {
        r#"{"dcOperatingPoint":true}"#
    };
    format!(r#"{{"analysis":{analysis},"backend":"rust-numeric-core","circuit":{{"devices":[{{"kind":"voltage-source","name":"V1","source":{{"acMagnitude":1,"acPhaseDegrees":0,"dcValue":5}},"terminals":[1,0]}},{{"kind":"resistor","name":"R1","terminals":[1,2],"value":1000}},{{"kind":"resistor","name":"R2","terminals":[2,0],"value":1000}}],"initialConditions":{{"elementCurrents":{{}},"nodeVoltages":{{}}}},"nodes":[{{"name":"0"}},{{"name":"in"}},{{"name":"out"}}],"referenceNode":0,"schemaVersion":1,"solver":{{"absoluteCurrentTolerance":1e-12,"absoluteVoltageTolerance":1e-6,"maximumIterations":100,"minimumConductance":1e-12,"nominalTemperatureCelsius":27,"relativeTolerance":0.001,"temperatureCelsius":27}}}},"protocolVersion":1,"requestID":"rust-qualification"}}"#).into_bytes()
}

fn nonlinear_request(diode: bool) -> Vec<u8> {
    let (nodes, devices) = if diode {
        (
            json!([{"name":"0"},{"name":"in"},{"name":"out"}]),
            json!([
                {"kind":"voltage-source","name":"V1","source":{"acMagnitude":0,"acPhaseDegrees":0,"dcValue":5},"terminals":[1,0]},
                {"kind":"resistor","name":"R1","terminals":[1,2],"value":1000},
                {"diode":{"activationEnergy":1.11,"area":1,"emissionCoefficient":1,"saturationCurrent":1e-12,
                    "saturationCurrentTemperatureExponent":3,"thermalVoltage":0.02585},
                 "kind":"diode","name":"D1","terminals":[2,0]}
            ]),
        )
    } else {
        (
            json!([{"name":"0"},{"name":"vdd"},{"name":"gate"},{"name":"drain"}]),
            json!([
                {"kind":"voltage-source","name":"VDD","source":{"acMagnitude":0,"acPhaseDegrees":0,"dcValue":5},"terminals":[1,0]},
                {"kind":"voltage-source","name":"VG","source":{"acMagnitude":0,"acPhaseDegrees":0,"dcValue":2},"terminals":[2,0]},
                {"kind":"resistor","name":"R1","terminals":[1,3],"value":1000},
                {"kind":"mosfet","mosfet":{"bodyEffect":0,"channelLengthModulation":0.02,"mobilityTemperatureExponent":-1.5,
                    "polarity":"nmos","surfacePotential":0.6,"thresholdTemperatureCoefficient":0,
                    "thresholdVoltage":1,"transconductanceParameter":0.001},
                 "name":"M1","terminals":[3,2,0,0]}
            ]),
        )
    };
    serde_json::to_vec(&json!({
        "analysis":{"dcOperatingPoint":true},
        "backend":BACKEND,
        "circuit":{
            "devices":devices,
            "initialConditions":{"elementCurrents":{},"nodeVoltages":{}},
            "nodes":nodes,
            "referenceNode":0,
            "schemaVersion":1,
            "solver":{"absoluteCurrentTolerance":1e-12,"absoluteVoltageTolerance":1e-6,"maximumIterations":100,
                "minimumConductance":1e-12,"nominalTemperatureCelsius":27,"relativeTolerance":0.001,"temperatureCelsius":27}
        },
        "protocolVersion":1,
        "requestID":if diode {"rust-diode"} else {"rust-nmos"}
    })).expect("qualification request is serializable")
}

pub fn execute(input: &[u8]) -> Execution {
    if input.len() > MAX_REQUEST_BYTES {
        return encoded_failure("", "invalid-request", "request exceeds the 16 MiB limit");
    }
    let raw: Value = match serde_json::from_slice(input) {
        Ok(value) => value,
        Err(error) => return encoded_failure("", "invalid-request", &error.to_string()),
    };
    let canonical = match serde_json::to_vec(&raw) {
        Ok(data) => data,
        Err(error) => return encoded_failure("", "invalid-request", &error.to_string()),
    };
    let request: Request = match serde_json::from_value(raw) {
        Ok(request) => request,
        Err(error) => return encoded_failure("", "invalid-request", &error.to_string()),
    };
    let request_id = request.request_id.clone();
    if request.request_id.is_empty() || request.request_id.len() > 256 {
        return encoded_failure(
            "",
            "invalid-request",
            "requestID must contain 1 through 256 UTF-8 bytes",
        );
    }
    if request.protocol_version != PROTOCOL_VERSION {
        return encoded_failure(
            &request_id,
            "unsupported-protocol",
            "portable simulation protocol version is not supported",
        );
    }
    if request.backend != BACKEND {
        return encoded_failure(
            &request_id,
            "unknown-backend",
            "native Rust host accepts only rust-numeric-core",
        );
    }
    if !request.analysis.dc_operating_point
        && request.analysis.ac.is_none()
        && request.analysis.transient.is_none()
        && request.analysis.dc_sweep.is_none()
    {
        return encoded_failure(
            &request_id,
            "invalid-request",
            "at least one supported analysis is required",
        );
    }
    let digest = format!("{:x}", Sha256::digest(&canonical));
    match solve(request, digest) {
        Ok(response) => Execution {
            json: serde_json::to_string(&response).expect("response is serializable"),
            succeeded: true,
        },
        Err((code, message)) => encoded_failure(&request_id, code, &message),
    }
}

fn encoded_failure(request_id: &str, code: &'static str, message: &str) -> Execution {
    let response = FailureResponse {
        protocol_version: PROTOCOL_VERSION,
        request_id,
        status: "failure",
        error: Failure { code, message },
    };
    Execution {
        json: serde_json::to_string(&response).expect("failure is serializable"),
        succeeded: false,
    }
}

type HostError = (&'static str, String);
fn invalid(message: impl Into<String>) -> HostError {
    ("invalid-request", message.into())
}
fn unsupported(message: impl Into<String>) -> HostError {
    ("unsupported-capability", message.into())
}
fn simulation(error: impl std::fmt::Display) -> HostError {
    ("simulation-failed", error.to_string())
}

fn solve(request: Request, digest: String) -> Result<SuccessResponse, HostError> {
    let bridge = Bridge::new(&request.circuit)?;
    let operating = bridge
        .model
        .dc_operating_point_continuation(None, bridge.nonlinear_options(), Default::default())
        .map_err(simulation)?;
    bridge.certify(&operating)?;
    let dc = request
        .analysis
        .dc_operating_point
        .then(|| bridge.dc_result(&operating))
        .transpose()?;
    let ac = request
        .analysis
        .ac
        .as_ref()
        .map(|analysis| bridge.ac_result(&operating, analysis))
        .transpose()?;
    let transient = request
        .analysis
        .transient
        .as_ref()
        .map(|analysis| bridge.transient_result(&operating, analysis))
        .transpose()?;
    let sweep = request
        .analysis
        .dc_sweep
        .as_ref()
        .map(|analysis| Bridge::sweep_result(&request.circuit, analysis))
        .transpose()?;
    Ok(SuccessResponse {
        protocol_version: PROTOCOL_VERSION,
        request_id: request.request_id,
        status: "success",
        backend: BACKEND,
        implementation_version: IMPLEMENTATION_VERSION,
        provenance: Provenance {
            product_version: PRODUCT_VERSION,
            protocol_media_type: MEDIA_TYPE,
            circuit_ir_version: 1,
            simulation_result_version: 1,
            backend: BACKEND,
            implementation_version: IMPLEMENTATION_VERSION,
            model_source: "embedded-circuit-ir",
            request_sha256: digest,
        },
        result: SimulationResult {
            contract_version: 1,
            dc,
            ac,
            transient,
            sweep,
            fourier: Vec::new(),
            warnings: Vec::new(),
        },
    })
}

struct Bridge<'a> {
    circuit: &'a Circuit,
    model: CircuitModel,
    source_override: Option<(usize, f64)>,
    voltage_scale: f64,
    current_scale: f64,
}

impl<'a> Bridge<'a> {
    fn new(circuit: &'a Circuit) -> Result<Self, HostError> {
        circuit.validate()?;
        let initial_voltages = lower_map(&circuit.initial_conditions.node_voltages);
        let initial_currents = lower_map(&circuit.initial_conditions.element_currents);
        let nodes = circuit
            .nodes
            .iter()
            .map(|node| CircuitNode {
                name: node.name.clone(),
                initial_voltage: initial_voltages
                    .get(&node.name.to_lowercase())
                    .copied()
                    .unwrap_or(0.0),
            })
            .collect();
        let mut devices = Vec::with_capacity(circuit.devices.len());
        for device in &circuit.devices {
            let terminals = &device.terminals;
            let mapped =
                match device.kind {
                    DeviceKind::Resistor => CircuitDevice::Resistor {
                        name: device.name.clone(),
                        positive: terminals[0],
                        negative: terminals[1],
                        resistance: required(device.value, device, "value")?,
                    },
                    DeviceKind::Capacitor => CircuitDevice::Capacitor {
                        name: device.name.clone(),
                        positive: terminals[0],
                        negative: terminals[1],
                        capacitance: required(device.value, device, "value")?,
                    },
                    DeviceKind::Inductor => CircuitDevice::Inductor {
                        name: device.name.clone(),
                        positive: terminals[0],
                        negative: terminals[1],
                        inductance: required(device.value, device, "value")?,
                        initial_current: initial_currents
                            .get(&device.name.to_lowercase())
                            .copied()
                            .unwrap_or(0.0),
                    },
                    DeviceKind::CurrentSource => CircuitDevice::CurrentSource {
                        name: device.name.clone(),
                        positive: terminals[0],
                        negative: terminals[1],
                        source: source(device)?,
                    },
                    DeviceKind::VoltageSource => CircuitDevice::VoltageSource {
                        name: device.name.clone(),
                        positive: terminals[0],
                        negative: terminals[1],
                        source: source(device)?,
                        initial_current: initial_currents
                            .get(&device.name.to_lowercase())
                            .copied()
                            .unwrap_or(0.0),
                    },
                    DeviceKind::Diode => {
                        require_nominal_temperature(circuit, device)?;
                        let diode = device.diode.as_ref().ok_or_else(|| {
                            invalid(format!("{} has no diode model", device.name))
                        })?;
                        CircuitDevice::Diode {
                            name: device.name.clone(),
                            anode: terminals[0],
                            cathode: terminals[1],
                            saturation_current: diode.saturation_current * diode.area,
                            thermal_voltage: diode.emission_coefficient * diode.thermal_voltage,
                        }
                    }
                    DeviceKind::Mosfet => {
                        require_nominal_temperature(circuit, device)?;
                        let model = device.mosfet.as_ref().ok_or_else(|| {
                            invalid(format!("{} has no MOSFET model", device.name))
                        })?;
                        if model.polarity != MosfetPolarity::Nmos
                            || terminals[2] != terminals[3]
                            || model.body_effect != 0.0
                        {
                            return Err(unsupported(format!(
                                "{} is not a body-tied Level-1 NMOS",
                                device.name
                            )));
                        }
                        CircuitDevice::NmosLevel1 {
                            name: device.name.clone(),
                            drain: terminals[0],
                            gate: terminals[1],
                            source: terminals[2],
                            transconductance: model.transconductance_parameter,
                            threshold: model.threshold_voltage,
                            channel_length_modulation: model.channel_length_modulation,
                        }
                    }
                    DeviceKind::Bjt | DeviceKind::Jfet => {
                        return Err(unsupported(format!("{} is not supported", device.name)))
                    }
                };
            devices.push(mapped);
        }
        let model =
            CircuitModel::new(nodes, circuit.reference_node, devices).map_err(simulation)?;
        if model.unknown_count() > MAX_DENSE_UNKNOWNS {
            return Err(invalid(format!(
                "circuit has {} dense unknowns; host limit is {MAX_DENSE_UNKNOWNS}",
                model.unknown_count()
            )));
        }
        let relative = circuit.solver.relative_tolerance.max(1e-15);
        let voltage_scale = circuit
            .devices
            .iter()
            .filter(|device| device.kind == DeviceKind::VoltageSource)
            .filter_map(|device| device.source.as_ref().map(|source| source.dc_value.abs()))
            .chain(
                circuit
                    .initial_conditions
                    .node_voltages
                    .values()
                    .map(|value| value.abs()),
            )
            .fold(
                (circuit.solver.absolute_voltage_tolerance / relative).max(1e-12),
                f64::max,
            );
        let resistance_logs = circuit
            .devices
            .iter()
            .filter(|device| device.kind == DeviceKind::Resistor)
            .filter_map(|device| device.value.filter(|value| *value > 0.0).map(f64::ln))
            .collect::<Vec<_>>();
        let resistance_scale = if resistance_logs.is_empty() {
            1_000.0
        } else {
            (resistance_logs.iter().sum::<f64>() / resistance_logs.len() as f64).exp()
        };
        let current_scale = circuit
            .devices
            .iter()
            .filter(|device| device.kind == DeviceKind::CurrentSource)
            .filter_map(|device| device.source.as_ref().map(|source| source.dc_value.abs()))
            .chain(std::iter::once(voltage_scale / resistance_scale))
            .chain(
                circuit
                    .initial_conditions
                    .element_currents
                    .values()
                    .map(|value| value.abs()),
            )
            .fold(
                (circuit.solver.absolute_current_tolerance / relative).max(1e-18),
                f64::max,
            );
        Ok(Self {
            circuit,
            model,
            source_override: None,
            voltage_scale,
            current_scale,
        })
    }

    fn nonlinear_options(&self) -> NonlinearSystemOptions {
        let node_unknowns = self.circuit.nodes.len() - 1;
        let branch_unknowns = self.model.unknown_count() - node_unknowns;
        NonlinearSystemOptions {
            max_iterations: self.circuit.solver.maximum_iterations,
            residual_tolerance: (self.circuit.solver.absolute_current_tolerance
                / self.current_scale)
                .max(self.circuit.solver.absolute_voltage_tolerance / self.voltage_scale)
                .max(1e-15),
            step_tolerance: self.circuit.solver.absolute_voltage_tolerance.max(1e-15),
            variable_scale: [
                vec![self.voltage_scale; node_unknowns],
                vec![self.current_scale; branch_unknowns],
            ]
            .concat(),
            residual_scale: [
                vec![1.0 / self.current_scale; node_unknowns],
                vec![1.0 / self.voltage_scale; branch_unknowns],
            ]
            .concat(),
            ..Default::default()
        }
    }

    fn certify(&self, operating: &CircuitOperatingPoint) -> Result<(), HostError> {
        let converged = matches!(
            operating.termination,
            NonlinearSystemTermination::ConvergedResidual
                | NonlinearSystemTermination::ConvergedStep
        );
        let kcl_limit = self.circuit.solver.absolute_current_tolerance
            + self.circuit.solver.relative_tolerance * self.current_scale;
        let branch_limit = self.circuit.solver.absolute_voltage_tolerance
            + self.circuit.solver.relative_tolerance * self.voltage_scale;
        if converged
            && operating.diagnostics.finite
            && operating.state.iter().all(|value| value.is_finite())
            && operating.diagnostics.maximum_kcl_residual <= kcl_limit
            && operating.diagnostics.maximum_branch_residual <= branch_limit
        {
            Ok(())
        } else {
            Err(simulation(format!(
                "operating point failed numerical certification: {:?}, KCL {}, branch {}",
                operating.termination,
                operating.diagnostics.maximum_kcl_residual,
                operating.diagnostics.maximum_branch_residual
            )))
        }
    }

    fn dc_result(&self, operating: &CircuitOperatingPoint) -> Result<DcResult, HostError> {
        let branches: BTreeMap<&str, f64> = operating
            .branch_currents
            .iter()
            .map(|(name, value)| (name.as_str(), *value))
            .collect();
        let components = self
            .circuit
            .devices
            .iter()
            .enumerate()
            .map(|(index, device)| {
                let voltage = operating.node_voltages[device.terminals[0]]
                    - operating.node_voltages[device.terminals[1]];
                let current = match device.kind {
                    DeviceKind::Resistor => voltage / device.value.unwrap(),
                    DeviceKind::Capacitor => 0.0,
                    DeviceKind::Inductor | DeviceKind::VoltageSource => {
                        *branches.get(device.name.as_str()).ok_or_else(|| {
                            simulation(format!("missing branch current for {}", device.name))
                        })?
                    }
                    DeviceKind::CurrentSource => self
                        .source_override
                        .filter(|(source_index, _)| *source_index == index)
                        .map(|(_, value)| value)
                        .unwrap_or_else(|| device.source.as_ref().unwrap().dc_value),
                    DeviceKind::Diode => diode_current(device, voltage)?,
                    DeviceKind::Mosfet => nmos_current(device, &operating.node_voltages)?,
                    DeviceKind::Bjt | DeviceKind::Jfet => {
                        return Err(unsupported(format!("{} is not supported", device.name)))
                    }
                };
                Ok(ComponentValue {
                    name: device.name.clone(),
                    voltage,
                    current,
                })
            })
            .collect::<Result<Vec<_>, HostError>>()?;
        let sources = self
            .circuit
            .devices
            .iter()
            .filter(|device| device.kind == DeviceKind::VoltageSource)
            .map(|device| {
                Ok(NamedValue {
                    name: device.name.clone(),
                    value: *branches.get(device.name.as_str()).ok_or_else(|| {
                        simulation(format!("missing branch current for {}", device.name))
                    })?,
                })
            })
            .collect::<Result<Vec<_>, HostError>>()?;
        Ok(DcResult {
            nodes: self
                .circuit
                .nodes
                .iter()
                .enumerate()
                .skip(1)
                .map(|(index, node)| NamedValue {
                    name: node.name.clone(),
                    value: operating.node_voltages[index],
                })
                .collect(),
            components,
            sources,
            converged: operating.diagnostics.finite
                && matches!(
                    operating.termination,
                    NonlinearSystemTermination::ConvergedResidual
                        | NonlinearSystemTermination::ConvergedStep
                ),
        })
    }

    fn ac_result(
        &self,
        operating: &CircuitOperatingPoint,
        analysis: &AcAnalysis,
    ) -> Result<AcResult, HostError> {
        let frequencies = analysis.frequencies()?;
        let series_count = self.circuit.nodes.len().saturating_sub(1) + self.circuit.devices.len();
        if frequencies.len().saturating_mul(series_count) > MAX_PROJECTED_VALUES {
            return Err(invalid(
                "AC result exceeds the native host projection budget",
            ));
        }
        let excitations = self
            .circuit
            .devices
            .iter()
            .filter_map(|device| {
                let source = device.source.as_ref()?;
                if !matches!(
                    device.kind,
                    DeviceKind::VoltageSource | DeviceKind::CurrentSource
                ) || source.ac_magnitude == 0.0
                {
                    return None;
                }
                Some(CircuitAcExcitation {
                    device_name: device.name.clone(),
                    magnitude: source.ac_magnitude,
                    phase: source.ac_phase_degrees.to_radians(),
                })
            })
            .collect::<Vec<_>>();
        if excitations.is_empty() {
            return Err(unsupported("AC analysis requires an AC source"));
        }
        let sweep = self
            .model
            .ac_analysis(&operating.state, &frequencies, &excitations)
            .map_err(simulation)?;
        let mut node_values = vec![Vec::new(); self.circuit.nodes.len()];
        let mut component_values = vec![Vec::new(); self.circuit.devices.len()];
        for point in &sweep.points {
            let mut voltages = vec![(0.0, 0.0); self.circuit.nodes.len()];
            for node in 1..self.circuit.nodes.len() {
                if let Some(index) = self.model.node_unknown_index(node).map_err(simulation)? {
                    let value = point.unknowns[index];
                    voltages[node] = (value.real, value.imaginary);
                    node_values[node].push(frequency_point(point.frequency, voltages[node]));
                }
            }
            for (index, device) in self.circuit.devices.iter().enumerate() {
                let voltage = sub(voltages[device.terminals[0]], voltages[device.terminals[1]]);
                let current = match device.kind {
                    DeviceKind::Resistor => scale(voltage, 1.0 / device.value.unwrap()),
                    DeviceKind::Capacitor => mul_i(
                        voltage,
                        std::f64::consts::TAU * point.frequency * device.value.unwrap(),
                    ),
                    DeviceKind::Inductor | DeviceKind::VoltageSource => {
                        let branch = self
                            .model
                            .branch_unknown_index(index)
                            .map_err(simulation)?
                            .ok_or_else(|| {
                                simulation(format!("missing branch current for {}", device.name))
                            })?;
                        let value = point.unknowns[branch];
                        (value.real, value.imaginary)
                    }
                    DeviceKind::CurrentSource => {
                        let source = device.source.as_ref().unwrap();
                        polar(source.ac_magnitude, source.ac_phase_degrees.to_radians())
                    }
                    DeviceKind::Diode => {
                        let bias = operating.node_voltages[device.terminals[0]]
                            - operating.node_voltages[device.terminals[1]];
                        let diode = device.diode.as_ref().unwrap();
                        let thermal = diode.emission_coefficient * diode.thermal_voltage;
                        scale(
                            voltage,
                            diode.saturation_current
                                * diode.area
                                * (bias / thermal).min(80.0).exp()
                                / thermal,
                        )
                    }
                    DeviceKind::Mosfet => {
                        nmos_ac_current(device, &operating.node_voltages, &voltages)?
                    }
                    DeviceKind::Bjt | DeviceKind::Jfet => {
                        return Err(unsupported(format!("{} is not supported", device.name)))
                    }
                };
                component_values[index].push(frequency_point(point.frequency, current));
            }
        }
        Ok(AcResult {
            frequencies,
            nodes: self
                .circuit
                .nodes
                .iter()
                .enumerate()
                .skip(1)
                .map(|(index, node)| FrequencySeries {
                    name: node.name.clone(),
                    values: std::mem::take(&mut node_values[index]),
                })
                .collect(),
            components: self
                .circuit
                .devices
                .iter()
                .enumerate()
                .map(|(index, device)| FrequencySeries {
                    name: device.name.clone(),
                    values: std::mem::take(&mut component_values[index]),
                })
                .collect(),
        })
    }

    fn transient_result(
        &self,
        operating: &CircuitOperatingPoint,
        analysis: &TransientAnalysis,
    ) -> Result<TransientResult, HostError> {
        let times = analysis.times()?;
        let series_count = self.circuit.nodes.len().saturating_sub(1) + self.circuit.devices.len();
        if times.len().saturating_mul(series_count) > MAX_PROJECTED_VALUES {
            return Err(invalid(
                "transient result exceeds the native host projection budget",
            ));
        }
        let integration_end = *times
            .last()
            .ok_or_else(|| invalid("invalid transient analysis"))?;
        let mut initial = operating.state.clone();
        let node_overrides = lower_map(&self.circuit.initial_conditions.node_voltages);
        for (node, description) in self.circuit.nodes.iter().enumerate() {
            if let (Some(value), Some(unknown)) = (
                node_overrides.get(&description.name.to_lowercase()),
                self.model.node_unknown_index(node).map_err(simulation)?,
            ) {
                initial[unknown] = *value;
            }
        }
        let current_overrides = lower_map(&self.circuit.initial_conditions.element_currents);
        for (device, description) in self.circuit.devices.iter().enumerate() {
            if let (Some(value), Some(unknown)) = (
                current_overrides.get(&description.name.to_lowercase()),
                self.model
                    .branch_unknown_index(device)
                    .map_err(simulation)?,
            ) {
                initial[unknown] = *value;
            }
        }
        let zero_derivative = self.model.zero_derivative();
        let evaluation = self
            .model
            .dae_evaluation(analysis.start, &initial, &zero_derivative)
            .map_err(simulation)?;
        let free_state = (0..initial.len())
            .map(|column| {
                evaluation
                    .jacobian_derivative
                    .iter()
                    .all(|row| row[column].abs() <= f64::EPSILON)
            })
            .collect::<Vec<_>>();
        let consistent = consistent_dae_initial_conditions(
            analysis.start,
            &initial,
            &zero_derivative,
            &free_state,
            self.circuit.solver.maximum_iterations,
            self.circuit.solver.absolute_voltage_tolerance,
            |time, state, derivative| self.model.dae_evaluation(time, state, derivative),
        )
        .map_err(simulation)?;
        let integrated = self
            .model
            .transient(
                analysis.start,
                integration_end,
                &consistent.state,
                &consistent.derivative,
                TimeIntegrationOptions {
                    absolute_tolerance: self.circuit.solver.absolute_voltage_tolerance,
                    relative_tolerance: self.circuit.solver.relative_tolerance,
                    initial_step: analysis.step,
                    minimum_step: (analysis.step * 1e-9).max(1e-15),
                    maximum_step: analysis.step,
                    max_steps: MAX_SAMPLES,
                    max_rejected_steps: 10_000,
                    max_newton_iterations: self.circuit.solver.maximum_iterations,
                    newton_tolerance: self.circuit.solver.absolute_voltage_tolerance,
                },
            )
            .map_err(simulation)?;
        if integrated.termination != TimeIntegrationTermination::ReachedEnd {
            return Err(simulation(format!(
                "transient integration terminated as {:?}",
                integrated.termination
            )));
        }
        let states = times
            .iter()
            .map(|time| {
                integrated
                    .evaluate(*time)
                    .ok_or_else(|| simulation("transient result cannot be sampled"))
            })
            .collect::<Result<Vec<_>, _>>()?;
        let mut node_values = vec![Vec::with_capacity(times.len()); self.circuit.nodes.len()];
        let mut component_values =
            vec![Vec::with_capacity(times.len()); self.circuit.devices.len()];
        let mut previous_voltages = vec![0.0; self.circuit.devices.len()];
        for (sample, state) in states.iter().enumerate() {
            let voltages = self.model.node_voltages(state).map_err(simulation)?;
            for (node, value) in voltages.iter().enumerate() {
                node_values[node].push(*value);
            }
            for (index, device) in self.circuit.devices.iter().enumerate() {
                let voltage = voltages[device.terminals[0]] - voltages[device.terminals[1]];
                let current = match device.kind {
                    DeviceKind::Resistor => voltage / device.value.unwrap(),
                    DeviceKind::Capacitor => {
                        if sample == 0 {
                            0.0
                        } else {
                            device.value.unwrap() * (voltage - previous_voltages[index])
                                / (times[sample] - times[sample - 1])
                        }
                    }
                    DeviceKind::Inductor | DeviceKind::VoltageSource => {
                        let branch = self
                            .model
                            .branch_unknown_index(index)
                            .map_err(simulation)?
                            .ok_or_else(|| {
                                simulation(format!("missing branch current for {}", device.name))
                            })?;
                        state[branch]
                    }
                    DeviceKind::CurrentSource => source_value(device, times[sample])?,
                    DeviceKind::Diode => diode_current(device, voltage)?,
                    DeviceKind::Mosfet => nmos_current(device, &voltages)?,
                    DeviceKind::Bjt | DeviceKind::Jfet => {
                        return Err(unsupported(format!("{} is not supported", device.name)))
                    }
                };
                component_values[index].push(current);
                previous_voltages[index] = voltage;
            }
        }
        Ok(TransientResult {
            times,
            nodes: self
                .circuit
                .nodes
                .iter()
                .enumerate()
                .skip(1)
                .map(|(index, node)| NamedSeries {
                    name: node.name.clone(),
                    values: std::mem::take(&mut node_values[index]),
                })
                .collect(),
            components: self
                .circuit
                .devices
                .iter()
                .enumerate()
                .map(|(index, device)| NamedSeries {
                    name: device.name.clone(),
                    values: std::mem::take(&mut component_values[index]),
                })
                .collect(),
        })
    }

    fn sweep_result(circuit: &Circuit, analysis: &DcSweep) -> Result<SweepResult, HostError> {
        let values = analysis.values()?;
        let point_width = circuit.nodes.len().saturating_sub(1) + circuit.devices.len();
        if values.len().saturating_mul(point_width) > MAX_PROJECTED_VALUES {
            return Err(invalid(
                "DC sweep result exceeds the native host projection budget",
            ));
        }
        let source_index = circuit
            .devices
            .iter()
            .position(|device| {
                device.name.eq_ignore_ascii_case(&analysis.source)
                    && matches!(
                        device.kind,
                        DeviceKind::VoltageSource | DeviceKind::CurrentSource
                    )
            })
            .ok_or_else(|| invalid(format!("unknown DC sweep source {}", analysis.source)))?;
        let mut points = Vec::with_capacity(values.len());
        let mut previous: Option<Vec<f64>> = None;
        for value in &values {
            let bridge = Bridge::new_with_source_override(circuit, source_index, *value)?;
            let operating = bridge
                .model
                .dc_operating_point_continuation(
                    previous.as_deref(),
                    bridge.nonlinear_options(),
                    Default::default(),
                )
                .map_err(simulation)?;
            bridge.certify(&operating)?;
            let dc = bridge.dc_result(&operating)?;
            previous = Some(operating.state);
            points.push(SweepPoint {
                coordinates: vec![NamedValue {
                    name: analysis.source.clone(),
                    value: *value,
                }],
                nodes: dc.nodes,
                components: dc.components,
            });
        }
        Ok(SweepResult {
            axes: vec![SweepAxis {
                name: analysis.source.clone(),
                values,
            }],
            points,
        })
    }

    fn new_with_source_override(
        circuit: &'a Circuit,
        source_index: usize,
        value: f64,
    ) -> Result<Self, HostError> {
        let mut bridge = Self::new(circuit)?;
        match &mut bridge.model.devices[source_index] {
            CircuitDevice::VoltageSource { source, .. }
            | CircuitDevice::CurrentSource { source, .. } => source.dc = value,
            _ => return Err(invalid("DC sweep target is not an independent source")),
        }
        bridge.source_override = Some((source_index, value));
        Ok(bridge)
    }
}

fn lower_map(values: &BTreeMap<String, f64>) -> BTreeMap<String, f64> {
    values
        .iter()
        .map(|(key, value)| (key.to_lowercase(), *value))
        .collect()
}

fn required(value: Option<f64>, device: &Device, field: &str) -> Result<f64, HostError> {
    value.ok_or_else(|| invalid(format!("{} has no {field}", device.name)))
}

fn require_nominal_temperature(circuit: &Circuit, device: &Device) -> Result<(), HostError> {
    if (circuit.solver.temperature_celsius - circuit.solver.nominal_temperature_celsius).abs()
        > 1e-12
    {
        Err(unsupported(format!(
            "{} requires nominal temperature",
            device.name
        )))
    } else {
        Ok(())
    }
}

fn source(device: &Device) -> Result<CircuitSource, HostError> {
    let value = device
        .source
        .as_ref()
        .ok_or_else(|| invalid(format!("{} has no source", device.name)))?;
    let waveform = match value.transient.as_ref() {
        None => None,
        Some(waveform) => Some(match waveform.kind {
            WaveformKind::Pulse => CircuitWaveform::Pulse {
                low: waveform.parameter("initial")?,
                high: waveform.parameter("pulsed")?,
                delay: waveform.parameter("delay")?,
                rise: waveform.parameter("riseTime")?,
                fall: waveform.parameter("fallTime")?,
                width: waveform.parameter("pulseWidth")?,
                period: waveform.parameter("period")?,
            },
            WaveformKind::Sine => {
                if waveform.parameter("delay")? != 0.0 || waveform.parameter("damping")? != 0.0 {
                    return Err(unsupported(format!(
                        "{} uses delayed or damped sine",
                        device.name
                    )));
                }
                CircuitWaveform::Sinusoidal {
                    offset: waveform.parameter("offset")?,
                    amplitude: waveform.parameter("amplitude")?,
                    frequency: waveform.parameter("frequency")?,
                    phase: waveform.parameter("phaseDegrees")?.to_radians(),
                }
            }
            WaveformKind::Pwl => {
                return Err(unsupported(format!(
                    "{} uses a piecewise-linear waveform",
                    device.name
                )))
            }
        }),
    };
    Ok(match waveform {
        Some(waveform) => CircuitSource::transient(value.dc_value, waveform),
        None => CircuitSource::dc(value.dc_value),
    })
}

fn source_value(device: &Device, time: f64) -> Result<f64, HostError> {
    let source = device
        .source
        .as_ref()
        .ok_or_else(|| invalid(format!("{} has no source", device.name)))?;
    let Some(waveform) = source.transient.as_ref() else {
        return Ok(source.dc_value);
    };
    Ok(match waveform.kind {
        WaveformKind::Pulse => {
            let low = waveform.parameter("initial")?;
            let high = waveform.parameter("pulsed")?;
            let delay = waveform.parameter("delay")?;
            let rise = waveform.parameter("riseTime")?;
            let fall = waveform.parameter("fallTime")?;
            let width = waveform.parameter("pulseWidth")?;
            let period = waveform.parameter("period")?;
            if time < delay {
                low
            } else {
                let local = if period > 0.0 {
                    (time - delay) % period
                } else {
                    time - delay
                };
                if rise > 0.0 && local < rise {
                    low + (high - low) * local / rise
                } else if local < rise + width {
                    high
                } else if fall > 0.0 && local < rise + width + fall {
                    high + (low - high) * (local - rise - width) / fall
                } else {
                    low
                }
            }
        }
        WaveformKind::Sine => {
            let delay = waveform.parameter("delay")?;
            let damping = waveform.parameter("damping")?;
            if delay != 0.0 || damping != 0.0 {
                return Err(unsupported(format!(
                    "{} uses delayed or damped sine",
                    device.name
                )));
            }
            waveform.parameter("offset")?
                + waveform.parameter("amplitude")?
                    * (std::f64::consts::TAU * waveform.parameter("frequency")? * time
                        + waveform.parameter("phaseDegrees")?.to_radians())
                    .sin()
        }
        WaveformKind::Pwl => {
            return Err(unsupported(format!(
                "{} uses a piecewise-linear waveform",
                device.name
            )))
        }
    })
}

fn diode_current(device: &Device, voltage: f64) -> Result<f64, HostError> {
    let diode = device
        .diode
        .as_ref()
        .ok_or_else(|| invalid(format!("{} has no diode model", device.name)))?;
    let thermal = diode.emission_coefficient * diode.thermal_voltage;
    Ok(diode.saturation_current * diode.area * ((voltage / thermal).min(80.0).exp() - 1.0))
}

fn nmos_values(device: &Device, voltages: &[f64]) -> Result<(f64, f64, f64), HostError> {
    let model = device
        .mosfet
        .as_ref()
        .ok_or_else(|| invalid(format!("{} has no MOSFET model", device.name)))?;
    let vgs = voltages[device.terminals[1]] - voltages[device.terminals[2]];
    let vds = voltages[device.terminals[0]] - voltages[device.terminals[2]];
    let overdrive = vgs - model.threshold_voltage;
    if overdrive <= 0.0 {
        return Ok((0.0, 0.0, 0.0));
    }
    let beta = model.transconductance_parameter;
    let lambda = model.channel_length_modulation;
    if vds < overdrive {
        let base = beta * (overdrive * vds - 0.5 * vds * vds);
        let modulation = 1.0 + lambda * vds;
        Ok((
            base * modulation,
            beta * vds * modulation,
            beta * (overdrive - vds) * modulation + lambda * base,
        ))
    } else {
        let base = 0.5 * beta * overdrive * overdrive;
        Ok((
            base * (1.0 + lambda * vds),
            beta * overdrive * (1.0 + lambda * vds),
            lambda * base,
        ))
    }
}

fn nmos_current(device: &Device, voltages: &[f64]) -> Result<f64, HostError> {
    Ok(nmos_values(device, voltages)?.0)
}

fn nmos_ac_current(
    device: &Device,
    bias: &[f64],
    phasors: &[(f64, f64)],
) -> Result<(f64, f64), HostError> {
    let (_, gm, gds) = nmos_values(device, bias)?;
    let drain_source = sub(phasors[device.terminals[0]], phasors[device.terminals[2]]);
    let gate_source = sub(phasors[device.terminals[1]], phasors[device.terminals[2]]);
    Ok(add(scale(drain_source, gds), scale(gate_source, gm)))
}

fn add(a: (f64, f64), b: (f64, f64)) -> (f64, f64) {
    (a.0 + b.0, a.1 + b.1)
}
fn sub(a: (f64, f64), b: (f64, f64)) -> (f64, f64) {
    (a.0 - b.0, a.1 - b.1)
}
fn scale(a: (f64, f64), factor: f64) -> (f64, f64) {
    (a.0 * factor, a.1 * factor)
}
fn mul_i(a: (f64, f64), factor: f64) -> (f64, f64) {
    (-a.1 * factor, a.0 * factor)
}
fn polar(magnitude: f64, phase: f64) -> (f64, f64) {
    (magnitude * phase.cos(), magnitude * phase.sin())
}
fn frequency_point(frequency: f64, value: (f64, f64)) -> FrequencyPoint {
    FrequencyPoint {
        frequency,
        magnitude_db: 20.0 * value.0.hypot(value.1).log10(),
        phase_degrees: value.1.atan2(value.0).to_degrees(),
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    protocol_version: u32,
    #[serde(rename = "requestID")]
    request_id: String,
    backend: String,
    circuit: Circuit,
    analysis: Analysis,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Analysis {
    dc_operating_point: bool,
    #[serde(default)]
    ac: Option<AcAnalysis>,
    #[serde(default)]
    transient: Option<TransientAnalysis>,
    #[serde(default)]
    dc_sweep: Option<DcSweep>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct AcAnalysis {
    #[serde(rename = "type")]
    kind: SweepKind,
    start_frequency: f64,
    stop_frequency: f64,
    points: usize,
}

impl AcAnalysis {
    fn frequencies(&self) -> Result<Vec<f64>, HostError> {
        if !self.start_frequency.is_finite()
            || !self.stop_frequency.is_finite()
            || self.start_frequency <= 0.0
            || self.stop_frequency <= self.start_frequency
            || self.points == 0
        {
            return Err(invalid("invalid AC sweep"));
        }
        let frequencies = match self.kind {
            SweepKind::Lin => {
                if self.points == 1 {
                    vec![self.start_frequency]
                } else {
                    let step =
                        (self.stop_frequency - self.start_frequency) / (self.points - 1) as f64;
                    (0..self.points)
                        .map(|index| self.start_frequency + index as f64 * step)
                        .collect()
                }
            }
            SweepKind::Dec | SweepKind::Oct => {
                let base: f64 = if self.kind == SweepKind::Oct {
                    2.0
                } else {
                    10.0
                };
                let span = (self.stop_frequency / self.start_frequency).ln() / base.ln();
                let intervals = ((span * self.points as f64).ceil() as usize).max(1);
                let mut values = (0..=intervals)
                    .map(|index| {
                        (self.start_frequency * base.powf(index as f64 / self.points as f64))
                            .min(self.stop_frequency)
                    })
                    .collect::<Vec<_>>();
                if values.last().copied() != Some(self.stop_frequency) {
                    values.push(self.stop_frequency);
                }
                values
            }
        };
        if frequencies.len() > MAX_SAMPLES {
            Err(invalid("AC sweep exceeds sample limit"))
        } else {
            Ok(frequencies)
        }
    }
}

#[derive(Clone, Copy, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
enum SweepKind {
    Lin,
    Dec,
    Oct,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TransientAnalysis {
    step: f64,
    stop: f64,
    start: f64,
}

impl TransientAnalysis {
    fn times(&self) -> Result<Vec<f64>, HostError> {
        if !self.step.is_finite()
            || !self.start.is_finite()
            || !self.stop.is_finite()
            || self.step <= 0.0
            || self.start < 0.0
            || self.stop <= self.start
        {
            return Err(invalid("invalid transient analysis"));
        }
        let steps = ((self.stop - self.start) / self.step).ceil() as usize;
        if steps == 0 || steps >= MAX_SAMPLES {
            return Err(invalid("transient analysis exceeds sample limit"));
        }
        Ok((0..=steps)
            .map(|index| self.start + index as f64 * self.step)
            .collect())
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DcSweep {
    source: String,
    start: f64,
    stop: f64,
    step: f64,
}

impl DcSweep {
    fn values(&self) -> Result<Vec<f64>, HostError> {
        if self.source.is_empty()
            || !self.start.is_finite()
            || !self.stop.is_finite()
            || !self.step.is_finite()
            || self.step == 0.0
            || (self.stop > self.start && self.step < 0.0)
            || (self.stop < self.start && self.step > 0.0)
        {
            return Err(invalid("invalid DC sweep"));
        }
        let steps = ((self.stop - self.start) / self.step).abs().ceil() as usize;
        if steps >= MAX_SAMPLES {
            return Err(invalid("DC sweep exceeds sample limit"));
        }
        let mut values = (0..=steps)
            .map(|index| self.start + index as f64 * self.step)
            .take_while(|value| {
                if self.step > 0.0 {
                    *value <= self.stop
                } else {
                    *value >= self.stop
                }
            })
            .collect::<Vec<_>>();
        if values.last().copied() != Some(self.stop) {
            values.push(self.stop);
        }
        Ok(values)
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Circuit {
    schema_version: u32,
    reference_node: usize,
    nodes: Vec<Node>,
    devices: Vec<Device>,
    solver: SolverConfiguration,
    initial_conditions: InitialConditions,
}

impl Circuit {
    fn validate(&self) -> Result<(), HostError> {
        if self.schema_version != 1 {
            return Err(invalid("unsupported Circuit IR version"));
        }
        if self.reference_node != 0
            || self.nodes.first().map(|node| node.name.as_str()) != Some("0")
        {
            return Err(invalid("invalid Circuit IR reference node"));
        }
        if self.nodes.is_empty() || self.nodes.len() > MAX_NODES || self.devices.len() > MAX_DEVICES
        {
            return Err(invalid("Circuit IR exceeds host limits"));
        }
        let mut names = BTreeSet::new();
        if self.nodes.iter().any(|node| {
            node.name.is_empty()
                || node.name.len() > 1_024
                || !names.insert(node.name.to_lowercase())
        }) {
            return Err(invalid("node names must be non-empty and unique"));
        }
        let node_names = names.clone();
        names.clear();
        for device in &self.devices {
            let expected = match device.kind {
                DeviceKind::Mosfet => 4,
                DeviceKind::Bjt | DeviceKind::Jfet => 3,
                _ => 2,
            };
            if device.name.is_empty()
                || device.name.len() > 1_024
                || !names.insert(device.name.to_lowercase())
                || device.terminals.len() != expected
                || device
                    .terminals
                    .iter()
                    .any(|node| *node >= self.nodes.len())
            {
                return Err(invalid(format!("device {} is malformed", device.name)));
            }
        }
        let device_names = names;
        if self
            .initial_conditions
            .node_voltages
            .keys()
            .any(|name| !node_names.contains(&name.to_lowercase()))
            || self
                .initial_conditions
                .element_currents
                .keys()
                .any(|name| !device_names.contains(&name.to_lowercase()))
        {
            return Err(invalid(
                "initial condition names must reference circuit nodes or devices",
            ));
        }
        if self.solver.maximum_iterations == 0
            || self.solver.maximum_iterations > 10_000
            || self.solver.relative_tolerance <= 0.0
            || self.solver.absolute_current_tolerance <= 0.0
            || self.solver.absolute_voltage_tolerance <= 0.0
            || self.solver.minimum_conductance <= 0.0
        {
            return Err(invalid("invalid solver configuration"));
        }
        Ok(())
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Node {
    name: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Device {
    name: String,
    kind: DeviceKind,
    terminals: Vec<usize>,
    #[serde(default)]
    value: Option<f64>,
    #[serde(default)]
    source: Option<Source>,
    #[serde(default)]
    diode: Option<DiodeModel>,
    #[allow(dead_code)]
    #[serde(default)]
    bjt: Option<BjtModel>,
    #[serde(default)]
    mosfet: Option<MosfetModel>,
    #[allow(dead_code)]
    #[serde(default)]
    jfet: Option<JfetModel>,
}

#[derive(Clone, Copy, Deserialize, PartialEq)]
#[serde(rename_all = "kebab-case")]
enum DeviceKind {
    Resistor,
    Capacitor,
    Inductor,
    VoltageSource,
    CurrentSource,
    Diode,
    Bjt,
    Mosfet,
    Jfet,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Source {
    dc_value: f64,
    ac_magnitude: f64,
    ac_phase_degrees: f64,
    #[serde(default)]
    transient: Option<Waveform>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Waveform {
    kind: WaveformKind,
    parameters: BTreeMap<String, f64>,
    #[allow(dead_code)]
    points: Vec<WaveformPoint>,
}
impl Waveform {
    fn parameter(&self, name: &str) -> Result<f64, HostError> {
        self.parameters
            .get(name)
            .copied()
            .ok_or_else(|| invalid(format!("waveform has no {name}")))
    }
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "lowercase")]
enum WaveformKind {
    Pulse,
    Sine,
    Pwl,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WaveformPoint {
    #[allow(dead_code)]
    time: f64,
    #[allow(dead_code)]
    value: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DiodeModel {
    saturation_current: f64,
    emission_coefficient: f64,
    thermal_voltage: f64,
    area: f64,
    #[allow(dead_code)]
    saturation_current_temperature_exponent: f64,
    #[allow(dead_code)]
    activation_energy: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct BjtModel {
    #[allow(dead_code)]
    polarity: String,
    #[allow(dead_code)]
    saturation_current: f64,
    #[allow(dead_code)]
    forward_beta: f64,
    #[allow(dead_code)]
    reverse_beta: f64,
    #[allow(dead_code)]
    thermal_voltage: f64,
    #[allow(dead_code)]
    saturation_current_temperature_exponent: f64,
    #[allow(dead_code)]
    activation_energy: f64,
    #[allow(dead_code)]
    beta_temperature_exponent: f64,
}

#[derive(Clone, Copy, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
enum MosfetPolarity {
    Nmos,
    Pmos,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MosfetModel {
    polarity: MosfetPolarity,
    threshold_voltage: f64,
    transconductance_parameter: f64,
    channel_length_modulation: f64,
    body_effect: f64,
    #[allow(dead_code)]
    surface_potential: f64,
    #[allow(dead_code)]
    mobility_temperature_exponent: f64,
    #[allow(dead_code)]
    threshold_temperature_coefficient: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct JfetModel {
    #[allow(dead_code)]
    polarity: String,
    #[allow(dead_code)]
    threshold_voltage: f64,
    #[allow(dead_code)]
    transconductance_parameter: f64,
    #[allow(dead_code)]
    channel_length_modulation: f64,
    #[allow(dead_code)]
    gate_saturation_current: f64,
    #[allow(dead_code)]
    thermal_voltage: f64,
    #[allow(dead_code)]
    mobility_temperature_exponent: f64,
    #[allow(dead_code)]
    threshold_temperature_coefficient: f64,
    #[allow(dead_code)]
    saturation_current_temperature_exponent: f64,
    #[allow(dead_code)]
    activation_energy: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SolverConfiguration {
    relative_tolerance: f64,
    absolute_current_tolerance: f64,
    absolute_voltage_tolerance: f64,
    minimum_conductance: f64,
    maximum_iterations: usize,
    temperature_celsius: f64,
    nominal_temperature_celsius: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct InitialConditions {
    node_voltages: BTreeMap<String, f64>,
    element_currents: BTreeMap<String, f64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct FailureResponse<'a> {
    protocol_version: u32,
    #[serde(rename = "requestID")]
    request_id: &'a str,
    status: &'static str,
    error: Failure<'a>,
}
#[derive(Serialize)]
struct Failure<'a> {
    code: &'static str,
    message: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SuccessResponse {
    protocol_version: u32,
    #[serde(rename = "requestID")]
    request_id: String,
    status: &'static str,
    backend: &'static str,
    implementation_version: &'static str,
    provenance: Provenance,
    result: SimulationResult,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Provenance {
    product_version: &'static str,
    protocol_media_type: &'static str,
    #[serde(rename = "circuitIRVersion")]
    circuit_ir_version: u32,
    simulation_result_version: u32,
    backend: &'static str,
    implementation_version: &'static str,
    model_source: &'static str,
    #[serde(rename = "requestSHA256")]
    request_sha256: String,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SimulationResult {
    contract_version: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    dc: Option<DcResult>,
    #[serde(skip_serializing_if = "Option::is_none")]
    ac: Option<AcResult>,
    #[serde(skip_serializing_if = "Option::is_none")]
    transient: Option<TransientResult>,
    #[serde(skip_serializing_if = "Option::is_none")]
    sweep: Option<SweepResult>,
    fourier: Vec<Value>,
    warnings: Vec<String>,
}
#[derive(Serialize)]
struct DcResult {
    nodes: Vec<NamedValue>,
    components: Vec<ComponentValue>,
    sources: Vec<NamedValue>,
    converged: bool,
}
#[derive(Serialize)]
struct NamedValue {
    name: String,
    value: f64,
}
#[derive(Serialize)]
struct ComponentValue {
    name: String,
    voltage: f64,
    current: f64,
}
#[derive(Serialize)]
struct AcResult {
    frequencies: Vec<f64>,
    nodes: Vec<FrequencySeries>,
    components: Vec<FrequencySeries>,
}
#[derive(Serialize)]
struct FrequencySeries {
    name: String,
    values: Vec<FrequencyPoint>,
}
#[derive(Clone, Copy, Serialize)]
#[serde(rename_all = "camelCase")]
struct FrequencyPoint {
    frequency: f64,
    #[serde(rename = "magnitudeDB")]
    magnitude_db: f64,
    phase_degrees: f64,
}

#[derive(Serialize)]
struct TransientResult {
    times: Vec<f64>,
    nodes: Vec<NamedSeries>,
    components: Vec<NamedSeries>,
}

#[derive(Serialize)]
struct NamedSeries {
    name: String,
    values: Vec<f64>,
}

#[derive(Serialize)]
struct SweepAxis {
    name: String,
    values: Vec<f64>,
}

#[derive(Serialize)]
struct SweepPoint {
    coordinates: Vec<NamedValue>,
    nodes: Vec<NamedValue>,
    components: Vec<ComponentValue>,
}

#[derive(Serialize)]
struct SweepResult {
    axes: Vec<SweepAxis>,
    points: Vec<SweepPoint>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use approx::assert_abs_diff_eq;

    fn divider(backend: &str) -> Vec<u8> {
        format!(r#"{{"analysis":{{"dcOperatingPoint":true}},"backend":"{backend}","circuit":{{"devices":[{{"kind":"voltage-source","name":"V1","source":{{"acMagnitude":1,"acPhaseDegrees":0,"dcValue":5}},"terminals":[1,0]}},{{"kind":"resistor","name":"R1","terminals":[1,2],"value":1000}},{{"kind":"resistor","name":"R2","terminals":[2,0],"value":1000}}],"initialConditions":{{"elementCurrents":{{}},"nodeVoltages":{{}}}},"nodes":[{{"name":"0"}},{{"name":"in"}},{{"name":"out"}}],"referenceNode":0,"schemaVersion":1,"solver":{{"absoluteCurrentTolerance":1e-12,"absoluteVoltageTolerance":1e-6,"maximumIterations":100,"minimumConductance":1e-12,"nominalTemperatureCelsius":27,"relativeTolerance":0.001,"temperatureCelsius":27}}}},"protocolVersion":1,"requestID":"rust-divider"}}"#).into_bytes()
    }

    #[test]
    fn solves_divider_without_swift_or_ffi() {
        let execution = execute(&divider(BACKEND));
        assert!(execution.succeeded, "{}", execution.json);
        let value: Value = serde_json::from_str(&execution.json).unwrap();
        assert_abs_diff_eq!(
            value["result"]["dc"]["nodes"][1]["value"].as_f64().unwrap(),
            2.5,
            epsilon = 1e-12
        );
        assert_eq!(value["implementationVersion"], IMPLEMENTATION_VERSION);
    }

    #[test]
    fn rejects_unknown_backend_and_unknown_members() {
        let unknown = execute(&divider("numeric-core"));
        assert!(!unknown.succeeded);
        assert!(unknown.json.contains("unknown-backend"));
        let malformed = execute(br#"{"protocolVersion":1,"unexpected":true}"#);
        assert!(!malformed.succeeded);
        assert!(malformed.json.contains("invalid-request"));
    }

    #[test]
    fn manifest_declares_native_rust_boundary() {
        let manifest: Value = serde_json::from_str(&manifest_json()).unwrap();
        assert_eq!(manifest["nativeRust"], true);
        assert_eq!(manifest["rustNumericCoreVersion"], "0.34.0");
        assert_eq!(manifest["protocolVersion"], 1);
    }

    #[test]
    fn executable_qualification_covers_completed_portable_surface() {
        let qualification = qualification_json();
        assert!(qualification.succeeded, "{}", qualification.json);
        let report: Value = serde_json::from_str(&qualification.json).unwrap();
        assert_eq!(report["cases"].as_array().unwrap().len(), 10);
    }
}
