import Foundation

/// Versioned, language-neutral execution boundary for headless simulation.
/// The JSON protocol contains only Circuit IR, an analysis plan, and result
/// values; no Swift, UI, plugin, or process-global engine state crosses it.
public enum PortableSimulationPlatform {
    public static let currentContractVersion = 1
    public static let mediaType = "application/vnd.ohmlab.simulation+json;version=1"
    public static let requestSchemaID = "urn:ohmlab:schema:portable-simulation-request:1"
    public static let responseSchemaID = "urn:ohmlab:schema:portable-simulation-response:1"

    public struct Limits: Codable, Equatable, Sendable {
        public let maximumRequestBytes: Int
        public let maximumNodes: Int
        public let maximumDevices: Int
        public let maximumAnalysisSamples: Int
        public let maximumWaveformPoints: Int
        public let maximumNameBytes: Int
        public let maximumSolverIterations: Int

        public init(
            maximumRequestBytes: Int = 16 * 1_024 * 1_024,
            maximumNodes: Int = 100_000,
            maximumDevices: Int = 200_000,
            maximumAnalysisSamples: Int = 100_000,
            maximumWaveformPoints: Int = 100_000,
            maximumNameBytes: Int = 1_024,
            maximumSolverIterations: Int = 10_000
        ) {
            self.maximumRequestBytes = maximumRequestBytes
            self.maximumNodes = maximumNodes
            self.maximumDevices = maximumDevices
            self.maximumAnalysisSamples = maximumAnalysisSamples
            self.maximumWaveformPoints = maximumWaveformPoints
            self.maximumNameBytes = maximumNameBytes
            self.maximumSolverIterations = maximumSolverIterations
        }
    }

    public static let limits = Limits()

    public struct ACSweep: Codable, Equatable, Sendable {
        public let type: FrequencySweepType
        public let startFrequency: Double
        public let stopFrequency: Double
        public let points: Int

        public init(type: FrequencySweepType, startFrequency: Double, stopFrequency: Double, points: Int) {
            self.type = type
            self.startFrequency = startFrequency
            self.stopFrequency = stopFrequency
            self.points = points
        }
    }

    public struct Transient: Codable, Equatable, Sendable {
        public let step: Double
        public let stop: Double
        public let start: Double

        public init(step: Double, stop: Double, start: Double = 0) {
            self.step = step
            self.stop = stop
            self.start = start
        }
    }

    public struct DCSweep: Codable, Equatable, Sendable {
        public let source: String
        public let start: Double
        public let stop: Double
        public let step: Double

        public init(source: String, start: Double, stop: Double, step: Double) {
            self.source = source
            self.start = start
            self.stop = stop
            self.step = step
        }
    }

    public struct AnalysisPlan: Codable, Equatable, Sendable {
        public let dcOperatingPoint: Bool
        public let ac: ACSweep?
        public let transient: Transient?
        public let dcSweep: DCSweep?

        public init(
            dcOperatingPoint: Bool = true,
            ac: ACSweep? = nil,
            transient: Transient? = nil,
            dcSweep: DCSweep? = nil
        ) {
            self.dcOperatingPoint = dcOperatingPoint
            self.ac = ac
            self.transient = transient
            self.dcSweep = dcSweep
        }

        fileprivate func settings() throws -> AnalysisSettings {
            guard dcOperatingPoint || ac != nil || transient != nil || dcSweep != nil else {
                throw PlatformError.invalidRequest("at least one analysis is required")
            }
            if let ac {
                guard ac.startFrequency.isFinite, ac.stopFrequency.isFinite,
                      ac.startFrequency > 0, ac.stopFrequency >= ac.startFrequency,
                      ac.points > 0 else {
                    throw PlatformError.invalidRequest("invalid AC sweep")
                }
                let samples: Double
                switch ac.type {
                case .lin: samples = Double(ac.points)
                case .dec: samples = ceil(log10(ac.stopFrequency / ac.startFrequency) * Double(ac.points)) + 2
                case .oct: samples = ceil(log2(ac.stopFrequency / ac.startFrequency) * Double(ac.points)) + 2
                }
                guard samples.isFinite, samples <= Double(limits.maximumAnalysisSamples) else {
                    throw PlatformError.invalidRequest("AC sweep exceeds the \(limits.maximumAnalysisSamples)-sample limit")
                }
            }
            if let transient {
                guard transient.step.isFinite, transient.stop.isFinite, transient.start.isFinite,
                      transient.step > 0, transient.stop > 0,
                      transient.start >= 0, transient.start <= transient.stop else {
                    throw PlatformError.invalidRequest("invalid transient analysis")
                }
                let samples = ceil(transient.stop / transient.step) + 1
                guard samples.isFinite, samples <= Double(limits.maximumAnalysisSamples) else {
                    throw PlatformError.invalidRequest("transient analysis exceeds the \(limits.maximumAnalysisSamples)-sample limit")
                }
            }
            if let dcSweep {
                guard !dcSweep.source.isEmpty,
                      dcSweep.start.isFinite, dcSweep.stop.isFinite, dcSweep.step.isFinite,
                      dcSweep.step != 0,
                      dcSweep.start == dcSweep.stop
                        || (dcSweep.stop > dcSweep.start && dcSweep.step > 0)
                        || (dcSweep.stop < dcSweep.start && dcSweep.step < 0) else {
                    throw PlatformError.invalidRequest("invalid DC sweep")
                }
                let samples = ceil(abs((dcSweep.stop - dcSweep.start) / dcSweep.step)) + 1
                guard samples.isFinite, samples <= Double(limits.maximumAnalysisSamples) else {
                    throw PlatformError.invalidRequest("DC sweep exceeds the \(limits.maximumAnalysisSamples)-sample limit")
                }
            }
            return AnalysisSettings(
                runDC: dcOperatingPoint,
                runAC: ac != nil,
                runTransient: transient != nil,
                acStartFrequency: ac?.startFrequency ?? 1,
                acStopFrequency: ac?.stopFrequency ?? 1,
                acPointsPerDecade: ac?.points ?? 1,
                acSweepType: ac?.type ?? .lin,
                tranStep: transient?.step ?? 1e-4,
                tranStop: transient?.stop ?? 1e-2,
                tranStart: transient?.start ?? 0,
                runDCSweep: dcSweep != nil,
                dcSweepSource: dcSweep?.source ?? "",
                dcSweepStart: dcSweep?.start ?? 0,
                dcSweepStop: dcSweep?.stop ?? 0,
                dcSweepStep: dcSweep?.step ?? 1
            )
        }
    }

    public struct Request: Codable, Equatable, Sendable {
        public let protocolVersion: Int
        public let requestID: String
        public let backend: String
        public let circuit: CircuitIR
        public let analysis: AnalysisPlan

        public init(
            protocolVersion: Int = currentContractVersion,
            requestID: String,
            backend: String = "native-mna",
            circuit: CircuitIR,
            analysis: AnalysisPlan
        ) {
            self.protocolVersion = protocolVersion
            self.requestID = requestID
            self.backend = backend
            self.circuit = circuit
            self.analysis = analysis
        }
    }

    public enum Status: String, Codable, Sendable { case success, failure }
    public enum ErrorCode: String, Codable, Sendable {
        case unsupportedProtocol = "unsupported-protocol"
        case invalidRequest = "invalid-request"
        case unknownBackend = "unknown-backend"
        case unsupportedCapability = "unsupported-capability"
        case simulationFailed = "simulation-failed"
    }

    public struct Failure: Codable, Equatable, Sendable {
        public let code: ErrorCode
        public let message: String
    }

    /// Stable, deterministic evidence needed to reproduce a successful run.
    /// Circuit models are embedded in Circuit IR v1, so no host filesystem or
    /// mutable model-library lookup participates in the digest.
    public struct Provenance: Codable, Equatable, Sendable {
        public let productVersion: String
        public let protocolMediaType: String
        public let circuitIRVersion: Int
        public let simulationResultVersion: Int
        public let backend: String
        public let implementationVersion: String?
        public let modelSource: String
        public let requestSHA256: String
    }

    public struct Response: Codable, Equatable, Sendable {
        public let protocolVersion: Int
        public let requestID: String
        public let status: Status
        public let backend: String?
        public let implementationVersion: String?
        public let provenance: Provenance?
        public let result: Result?
        public let error: Failure?

        public var succeeded: Bool { status == .success && result != nil && error == nil }
    }

    public struct Manifest: Codable, Equatable, Sendable {
        public let productVersion: String
        public let protocolVersion: Int
        public let mediaType: String
        public let requestSchemaID: String
        public let responseSchemaID: String
        public let canonicalEncoding: String
        public let provenanceDigest: String
        public let circuitIRVersion: Int
        public let simulationResultVersion: Int
        public let supportedAnalyses: [SimulationAnalysisKind]
        public let supportedFeatures: [SimulationBackendFeature]
        public let limits: Limits
        public let backends: [SimulationBackendDescriptor]
    }

    public struct NamedValue: Codable, Equatable, Sendable {
        public let name: String
        public let value: Double
    }

    public struct ComponentValue: Codable, Equatable, Sendable {
        public let name: String
        public let voltage: Double
        public let current: Double
    }

    public struct FrequencyPoint: Codable, Equatable, Sendable {
        public let frequency: Double
        public let magnitudeDB: Double
        public let phaseDegrees: Double
    }

    public struct NamedFrequencySeries: Codable, Equatable, Sendable {
        public let name: String
        public let values: [FrequencyPoint]
    }

    public struct NamedSeries: Codable, Equatable, Sendable {
        public let name: String
        public let values: [Double]
    }

    public struct DCResult: Codable, Equatable, Sendable {
        public let nodes: [NamedValue]
        public let components: [ComponentValue]
        public let sources: [NamedValue]
        public let converged: Bool
    }

    public struct ACResult: Codable, Equatable, Sendable {
        public let frequencies: [Double]
        public let nodes: [NamedFrequencySeries]
        public let components: [NamedFrequencySeries]
    }

    public struct TransientResult: Codable, Equatable, Sendable {
        public let times: [Double]
        public let nodes: [NamedSeries]
        public let components: [NamedSeries]
    }

    public struct SweepAxis: Codable, Equatable, Sendable {
        public let name: String
        public let values: [Double]
    }

    public struct SweepPoint: Codable, Equatable, Sendable {
        public let coordinates: [NamedValue]
        public let nodes: [NamedValue]
        public let components: [ComponentValue]
    }

    public struct SweepResult: Codable, Equatable, Sendable {
        public let axes: [SweepAxis]
        public let points: [SweepPoint]
    }

    public struct Harmonic: Codable, Equatable, Sendable {
        public let number: Int
        public let frequency: Double
        public let magnitude: Double
        public let phaseDegrees: Double
        public let normalizedMagnitude: Double
        public let normalizedPhaseDegrees: Double
    }

    public struct FourierResult: Codable, Equatable, Sendable {
        public let variable: String
        public let fundamentalFrequency: Double
        public let dcComponent: Double
        public let totalHarmonicDistortion: Double
        public let harmonics: [Harmonic]
    }

    public struct Result: Codable, Equatable, Sendable {
        public let contractVersion: Int
        public let dc: DCResult?
        public let ac: ACResult?
        public let transient: TransientResult?
        public let sweep: SweepResult?
        public let fourier: [FourierResult]
        public let warnings: [String]

        fileprivate init(_ result: CircuitSimResult) {
            contractVersion = result.contractVersion
            dc = result.dc.map { value in
                DCResult(
                    nodes: value.nodes.map { .init(name: $0.name, value: $0.voltage) },
                    components: value.components.map { .init(name: $0.name, voltage: $0.voltage, current: $0.current) },
                    sources: value.sources.map { .init(name: $0.name, value: $0.current) },
                    converged: value.converged
                )
            }
            ac = result.ac.map { value in
                ACResult(
                    frequencies: value.frequencies,
                    nodes: value.nodes.map { .init(name: $0.name, values: $0.response.map(FrequencyPoint.init)) },
                    components: value.components.map { .init(name: $0.name, values: $0.response.map(FrequencyPoint.init)) }
                )
            }
            transient = result.transient.map { value in
                TransientResult(
                    times: value.times,
                    nodes: value.nodes.map { .init(name: $0.name, values: $0.values) },
                    components: value.components.map { .init(name: $0.name, values: $0.values) }
                )
            }
            sweep = result.sweep.map { value in
                SweepResult(
                    axes: value.axes.map { .init(name: $0.name, values: $0.values) },
                    points: value.points.map { point in
                        .init(
                            coordinates: point.coordinates.map { .init(name: $0.name, value: $0.value) },
                            nodes: point.nodes.map { .init(name: $0.name, value: $0.voltage) },
                            components: point.components.map { .init(name: $0.name, voltage: $0.voltage, current: $0.current) }
                        )
                    }
                )
            }
            fourier = result.fourier.map { value in
                .init(
                    variable: value.variable,
                    fundamentalFrequency: value.fundamentalFrequency,
                    dcComponent: value.spectrum.dcComponent,
                    totalHarmonicDistortion: value.spectrum.totalHarmonicDistortion,
                    harmonics: value.spectrum.harmonics.map {
                        .init(number: $0.number, frequency: $0.frequency, magnitude: $0.magnitude,
                              phaseDegrees: $0.phaseDegrees, normalizedMagnitude: $0.normalizedMagnitude,
                              normalizedPhaseDegrees: $0.normalizedPhaseDegrees)
                    }
                )
            }
            warnings = result.warnings
        }
    }

    public static var manifest: Manifest {
        Manifest(
            productVersion: OhmLabRelease.version,
            protocolVersion: currentContractVersion,
            mediaType: mediaType,
            requestSchemaID: requestSchemaID,
            responseSchemaID: responseSchemaID,
            canonicalEncoding: "json-sorted-keys-utf8",
            provenanceDigest: "sha-256",
            circuitIRVersion: CircuitIR.currentSchemaVersion,
            simulationResultVersion: SimulationResultContract.currentVersion,
            supportedAnalyses: [.dcOperatingPoint, .acSmallSignal, .transient, .dcSweep],
            supportedFeatures: [.circuitIRInput, .sourceWaveforms, .initialConditions, .temperature],
            limits: limits,
            backends: EngineBackends.descriptorMatrix.filter(\.isProductionQualified)
        )
    }

    public static func execute(_ request: Request) -> Response {
        func failure(_ code: ErrorCode, _ message: String, backend: String? = nil) -> Response {
            Response(protocolVersion: currentContractVersion, requestID: request.requestID,
                     status: .failure, backend: backend, implementationVersion: nil,
                     provenance: nil, result: nil, error: Failure(code: code, message: message))
        }
        guard request.protocolVersion == currentContractVersion else {
            return failure(.unsupportedProtocol, "unsupported portable simulation protocol version \(request.protocolVersion)")
        }
        guard !request.requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.requestID.utf8.count <= 256 else {
            return failure(.invalidRequest, "requestID must contain 1...256 UTF-8 bytes")
        }
        guard request.circuit.nodes.count <= limits.maximumNodes,
              request.circuit.devices.count <= limits.maximumDevices else {
            return failure(.invalidRequest, "circuit exceeds portable platform limits")
        }
        guard let backend = EngineBackends.make(request.backend) else {
            return failure(.unknownBackend, "unknown backend \(request.backend)")
        }
        do {
            try request.circuit.validate()
            try validateResourceBudget(request)
            try ProductionBoundary.requireValid(backend)
            guard backend.capabilities.supports(.circuitIRInput) else {
                return failure(.unsupportedCapability, "backend does not accept Circuit IR", backend: backend.identifier)
            }
            let settings = try request.analysis.settings()
            let requested: [(Bool, SimulationAnalysisKind)] = [
                (settings.runDC, .dcOperatingPoint), (settings.runAC, .acSmallSignal),
                (settings.runTransient, .transient), (settings.runDCSweep, .dcSweep),
            ]
            if let missing = requested.first(where: { $0.0 && !backend.capabilities.supports($0.1) })?.1 {
                return failure(.unsupportedCapability, "backend does not support \(missing.rawValue)", backend: backend.identifier)
            }
            let raw = try backend.solve(circuit: request.circuit, settings: settings)
            try SimulationResultContract.validate(raw)
            let canonicalRequest = try encode(request)
            return Response(
                protocolVersion: currentContractVersion,
                requestID: request.requestID,
                status: .success,
                backend: backend.identifier,
                implementationVersion: backend.implementationVersion,
                provenance: Provenance(
                    productVersion: OhmLabRelease.version,
                    protocolMediaType: mediaType,
                    circuitIRVersion: request.circuit.schemaVersion,
                    simulationResultVersion: raw.contractVersion,
                    backend: backend.identifier,
                    implementationVersion: backend.implementationVersion,
                    modelSource: "embedded-circuit-ir",
                    requestSHA256: StableSHA256.hexDigest(canonicalRequest)
                ),
                result: Result(raw),
                error: nil
            )
        } catch let error as PlatformError {
            return failure(error.code, error.localizedDescription, backend: backend.identifier)
        } catch let error as CircuitIRError {
            return failure(.invalidRequest, error.localizedDescription, backend: backend.identifier)
        } catch {
            return failure(.simulationFailed, error.localizedDescription, backend: backend.identifier)
        }
    }

    /// Decodes and executes one complete JSON envelope. Malformed input is
    /// returned as a protocol-shaped failure so hosts never have to invent an
    /// out-of-band error format.
    public static func execute(_ data: Data) -> Response {
        do { return execute(try decodeRequest(data)) }
        catch {
            return Response(
                protocolVersion: currentContractVersion,
                requestID: "",
                status: .failure,
                backend: nil,
                implementationVersion: nil,
                provenance: nil,
                result: nil,
                error: Failure(code: .invalidRequest, message: error.localizedDescription)
            )
        }
    }

    public static func decodeRequest(_ data: Data) throws -> Request {
        guard data.count <= limits.maximumRequestBytes else {
            throw PlatformError.invalidRequest("request exceeds \(limits.maximumRequestBytes) bytes")
        }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dictionary = object as? [String: Any] else {
                throw PlatformError.invalidRequest("request JSON must be an object")
            }
            try validateKnownJSONMembers(dictionary)
            return try JSONDecoder().decode(Request.self, from: data)
        }
        catch let error as PlatformError { throw error }
        catch { throw PlatformError.invalidRequest("invalid request JSON") }
    }

    public static func encode<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private enum PlatformError: LocalizedError {
        case invalidRequest(String)
        var code: ErrorCode { .invalidRequest }
        var errorDescription: String? {
            switch self { case .invalidRequest(let message): message }
        }
    }

    private static func validateResourceBudget(_ request: Request) throws {
        let names = request.circuit.nodes.map(\.name) + request.circuit.devices.map(\.name)
        guard names.allSatisfy({ $0.utf8.count <= limits.maximumNameBytes }) else {
            throw PlatformError.invalidRequest("circuit name exceeds \(limits.maximumNameBytes) UTF-8 bytes")
        }
        guard request.circuit.solver.maximumIterations <= limits.maximumSolverIterations else {
            throw PlatformError.invalidRequest("solver exceeds the \(limits.maximumSolverIterations)-iteration limit")
        }
        let waveformPoints = request.circuit.devices.reduce(into: 0) { count, device in
            count += device.source?.transient?.points.count ?? 0
        }
        guard waveformPoints <= limits.maximumWaveformPoints else {
            throw PlatformError.invalidRequest("circuit exceeds the \(limits.maximumWaveformPoints)-waveform-point limit")
        }
        guard request.circuit.initialConditions.nodeVoltages.count <= request.circuit.nodes.count,
              request.circuit.initialConditions.elementCurrents.count <= request.circuit.devices.count else {
            throw PlatformError.invalidRequest("initial conditions exceed circuit dimensions")
        }
    }

    /// Swift decoding deliberately ignores unknown keys. Protocol v1 instead
    /// fails closed so a misspelled option cannot appear to have taken effect.
    private static func validateKnownJSONMembers(_ root: [String: Any]) throws {
        try requireKeys(root, ["protocolVersion", "requestID", "backend", "circuit", "analysis"], at: "request")
        if let analysis = root["analysis"] as? [String: Any] {
            try requireKeys(analysis, ["dcOperatingPoint", "ac", "transient", "dcSweep"], at: "analysis")
            if let ac = analysis["ac"] as? [String: Any] {
                try requireKeys(ac, ["type", "startFrequency", "stopFrequency", "points"], at: "analysis.ac")
            }
            if let transient = analysis["transient"] as? [String: Any] {
                try requireKeys(transient, ["step", "stop", "start"], at: "analysis.transient")
            }
            if let sweep = analysis["dcSweep"] as? [String: Any] {
                try requireKeys(sweep, ["source", "start", "stop", "step"], at: "analysis.dcSweep")
            }
        }
        guard let circuit = root["circuit"] as? [String: Any] else { return }
        try requireKeys(
            circuit, ["schemaVersion", "referenceNode", "nodes", "devices", "solver", "initialConditions"],
            at: "circuit"
        )
        for (index, value) in (circuit["nodes"] as? [Any] ?? []).enumerated() {
            if let node = value as? [String: Any] {
                try requireKeys(node, ["name"], at: "circuit.nodes[\(index)]")
            }
        }
        for (index, value) in (circuit["devices"] as? [Any] ?? []).enumerated() {
            guard let device = value as? [String: Any] else { continue }
            let path = "circuit.devices[\(index)]"
            try requireKeys(
                device, ["name", "kind", "terminals", "value", "source", "diode", "bjt", "mosfet", "jfet"],
                at: path
            )
            if let source = device["source"] as? [String: Any] {
                try requireKeys(source, ["dcValue", "acMagnitude", "acPhaseDegrees", "transient"], at: "\(path).source")
                if let waveform = source["transient"] as? [String: Any] {
                    try requireKeys(waveform, ["kind", "parameters", "points"], at: "\(path).source.transient")
                    for (pointIndex, value) in (waveform["points"] as? [Any] ?? []).enumerated() {
                        if let point = value as? [String: Any] {
                            try requireKeys(point, ["time", "value"], at: "\(path).source.transient.points[\(pointIndex)]")
                        }
                    }
                }
            }
            let modelKeys: [(String, Set<String>)] = [
                ("diode", ["saturationCurrent", "emissionCoefficient", "thermalVoltage", "area",
                           "saturationCurrentTemperatureExponent", "activationEnergy"]),
                ("bjt", ["polarity", "saturationCurrent", "forwardBeta", "reverseBeta", "thermalVoltage",
                         "saturationCurrentTemperatureExponent", "activationEnergy", "betaTemperatureExponent"]),
                ("mosfet", ["polarity", "thresholdVoltage", "transconductanceParameter",
                            "channelLengthModulation", "bodyEffect", "surfacePotential",
                            "mobilityTemperatureExponent", "thresholdTemperatureCoefficient"]),
                ("jfet", ["polarity", "thresholdVoltage", "transconductanceParameter",
                          "channelLengthModulation", "gateSaturationCurrent", "thermalVoltage",
                          "mobilityTemperatureExponent", "thresholdTemperatureCoefficient",
                          "saturationCurrentTemperatureExponent", "activationEnergy"]),
            ]
            for (name, keys) in modelKeys where device[name] != nil {
                if let model = device[name] as? [String: Any] {
                    try requireKeys(model, keys, at: "\(path).\(name)")
                }
            }
        }
        if let solver = circuit["solver"] as? [String: Any] {
            try requireKeys(
                solver, ["relativeTolerance", "absoluteCurrentTolerance", "absoluteVoltageTolerance",
                         "minimumConductance", "maximumIterations", "temperatureCelsius",
                         "nominalTemperatureCelsius"],
                at: "circuit.solver"
            )
        }
        if let conditions = circuit["initialConditions"] as? [String: Any] {
            try requireKeys(conditions, ["nodeVoltages", "elementCurrents"], at: "circuit.initialConditions")
        }
    }

    private static func requireKeys(_ value: [String: Any], _ allowed: Set<String>, at path: String) throws {
        let unknown = Set(value.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else {
            throw PlatformError.invalidRequest("\(path) contains unknown member \(unknown[0])")
        }
    }
}

private extension PortableSimulationPlatform.FrequencyPoint {
    init(_ point: FreqPoint) {
        self.init(frequency: point.freqHz, magnitudeDB: point.magnitudeDb, phaseDegrees: point.phaseDeg)
    }
}
