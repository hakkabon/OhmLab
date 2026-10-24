import Foundation

/// Product version shipped on the stable 1.x production boundary.
public enum OhmLabRelease {
    public static let version = "1.1.0"
    public static let productionBoundaryVersion = 1
}

/// Whether a backend is covered by OhmLab's production compatibility promise.
public enum SimulationBackendMaturity: String, Codable, Sendable, Comparable {
    case production
    case preview
    case external

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A backend declaration plus the validation findings that qualify it for use.
public struct SimulationBackendDescriptor: Codable, Equatable, Sendable {
    public let identifier: String
    public let implementationVersion: String?
    public let maturity: SimulationBackendMaturity
    public let capabilities: SimulationBackendCapabilities
    public let issues: [String]

    public var isValid: Bool { issues.isEmpty }
    public var isProductionReady: Bool { maturity == .production && isValid }

    init(backend: any SimulationEngineBackend) {
        identifier = backend.identifier
        implementationVersion = backend.implementationVersion
        maturity = backend.maturity
        capabilities = backend.capabilities
        issues = Self.validate(
            identifier: backend.identifier,
            implementationVersion: backend.implementationVersion,
            maturity: backend.maturity,
            capabilities: backend.capabilities
        )
    }

    private static func validate(
        identifier: String,
        implementationVersion: String?,
        maturity: SimulationBackendMaturity,
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
        return issues
    }
}

public struct ProductionContractVersions: Codable, Equatable, Sendable {
    public let productionBoundary: Int
    public let capabilityContract: Int
    public let circuitIR: Int
    public let simulationResult: Int
    public let rustTransport: Int
    public let numericalTrust: Int
}

/// Machine-readable answer to “is this build safe to ship on the stable 1.x boundary?”.
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
        let production = descriptors.filter(\.isProductionReady)
        if production.map(\.identifier) != ["native-mna"] {
            issues.append("native-mna must be the sole production-qualified backend")
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
                rustTransport: RustCircuitTransport.currentVersion,
                numericalTrust: NumericalTrust.currentContractVersion
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
