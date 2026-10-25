import Foundation

/// Product version shipped on the stable production boundary.
public enum OhmLabRelease {
    public static let version = "2.0.0"
    public static let productionBoundaryVersion = 4
}

/// Whether a backend is covered by OhmLab's production compatibility promise.
public enum SimulationBackendMaturity: String, Codable, Sendable, Comparable {
    case production
    case linearProduction = "linear-production"
    case nonlinearProduction = "nonlinear-production"
    case preview
    case external

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum NonlinearBackendDevice: String, Codable, Sendable, CaseIterable, Comparable {
    case shockleyDiode = "shockley-diode"
    case level1NmosBodyTied = "level1-nmos-body-tied"

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct NonlinearBackendScope: Codable, Equatable, Sendable {
    public static let currentContractVersion = 1
    public let contractVersion: Int
    public let devices: [NonlinearBackendDevice]

    public init(
        devices: [NonlinearBackendDevice],
        contractVersion: Int = currentContractVersion
    ) {
        self.contractVersion = contractVersion
        self.devices = Array(Set(devices)).sorted()
    }
}

/// Lifecycle information is separate from numerical maturity so a backend can
/// remain available for a compatibility window without being recommended.
public enum SimulationBackendLifecycle: String, Codable, Sendable {
    case supported
    case deprecated
}

/// A backend declaration plus the validation findings that qualify it for use.
public struct SimulationBackendDescriptor: Codable, Equatable, Sendable {
    public let identifier: String
    public let implementationVersion: String?
    public let maturity: SimulationBackendMaturity
    public let lifecycle: SimulationBackendLifecycle
    public let deprecationMessage: String?
    public let removalVersion: String?
    public let nonlinearScope: NonlinearBackendScope?
    public let capabilities: SimulationBackendCapabilities
    public let issues: [String]

    public var isValid: Bool { issues.isEmpty }
    public var isProductionReady: Bool { maturity == .production && isValid }
    public var isLinearProductionReady: Bool {
        (maturity == .linearProduction || maturity == .nonlinearProduction) && isValid
    }
    public var isNonlinearProductionReady: Bool { maturity == .nonlinearProduction && isValid }
    public var isProductionQualified: Bool {
        isProductionReady || isLinearProductionReady || isNonlinearProductionReady
    }

    init(backend: any SimulationEngineBackend) {
        identifier = backend.identifier
        implementationVersion = backend.implementationVersion
        maturity = backend.maturity
        lifecycle = backend.lifecycle
        deprecationMessage = backend.deprecationMessage
        removalVersion = backend.removalVersion
        nonlinearScope = backend.nonlinearScope
        capabilities = backend.capabilities
        issues = Self.validate(
            identifier: backend.identifier,
            implementationVersion: backend.implementationVersion,
            maturity: backend.maturity,
            lifecycle: backend.lifecycle,
            deprecationMessage: backend.deprecationMessage,
            removalVersion: backend.removalVersion,
            nonlinearScope: backend.nonlinearScope,
            capabilities: backend.capabilities
        )
    }

    private static func validate(
        identifier: String,
        implementationVersion: String?,
        maturity: SimulationBackendMaturity,
        lifecycle: SimulationBackendLifecycle,
        deprecationMessage: String?,
        removalVersion: String?,
        nonlinearScope: NonlinearBackendScope?,
        capabilities: SimulationBackendCapabilities
    ) -> [String] {
        var issues: [String] = []
        let validIdentifier = identifier.range(
            of: "^[a-z0-9]+(?:-[a-z0-9]+)*$",
            options: .regularExpression
        ) != nil
        if !validIdentifier {
            issues.append("identifier must contain only lowercase ASCII letters, digits, and hyphens")
        }
        if capabilities.backendIdentifier != identifier {
            issues.append("capability identifier does not match backend identifier")
        }
        if capabilities.contractVersion != SimulationBackendCapabilities.currentContractVersion {
            issues.append("unsupported capability contract version \(capabilities.contractVersion)")
        }
        if capabilities.analyses.isEmpty { issues.append("no analyses declared") }
        if capabilities.devices.isEmpty { issues.append("no devices declared") }
        if !capabilities.supports(.spiceNetlistInput)
            && !capabilities.supports(.schematicInput)
            && !capabilities.supports(.circuitIRInput) {
            issues.append("no input boundary declared")
        }
        if let implementationVersion, implementationVersion.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append("implementation version is empty")
        }
        if lifecycle == .deprecated {
            if deprecationMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                issues.append("deprecated backend has no migration guidance")
            }
            if removalVersion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                issues.append("deprecated backend has no removal version")
            }
        } else if deprecationMessage != nil || removalVersion != nil {
            issues.append("supported backend declares deprecation metadata")
        }
        if maturity == .production {
            if implementationVersion == nil { issues.append("production backend has no implementation version") }
            if capabilities.analyses != SimulationAnalysisKind.allCases.sorted() {
                issues.append("production backend does not cover every analysis")
            }
            if capabilities.devices != CircuitIR.DeviceKind.allCases.sorted() {
                issues.append("production backend does not cover every device")
            }
            if capabilities.features != SimulationBackendFeature.allCases.sorted() {
                issues.append("production backend does not cover every execution feature")
            }
        }
        if maturity == .linearProduction || maturity == .nonlinearProduction {
            let analyses: Set<SimulationAnalysisKind> = [.dcOperatingPoint, .acSmallSignal, .transient]
            let devices: Set<CircuitIR.DeviceKind> = [.resistor, .capacitor, .inductor, .voltageSource, .currentSource]
            let features: Set<SimulationBackendFeature> = [.spiceNetlistInput, .circuitIRInput, .sourceWaveforms, .initialConditions]
            if implementationVersion == nil { issues.append("linear-production backend has no implementation version") }
            if !analyses.isSubset(of: Set(capabilities.analyses)) {
                issues.append("linear-production backend does not cover DC, AC, and transient analysis")
            }
            if !devices.isSubset(of: Set(capabilities.devices)) {
                issues.append("linear-production backend does not cover linear R/C/L/V/I devices")
            }
            if !features.isSubset(of: Set(capabilities.features)) {
                issues.append("linear-production backend lacks a required execution feature")
            }
        }
        if maturity == .nonlinearProduction {
            let required: Set<NonlinearBackendDevice> = [.shockleyDiode, .level1NmosBodyTied]
            guard let nonlinearScope else {
                issues.append("nonlinear-production backend has no nonlinear scope")
                return issues
            }
            if nonlinearScope.contractVersion != NonlinearBackendScope.currentContractVersion {
                issues.append("unsupported nonlinear scope contract version \(nonlinearScope.contractVersion)")
            }
            if !required.isSubset(of: Set(nonlinearScope.devices)) {
                issues.append("nonlinear-production backend lacks the required diode/NMOS scope")
            }
            if !capabilities.supports(.diode) || !capabilities.supports(.mosfet) {
                issues.append("nonlinear-production capability declaration omits diode or MOSFET")
            }
        } else if nonlinearScope != nil {
            issues.append("non-nonlinear backend declares a nonlinear-production scope")
        }
        return issues
    }
}

public struct ProductionContractVersions: Codable, Equatable, Sendable {
    public let productionBoundary: Int
    public let capabilityContract: Int
    public let circuitIR: Int
    public let simulationResult: Int
    public let numericalTrust: Int
    public let linearBackendGraduation: Int
    public let nonlinearConvergence: Int
    public let portableSimulation: Int
}

/// Machine-readable answer to “is this build safe to ship on the stable boundary?”.
public struct ProductionReadinessReport: Codable, Equatable, Sendable {
    public let productVersion: String
    public let contracts: ProductionContractVersions
    public let defaultBackend: String
    public let backends: [SimulationBackendDescriptor]
    public let issues: [String]
    public let ready: Bool
}

public enum ProductionBoundary {
    public static func descriptor(for backend: any SimulationEngineBackend) -> SimulationBackendDescriptor {
        SimulationBackendDescriptor(backend: backend)
    }

    public static func requireValid(_ backend: any SimulationEngineBackend) throws {
        let descriptor = descriptor(for: backend)
        guard descriptor.isValid else {
            throw SimulationContractError.invalidBackendDeclaration(
                backend.identifier,
                descriptor.issues.joined(separator: "; ")
            )
        }
    }

    public static func report() -> ProductionReadinessReport {
        let descriptors = EngineBackends.descriptorMatrix
        var issues = descriptors.flatMap { descriptor in
            descriptor.issues.map { "\(descriptor.identifier): \($0)" }
        }
        let fullProduction = descriptors.filter(\.isProductionReady)
        if fullProduction.map(\.identifier) != ["native-mna"] {
            issues.append("native-mna must be the sole full-production backend")
        }
        let linearProduction = descriptors.filter(\.isLinearProductionReady)
        if linearProduction.map(\.identifier) != ["numeric-core"] {
            issues.append("numeric-core must be the sole linear-production backend")
        }
        let nonlinearProduction = descriptors.filter(\.isNonlinearProductionReady)
        if nonlinearProduction.map(\.identifier) != ["numeric-core"] {
            issues.append("numeric-core must be the sole nonlinear-production backend")
        }
        if SimulationEngine.defaultBackendIdentifier != "native-mna" {
            issues.append("the default backend must be native-mna")
        }
        return ProductionReadinessReport(
            productVersion: OhmLabRelease.version,
            contracts: ProductionContractVersions(
                productionBoundary: OhmLabRelease.productionBoundaryVersion,
                capabilityContract: SimulationBackendCapabilities.currentContractVersion,
                circuitIR: CircuitIR.currentSchemaVersion,
                simulationResult: SimulationResultContract.currentVersion,
                numericalTrust: NumericalTrust.currentContractVersion,
                linearBackendGraduation: LinearBackendGraduation.currentContractVersion,
                nonlinearConvergence: NonlinearConvergence.currentContractVersion,
                portableSimulation: PortableSimulationPlatform.currentContractVersion
            ),
            defaultBackend: SimulationEngine.defaultBackendIdentifier,
            backends: descriptors,
            issues: issues.sorted(),
            ready: issues.isEmpty
        )
    }

    /// Validates both sides of the extension boundary. A plugin may annotate a
    /// result, but it may not invalidate units, axes, names, or finite values.
    static func validate(raw: CircuitSimResult, processed: CircuitSimResult) throws {
        try SimulationResultContract.validate(raw)
        do {
            try SimulationResultContract.validate(processed)
        } catch {
            throw SimulationContractError.postProcessorViolation(error.localizedDescription)
        }
    }
}
