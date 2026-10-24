import Foundation
import Testing
@testable import OhmLabCore

@Suite("OhmLab 1.0 production boundary")
struct ProductionBoundaryTests {
    private struct InvalidBackend: SimulationEngineBackend {
        let identifier = "invalid-backend"
        let capabilities = SimulationBackendCapabilities(
            backendIdentifier: "different-name",
            analyses: [.dcOperatingPoint],
            devices: [.resistor],
            features: [.spiceNetlistInput]
        )

        func solve(
            netlist: String,
            settings: AnalysisSettings,
            libraries: [SpiceModelLibrary]
        ) throws -> CircuitSimResult {
            CircuitSimResult(dc: nil, ac: nil, transient: nil, sweep: nil, fourier: [], warnings: [])
        }
    }

    @Test func releaseAndContractsRemainCompatibleAtOneDotOne() {
        #expect(OhmLabRelease.version == "1.1.0")
        #expect(OhmLabRelease.productionBoundaryVersion == 1)
        #expect(CircuitIR.currentSchemaVersion == 1)
        #expect(SimulationResultContract.currentVersion == 1)
        #expect(SimulationBackendCapabilities.currentContractVersion == 1)
        #expect(RustCircuitTransport.currentVersion == 1)
        #expect(NumericalTrust.currentContractVersion == 1)
    }

    @Test func readinessReportQualifiesOnlyTheNativeReference() {
        SimulationEngine.resetToDefaultBackend()
        let report = ProductionBoundary.report()
        #expect(report.ready)
        #expect(report.productVersion == "1.1.0")
        #expect(report.defaultBackend == "native-mna")
        #expect(report.backends.filter(\.isProductionReady).map(\.identifier) == ["native-mna"])
        #expect(report.backends.allSatisfy { $0.isValid })
        #expect(report.backends.first { $0.identifier == "numeric-core" }?.maturity == .preview)
        #if canImport(CCOhmCore)
        #expect(report.backends.first { $0.identifier == "ohm-core" }?.maturity == .preview)
        #endif
    }

    @Test func readinessReportSerializesItsVerdict() throws {
        let data = try JSONEncoder().encode(ProductionBoundary.report())
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"ready\":true"))
    }

    @Test func invalidBackendDeclarationFailsBeforeSelection() {
        let descriptor = ProductionBoundary.descriptor(for: InvalidBackend())
        #expect(!descriptor.isValid)
        #expect(descriptor.issues.contains { $0.contains("does not match") })
        #expect(throws: SimulationContractError.self) {
            try ProductionBoundary.requireValid(InvalidBackend())
        }
        #expect(throws: SimulationContractError.self) {
            try SimulationEngine.registerValidated(InvalidBackend(), makeDefault: true)
        }
    }

    @Test func extensionBoundaryRevalidatesProcessedResults() throws {
        let raw = CircuitSimResult(
            dc: .init(
                nodes: [("out", 1)], components: [], sources: [], converged: true
            ),
            ac: nil, transient: nil, sweep: nil, fourier: [], warnings: []
        )
        let malformed = CircuitSimResult(
            dc: .init(
                nodes: [("out", .nan)], components: [], sources: [], converged: true
            ),
            ac: nil, transient: nil, sweep: nil, fourier: [], warnings: []
        )
        #expect(throws: SimulationContractError.self) {
            try ProductionBoundary.validate(raw: raw, processed: malformed)
        }
    }
}
