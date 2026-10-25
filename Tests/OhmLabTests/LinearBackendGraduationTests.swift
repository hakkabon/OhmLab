import Foundation
import Testing
@testable import OhmLabCore

@Suite("OhmLab 1.2 linear backend graduation")
struct LinearBackendGraduationTests {
    @Test func numericCorePassesTheExecutableGraduationContract() throws {
        let report = LinearBackendGraduation.evaluate()
        #expect(report.contractVersion == 1)
        #expect(report.productVersion == "2.4.0")
        #expect(report.requiredBackends == ["numeric-core"])
        #expect(report.ready)
        #expect(report.issues.isEmpty)

        let numeric = try #require(report.backends.first { $0.identifier == "numeric-core" })
        #expect(numeric.maturity == .nonlinearProduction)
        #expect(numeric.declarationPassed)
        #expect(numeric.numericalTrustPassed)
        #expect(numeric.transientCases.count == 6)
        #expect(numeric.transientCases.allSatisfy { $0.passed })
        #expect(numeric.passed)
    }

    @Test func reportSerializesScopeAndEvidence() throws {
        let data = try JSONEncoder().encode(LinearBackendGraduation.evaluate())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["ready"] as? Bool == true)
        #expect(object["requiredBackends"] as? [String] == ["numeric-core"])
        let backends = try #require(object["backends"] as? [[String: Any]])
        let cases = try #require(backends.first?["transientCases"] as? [[String: Any]])
        #expect(cases.count == 6)
        #expect(cases.allSatisfy { $0["absoluteError"] != nil })
    }

}
