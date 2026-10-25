import Foundation
import Testing
@testable import OhmLabCore

@Suite("OhmLab 1.3–1.5 nonlinear convergence")
struct NonlinearConvergenceTests {
    @Test func numericCorePassesTheExecutableNonlinearContract() throws {
        let report = NonlinearConvergence.evaluate()
        #expect(report.contractVersion == 1)
        #expect(report.productVersion == "2.0.1")
        #expect(report.referenceBackend == "native-mna")
        #expect(report.backend == "numeric-core")
        #expect(report.cases.count == 7)
        #expect(report.cases.allSatisfy { $0.passed })
        #expect(report.issues.isEmpty)
        #expect(report.ready)
        let scope = try #require(report.scope)
        #expect(scope.contractVersion == 1)
        #expect(scope.devices == [.level1NmosBodyTied, .shockleyDiode])
    }

    @Test func reportSerializesMeasurementsAndScope() throws {
        let data = try JSONEncoder().encode(NonlinearConvergence.evaluate())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["ready"] as? Bool == true)
        let scope = try #require(object["scope"] as? [String: Any])
        #expect(scope["contractVersion"] as? Int == 1)
        let cases = try #require(object["cases"] as? [[String: Any]])
        let measurements = try #require(cases.first?["measurements"] as? [[String: Any]])
        #expect(measurements.first?["absoluteError"] != nil)
    }

    @Test func unsupportedNonlinearVariantsFailClosed() throws {
        let backend = NumericCoreEngineBackend()
        var settings = AnalysisSettings.default
        settings.runAC = false

        let bjt = try CircuitIRCompiler.compile(netlist: """
        V1 c 0 5
        Q1 c b 0 QN
        V2 b 0 0.7
        .model QN NPN
        .end
        """)
        #expect(throws: NumericCoreAdapterError.self) {
            _ = try backend.solve(circuit: bjt, settings: settings)
        }

        let pmos = try CircuitIRCompiler.compile(netlist: """
        V1 s 0 5
        V2 g 0 2
        M1 d g s s PM
        R1 d 0 1k
        .model PM PMOS(VTO=-1 KP=1m)
        .end
        """)
        #expect(throws: NumericCoreAdapterError.self) {
            _ = try backend.solve(circuit: pmos, settings: settings)
        }
    }

    @Test func transientOnlyNetlistUsesTheNonlinearAdapter() throws {
        var settings = AnalysisSettings.default
        settings.runDC = false
        settings.runAC = false
        settings.runTransient = true
        settings.tranStep = 10e-6
        settings.tranStop = 100e-6
        let result = try NumericCoreEngineBackend().solve(
            netlist: """
            V1 in 0 PULSE(0 5 0 1u 1u 1m 2m)
            R1 in out 1k
            D1 out 0 DM
            .model DM D(IS=1e-14 N=1)
            .end
            """,
            settings: settings,
            libraries: []
        )
        #expect(result.dc == nil)
        #expect(result.ac == nil)
        #expect(result.transient?.nodes.first { $0.name == "out" }?.values.isEmpty == false)
    }
}
