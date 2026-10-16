import Foundation
import Testing
@testable import db_Lab

@Test func pinOnWireInteriorConnectsAndDetectsGround() {
    let resistor = SymbolInstance(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        descriptorId: "resistor",
        refDes: "R1",
        position: GridPoint(0, 0)
    )
    let ground = SymbolInstance(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        descriptorId: "ground",
        refDes: "GND1",
        position: GridPoint(-2, 1)
    )
    let wire = WireSegment(points: [GridPoint(-3, 0), GridPoint(-1, 0)])

    let nets = ConnectivityBuilder.build(symbols: [resistor, ground], wires: [wire])
    let net = net(containing: PinRef(symbolId: resistor.id, pinId: "1"), in: nets)

    #expect(net?.isGround == true)
    #expect(net?.name == "0")
    #expect(net?.connectedPins.contains(PinRef(symbolId: ground.id, pinId: "1")) == true)
}

@Test func rotatedPinsUseTransformedCoordinates() {
    let resistor = SymbolInstance(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
        descriptorId: "resistor",
        refDes: "R1",
        position: GridPoint(0, 0),
        rotation: 90
    )
    let ground = SymbolInstance(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
        descriptorId: "ground",
        refDes: "GND1",
        position: GridPoint(0, -1)
    )

    let nets = ConnectivityBuilder.build(symbols: [resistor, ground], wires: [])
    let net = net(containing: PinRef(symbolId: resistor.id, pinId: "1"), in: nets)

    #expect(net?.connectedPins.contains(PinRef(symbolId: ground.id, pinId: "1")) == true)
}

@Test func wireVertexConnectsToAnotherWireSegment() {
    let horizontal = SymbolInstance(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
        descriptorId: "resistor",
        refDes: "R1",
        position: GridPoint(0, 0)
    )
    let vertical = SymbolInstance(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
        descriptorId: "resistor",
        refDes: "R2",
        position: GridPoint(0, 2),
        rotation: 90
    )
    let wires = [
        WireSegment(points: [GridPoint(-4, 0), GridPoint(4, 0)]),
        WireSegment(points: [GridPoint(0, 0), GridPoint(0, 6)])
    ]

    let nets = ConnectivityBuilder.build(symbols: [horizontal, vertical], wires: wires)
    let horizontalPin = net(containing: PinRef(symbolId: horizontal.id, pinId: "1"), in: nets)
    let verticalPin = net(containing: PinRef(symbolId: vertical.id, pinId: "1"), in: nets)

    #expect(horizontalPin?.id == verticalPin?.id)
}

@Test func crossingWireInteriorsDoNotConnect() {
    let horizontal = SymbolInstance(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
        descriptorId: "resistor",
        refDes: "R1",
        position: GridPoint(0, 0)
    )
    let vertical = SymbolInstance(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000032")!,
        descriptorId: "resistor",
        refDes: "R2",
        position: GridPoint(0, 3),
        rotation: 90
    )
    let wires = [
        WireSegment(points: [GridPoint(-4, 0), GridPoint(4, 0)]),
        WireSegment(points: [GridPoint(0, -2), GridPoint(0, 8)])
    ]

    let nets = ConnectivityBuilder.build(symbols: [horizontal, vertical], wires: wires)
    let horizontalPin = net(containing: PinRef(symbolId: horizontal.id, pinId: "1"), in: nets)
    let verticalPin = net(containing: PinRef(symbolId: vertical.id, pinId: "1"), in: nets)

    #expect(horizontalPin?.id != verticalPin?.id)
}

@Test func netIDsAreStableWhenInputOrderChanges() {
    let first = SymbolInstance(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!,
        descriptorId: "resistor",
        refDes: "R1",
        position: GridPoint(0, 0)
    )
    let second = SymbolInstance(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!,
        descriptorId: "resistor",
        refDes: "R2",
        position: GridPoint(10, 10)
    )

    let forward = ConnectivityBuilder.build(symbols: [first, second], wires: [])
    let reversed = ConnectivityBuilder.build(symbols: [second, first], wires: [])

    #expect(netSignature(forward) == netSignature(reversed))
}

@Test @MainActor func componentRegistryProvidesTypedPassiveDefaults() {
    let document = SchematicDocument()
    let resistor = document.addComponent(descriptorId: "resistor", at: GridPoint(0, 0))
    let capacitor = document.addComponent(descriptorId: "capacitor", at: GridPoint(5, 0))
    let inductor = document.addComponent(descriptorId: "inductor", at: GridPoint(10, 0))

    #expect(resistor?.parameters["resistance"] == 1_000)
    #expect(capacitor?.parameters["capacitance"] == 1e-6)
    #expect(inductor?.parameters["inductance"] == 1e-3)
    #expect(resistor?.refDes == "R1")
    #expect(document.addComponent(descriptorId: "resistor", at: GridPoint(15, 0))?.refDes == "R2")
}

@Test @MainActor func schematicNetlistEmitsVoltageSourceAndPassiveComponents() throws {
    let document = SchematicDocument()
    let source = document.addComponent(descriptorId: "voltage-source", at: GridPoint(0, 0))!
    let resistor = document.addComponent(descriptorId: "resistor", at: GridPoint(4, 0))!
    let ground = document.addComponent(descriptorId: "ground", at: GridPoint(-2, 1))!

    #expect(source.refDes == "V1")
    #expect(resistor.parameters["resistance"] == 1_000)
    #expect(ground.descriptorId == "ground")

    let netlist = try SpiceNetlistBuilder.build(from: document)
    #expect(netlist.contains("V1 0 N"))
    #expect(netlist.contains("R1 N"))
    #expect(netlist.contains("AC 1"))
    #expect(netlist.hasSuffix(".end"))
}

@Test @MainActor func schematicNetlistEmitsCapacitorsAndInductors() throws {
    let document = SchematicDocument()
    let capacitor = document.addComponent(descriptorId: "capacitor", at: GridPoint(0, 0))!
    let inductor = document.addComponent(descriptorId: "inductor", at: GridPoint(5, 0))!
    _ = document.addComponent(descriptorId: "ground", at: GridPoint(0, 2))

    let netlist = try SpiceNetlistBuilder.build(from: document)

    #expect(netlist.contains("C1 N"))
    #expect(netlist.localizedCaseInsensitiveContains("1e-06"))
    #expect(netlist.contains("L1 N"))
    #expect(netlist.contains("0.001"))
    #expect(capacitor.parameters["capacitance"] == 1e-6)
    #expect(inductor.parameters["inductance"] == 1e-3)
}

@Test @MainActor func seriesResistanceInductorExpandsToResistorAndInductor() throws {
    let document = SchematicDocument()
    let inductor = document.addComponent(descriptorId: "inductor-series-resistance", at: GridPoint(0, 0))!
    _ = document.addComponent(descriptorId: "ground", at: GridPoint(-2, 1))
    _ = document.addComponent(descriptorId: "ground", at: GridPoint(2, 1))

    let netlist = try SpiceNetlistBuilder.build(from: document)

    #expect(inductor.refDes == "L1")
    #expect(netlist.contains("R1_SER 0 L1_SER 0.2"))
    #expect(netlist.contains("L1 L1_SER 0 0.001"))
}

@Test @MainActor func schematicNetlistRequiresGroundAndRejectsInvalidValues() {
    let document = SchematicDocument()
    _ = document.addComponent(descriptorId: "resistor", at: GridPoint(0, 0))

    do {
        _ = try SpiceNetlistBuilder.build(from: document)
        Issue.record("A schematic without ground should not generate an analysis netlist.")
    } catch SpiceNetlistBuildError.missingGround {
    } catch {
        Issue.record("Unexpected error: \(error.localizedDescription)")
    }

    _ = document.addComponent(descriptorId: "ground", at: GridPoint(0, 2))
    document.symbols[0].parameters["resistance"] = 0
    do {
        _ = try SpiceNetlistBuilder.build(from: document)
        Issue.record("A zero-ohm resistor should be rejected.")
    } catch SpiceNetlistBuildError.invalidParameter(reference: "R1", parameter: "resistance") {
    } catch {
        Issue.record("Unexpected error: \(error.localizedDescription)")
    }
}

@Test @MainActor func schematicModeBuildsNetlistBeforeSimulation() async {
    let document = CircuitDocument()
    document.usesSchematic = true
    _ = document.schematic.addComponent(descriptorId: "voltage-source", at: GridPoint(0, 0))
    _ = document.schematic.addComponent(descriptorId: "resistor", at: GridPoint(4, 0))
    _ = document.schematic.addComponent(descriptorId: "ground", at: GridPoint(-2, 1))

    await document.runSimulation()

    #expect(document.simulationError == nil)
    #expect(document.simulationResult?.isMock == true)
}

@Test @MainActor func mockSimulationHonorsAnalysisSettings() async throws {
    let result = try await EngineClient.shared.simulateSpice(
        netlist: "R1 1 0 1k",
        runDC: false,
        runAC: true,
        acFStart: 10,
        acFStop: 1_000,
        acPointsPerDecade: 5,
        runTRAN: true,
        tranTStop: 0.001,
        tranTStep: 0.0001
    )

    #expect(result.isMock)
    #expect(result.dc.map { $0.nodes.isEmpty } ?? true)
    #expect(result.ac?.frequencies.count == 11)
    #expect(result.ac?.frequencies.first == 10)
    #expect(result.ac?.frequencies.last == 1_000)
    #expect(result.tran?.timePoints.count == 11)
    #expect(result.tran?.timePoints.last == 0.001)
}

@Test @MainActor func mockSimulationRejectsNoSelectedAnalysis() async {
    do {
        _ = try await EngineClient.shared.simulateSpice(
            netlist: "R1 1 0 1k",
            runDC: false,
            runAC: false,
            runTRAN: false
        )
        Issue.record("Simulation should reject an empty analysis selection.")
    } catch CircuitSimulationError.noAnalysisSelected {
    } catch {
        Issue.record("Unexpected simulation error: \(error.localizedDescription)")
    }
}

private func net(containing pin: PinRef, in nets: [Net]) -> Net? {
    nets.first { $0.connectedPins.contains(pin) }
}

private func netSignature(_ nets: [Net]) -> [String] {
    nets.map { net in
        let pins = net.connectedPins.map { "\($0.symbolId.uuidString):\($0.pinId)" }.sorted()
        return "\(net.id):\(net.name):\(pins.joined(separator: ","))"
    }
}
