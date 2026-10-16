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

// MARK: - Phase 0 hardening

@Test @MainActor func selectingComponentsDoesNotDirtyOrClearResults() async {
    let document = CircuitDocument()
    document.settings.runDC = false
    document.settings.runAC = true
    document.settings.acStartFrequency = 10
    document.settings.acStopFrequency = 10_000
    document.settings.acPointsPerDecade = 5

    _ = document.schematic.addComponent(descriptorId: "voltage-source", at: GridPoint(4, 0))
    _ = document.schematic.addComponent(descriptorId: "resistor", at: GridPoint(8, 0))
    _ = document.schematic.addComponent(descriptorId: "capacitor", at: GridPoint(12, 0))
    _ = document.schematic.addComponent(descriptorId: "ground", at: GridPoint(2, 1))
    _ = document.schematic.addComponent(descriptorId: "ground", at: GridPoint(14, 1))

    await document.runSimulation()
    #expect(document.simulationResult != nil)
    let dirtyBefore = document.isDirty

    document.schematic.selectedSymbolID = document.schematic.symbols.first?.id
    document.schematic.selectedWireID = document.schematic.wires.first?.id

    #expect(document.simulationResult != nil)
    #expect(document.isDirty == dirtyBefore)
}

@Test func sourceKeepsSeparateDcAndAcValues() throws {
    let netlist = """
    V1 1 0 DC 5 AC 1
    R1 1 0 1k
    .end
    """
    let dcResult = try SimulationEngine.solve(netlist: netlist, settings: .default)
    let dc = try #require(dcResult.dc)
    #expect(abs((dc.nodes.first { $0.name == "1" }?.voltage ?? 0) - 5) < 1e-9)

    var acSettings = AnalysisSettings.default
    acSettings.runDC = false
    acSettings.runAC = true
    acSettings.acStartFrequency = 100
    acSettings.acStopFrequency = 1_000
    acSettings.acPointsPerDecade = 2
    let acResult = try SimulationEngine.solve(netlist: netlist, settings: acSettings)
    let ac = try #require(acResult.ac)
    let node = try #require(ac.nodes.first { $0.name == "1" })
    #expect(abs((node.response.first?.magnitudeDb ?? 99)) < 1e-6)
}

@Test func elementUsesSeparateDcAndAcMagnitudes() {
    let element = LinearCircuit.Element(
        kind: .voltageSource, nodeA: 1, nodeB: 0, value: 1, dcValue: 5, acValue: 2, name: "V1"
    )
    #expect(element.magnitude(isDC: true) == 5)
    #expect(element.magnitude(isDC: false) == 2)

    let fallback = LinearCircuit.Element(kind: .voltageSource, nodeA: 1, nodeB: 0, value: 3, name: "V2")
    #expect(fallback.magnitude(isDC: true) == 3)
    #expect(fallback.magnitude(isDC: false) == 3)
}

@Test func linearSweepProducesEquallySpacedPoints() throws {
    var settings = AnalysisSettings.default
    settings.runDC = false
    settings.runAC = true
    settings.acSweepType = .lin
    settings.acStartFrequency = 100
    settings.acStopFrequency = 200
    settings.acPointsPerDecade = 5

    let netlist = "V1 1 0 AC 1\nR1 1 0 1k\n.end"
    let result = try SimulationEngine.solve(netlist: netlist, settings: settings)
    let ac = try #require(result.ac)
    #expect(ac.frequencies.count == 5)
    #expect(ac.frequencies.first == 100)
    #expect(ac.frequencies.last == 200)
    #expect(abs(ac.frequencies[1] - 125) < 1e-9)
}

@Test func octaveSweepStepsByPowersOfTwo() {
    let points = FrequencySweep.points(from: 100, to: 400, count: 1, type: .oct)
    #expect(points.first == 100)
    #expect(points.last == 400)
    #expect(points.contains { abs($0 - 200) < 1e-9 })
}

@Test func netlistParserReadsLinearSweep() throws {
    let parsed = try SpiceNetlistParser.parse("V1 1 0 AC 1\nR1 1 0 1k\n.ac lin 5 100 200\n.end")
    #expect(parsed.analysis.sweep == .lin)
    #expect(parsed.analysis.points == 5)
    #expect(parsed.analysis.startFrequency == 100)
    #expect(parsed.analysis.stopFrequency == 200)
}

@Test func netlistNodeNamesAreCaseInsensitive() throws {
    let parsed = try SpiceNetlistParser.parse("V1 In 0 AC 1\nR1 IN 0 1k\n.end")
    #expect(parsed.circuit.nodeNames == ["0", "In"])
    #expect(parsed.circuit.elements[0].nodeA == parsed.circuit.elements[1].nodeA)
}

@Test func nodeMapReservesZeroAndDeduplicatesNames() {
    let nets = [
        Net(id: 1, name: "0", connectedPins: []),
        Net(id: 2, name: "OUT", connectedPins: []),
        Net(id: 3, name: "OUT", connectedPins: []),
        Net(id: 4, name: "0", connectedPins: [], isGround: true)
    ]
    let map = NodeMap.build(from: nets)

    #expect(map.nodeNames[0] == "0")
    #expect(map.nodeNameByNetID[4] == "0")
    #expect(map.nodeNameByNetID[1] != "0")
    #expect(Set([map.nodeNameByNetID[2], map.nodeNameByNetID[3]]).count == 2)
}

@Test func analysisSettingsDecodeLegacyJSONWithoutSweepType() throws {
    let json = #"{"runDC":true,"runAC":true,"acStartFrequency":1,"acStopFrequency":1000,"acPointsPerDecade":10}"#
    let settings = try JSONDecoder().decode(AnalysisSettings.self, from: Data(json.utf8))
    #expect(settings.acSweepType == .dec)
    #expect(settings.outputNetNames.isEmpty)
}

@Test func diagnosticsReportUngroundedSubcircuit() {
    let source = SymbolInstance(descriptorId: "voltage-source", refDes: "V1", position: GridPoint(0, 0))
    let load = SymbolInstance(descriptorId: "resistor", refDes: "R1", position: GridPoint(4, 0))
    let ground = SymbolInstance(descriptorId: "ground", refDes: "GND1", position: GridPoint(-2, 1))
    let floatingA = SymbolInstance(descriptorId: "resistor", refDes: "R2", position: GridPoint(20, 0))
    let floatingB = SymbolInstance(descriptorId: "resistor", refDes: "R3", position: GridPoint(26, 0))

    let diagnostics = CircuitDiagnostics.analyze(
        symbols: [source, load, ground, floatingA, floatingB],
        wires: [],
        labels: []
    )

    #expect(diagnostics.contains {
        $0.severity == .warning
            && $0.message.localizedCaseInsensitiveContains("not connected to ground")
            && $0.message.contains("R2")
    })
}

// MARK: - Phase 1: complete the passive workflow

@Test func compilerMapsSourceDcAndAcParameters() throws {
    let source = SymbolInstance(
        descriptorId: "voltage-source",
        refDes: "V1",
        position: GridPoint(0, 0),
        parameters: ["dcVoltage": 5, "acMagnitude": 1, "acPhaseDegrees": 90]
    )
    let resistor = SymbolInstance(
        descriptorId: "resistor",
        refDes: "R1",
        position: GridPoint(4, 0),
        parameters: ["resistance": 1_000]
    )
    let ground = SymbolInstance(descriptorId: "ground", refDes: "GND1", position: GridPoint(-2, 1))

    let circuit = try CircuitCompiler.compile(symbols: [source, resistor, ground], wires: [], labels: [])
    let v1 = try #require(circuit.elements.first { $0.name == "V1" })
    #expect(v1.dcValue == 5)
    #expect(v1.acValue == 1)
    #expect(v1.phaseDegrees == 90)
}

@Test func circuitFileMigratesLegacySourceParameters() throws {
    let symbol = SymbolInstance(
        descriptorId: "voltage-source",
        refDes: "V1",
        position: GridPoint(0, 0),
        parameters: ["voltage": 2]
    )
    let file = CircuitFile(
        schemaVersion: 1,
        name: "Legacy",
        schematic: SchematicSnapshot(symbols: [symbol]),
        analysis: .default
    )
    let decoded = try CircuitFileStore.decode(CircuitFileStore.encode(file))

    #expect(decoded.schemaVersion == 2)
    let migrated = try #require(decoded.schematic.symbols.first)
    #expect(migrated.parameters["voltage"] == nil)
    #expect(migrated.parameters["dcVoltage"] == 2)
    #expect(migrated.parameters["acMagnitude"] == 2)
}

@Test @MainActor func netlistBuilderEmitsDcAndAcSourceValues() throws {
    let document = SchematicDocument()
    let source = try #require(document.addComponent(descriptorId: "voltage-source", at: GridPoint(0, 0)))
    document.setParameter(id: source.id, key: "dcVoltage", value: 5)
    _ = document.addComponent(descriptorId: "ground", at: GridPoint(-2, 1))

    let netlist = try SpiceNetlistBuilder.build(from: document)
    #expect(netlist.contains("DC 5 AC 1"))
}

@Test func dcResultsIncludeComponentCurrents() throws {
    let netlist = """
    V1 1 0 DC 10
    R1 1 0 1k
    .end
    """
    let result = try SimulationEngine.solve(netlist: netlist, settings: .default)
    let dc = try #require(result.dc)

    let resistor = try #require(dc.components.first { $0.name == "R1" })
    #expect(abs(resistor.voltage - 10) < 1e-9)
    #expect(abs(resistor.current - 0.01) < 1e-9)

    let source = try #require(dc.components.first { $0.name == "V1" })
    #expect(abs(abs(source.current) - 0.01) < 1e-9)
}

@Test func dcResultsIncludeInductorBranchCurrent() throws {
    let netlist = """
    V1 1 0 DC 1
    R1 1 2 100
    L1 2 0 1e-3
    .end
    """
    let result = try SimulationEngine.solve(netlist: netlist, settings: .default)
    let dc = try #require(result.dc)
    let inductor = try #require(dc.components.first { $0.name == "L1" })
    #expect(abs(abs(inductor.current) - 0.01) < 1e-9)
}

@Test func acResultsIncludeComponentCurrents() throws {
    var settings = AnalysisSettings.default
    settings.runDC = false
    settings.runAC = true
    settings.acStartFrequency = 10
    settings.acStopFrequency = 1_000
    settings.acPointsPerDecade = 2

    let netlist = "V1 1 0 AC 1\nR1 1 0 1k\n.end"
    let result = try SimulationEngine.solve(netlist: netlist, settings: settings)
    let ac = try #require(result.ac)
    let resistor = try #require(ac.components.first { $0.name == "R1" })
    #expect(resistor.response.count == ac.frequencies.count)
    #expect(abs((resistor.response.first?.magnitudeDb ?? 0) - 20 * log10(0.001)) < 1e-6)
}

@Test func csvExportContainsDcAndAcRows() throws {
    let netlist = "V1 1 0 DC 5 AC 1\nR1 1 0 1k\n.end"
    let result = try SimulationEngine.solve(netlist: netlist, settings: .default)
    let csv = CircuitResultExport.csv(result)

    #expect(csv.hasPrefix("analysis,frequency_hz,signal,quantity,value"))
    #expect(csv.contains("dc,,R1,current,0.005"))
    #expect(csv.contains(",1,voltage_mag_db,"))
}

@Test func diagnosticsRejectNegativeAcMagnitude() {
    var source = SymbolInstance(descriptorId: "voltage-source", refDes: "V1", position: GridPoint(0, 0))
    source.parameters = ComponentRegistry.shared.descriptor(for: "voltage-source")!.defaultParameterValues
    source.parameters["acMagnitude"] = -1
    let ground = SymbolInstance(descriptorId: "ground", refDes: "GND1", position: GridPoint(-2, 1))

    let diagnostics = CircuitDiagnostics.analyze(symbols: [source, ground], wires: [], labels: [])
    #expect(diagnostics.contains {
        $0.severity == .error && $0.message.localizedCaseInsensitiveContains("AC magnitude")
    })
}

// MARK: - Phase 2: transient analysis

@Test func transientRCStepChargesTowardSource() throws {
    let circuit = LinearCircuit(
        nodeNames: ["0", "in", "out"],
        elements: [
            .init(
                kind: .voltageSource,
                nodeA: 1,
                nodeB: 0,
                value: 0,
                transient: .pulse(
                    initial: 0, pulsed: 5, delay: 0, riseTime: 1e-9,
                    fallTime: 0, pulseWidth: .infinity, period: 0
                ),
                name: "V1"
            ),
            .init(kind: .resistor, nodeA: 1, nodeB: 2, value: 1_000, name: "R1"),
            .init(kind: .capacitor, nodeA: 2, nodeB: 0, value: 1e-6, name: "C1")
        ]
    )
    // tau = RC = 1 ms.
    let solver = TransientSolver(circuit: circuit, timestep: 1e-5)
    let result = try solver.run(startTime: 0, stopTime: 5e-3, maxSteps: 100_000)

    let output = result.nodeSeries[2]
    #expect(abs((output.first ?? 1)) < 1e-6)
    #expect(abs((output.last ?? 0) - 5) < 0.05)
    // One time constant: 5·(1 − e⁻¹) ≈ 3.16 V at index 100.
    #expect(abs(output[100] - 3.161) < 0.05)
    // The capacitor current decays to zero in steady state.
    #expect(abs(result.componentSeries[2].last ?? 1) < 1e-4)
}

@Test func transientRLStepRampsTowardSteadyCurrent() throws {
    let circuit = LinearCircuit(
        nodeNames: ["0", "in", "out"],
        elements: [
            .init(
                kind: .voltageSource,
                nodeA: 1,
                nodeB: 0,
                value: 0,
                transient: .pulse(
                    initial: 0, pulsed: 5, delay: 0, riseTime: 1e-12,
                    fallTime: 0, pulseWidth: .infinity, period: 0
                ),
                name: "V1"
            ),
            .init(kind: .resistor, nodeA: 1, nodeB: 2, value: 100, name: "R1"),
            .init(kind: .inductor, nodeA: 2, nodeB: 0, value: 1e-3, name: "L1")
        ]
    )
    // tau = L/R = 10 us.
    let solver = TransientSolver(circuit: circuit, timestep: 1e-7)
    let result = try solver.run(startTime: 0, stopTime: 1e-4, maxSteps: 100_000)

    let current = result.componentSeries[2]
    #expect(abs(current.first ?? 1) < 1e-9)
    #expect(abs((current.last ?? 0) - 0.05) < 1e-3)
    // One time constant: 0.05·(1 − e⁻¹) ≈ 0.0316 A at index 100.
    #expect(abs(current[100] - 0.0315) < 5e-3)
}

@Test func waveformSineAndPWLInterpolate() {
    let sine = Waveform.sine(offset: 1, amplitude: 2, frequency: 1_000, delay: 0, damping: 0, phaseDegrees: 90)
    #expect(abs(sine.value(at: 0) - 3) < 1e-9)
    #expect(abs(sine.value(at: 0.00025) - 1) < 1e-6)

    let pwl = Waveform.pwl(points: [
        WaveformPoint(time: 0, value: 0),
        WaveformPoint(time: 1, value: 10)
    ])
    #expect(pwl.value(at: 0.5) == 5)
    #expect(pwl.value(at: -1) == 0)
    #expect(pwl.value(at: 5) == 10)
}

@Test func netlistParserReadsPulseSourceAndTranCard() throws {
    let netlist = """
    V1 in 0 PULSE(0 5 0 1n 1n 1 2)
    R1 in out 1k
    C1 out 0 1u
    .tran 1u 5m
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist)
    let source = try #require(parsed.circuit.elements.first { $0.name == "V1" })
    let waveform = try #require(source.transient)
    #expect(abs(waveform.value(at: 0)) < 1e-9)
    #expect(abs(waveform.value(at: 1e-6) - 5) < 1e-9)
    #expect(abs(waveform.value(at: 1.5)) < 1e-9)
    #expect(parsed.analysis.hasTransient)
    #expect(parsed.analysis.tranStep == 1e-6)
    #expect(parsed.analysis.tranStop == 5e-3)
}

@Test func netlistParserReadsSineSource() throws {
    let parsed = try SpiceNetlistParser.parse("V1 1 0 SIN(0 1 1k)\nR1 1 0 1k\n.end")
    let source = try #require(parsed.circuit.elements.first)
    let waveform = try #require(source.transient)
    #expect(abs(waveform.value(at: 0)) < 1e-9)
    #expect(abs(waveform.value(at: 0.00025) - 1) < 1e-6)
}

@Test func transientResultsExposedByEngine() throws {
    var settings = AnalysisSettings.default
    settings.runDC = false
    settings.runAC = false
    settings.runTransient = true
    settings.tranStep = 1e-5
    settings.tranStop = 1e-3

    let netlist = """
    V1 in 0 PULSE(0 5 0 1n 1n 1 2)
    R1 in out 1k
    C1 out 0 1u
    .end
    """
    let result = try SimulationEngine.solve(netlist: netlist, settings: settings)
    let transient = try #require(result.transient)
    #expect(transient.times.first == 0)
    #expect(transient.times.count == 101)
    #expect(transient.nodes.contains { $0.name == "out" })
    #expect(transient.components.contains { $0.name == "C1" })
}

@Test func transientHonorsNetlistTranCard() throws {
    let settings = AnalysisSettings.default
    let netlist = """
    V1 1 0 PULSE(0 1 0 1n 1n 1 2)
    R1 1 0 1k
    .tran 2u 20u
    .end
    """
    let result = try SimulationEngine.solve(netlist: netlist, settings: settings)
    let transient = try #require(result.transient)
    #expect(transient.times.count == 11)
    #expect(abs((transient.times.last ?? 0) - 20e-6) < 1e-12)
}

@Test func csvExportContainsTransientRows() throws {
    var settings = AnalysisSettings.default
    settings.runDC = false
    settings.runAC = false
    settings.runTransient = true
    settings.tranStep = 1e-4
    settings.tranStop = 1e-3

    let netlist = "V1 1 0 PULSE(0 5 0 1n 1n 1 2)\nR1 1 0 1k\n.end"
    let result = try SimulationEngine.solve(netlist: netlist, settings: settings)
    let csv = CircuitResultExport.csv(result)

    #expect(csv.hasPrefix("analysis,frequency_hz,signal,quantity,value,time_s"))
    #expect(csv.contains("tran,,"))
}

@Test func analysisSettingsDecodeLegacyJSONWithoutTransient() throws {
    let json = #"{"runDC":true,"runAC":true,"acStartFrequency":1,"acStopFrequency":1000,"acPointsPerDecade":10}"#
    let settings = try JSONDecoder().decode(AnalysisSettings.self, from: Data(json.utf8))
    #expect(settings.runTransient == false)
    #expect(settings.tranStep == 1e-4)
    #expect(settings.tranStop == 1e-2)
    #expect(settings.tranStart == 0)
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
