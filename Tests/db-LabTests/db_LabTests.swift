import Foundation
import Testing
@testable import db_Lab

// MARK: - Connectivity (Layer 2)

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

@Test func netLabelNamesItsNet() {
    let resistor = SymbolInstance(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000051")!,
        descriptorId: "resistor",
        refDes: "R1",
        position: GridPoint(0, 0)
    )
    let wire = WireSegment(points: [GridPoint(2, 0), GridPoint(4, 0)])
    let label = NetLabel(name: "OUT", position: GridPoint(4, 0))

    let nets = ConnectivityBuilder.build(symbols: [resistor], wires: [wire], labels: [label])
    let outNet = nets.first { $0.name == "OUT" }

    #expect(outNet != nil)
    #expect(outNet?.isLabeled == true)
    #expect(outNet?.connectedPins.contains(PinRef(symbolId: resistor.id, pinId: "2")) == true)
}

// MARK: - Component registry and editing

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

@Test @MainActor func undoAndRedoRestoreDocumentState() {
    let document = SchematicDocument()
    _ = document.addComponent(descriptorId: "resistor", at: GridPoint(0, 0))
    #expect(document.symbols.count == 1)
    #expect(document.canUndo)

    document.undo()
    #expect(document.symbols.isEmpty)
    #expect(document.canRedo)

    document.redo()
    #expect(document.symbols.count == 1)
}

@Test @MainActor func deletingSymbolUpdatesConnectivity() {
    let document = SchematicDocument()
    let resistor = document.addComponent(descriptorId: "resistor", at: GridPoint(0, 0))!
    _ = document.addComponent(descriptorId: "ground", at: GridPoint(-2, 1))

    document.deleteSymbol(id: resistor.id)

    #expect(document.symbols.count == 1)
    #expect(document.nets.allSatisfy { net in
        !net.connectedPins.contains(PinRef(symbolId: resistor.id, pinId: "1"))
    })
}

// MARK: - Diagnostics

@Test func diagnosticsReportMissingGroundAndFloatingPins() {
    let resistor = SymbolInstance(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000061")!,
        descriptorId: "resistor",
        refDes: "R1",
        position: GridPoint(0, 0)
    )
    let diagnostics = CircuitDiagnostics.analyze(symbols: [resistor], wires: [], labels: [])

    #expect(diagnostics.contains { $0.severity == .error && $0.message.localizedCaseInsensitiveContains("ground") })
    #expect(diagnostics.contains { $0.severity == .warning && $0.message.localizedCaseInsensitiveContains("not connected") })
}

@Test func diagnosticsReportDuplicateReferences() {
    let first = SymbolInstance(descriptorId: "resistor", refDes: "R1", position: GridPoint(0, 0))
    let second = SymbolInstance(descriptorId: "resistor", refDes: "R1", position: GridPoint(5, 0))
    let ground = SymbolInstance(descriptorId: "ground", refDes: "GND1", position: GridPoint(-2, 1))

    let diagnostics = CircuitDiagnostics.analyze(symbols: [first, second, ground], wires: [], labels: [])

    #expect(diagnostics.contains { $0.severity == .error && $0.message.localizedCaseInsensitiveContains("more than once") })
}

@Test func diagnosticsReportInvalidValues() {
    var resistor = SymbolInstance(descriptorId: "resistor", refDes: "R1", position: GridPoint(0, 0))
    resistor.parameters["resistance"] = 0
    let ground = SymbolInstance(descriptorId: "ground", refDes: "GND1", position: GridPoint(-2, 1))

    let diagnostics = CircuitDiagnostics.analyze(symbols: [resistor, ground], wires: [], labels: [])

    #expect(diagnostics.contains { $0.severity == .error && $0.message.localizedCaseInsensitiveContains("greater than zero") })
}

// MARK: - Linear solver

@Test func voltageDividerDC() throws {
    let circuit = LinearCircuit(
        nodeNames: ["0", "in", "out"],
        elements: [
            .init(kind: .voltageSource, nodeA: 1, nodeB: 0, value: 10, name: "V1"),
            .init(kind: .resistor, nodeA: 1, nodeB: 2, value: 1_000, name: "R1"),
            .init(kind: .resistor, nodeA: 2, nodeB: 0, value: 1_000, name: "R2")
        ]
    )

    let solution = try circuit.solveDC()
    #expect(abs(solution.nodeVoltages[1].re - 10) < 1e-9)
    #expect(abs(solution.nodeVoltages[2].re - 5) < 1e-9)
}

@Test func rCLowPassHasMinusThreeDbAtCutoff() throws {
    let resistance = 1_000.0
    let capacitance = 1e-6
    let cutoff = 1 / (2 * Double.pi * resistance * capacitance)

    let circuit = LinearCircuit(
        nodeNames: ["0", "in", "out"],
        elements: [
            .init(kind: .voltageSource, nodeA: 1, nodeB: 0, value: 1, name: "V1"),
            .init(kind: .resistor, nodeA: 1, nodeB: 2, value: resistance, name: "R1"),
            .init(kind: .capacitor, nodeA: 2, nodeB: 0, value: capacitance, name: "C1")
        ]
    )

    let solution = try circuit.solveAC(frequencyHz: cutoff)
    let output = solution.nodeVoltages[2]
    #expect(abs(output.magnitude - 0.70710678) < 1e-3)
    #expect(abs(output.phaseDegrees + 45) < 0.1)
}

@Test func currentSourceDrivesResistor() throws {
    let circuit = LinearCircuit(
        nodeNames: ["0", "n"],
        elements: [
            .init(kind: .currentSource, nodeA: 0, nodeB: 1, value: 1e-3, name: "I1"),
            .init(kind: .resistor, nodeA: 1, nodeB: 0, value: 1_000, name: "R1")
        ]
    )

    let solution = try circuit.solveDC()
    #expect(abs(solution.nodeVoltages[1].re - 1) < 1e-9)
}

@Test func inductorWithSeriesResistanceFormsDividerAtDC() throws {
    // At DC the inductor is a short, so the source sees only the series resistance.
    let circuit = LinearCircuit(
        nodeNames: ["0", "in", "out"],
        elements: [
            .init(kind: .voltageSource, nodeA: 1, nodeB: 0, value: 1, name: "V1"),
            .init(kind: .resistor, nodeA: 1, nodeB: 2, value: 100, name: "RSER"),
            .init(kind: .inductor, nodeA: 2, nodeB: 0, value: 1e-3, name: "L1")
        ]
    )

    let solution = try circuit.solveDC()
    #expect(abs(solution.nodeVoltages[2].re) < 1e-9)
}

@Test func singularCircuitReportsError() {
    // A node fed only by an ideal current source has no conductance path, so
    // the nodal equations are singular and the solve must fail loudly.
    let circuit = LinearCircuit(
        nodeNames: ["0", "n"],
        elements: [
            .init(kind: .currentSource, nodeA: 0, nodeB: 1, value: 1e-3, name: "I1")
        ]
    )
    #expect(throws: (any Error).self) {
        _ = try circuit.solveDC()
    }
}

// MARK: - Netlist parsing

@Test func netlistParserUnderstandsSuffixesAndSources() throws {
    let netlist = """
    * divider
    V1 1 0 AC 1
    R1 1 2 4.7k
    R2 2 0 10u
    .ac dec 10 1 1meg
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist)
    #expect(parsed.circuit.nodeNames == ["0", "1", "2"])

    let resistor = parsed.circuit.elements.first { $0.name == "R1" }
    #expect(abs((resistor?.value ?? 0) - 4_700) < 1e-9)
    #expect(parsed.analysis.hasAC)
    #expect(parsed.analysis.stopFrequency == 1e6)
}

@Test func netlistParseRejectsUnsupportedElement() {
    #expect(throws: (any Error).self) {
        _ = try SpiceNetlistParser.parse("Q1 1 2 3 model\nR1 1 0 1k")
    }
}

@Test func engineSolvesNetlistAndHonorsAnalysisCard() throws {
    var settings = AnalysisSettings.default
    let netlist = """
    V1 1 0 AC 1
    R1 1 2 1000
    C1 2 0 1e-6
    .ac dec 10 1 1000
    .end
    """
    // Use non-default frequencies so the `.ac` card is not consulted.
    settings.acStartFrequency = 1
    settings.acStopFrequency = 1_000
    settings.acPointsPerDecade = 10

    let result = try SimulationEngine.solve(netlist: netlist, settings: settings)
    let ac = try #require(result.ac)
    #expect(ac.frequencies.first == 1)
    #expect(ac.frequencies.last == 1_000)
    #expect(ac.nodes.contains { $0.name == "2" })
}

// MARK: - Persistence

@Test @MainActor func circuitFileRoundTrips() throws {
    let document = CircuitDocument()
    _ = document.schematic.addComponent(descriptorId: "voltage-source", at: GridPoint(0, 0))
    _ = document.schematic.addComponent(descriptorId: "resistor", at: GridPoint(2, 0))
    document.schematic.addNetLabel(name: "OUT", at: GridPoint(4, 0))
    document.settings.acPointsPerDecade = 33

    let file = document.makeFile()
    let data = try CircuitFileStore.encode(file)
    let decoded = try CircuitFileStore.decode(data)

    #expect(decoded.name == file.name)
    #expect(decoded.schematic.symbols.count == 2)
    #expect(decoded.schematic.netLabels.first?.name == "OUT")
    #expect(decoded.analysis.acPointsPerDecade == 33)
}

@Test func circuitFileRejectsNewerSchema() throws {
    let file = CircuitFile(
        schemaVersion: CircuitFile.currentSchemaVersion + 1,
        name: "Future",
        schematic: SchematicSnapshot(),
        analysis: .default
    )
    let data = try CircuitFileStore.encode(file)
    #expect(throws: CircuitFileError.self) {
        _ = try CircuitFileStore.decode(data)
    }
}

// MARK: - End-to-end document simulation

@Test @MainActor func documentSimulatesSchematicWithRealEngine() async {
    let document = CircuitDocument()
    document.settings.runDC = false
    document.settings.runAC = true
    document.settings.acStartFrequency = 10
    document.settings.acStopFrequency = 10_000
    document.settings.acPointsPerDecade = 5

    // V1 between in(4,0) and ground(0,0); R from in to out(8,0); C from out to ground.
    _ = document.schematic.addComponent(descriptorId: "voltage-source", at: GridPoint(4, 0))
    _ = document.schematic.addComponent(descriptorId: "resistor", at: GridPoint(8, 0))
    _ = document.schematic.addComponent(descriptorId: "capacitor", at: GridPoint(12, 0))
    _ = document.schematic.addComponent(descriptorId: "ground", at: GridPoint(2, 1))
    _ = document.schematic.addComponent(descriptorId: "ground", at: GridPoint(14, 1))

    await document.runSimulation()

    #expect(document.simulationError == nil)
    let ac = document.simulationResult?.ac
    #expect(ac != nil)
    #expect((ac?.nodes.count ?? 0) >= 2)
    #expect(ac?.frequencies.first == 10)
}

// MARK: - Helpers

private func net(containing pin: PinRef, in nets: [Net]) -> Net? {
    nets.first { $0.connectedPins.contains(pin) }
}

private func netSignature(_ nets: [Net]) -> [String] {
    nets.map { net in
        let pins = net.connectedPins.map { "\($0.symbolId.uuidString):\($0.pinId)" }.sorted()
        return "\(net.id):\(net.name):\(pins.joined(separator: ","))"
    }
}
