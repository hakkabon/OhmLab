import Foundation
import Testing
@testable import OhmLabCore
import OhmLabSimulationProtocol

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

    private struct IncompleteLinearBackend: SimulationEngineBackend {
        let identifier = "incomplete-linear"
        let maturity: SimulationBackendMaturity = .linearProduction
        let implementationVersion: String? = "1"
        let capabilities = SimulationBackendCapabilities(
            backendIdentifier: "incomplete-linear",
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

    @Test func releaseAndContractsRemainCompatibleAtTwoDotOne() {
        #expect(OhmLabRelease.version == "2.1.0")
        #expect(OhmLabRelease.productionBoundaryVersion == 5)
        #expect(CircuitIR.currentSchemaVersion == 1)
        #expect(SimulationResultContract.currentVersion == 1)
        #expect(SimulationBackendCapabilities.currentContractVersion == 1)
        #expect(NumericalTrust.currentContractVersion == 1)
        #expect(LinearBackendGraduation.currentContractVersion == 1)
        #expect(NonlinearConvergence.currentContractVersion == 1)
        #expect(PortableSimulationPlatform.currentContractVersion == 1)
        #expect(SimulationHostContract.currentVersion == 1)
    }

    @Test func readinessReportQualifiesOnlyTheNativeReference() {
        SimulationEngine.resetToDefaultBackend()
        let report = ProductionBoundary.report()
        #expect(report.ready)
        #expect(report.productVersion == "2.1.0")
        #expect(report.contracts.simulationHost == 1)
        #expect(report.defaultBackend == "native-mna")
        #expect(report.backends.filter(\.isProductionReady).map(\.identifier) == ["native-mna"])
        #expect(report.backends.filter(\.isLinearProductionReady).map(\.identifier) == ["numeric-core"])
        #expect(report.backends.allSatisfy { $0.isValid })
        #expect(report.backends.filter(\.isNonlinearProductionReady).map(\.identifier) == ["numeric-core"])
        #expect(report.backends.first { $0.identifier == "numeric-core" }?.maturity == .nonlinearProduction)
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

    @Test func linearProductionDeclarationRequiresTheCompleteLinearSurface() {
        let descriptor = ProductionBoundary.descriptor(for: IncompleteLinearBackend())
        #expect(!descriptor.isValid)
        #expect(descriptor.issues.contains { $0.contains("DC, AC, and transient") })
        #expect(descriptor.issues.contains { $0.contains("R/C/L/V/I") })
        #expect(descriptor.issues.contains { $0.contains("execution feature") })
        #expect(throws: SimulationContractError.self) {
            try ProductionBoundary.requireValid(IncompleteLinearBackend())
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
