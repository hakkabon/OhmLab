// CircuitDocument.swift
// Observable document model for a SPICE circuit simulation session.

import SwiftUI

@MainActor
final class CircuitDocument: ObservableObject, Identifiable {
    let id = UUID()

    @Published var name: String = "Untitled Circuit"
    @Published var netlistText: String = defaultNetlist

    // Analysis settings
    @Published var runDC: Bool = true
    @Published var runAC: Bool = true
    @Published var acFStart: Double = 1
    @Published var acFStop: Double = 1_000_000
    @Published var acPointsPerDecade: Int = 20
    @Published var runTRAN: Bool = false
    @Published var tranTStop: Double = 1e-3
    @Published var tranTStep: Double = 1e-6

    // Results
    @Published var simulationResult: CircuitSimResult? = nil
    @Published var isSimulating: Bool = false
    @Published var simulationError: String? = nil

    func runSimulation() async {
        isSimulating = true
        simulationError = nil
        do {
            simulationResult = try await EngineClient.shared.simulateSpice(
                netlist: netlistText,
                runDC: runDC,
                runAC: runAC,
                acFStart: acFStart,
                acFStop: acFStop,
                acPointsPerDecade: acPointsPerDecade,
                runTRAN: runTRAN,
                tranTStop: tranTStop,
                tranTStep: tranTStep
            )
        } catch {
            simulationError = error.localizedDescription
        }
        isSimulating = false
    }
}

// MARK: – Default netlist (RC low-pass filter example)

private let defaultNetlist = """
* RC Low-Pass Filter
* fc = 1/(2*pi*R*C) = 1/(2*pi*1000*1e-6) ≈ 159 Hz
V1 1 0 AC 1 0
R1 1 2 1000
C1 2 0 1e-6
.AC DEC 20 1 100000
.END
"""
