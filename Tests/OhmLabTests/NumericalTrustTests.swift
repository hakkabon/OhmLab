import Foundation
import Testing
@testable import OhmLabCore

@Suite("OhmLab 1.1 numerical trust")
struct NumericalTrustTests {
    @Test func analyticalCorpusQualifiesEveryRequiredBackend() {
        let report = NumericalTrust.evaluate()
        #expect(report.contractVersion == 1)
        #expect(report.productVersion == "2.1.0")
        #expect(report.caseCount == 32)
        #expect(report.ready)
        #expect(report.issues.isEmpty)
        #expect(report.backends.first { $0.identifier == "native-mna" }?.passed == true)
        #expect(report.backends.first { $0.identifier == "numeric-core" }?.passed == true)
        #expect(report.backends.filter(\.required).allSatisfy { $0.passed })
        #expect(report.backends.allSatisfy { $0.cases.count == report.caseCount })
    }

    @Test func seededCorpusIsNumericallyDeterministic() throws {
        let first = NumericalTrust.evaluate(seed: 42)
        let second = NumericalTrust.evaluate(seed: 42)
        let changed = NumericalTrust.evaluate(seed: 43)

        let firstExpected = first.backends.first?.cases.flatMap(\.measurements).map(\.expected)
        let secondExpected = second.backends.first?.cases.flatMap(\.measurements).map(\.expected)
        let changedExpected = changed.backends.first?.cases.flatMap(\.measurements).map(\.expected)
        #expect(firstExpected == secondExpected)
        #expect(firstExpected != changedExpected)
    }

    @Test func reportSerializesVerdictAndDiagnostics() throws {
        let data = try JSONEncoder().encode(NumericalTrust.evaluate(seed: 7))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["ready"] as? Bool == true)
        #expect(object["caseCount"] as? Int == 32)
        let backends = try #require(object["backends"] as? [[String: Any]])
        let cases = try #require(backends.first?["cases"] as? [[String: Any]])
        let measurements = try #require(cases.first?["measurements"] as? [[String: Any]])
        #expect(measurements.first?["absoluteError"] != nil)
        #expect(cases.first?["elapsedMilliseconds"] != nil)
    }
}
