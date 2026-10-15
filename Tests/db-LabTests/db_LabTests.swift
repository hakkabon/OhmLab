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
