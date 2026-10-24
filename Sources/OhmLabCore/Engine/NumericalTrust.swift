import Foundation

/// Versioned, executable numerical-conformance contract for OhmLab 1.1.
public enum NumericalTrust {
    public static let currentContractVersion = 1
    public static let defaultSeed: UInt64 = 0x4f_48_4d_4c_41_42_11
    public static let minimumCaseCount = 32

    public struct Measurement: Codable, Equatable, Sendable {
        public let name: String
        public let expected: Double
        public let actual: Double?
        public let absoluteError: Double?
        public let tolerance: Double
        public let passed: Bool
    }

    public struct CaseResult: Codable, Equatable, Sendable {
        public let identifier: String
        public let category: String
        public let measurements: [Measurement]
        public let error: String?
        public let elapsedMilliseconds: Double
        public let passed: Bool
    }

    public struct BackendReport: Codable, Equatable, Sendable {
        public let identifier: String
        public let implementationVersion: String?
        public let required: Bool
        public let cases: [CaseResult]
        public let passed: Bool
    }

    public struct Report: Codable, Equatable, Sendable {
        public let contractVersion: Int
        public let productVersion: String
        public let seed: UInt64
        public let caseCount: Int
        public let backends: [BackendReport]
        public let issues: [String]
        public let ready: Bool
    }

    /// Runs deterministic analytical DC/AC cases against every linked backend
    /// that declares the required Circuit IR capabilities.
    public static func evaluate(seed: UInt64 = defaultSeed) -> Report {
        let cases: [TrustCase]
        do {
            cases = try makeCases(seed: seed)
        } catch {
            return Report(
                contractVersion: currentContractVersion,
                productVersion: OhmLabRelease.version,
                seed: seed,
                caseCount: 0,
                backends: [],
                issues: ["could not construct the analytical corpus: \(error.localizedDescription)"],
                ready: false
            )
        }
        let candidates = EngineBackends.canonicalBackends.filter {
            $0.capabilities.supports(.circuitIRInput)
                && $0.capabilities.supports(.dcOperatingPoint)
                && $0.capabilities.supports(.acSmallSignal)
        }
        let linkedIdentifiers = Set(candidates.map(\.identifier))
        var required = Set(["native-mna", "numeric-core"])
        if linkedIdentifiers.contains("ohm-core") { required.insert("ohm-core") }

        let reports = candidates.map { backend in
            evaluate(backend: backend, cases: cases, required: required.contains(backend.identifier))
        }
        var issues: [String] = []
        for identifier in required where !linkedIdentifiers.contains(identifier) {
            issues.append("required backend \(identifier) is not linked")
        }
        for report in reports where report.required && !report.passed {
            let failures = report.cases.filter { !$0.passed }.map(\.identifier).joined(separator: ", ")
            issues.append("\(report.identifier) failed: \(failures)")
        }
        if cases.count < minimumCaseCount {
            issues.append("conformance corpus contains only \(cases.count) cases")
        }
        return Report(
            contractVersion: currentContractVersion,
            productVersion: OhmLabRelease.version,
            seed: seed,
            caseCount: cases.count,
            backends: reports,
            issues: issues.sorted(),
            ready: issues.isEmpty
        )
    }
}

private extension NumericalTrust {
    enum Expectation {
        case dc(node: String, voltage: Double)
        case ac(node: String, magnitudeDB: Double, phaseDegrees: Double)
    }

    struct TrustCase {
        let identifier: String
        let category: String
        let circuit: CircuitIR
        let settings: AnalysisSettings
        let expectation: Expectation
    }

    struct Generator {
        var state: UInt64

        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64.max >> 11)
        }

        mutating func logarithmic(from lower: Double, to upper: Double) -> Double {
            pow(10, lower + (upper - lower) * next())
        }
    }

    static func makeCases(seed: UInt64) throws -> [TrustCase] {
        var generator = Generator(state: seed == 0 ? defaultSeed : seed)
        var result: [TrustCase] = []
        result.reserveCapacity(minimumCaseCount)

        for index in 0..<24 {
            let source = 0.1 + generator.next() * 23.9
            let upper = generator.logarithmic(from: 0, to: 7)
            let lower = generator.logarithmic(from: 0, to: 7)
            let expected = source * lower / (upper + lower)
            let netlist = "V1 in 0 \(source)\nR1 in out \(upper)\nR2 out 0 \(lower)\n.end"
            var settings = AnalysisSettings.default
            settings.runDC = true
            settings.runAC = false
            settings.runTransient = false
            let circuit = try CircuitIRCompiler.compile(netlist: netlist)
            result.append(TrustCase(
                identifier: String(format: "dc-divider-%02d", index + 1),
                category: "analytical-dc",
                circuit: circuit,
                settings: settings,
                expectation: .dc(node: "out", voltage: expected)
            ))
        }

        for index in 0..<8 {
            let resistance = generator.logarithmic(from: 1, to: 7)
            let capacitance = generator.logarithmic(from: -12, to: -3)
            let cutoff = 1 / (2 * Double.pi * resistance * capacitance)
            let ratio = pow(10, -1 + 2 * generator.next())
            let frequency = cutoff * ratio
            let omegaRC = 2 * Double.pi * frequency * resistance * capacitance
            let magnitudeDB = 20 * log10(1 / sqrt(1 + omegaRC * omegaRC))
            let phase = -atan(omegaRC) * 180 / Double.pi
            let netlist = "V1 in 0 DC 0 AC 1\nR1 in out \(resistance)\nC1 out 0 \(capacitance)\n.end"
            var settings = AnalysisSettings.default
            settings.runDC = false
            settings.runAC = true
            settings.runTransient = false
            settings.acSweepType = .lin
            settings.acStartFrequency = frequency
            settings.acStopFrequency = frequency * 1.000_001
            settings.acPointsPerDecade = 2
            let circuit = try CircuitIRCompiler.compile(netlist: netlist)
            result.append(TrustCase(
                identifier: String(format: "ac-rc-lowpass-%02d", index + 1),
                category: "analytical-ac",
                circuit: circuit,
                settings: settings,
                expectation: .ac(node: "out", magnitudeDB: magnitudeDB, phaseDegrees: phase)
            ))
        }
        return result
    }

    static func evaluate(
        backend: any SimulationEngineBackend,
        cases: [TrustCase],
        required: Bool
    ) -> BackendReport {
        let results = cases.map { testCase -> CaseResult in
            let start = Date.timeIntervalSinceReferenceDate
            do {
                let result = try backend.solve(circuit: testCase.circuit, settings: testCase.settings)
                try SimulationResultContract.validate(result)
                let measurements = measure(result, expectation: testCase.expectation)
                return CaseResult(
                    identifier: testCase.identifier,
                    category: testCase.category,
                    measurements: measurements,
                    error: nil,
                    elapsedMilliseconds: (Date.timeIntervalSinceReferenceDate - start) * 1_000,
                    passed: !measurements.isEmpty && measurements.allSatisfy(\.passed)
                )
            } catch {
                return CaseResult(
                    identifier: testCase.identifier,
                    category: testCase.category,
                    measurements: [],
                    error: error.localizedDescription,
                    elapsedMilliseconds: (Date.timeIntervalSinceReferenceDate - start) * 1_000,
                    passed: false
                )
            }
        }
        return BackendReport(
            identifier: backend.identifier,
            implementationVersion: backend.implementationVersion,
            required: required,
            cases: results,
            passed: results.allSatisfy(\.passed)
        )
    }

    static func measure(_ result: CircuitSimResult, expectation: Expectation) -> [Measurement] {
        switch expectation {
        case .dc(let node, let expected):
            let actual = result.dc?.nodes.first { $0.name.caseInsensitiveCompare(node) == .orderedSame }?.voltage
            return [measurement(name: "v(\(node))", expected: expected, actual: actual, absolute: 1e-9, relative: 1e-9)]
        case .ac(let node, let expectedMagnitude, let expectedPhase):
            let point = result.ac?.nodes.first {
                $0.name.caseInsensitiveCompare(node) == .orderedSame
            }?.response.first
            return [
                measurement(name: "v(\(node)).magnitude-db", expected: expectedMagnitude, actual: point?.magnitudeDb, absolute: 1e-6, relative: 1e-8),
                phaseMeasurement(name: "v(\(node)).phase-deg", expected: expectedPhase, actual: point?.phaseDeg, tolerance: 1e-6),
            ]
        }
    }

    static func measurement(
        name: String,
        expected: Double,
        actual: Double?,
        absolute: Double,
        relative: Double
    ) -> Measurement {
        let tolerance = absolute + relative * abs(expected)
        let error = actual.map { abs($0 - expected) }
        return Measurement(
            name: name,
            expected: expected,
            actual: actual,
            absoluteError: error,
            tolerance: tolerance,
            passed: error.map { $0 <= tolerance } ?? false
        )
    }

    static func phaseMeasurement(
        name: String,
        expected: Double,
        actual: Double?,
        tolerance: Double
    ) -> Measurement {
        let error = actual.map { value in
            let wrapped = (value - expected).truncatingRemainder(dividingBy: 360)
            return min(abs(wrapped), abs(abs(wrapped) - 360))
        }
        return Measurement(
            name: name,
            expected: expected,
            actual: actual,
            absoluteError: error,
            tolerance: tolerance,
            passed: error.map { $0 <= tolerance } ?? false
        )
    }
}
