import Foundation

/// Executable release evidence for NumericCore scaling, residual certification,
/// bounded dense execution, and deterministic failure behavior.
public enum ScaleAndNumericalRobustness {
    public static let currentContractVersion = 1
    public static let maximumDenseUnknowns = 512
    public static let minimumCaseCount = 6

    public struct CaseResult: Codable, Equatable, Sendable {
        public let identifier: String
        public let detail: String
        public let error: String?
        public let passed: Bool
    }

    public struct Report: Codable, Equatable, Sendable {
        public let contractVersion: Int
        public let productVersion: String
        public let backend: String
        public let implementationVersion: String?
        public let maximumDenseUnknowns: Int
        public let cases: [CaseResult]
        public let issues: [String]
        public let ready: Bool
    }

    public static func evaluate() -> Report {
        let backend = NumericCoreEngineBackend()
        let cases = [
            measured(
                "mixed-impedance-divider",
                netlist: "V1 in 0 DC 1e6\nR1 in out 1e9\nR2 out 0 1e-3\n.end",
                node: "out",
                expected: 1e6 * 1e-3 / (1e9 + 1e-3),
                tolerance: 1e-12,
                backend: backend
            ),
            measured(
                "high-impedance-divider",
                netlist: "V1 in 0 DC 1\nR1 in out 1e12\nR2 out 0 1e12\n.end",
                node: "out",
                expected: 0.5,
                tolerance: 1e-9,
                backend: backend
            ),
            measured(
                "scaled-128-section-ladder",
                netlist: ladder(sectionCount: 128),
                node: "n64",
                expected: 5,
                tolerance: 1e-8,
                backend: backend
            ),
            sweepCase(backend),
            rejectionCase(
                "singular-topology-fails-closed",
                netlist: "V0 0 0 DC 0\nI1 a b DC 1m\nR1 a b 1k\n.end",
                backend: backend,
                expectsResourceLimit: false
            ),
            rejectionCase(
                "dense-budget-fails-before-solve",
                netlist: ladder(sectionCount: maximumDenseUnknowns + 1),
                backend: backend,
                expectsResourceLimit: true
            ),
        ]
        var issues: [String] = []
        if cases.count < minimumCaseCount {
            issues.append("scale corpus contains only \(cases.count) cases")
        }
        let failures = cases.filter { !$0.passed }.map(\.identifier)
        if !failures.isEmpty {
            issues.append("scale qualification failed: \(failures.joined(separator: ", "))")
        }
        return Report(
            contractVersion: currentContractVersion,
            productVersion: OhmLabRelease.version,
            backend: backend.identifier,
            implementationVersion: backend.implementationVersion,
            maximumDenseUnknowns: maximumDenseUnknowns,
            cases: cases,
            issues: issues,
            ready: issues.isEmpty
        )
    }
}

private extension ScaleAndNumericalRobustness {
    static var dcSettings: AnalysisSettings {
        var settings = AnalysisSettings.default
        settings.runDC = true
        settings.runAC = false
        settings.runTransient = false
        settings.runDCSweep = false
        return settings
    }

    static func measured(
        _ identifier: String,
        netlist: String,
        node: String,
        expected: Double,
        tolerance: Double,
        backend: NumericCoreEngineBackend
    ) -> CaseResult {
        do {
            let result = try backend.solve(netlist: netlist, settings: dcSettings, libraries: [])
            try SimulationResultContract.validate(result)
            guard let actual = result.dc?.nodes.first(where: {
                $0.name.caseInsensitiveCompare(node) == .orderedSame
            })?.voltage else {
                return .init(
                    identifier: identifier,
                    detail: "missing v(\(node))",
                    error: "DC node is absent",
                    passed: false
                )
            }
            let error = abs(actual - expected)
            return .init(
                identifier: identifier,
                detail: "expected \(expected), actual \(actual), absolute error \(error)",
                error: nil,
                passed: error <= tolerance
            )
        } catch {
            return .init(
                identifier: identifier,
                detail: "scaled DC solve",
                error: error.localizedDescription,
                passed: false
            )
        }
    }

    static func sweepCase(_ backend: NumericCoreEngineBackend) -> CaseResult {
        do {
            var settings = dcSettings
            settings.runDC = false
            settings.runDCSweep = true
            settings.dcSweepSource = "V1"
            settings.dcSweepStart = -10
            settings.dcSweepStop = 10
            settings.dcSweepStep = 0.2
            let result = try backend.solve(
                netlist: "V1 in 0 DC 0\nR1 in out 1e9\nR2 out 0 1e-3\n.end",
                settings: settings,
                libraries: []
            )
            try SimulationResultContract.validate(result)
            let values = result.sweep?.points.compactMap { point in
                point.nodes.first(where: { $0.name == "out" })?.voltage
            } ?? []
            let monotonic = zip(values, values.dropFirst()).allSatisfy { pair in
                pair.0 <= pair.1
            }
            return .init(
                identifier: "scaled-sweep-continuation",
                detail: "\(values.count) certified points",
                error: nil,
                passed: values.count == 101 && monotonic
            )
        } catch {
            return .init(
                identifier: "scaled-sweep-continuation",
                detail: "101-point mixed-impedance sweep",
                error: error.localizedDescription,
                passed: false
            )
        }
    }

    static func rejectionCase(
        _ identifier: String,
        netlist: String,
        backend: NumericCoreEngineBackend,
        expectsResourceLimit: Bool
    ) -> CaseResult {
        do {
            _ = try backend.solve(netlist: netlist, settings: dcSettings, libraries: [])
            return .init(
                identifier: identifier,
                detail: "request unexpectedly succeeded",
                error: nil,
                passed: false
            )
        } catch {
            let isResourceLimit = error is NumericCoreAdapterError
                && error.localizedDescription.contains("dense-solver budget")
            return .init(
                identifier: identifier,
                detail: error.localizedDescription,
                error: nil,
                passed: expectsResourceLimit ? isResourceLimit : !isResourceLimit
            )
        }
    }

    static func ladder(sectionCount: Int) -> String {
        var lines = ["V1 n0 0 DC 10"]
        for index in 1..<sectionCount {
            lines.append("R\(index) n\(index - 1) n\(index) 1k")
        }
        lines.append("R\(sectionCount) n\(sectionCount - 1) 0 1k")
        lines.append(".end")
        return lines.joined(separator: "\n")
    }
}
