import Foundation
import Testing
@testable import OhmLabCore

@Suite("Thermal analysis")
struct ThermalAnalysisTests {
    private let divider = """
    V1 in 0 DC 10
    R1 in out 1k
    R2 out 0 1k
    .end
    """

    private func run(
        components: [ThermalComponent],
        heatsinks: [ThermalHeatsink] = [],
        defaultRja: Double? = nil,
        ambient: Double = 25
    ) throws -> ThermalResult {
        try ThermalAnalysis.run(ThermalRequest(
            netlist: divider,
            settings: .default,
            specification: ThermalSpecification(
                ambientCelsius: ambient,
                defaultJunctionToAmbient: defaultRja,
                components: components,
                heatsinks: heatsinks
            )
        ))
    }

    @Test func derivesPowerFromTheDCOperatingPoint() throws {
        let result = try run(components: [
            ThermalComponent(designator: "R1", junctionToAmbient: 100),
            ThermalComponent(designator: "R2", junctionToAmbient: 50),
        ])
        #expect(result.converged)
        #expect(result.contractVersion == ThermalResult.currentContractVersion)
        #expect(result.components.count == 2)

        let r1 = try #require(result.components.first { $0.designator == "R1" })
        #expect(abs(r1.powerWatts - 0.025) < 1e-12)
        #expect(abs(r1.temperatureRiseCelsius - 2.5) < 1e-9)
        #expect(abs(r1.temperatureCelsius - 27.5) < 1e-9)
        #expect(abs(r1.thermalResistance - 100) < 1e-9)

        let r2 = try #require(result.components.first { $0.designator == "R2" })
        #expect(abs(r2.temperatureRiseCelsius - 1.25) < 1e-9)
        #expect(abs(r2.temperatureCelsius - 26.25) < 1e-9)
        #expect(abs(result.totalPowerWatts - 0.05) < 1e-12)
        #expect(result.warnings.isEmpty)
    }

    @Test func explicitPowerOverridesTheOperatingPoint() throws {
        let result = try run(components: [
            ThermalComponent(designator: "R1", powerWatts: 0.1, junctionToAmbient: 100),
        ])
        let r1 = try #require(result.components.first)
        #expect(abs(r1.powerWatts - 0.1) < 1e-12)
        #expect(abs(r1.temperatureRiseCelsius - 10) < 1e-9)
        #expect(abs(r1.temperatureCelsius - 35) < 1e-9)
    }

    @Test func defaultResistanceAppliesToUnlistedComponents() throws {
        let result = try run(
            components: [
                ThermalComponent(designator: "R1"),
                ThermalComponent(designator: "R2"),
            ],
            defaultRja: 40
        )
        for component in result.components {
            #expect(abs(component.thermalResistance - 40) < 1e-9)
            #expect(abs(component.temperatureRiseCelsius - 1) < 1e-9)
        }
    }

    @Test func sharedHeatsinkAggregatesPower() throws {
        let result = try run(
            components: [
                ThermalComponent(designator: "R1", junctionToCase: 10, heatsink: "hs"),
                ThermalComponent(designator: "R2", junctionToCase: 30, heatsink: "HS"),
            ],
            heatsinks: [ThermalHeatsink(name: "HS", thermalResistance: 2)]
        )
        let heatsink = try #require(result.heatsinks.first)
        #expect(abs(heatsink.powerWatts - 0.05) < 1e-12)
        #expect(abs(heatsink.temperatureRiseCelsius - 0.1) < 1e-9)

        let r1 = try #require(result.components.first { $0.designator == "R1" })
        #expect(abs(r1.temperatureRiseCelsius - 0.35) < 1e-9)
        let r2 = try #require(result.components.first { $0.designator == "R2" })
        #expect(abs(r2.temperatureRiseCelsius - 0.85) < 1e-9)
    }

    @Test func reportsJunctionTemperatureLimits() throws {
        let result = try run(components: [
            ThermalComponent(designator: "R1", junctionToAmbient: 100, maxTemperatureCelsius: 27),
            ThermalComponent(designator: "R2", junctionToAmbient: 50, maxTemperatureCelsius: 30),
        ])
        let r1 = try #require(result.components.first { $0.designator == "R1" })
        let r2 = try #require(result.components.first { $0.designator == "R2" })
        #expect(r1.exceedsLimit)
        #expect(!r2.exceedsLimit)
    }

    @Test func resultsAreDeterministicAndCodable() throws {
        let specification = ThermalSpecification(
            ambientCelsius: 30,
            components: [
                ThermalComponent(designator: "R1", junctionToAmbient: 100),
                ThermalComponent(designator: "R2", junctionToAmbient: 50),
            ],
            heatsinks: []
        )
        let request = ThermalRequest(netlist: divider, settings: .default, specification: specification)
        let first = try ThermalAnalysis.run(request)
        let second = try ThermalAnalysis.run(request)
        #expect(first == second)

        let data = try JSONEncoder().encode(first)
        let decoded = try JSONDecoder().decode(ThermalResult.self, from: data)
        #expect(decoded == first)
    }

    @Test func missingThermalPathFailsClosed() {
        #expect(throws: AnalysisError.self) {
            _ = try run(components: [ThermalComponent(designator: "R1")])
        }
    }

    @Test func unknownOperatingPointComponentFailsClosed() {
        #expect(throws: AnalysisError.self) {
            _ = try run(components: [ThermalComponent(designator: "R99", junctionToAmbient: 10)])
        }
    }

    @Test func invalidSpecificationsFailClosed() {
        #expect(throws: AnalysisError.self) {
            _ = try run(components: [])
        }
        #expect(throws: AnalysisError.self) {
            _ = try run(components: [
                ThermalComponent(designator: "R1", junctionToAmbient: 10),
                ThermalComponent(designator: "r1", junctionToAmbient: 20),
            ])
        }
        #expect(throws: AnalysisError.self) {
            _ = try run(components: [
                ThermalComponent(designator: "R1", junctionToAmbient: 0),
            ])
        }
        #expect(throws: AnalysisError.self) {
            _ = try run(components: [
                ThermalComponent(designator: "R1", powerWatts: -1, junctionToAmbient: 10),
            ])
        }
        #expect(throws: AnalysisError.self) {
            _ = try run(components: [
                ThermalComponent(designator: "R1", junctionToCase: 10, heatsink: "missing"),
            ])
        }
        #expect(throws: AnalysisError.self) {
            _ = try run(components: [
                ThermalComponent(designator: "R1", junctionToCase: 10),
            ])
        }
        #expect(throws: AnalysisError.self) {
            _ = try run(
                components: [ThermalComponent(designator: "R1", junctionToAmbient: 10)],
                heatsinks: [ThermalHeatsink(name: "HS", thermalResistance: 0)]
            )
        }
    }
}
