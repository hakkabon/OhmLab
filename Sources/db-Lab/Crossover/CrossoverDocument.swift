// CrossoverDocument.swift
// Observable document model for a single crossover design session.

import SwiftUI

@MainActor
final class CrossoverDocument: ObservableObject, Identifiable {
    let id = UUID()

    @Published var name: String = "Untitled Crossover"
    @Published var drivers: [DriverModel] = []
    @Published var filters: [FilterStageModel] = []
    @Published var compensations: [CompensationSpec] = []

    // Simulation state
    @Published var simulationResult: CrossoverSimResult? = nil
    @Published var isSimulating: Bool = false
    @Published var simulationError: String? = nil
    @Published var generatedAnalysisNetlist: String? = nil

    // Settings
    @Published var fMin: Double = 20
    @Published var fMax: Double = 20_000
    @Published var pointsPerDecade: Int = 200

    init() {
        // Start with a 2-way template
        applyTwoWayTemplate()
    }

    // MARK: – Templates

    func applyTwoWayTemplate() {
        name = "2-Way Crossover"
        drivers = [.defaultWoofer(), .defaultTweeter()]
        let w = drivers[0]
        let t = drivers[1]
        filters = [
            FilterStageModel(
                filterType: .lowPass,
                topology: .linkwitzRiley4,
                frequencyHz: 2500,
                driverName: w.name,
                components: []
            ),
            FilterStageModel(
                filterType: .highPass,
                topology: .linkwitzRiley4,
                frequencyHz: 2500,
                driverName: t.name,
                components: []
            )
        ]
        compensations = []
    }

    func applyThreeWayTemplate() {
        name = "3-Way Crossover"
        let woofer = DriverModel.defaultWoofer()
        var mid = DriverModel()
        mid.name = "Midrange"; mid.role = .midrange
        mid.nominalImpedance = 8; mid.re = 6; mid.sensitivityDb = 89
        let tweeter = DriverModel.defaultTweeter()
        drivers = [woofer, mid, tweeter]

        filters = [
            FilterStageModel(filterType: .lowPass, topology: .linkwitzRiley4, frequencyHz: 500, driverName: woofer.name, components: []),
            FilterStageModel(filterType: .bandPass, topology: .butterworth2, frequencyHz: 500, driverName: mid.name, components: []),
            FilterStageModel(filterType: .highPass, topology: .linkwitzRiley4, frequencyHz: 3000, driverName: tweeter.name, components: [])
        ]
        compensations = []
        simulationResult = nil
    }

    // MARK: – Simulation

    func runSimulation() async {
        guard !drivers.isEmpty, !filters.isEmpty else { return }
        isSimulating = true
        simulationError = nil
        simulationResult = nil
        generatedAnalysisNetlist = nil
        do {
            generatedAnalysisNetlist = try generateAnalysisCircuit()
            simulationResult = try await EngineClient.shared.simulateCrossover(
                drivers: drivers,
                filters: filters,
                fMin: fMin,
                fMax: fMax,
                pointsPerDecade: pointsPerDecade
            )
        } catch {
            simulationError = error.localizedDescription
        }
        isSimulating = false
    }

    @discardableResult
    func generateAnalysisCircuit() throws -> String {
        try CrossoverCircuitBuilder.build(
            drivers: drivers,
            filters: filters,
            compensations: compensations,
            fMin: fMin,
            fMax: fMax,
            pointsPerDecade: pointsPerDecade
        )
    }

    // MARK: – Filter synthesis helper

    func synthesizeFilter(at index: Int) {
        guard index < filters.count else { return }
        let f = filters[index]
        let driver = drivers.first(where: { $0.name == f.driverName })
        let rLoad = driver?.nominalImpedance ?? 8.0
        let components = EngineClient.shared.synthesizeFilter(
            type: f.filterType,
            topology: f.topology,
            fcHz: f.frequencyHz,
            rLoad: rLoad
        )
        filters[index].components = components
    }

    func synthesizeAllFilters() {
        for i in filters.indices { synthesizeFilter(at: i) }
    }
}

// ─── Compensation spec ────────────────────────────────────────────────────────

struct CompensationSpec: Identifiable {
    var id = UUID()
    var kind: CompensationKind
    var driverName: String
    var components: [ComponentValue] = []
}
