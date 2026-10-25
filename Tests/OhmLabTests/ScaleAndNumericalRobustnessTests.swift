import Testing
@testable import OhmLabCore
import OhmLabSimulationProtocol

@Suite("OhmLab 2.4 scale and numerical robustness")
struct ScaleAndNumericalRobustnessTests {
    @Test func qualificationCorpusPasses() {
        let report = ScaleAndNumericalRobustness.evaluate()
        #expect(report.ready)
        #expect(report.productVersion == "2.4.0")
        #expect(report.contractVersion == 1)
        #expect(report.maximumDenseUnknowns == 512)
        #expect(report.cases.count >= ScaleAndNumericalRobustness.minimumCaseCount)
        #expect(report.cases.allSatisfy { $0.passed })
        #expect(report.cases.contains { $0.identifier == "scaled-128-section-ladder" })
        #expect(report.cases.contains { $0.identifier == "dense-budget-fails-before-solve" })
    }

    @Test func portableContractsPublishTheSameDenseEnvelope() {
        #expect(ScaleAndNumericalRobustnessContract.currentVersion == 1)
        #expect(ScaleAndNumericalRobustnessContract.requiresResidualCertification)
        #expect(ScaleAndNumericalRobustness.maximumDenseUnknowns ==
                ScaleAndNumericalRobustnessContract.maximumDenseUnknowns)
        #expect(NativeRustPortabilityContract.maximumDenseUnknowns ==
                ScaleAndNumericalRobustnessContract.maximumDenseUnknowns)
    }
}
