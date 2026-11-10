import Foundation
import Testing
@testable import OhmLabCore

@Suite("Design optimization and yield")
struct DesignOptimizationYieldTests {
    private let divider = "V1 1 0 DC 5\nR1 1 2 1k\nR2 2 0 1k\n"
    private let lowPass = "V1 in 0 DC 1 AC 1\nR1 in out 1k\nC1 out 0 1u\n"
    private let step = "V1 in 0 PULSE(0 5 0 1n 1n 1 2)\nR1 in out 1k\nC1 out 0 1u\n"

    private var transientSettings: AnalysisSettings {
        var settings = AnalysisSettings.default
        settings.runDC = true
        settings.runAC = false
        settings.runTransient = true
        settings.tranStep = 5e-6
        settings.tranStart = 0
        settings.tranStop = 1e-3
        return settings
    }

    // MARK: - Metric syntax

    @Test func metricTextRoundTrips() {
        let metrics: [OptimizeMetric] = [
            .dc(.nodeVoltage("out")),
            .dc(.elementCurrent("R1")),
            .ac(.nodeVoltage("out"), frequencyHz: 1_000, quantity: .magnitude),
            .ac(.elementCurrent("C1"), frequencyHz: 1e6, quantity: .magnitudeDB),
            .ac(.nodeVoltage("2"), frequencyHz: 10, quantity: .phaseDegrees),
            .transient(.nodeVoltage("out"), time: 1e-3)
        ]
        for metric in metrics {
            #expect(OptimizeMetric.parse(metric.description) == metric, "\(metric.description)")
        }

        #expect(OptimizeMetric.parse("v(out)") == .dc(.nodeVoltage("out")))
        #expect(OptimizeMetric.parse("ac:v(out)@1k")
            == .ac(.nodeVoltage("out"), frequencyHz: 1_000, quantity: .magnitude))
        #expect(OptimizeMetric.parse("acdb:v(out)@1k")
            == .ac(.nodeVoltage("out"), frequencyHz: 1_000, quantity: .magnitudeDB))
        #expect(OptimizeMetric.parse("acph:v(out)@1k")
            == .ac(.nodeVoltage("out"), frequencyHz: 1_000, quantity: .phaseDegrees))
        #expect(OptimizeMetric.parse("tran:v(out)@1m")
            == .transient(.nodeVoltage("out"), time: 1e-3))

        #expect(OptimizeMetric.parse("") == nil)
        #expect(OptimizeMetric.parse("out") == nil)
        #expect(OptimizeMetric.parse("ac:v(out)") == nil)
        #expect(OptimizeMetric.parse("ac:v(out)@0") == nil)
        #expect(OptimizeMetric.parse("ac:v(out)@-1k") == nil)
        #expect(OptimizeMetric.parse("tran:v(out)@-1m") == nil)
        // AC and transient result contracts carry element current, not voltage.
        #expect(OptimizeMetric.parse("ac:vi(R1)@1k") == nil)
        #expect(OptimizeMetric.parse("tran:vi(R1)@1m") == nil)
    }

    // MARK: - Metric extraction

    @Test func metricReadsDCACAndTransientValues() throws {
        let result = try SimulationEngine.solve(
            netlist: lowPass,
            settings: .default,
            libraries: []
        )
        let dc = try #require(OptimizeMetric.parse("v(out)")?.value(in: result))
        #expect(abs(dc - 1) < 1e-9)

        let magnitude = try #require(OptimizeMetric.parse("ac:v(out)@1k")?.value(in: result))
        let expected = 1 / (1 + pow(2 * Double.pi * 1_000 * 1_000 * 1e-6, 2)).squareRoot()
        #expect(abs(magnitude - expected) < 1e-3)

        let decibels = try #require(OptimizeMetric.parse("acdb:v(out)@1k")?.value(in: result))
        #expect(abs(decibels - 20 * log10(expected)) < 0.02)

        let phase = try #require(OptimizeMetric.parse("acph:v(out)@1k")?.value(in: result))
        #expect(abs(phase - (-atan(2 * Double.pi * 1_000 * 1_000 * 1e-6) * 180 / .pi)) < 0.2)

        let transient = try SimulationEngine.solve(
            netlist: step,
            settings: transientSettings,
            libraries: []
        )
        let value = try #require(
            OptimizeMetric.parse("tran:v(out)@500u")?.value(in: transient)
        )
        #expect(abs(value - 5 * (1 - exp(-0.5))) < 0.05)
    }

    @Test func metricValidationRejectsUnsupportedProbesAndWindows() {
        let acVoltage = OptimizeMetric.ac(
            .elementVoltage("R1"), frequencyHz: 1_000, quantity: .magnitude
        )
        let transientVoltage = OptimizeMetric.transient(.elementVoltage("R1"), time: 1e-3)
        let outOfBandAC = OptimizeMetric.ac(
            .nodeVoltage("out"), frequencyHz: 1e9, quantity: .magnitude
        )
        let outOfBandTransient = OptimizeMetric.transient(.nodeVoltage("out"), time: 1)

        do {
            try acVoltage.validate(settings: .default)
            Issue.record("AC element voltage should be rejected")
        } catch let error as AnalysisError {
            guard case .invalidMetric = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }

        do {
            try transientVoltage.validate(settings: .default)
            Issue.record("transient element voltage should be rejected")
        } catch let error as AnalysisError {
            guard case .invalidMetric = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }

        do {
            try outOfBandAC.validate(settings: .default)
            Issue.record("AC frequency outside the sweep should be rejected")
        } catch let error as AnalysisError {
            guard case .metricOutOfRange = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }

        do {
            try outOfBandTransient.validate(settings: .default)
            Issue.record("transient time outside the window should be rejected")
        } catch let error as AnalysisError {
            guard case .metricOutOfRange = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    // MARK: - Analysis-aware optimization

    @Test func acTargetOptimizationFindsTheDesignValue() throws {
        // |H| = 1 / sqrt(1 + (2πfRC)²). For |H| = 0.5 at 1 kHz with C = 1 µF,
        // R = sqrt(3) / (2π·1 kHz·1 µF) ≈ 275.7 Ω.
        let result = try Optimization.run(OptimizeRequest(
            netlist: lowPass,
            variables: [OptimizeVariable(designator: "R1", minimum: 100, maximum: 10_000)],
            metric: .ac(.nodeVoltage("out"), frequencyHz: 1_000, quantity: .magnitude),
            goal: .target(0.5),
            gridDivisions: 20
        ))
        #expect(abs(result.bestObjective - 0.5) < 1e-2)
        #expect(abs((result.bestValues["R1"] ?? 0) - 275.66) < 5)
        #expect(result.metric == .ac(.nodeVoltage("out"), frequencyHz: 1_000, quantity: .magnitude))
    }

    @Test func transientTargetOptimizationFindsTheDesignValue() throws {
        // v(t) = 5·(1 − e^(−t/RC)). For v = 2.5 V at 500 µs with R = 1 kΩ,
        // C = 500 µs / (R·ln 2) ≈ 721.3 nF.
        let result = try Optimization.run(OptimizeRequest(
            netlist: step,
            settings: transientSettings,
            variables: [OptimizeVariable(designator: "C1", minimum: 1e-7, maximum: 1e-5)],
            metric: .transient(.nodeVoltage("out"), time: 500e-6),
            goal: .target(2.5),
            gridDivisions: 10,
            maxIterations: 40
        ))
        #expect(abs(result.bestObjective - 2.5) < 0.05)
        #expect(abs((result.bestValues["C1"] ?? 0) - 7.213e-7) < 1e-7)
    }

    @Test func optimizerRequiresAnObjective() {
        do {
            _ = try Optimization.run(OptimizeRequest(
                netlist: divider,
                variables: [OptimizeVariable(designator: "R1", minimum: 100, maximum: 10_000)],
                gridDivisions: 3
            ))
            Issue.record("an objective was not rejected")
        } catch let error as AnalysisError {
            #expect(error == .noObjective)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    // MARK: - Yield

    private func yieldSpecification(
        samples: Int,
        seed: UInt64,
        refine: Bool = false
    ) -> YieldSpecification {
        YieldSpecification(
            tolerances: [
                ComponentTolerance(designator: "R1", relative: 0.05),
                ComponentTolerance(designator: "R2", relative: 0.05)
            ],
            samples: samples,
            seed: seed,
            limits: [MetricLimit(metric: .dc(.nodeVoltage("2")), minimum: 2.4, maximum: 2.6)],
            refine: refine
        )
    }

    @Test func yieldIsDeterministicAndCountsEveryTrial() throws {
        let specification = yieldSpecification(samples: 32, seed: 7)
        let request = OptimizeRequest(
            netlist: divider,
            variables: [OptimizeVariable(designator: "R1", minimum: 100, maximum: 1_000)],
            metric: .dc(.nodeVoltage("2")),
            goal: .target(2.5),
            yield: specification,
            gridDivisions: 5
        )
        let first = try Optimization.run(request)
        let second = try Optimization.run(request)

        #expect(first.yield == second.yield)
        #expect(first.nominalYield == second.nominalYield)

        let report = try #require(first.yield)
        #expect(report.trials == 32)
        #expect(report.seed == 7)
        #expect(report.statistics.count == 1)
        #expect(report.overallYield >= 0 && report.overallYield <= 1)
        #expect(report.statistics[0].yield >= 0 && report.statistics[0].yield <= 1)
        // Refinement is disabled, so the reported yield is the nominal one.
        #expect(first.yield == first.nominalYield)
    }

    @Test func yieldRefinementCentresAnOffTargetDesign() throws {
        // Maximising v(2) drives R1 to its minimum, far from the 2.4–2.6 V
        // window; yield centring should move the design back toward 1 kΩ.
        let result = try Optimization.run(OptimizeRequest(
            netlist: divider,
            variables: [OptimizeVariable(designator: "R1", minimum: 100, maximum: 1_000)],
            metric: .dc(.nodeVoltage("2")),
            goal: .maximize,
            yield: yieldSpecification(samples: 32, seed: 3, refine: true),
            gridDivisions: 5
        ))

        let nominal = try #require(result.nominalYield)
        let centred = try #require(result.yield)
        #expect(nominal.overallYield < 0.2)
        #expect(centred.overallYield >= nominal.overallYield)
        #expect(centred.overallYield > 0.3)
        #expect((result.bestValues["R1"] ?? 0) > 700)
        #expect(result.nominalBestValues != result.bestValues)
    }

    @Test func yieldRequiresLimitsAndSamples() {
        do {
            _ = try YieldEvaluation.estimate(
                netlist: divider,
                values: ["R1": 1_000],
                specification: YieldSpecification(samples: 8),
                baseSettings: .default,
                libraries: [],
                baseDirectory: nil
            )
            Issue.record("a yield specification without limits was accepted")
        } catch let error as AnalysisError {
            #expect(error == .noYieldLimits)
        } catch {
            Issue.record("unexpected error \(error)")
        }

        do {
            _ = try YieldEvaluation.estimate(
                netlist: divider,
                values: ["R1": 1_000],
                specification: yieldSpecification(samples: 0, seed: 1),
                baseSettings: .default,
                libraries: [],
                baseDirectory: nil
            )
            Issue.record("a zero-sample yield specification was accepted")
        } catch let error as AnalysisError {
            #expect(error == .invalidYieldSamples)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
