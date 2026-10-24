import Foundation

/// Executable qualification contract for OhmLab's scoped linear-production
/// backend promise. Declaration checks are necessary, but graduation also
/// requires the analytical DC/AC trust corpus and transient conformance.
public enum LinearBackendGraduation {
    public static let currentContractVersion = 1
    public static let minimumTransientCaseCount = 6

    public struct TransientCaseResult: Codable, Equatable, Sendable {
        public let identifier: String
        public let expected: Double
        public let actual: Double?
        public let absoluteError: Double?
        public let tolerance: Double
        public let error: String?
        public let passed: Bool
    }

    public struct BackendReport: Codable, Equatable, Sendable {
        public let identifier: String
        public let implementationVersion: String?
        public let maturity: SimulationBackendMaturity
        public let declarationPassed: Bool
        public let numericalTrustPassed: Bool
        public let transientCases: [TransientCaseResult]
        public let passed: Bool
    }

    public struct Report: Codable, Equatable, Sendable {
        public let contractVersion: Int
        public let productVersion: String
        public let requiredBackends: [String]
        public let backends: [BackendReport]
        public let issues: [String]
        public let ready: Bool
    }

    /// Qualifies the stable Swift-NumericCore adapter. Standalone `ohm-core`
    /// is deliberately excluded: 1.2 retains it only as a deprecated
    /// compatibility backend before removal in 1.3.
    public static func evaluate() -> Report {
        let required = ["numeric-core"]
        let trust = NumericalTrust.evaluate()
        let trustByIdentifier = Dictionary(uniqueKeysWithValues: trust.backends.map { ($0.identifier, $0) })
        let candidates = EngineBackends.canonicalBackends.filter { required.contains($0.identifier) }
        let candidateIdentifiers = Set(candidates.map(\.identifier))
        var issues: [String] = []

        for identifier in required where !candidateIdentifiers.contains(identifier) {
            issues.append("required linear-production backend \(identifier) is not linked")
        }

        let reports = candidates.map { backend -> BackendReport in
            let descriptor = ProductionBoundary.descriptor(for: backend)
            let declarationPassed = descriptor.isLinearProductionReady
            let numericalTrustPassed = trustByIdentifier[backend.identifier]?.passed == true
            let transientCases = transientCases(for: backend)
            let passed = declarationPassed
                && numericalTrustPassed
                && transientCases.count >= minimumTransientCaseCount
                && transientCases.allSatisfy(\.passed)

            if !declarationPassed {
                issues.append("\(backend.identifier) does not have a valid linear-production declaration")
            }
            if !numericalTrustPassed {
                issues.append("\(backend.identifier) did not pass the numerical-trust DC/AC corpus")
            }
            let failures = transientCases.filter { !$0.passed }.map(\.identifier)
            if !failures.isEmpty {
                issues.append("\(backend.identifier) failed transient cases: \(failures.joined(separator: ", "))")
            }
            if transientCases.count < minimumTransientCaseCount {
                issues.append("\(backend.identifier) has insufficient transient qualification coverage")
            }

            return BackendReport(
                identifier: backend.identifier,
                implementationVersion: backend.implementationVersion,
                maturity: backend.maturity,
                declarationPassed: declarationPassed,
                numericalTrustPassed: numericalTrustPassed,
                transientCases: transientCases,
                passed: passed
            )
        }

        return Report(
            contractVersion: currentContractVersion,
            productVersion: OhmLabRelease.version,
            requiredBackends: required,
            backends: reports.sorted { $0.identifier < $1.identifier },
            issues: issues.sorted(),
            ready: issues.isEmpty && reports.count == required.count && reports.allSatisfy(\.passed)
        )
    }
}

private extension LinearBackendGraduation {
    struct TransientCase {
        let identifier: String
        let circuit: CircuitIR
        let settings: AnalysisSettings
        let expected: Double
        let tolerance: Double
    }

    static func transientCases(for backend: any SimulationEngineBackend) -> [TransientCaseResult] {
        do {
            return try makeTransientCases().map { testCase in
                do {
                    let result = try backend.solve(circuit: testCase.circuit, settings: testCase.settings)
                    try SimulationResultContract.validate(result)
                    let actual = result.transient?.nodes.first {
                        $0.name.caseInsensitiveCompare("out") == .orderedSame
                    }?.values.last
                    let absoluteError = actual.map { abs($0 - testCase.expected) }
                    return TransientCaseResult(
                        identifier: testCase.identifier,
                        expected: testCase.expected,
                        actual: actual,
                        absoluteError: absoluteError,
                        tolerance: testCase.tolerance,
                        error: actual == nil ? "transient output v(out) is missing" : nil,
                        passed: absoluteError.map { $0 <= testCase.tolerance } ?? false
                    )
                } catch {
                    return TransientCaseResult(
                        identifier: testCase.identifier,
                        expected: testCase.expected,
                        actual: nil,
                        absoluteError: nil,
                        tolerance: testCase.tolerance,
                        error: error.localizedDescription,
                        passed: false
                    )
                }
            }
        } catch {
            return [TransientCaseResult(
                identifier: "transient-corpus-construction",
                expected: 0,
                actual: nil,
                absoluteError: nil,
                tolerance: 0,
                error: error.localizedDescription,
                passed: false
            )]
        }
    }

    static func makeTransientCases() throws -> [TransientCase] {
        let values: [(Double, Double)] = [
            (100, 10e-6),
            (200, 5e-6),
            (1_000, 1e-6),
            (5_000, 200e-9),
            (10_000, 100e-9),
            (100_000, 10e-9),
        ]
        return try values.enumerated().map { index, pair in
            let (resistance, capacitance) = pair
            let timeConstant = resistance * capacitance
            let netlist = "V1 in 0 0\nR1 in out \(resistance)\nC1 out 0 \(capacitance)\n.ic V(out)=1\n.end"
            var settings = AnalysisSettings.default
            settings.runDC = false
            settings.runAC = false
            settings.runTransient = true
            settings.tranStep = timeConstant / 200
            settings.tranStop = timeConstant
            return TransientCase(
                identifier: String(format: "rc-discharge-%02d", index + 1),
                circuit: try CircuitIRCompiler.compile(netlist: netlist),
                settings: settings,
                expected: exp(-1),
                tolerance: 0.006
            )
        }
    }
}
