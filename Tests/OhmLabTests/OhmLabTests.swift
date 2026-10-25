import Foundation
import Testing
@testable import OhmLabCore

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

    #expect(decoded.schemaVersion == CircuitFile.currentSchemaVersion)
    let migrated = try #require(decoded.schematic.symbols.first)
    #expect(migrated.parameters["voltage"] == nil)
    #expect(migrated.parameters["dcVoltage"] == 2)
    #expect(migrated.parameters["acMagnitude"] == 2)
}

@Test func circuitFilePersistsNetlistModeAndLibraries() throws {
    let file = CircuitFile(
        name: "Netlist Mode",
        schematic: SchematicSnapshot(),
        analysis: .default,
        netlistText: "* my netlist\nV1 a 0 1",
        usesSchematic: false,
        modelLibraries: [StoredModelLibrary(name: "Q", text: ".model q1 NPN(IS=1e-14 BF=100)")]
    )
    let decoded = try CircuitFileStore.decode(CircuitFileStore.encode(file))
    #expect(decoded.netlistText == "* my netlist\nV1 a 0 1")
    #expect(decoded.usesSchematic == false)
    #expect(decoded.modelLibraries?.first?.name == "Q")
    #expect(decoded.modelLibraries?.first?.text == ".model q1 NPN(IS=1e-14 BF=100)")
}

@Test @MainActor func documentRoundTripsNetlistModeAndLibraries() throws {
    let document = CircuitDocument()
    document.importNetlist("* netlist\nV1 a 0 1")
    document.modelLibraries = [try SpiceModelLibrary.parse(".model q1 NPN(IS=1e-14 BF=100)", name: "Q")]

    let restored = CircuitDocument()
    restored.load(document.makeFile())

    #expect(restored.usesSchematic == false)
    #expect(restored.netlistText.contains("V1 a 0 1"))
    #expect(restored.modelLibraries.first?.name == "Q")
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

// MARK: - Phase 3: nonlinear devices (diode)

@Test func netlistParserReadsDiodeModelAndExpandsSeriesResistance() throws {
    let netlist = """
    V1 1 0 DC 5
    R1 1 2 1k
    D1 2 0 DMOD
    .model DMOD D(IS=2e-14 N=1.5 RS=10)
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist)
    let diode = try #require(parsed.circuit.elements.first { $0.name == "D1" })
    #expect(diode.kind == .diode)
    #expect(abs((diode.diode?.saturationCurrent ?? 0) - 2e-14) < 1e-20)
    #expect(abs((diode.diode?.emissionCoefficient ?? 0) - 1.5) < 1e-9)
    #expect(parsed.circuit.elements.contains { $0.name == "RD1_SER" && $0.kind == .resistor })
}

@Test func netlistParseRejectsDiodeWithUnknownModel() {
    #expect(throws: (any Error).self) {
        _ = try SpiceNetlistParser.parse("V1 1 0 DC 5\nR1 1 2 1k\nD1 2 0 NOPE\n.end")
    }
}

@Test func diodeForwardBiasConductsAtJunctionVoltage() throws {
    let netlist = """
    V1 1 0 DC 5
    R1 1 2 1k
    D1 2 0 DMOD
    .model DMOD D(IS=1e-14 N=1)
    .end
    """
    let result = try SimulationEngine.solve(netlist: netlist, settings: .default)
    let dc = try #require(result.dc)
    let voltage = try #require(dc.nodes.first { $0.name == "2" }?.voltage)
    #expect(voltage > 0.6 && voltage < 0.75)
    let diode = try #require(dc.components.first { $0.name == "D1" })
    #expect(abs(diode.current - (5 - voltage) / 1_000) < 1e-6)
}

@Test func diodeReverseBiasBlocks() throws {
    let netlist = """
    V1 1 0 DC 5
    R1 1 2 1k
    D1 0 2 DMOD
    .model DMOD D(IS=1e-14 N=1)
    .end
    """
    let result = try SimulationEngine.solve(netlist: netlist, settings: .default)
    let dc = try #require(result.dc)
    let voltage = try #require(dc.nodes.first { $0.name == "2" }?.voltage)
    #expect(abs(voltage - 5) < 0.01)
    let diode = try #require(dc.components.first { $0.name == "D1" })
    #expect(abs(diode.current) < 1e-9)
}

@Test func diodeSmallSignalACProducesFiniteResult() throws {
    var settings = AnalysisSettings.default
    settings.runDC = false
    settings.runAC = true
    settings.acStartFrequency = 10
    settings.acStopFrequency = 1_000
    settings.acPointsPerDecade = 2

    let netlist = """
    V1 1 0 DC 2 AC 1
    R1 1 2 1k
    D1 2 0 DMOD
    .model DMOD D(IS=1e-14 N=1)
    .end
    """
    let result = try SimulationEngine.solve(netlist: netlist, settings: settings)
    let ac = try #require(result.ac)
    let node = try #require(ac.nodes.first { $0.name == "2" })
    #expect(node.response.allSatisfy { $0.magnitudeDb.isFinite })
}

@Test func diodeTransientReachesForwardDrop() throws {
    var settings = AnalysisSettings.default
    settings.runDC = false
    settings.runAC = false
    settings.runTransient = true
    settings.tranStep = 1e-5
    settings.tranStop = 1e-3

    let netlist = """
    V1 1 0 PULSE(0 5 0 1n 1n 1 2)
    R1 1 2 1k
    D1 2 0 DMOD
    .model DMOD D(IS=1e-14 N=1)
    .end
    """
    let result = try SimulationEngine.solve(netlist: netlist, settings: settings)
    let transient = try #require(result.transient)
    let values = try #require(transient.nodes.first { $0.name == "2" }?.values)
    #expect((values.last ?? 0) > 0.6 && (values.last ?? 0) < 0.75)
}

@Test func compilerMapsDiodeParameters() throws {
    let diode = SymbolInstance(
        descriptorId: "diode",
        refDes: "D1",
        position: GridPoint(0, 0),
        parameters: ["saturationCurrent": 2e-14, "emissionCoefficient": 1.5]
    )
    let ground = SymbolInstance(descriptorId: "ground", refDes: "GND1", position: GridPoint(-2, 1))

    let circuit = try CircuitCompiler.compile(symbols: [diode, ground], wires: [], labels: [])
    let element = try #require(circuit.elements.first { $0.name == "D1" })
    #expect(element.kind == .diode)
    #expect(abs((element.diode?.saturationCurrent ?? 0) - 2e-14) < 1e-20)
    #expect(abs((element.diode?.emissionCoefficient ?? 0) - 1.5) < 1e-9)
}

@Test @MainActor func netlistBuilderEmitsDiodeAndModel() throws {
    let document = SchematicDocument()
    _ = document.addComponent(descriptorId: "diode", at: GridPoint(0, 0))
    _ = document.addComponent(descriptorId: "ground", at: GridPoint(-2, 1))

    let netlist = try SpiceNetlistBuilder.build(from: document)
    #expect(netlist.contains("D1 "))
    #expect(netlist.contains(".model DMOD1 D(IS=1E-14 N=1)"))
}

@Test func diagnosticsRejectZeroSaturationCurrent() {
    var diode = SymbolInstance(descriptorId: "diode", refDes: "D1", position: GridPoint(0, 0))
    diode.parameters = ComponentRegistry.shared.descriptor(for: "diode")!.defaultParameterValues
    diode.parameters["saturationCurrent"] = 0
    let ground = SymbolInstance(descriptorId: "ground", refDes: "GND1", position: GridPoint(-2, 1))

    let diagnostics = CircuitDiagnostics.analyze(symbols: [diode, ground], wires: [], labels: [])
    #expect(diagnostics.contains {
        $0.severity == .error && $0.message.localizedCaseInsensitiveContains("saturation current")
    })
}

// MARK: - Phase 4: nonlinear devices (bipolar junction transistor)

@Test func bjtNpnCommonEmitterBiasesInActiveRegion() throws {
    // +5 V drives the base through 100k, and the collector through 1k.
    let circuit = LinearCircuit(
        nodeNames: ["0", "vb", "b", "vc", "c"],
        elements: [
            .init(kind: .voltageSource, nodeA: 1, nodeB: 0, value: 5, name: "VB"),
            .init(kind: .resistor, nodeA: 1, nodeB: 2, value: 100_000, name: "RB"),
            .init(kind: .voltageSource, nodeA: 3, nodeB: 0, value: 5, name: "VC"),
            .init(kind: .resistor, nodeA: 3, nodeB: 4, value: 1_000, name: "RC"),
            .init(
                kind: .bjt, nodeA: 4, nodeB: 0, nodeC: 2, value: 0,
                bjt: LinearCircuit.BJTParameters(polarity: .npn, forwardBeta: 100), name: "Q1"
            ),
        ]
    )
    let solution = try circuit.solveDC()
    let vbe = solution.nodeVoltages[2].re
    let vce = solution.nodeVoltages[4].re
    let ic = solution.elementCurrents[4].re
    #expect(vbe > 0.5 && vbe < 0.8)
    #expect(vce > 0.1 && vce < 5)
    #expect(ic > 0)
    // Collector current matches the collector-resistor drop.
    #expect(abs(ic - (5 - vce) / 1_000) < 1e-5)
    // Beta relates base and collector currents in the active region.
    let ib = (5 - vbe) / 100_000
    #expect(abs(ic - 100 * ib) / ic < 0.05)
}

@Test func bjtPnpCommonEmitterMirrorsNpn() throws {
    // The PNP mirror: emitter at +5 V, base pulled to ground through 100k,
    // collector returned to ground through 1k.
    let circuit = LinearCircuit(
        nodeNames: ["0", "ve", "b", "c"],
        elements: [
            .init(kind: .voltageSource, nodeA: 1, nodeB: 0, value: 5, name: "VE"),
            .init(kind: .resistor, nodeA: 2, nodeB: 0, value: 100_000, name: "RB"),
            .init(kind: .resistor, nodeA: 3, nodeB: 0, value: 1_000, name: "RC"),
            .init(
                kind: .bjt, nodeA: 3, nodeB: 1, nodeC: 2, value: 0,
                bjt: LinearCircuit.BJTParameters(polarity: .pnp, forwardBeta: 100), name: "Q1"
            ),
        ]
    )
    let solution = try circuit.solveDC()
    let veb = solution.nodeVoltages[1].re - solution.nodeVoltages[2].re
    let vc = solution.nodeVoltages[3].re
    let vec = solution.nodeVoltages[1].re - vc
    let ic = solution.elementCurrents[3].re
    #expect(veb > 0.5 && veb < 0.8)
    #expect(vec > 0.1 && vec < 5)
    // Collector current flows out of the collector into the resistor to ground,
    // so the current into the device is negative.
    #expect(ic < 0)
    #expect(abs(ic + vc / 1_000) < 1e-5)
}

@Test func netlistParserReadsBJTModelAndElement() throws {
    let netlist = """
    VCC 3 0 DC 5
    VBB 1 0 DC 5
    RB 1 2 100k
    RC 3 4 1k
    Q1 4 2 0 QNPN
    .model QNPN NPN(IS=2e-15 BF=150 BR=2)
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist)
    let bjt = try #require(parsed.circuit.elements.first { $0.name == "Q1" })
    #expect(bjt.kind == .bjt)
    #expect(bjt.bjt?.polarity == .npn)
    #expect(abs((bjt.bjt?.saturationCurrent ?? 0) - 2e-15) < 1e-25)
    #expect(abs((bjt.bjt?.forwardBeta ?? 0) - 150) < 1e-9)
    #expect(abs((bjt.bjt?.reverseBeta ?? 0) - 2) < 1e-9)
    // Node convention: nodeA = collector, nodeB = emitter, nodeC = base.
    #expect(parsed.circuit.nodeNames[bjt.nodeA] == "4")
    #expect(parsed.circuit.nodeNames[bjt.nodeB] == "0")
    #expect(parsed.circuit.nodeNames[try #require(bjt.nodeC)] == "2")
}

@Test func netlistParserReadsPNPModel() throws {
    let netlist = """
    V1 1 0 DC 5
    Q1 1 2 0 QPNP
    .model QPNP PNP(IS=1e-15 BF=50)
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist)
    let bjt = try #require(parsed.circuit.elements.first { $0.name == "Q1" })
    #expect(bjt.bjt?.polarity == .pnp)
}

@Test func netlistParseRejectsBJTWithUnknownModel() {
    #expect(throws: (any Error).self) {
        _ = try SpiceNetlistParser.parse("V1 1 0 DC 5\nQ1 1 1 0 NOPE\n.end")
    }
}

@Test func bjtNetlistSolvesCommonEmitterBias() throws {
    let netlist = """
    VCC 3 0 DC 5
    VBB 1 0 DC 5
    RB 1 2 100k
    RC 3 4 1k
    Q1 4 2 0 QNPN
    .model QNPN NPN(IS=1e-15 BF=100)
    .end
    """
    let result = try SimulationEngine.solve(netlist: netlist, settings: .default)
    let dc = try #require(result.dc)
    let base = try #require(dc.nodes.first { $0.name == "2" }?.voltage)
    let collector = try #require(dc.nodes.first { $0.name == "4" }?.voltage)
    #expect(base > 0.5 && base < 0.8)
    #expect(collector > 0.1 && collector < 5)
    #expect(collector < base + 0.05 || collector > base)
}

@Test func bjtSmallSignalACProducesFiniteGain() throws {
    var settings = AnalysisSettings.default
    settings.runDC = false
    settings.runAC = true
    settings.acStartFrequency = 100
    settings.acStopFrequency = 10_000
    settings.acPointsPerDecade = 2

    let netlist = """
    VCC 3 0 DC 5 AC 0
    VBB 1 0 DC 5 AC 1
    RB 1 2 100k
    RC 3 4 1k
    Q1 4 2 0 QNPN
    .model QNPN NPN(IS=1e-15 BF=100)
    .end
    """
    let result = try SimulationEngine.solve(netlist: netlist, settings: settings)
    let ac = try #require(result.ac)
    let collector = try #require(ac.nodes.first { $0.name == "4" })
    #expect(collector.response.allSatisfy { $0.magnitudeDb.isFinite })
    #expect((collector.response.first?.magnitudeDb ?? -1_000) > -120)
}

@Test func bjtTransientRespondsToBasePulse() throws {
    var settings = AnalysisSettings.default
    settings.runDC = false
    settings.runAC = false
    settings.runTransient = true
    settings.tranStep = 1e-5
    settings.tranStop = 1e-3

    let netlist = """
    VCC 3 0 DC 5
    VBB 1 0 PULSE(0 5 0 1n 1n 1 2)
    RB 1 2 100k
    RC 3 4 1k
    Q1 4 2 0 QNPN
    .model QNPN NPN(IS=1e-15 BF=100)
    .end
    """
    let result = try SimulationEngine.solve(netlist: netlist, settings: settings)
    let transient = try #require(result.transient)
    let collector = try #require(transient.nodes.first { $0.name == "4" }?.values)
    // While the base is driven high the collector is pulled low.
    #expect((collector.last ?? 5) < 1)
}

@Test func compilerMapsBJTParametersAndPolarity() throws {
    let bjt = SymbolInstance(
        descriptorId: "npn-transistor",
        refDes: "Q1",
        position: GridPoint(0, 0),
        parameters: ["saturationCurrent": 3e-15, "forwardBeta": 120, "reverseBeta": 2]
    )
    let ground = SymbolInstance(descriptorId: "ground", refDes: "GND1", position: GridPoint(-2, 1))

    let circuit = try CircuitCompiler.compile(symbols: [bjt, ground], wires: [], labels: [])
    let element = try #require(circuit.elements.first { $0.name == "Q1" })
    #expect(element.kind == .bjt)
    #expect(element.bjt?.polarity == .npn)
    #expect(abs((element.bjt?.saturationCurrent ?? 0) - 3e-15) < 1e-25)
    #expect(abs((element.bjt?.forwardBeta ?? 0) - 120) < 1e-9)
}

@Test @MainActor func netlistBuilderEmitsBJTAndModel() throws {
    let document = SchematicDocument()
    _ = document.addComponent(descriptorId: "pnp-transistor", at: GridPoint(0, 0))
    _ = document.addComponent(descriptorId: "ground", at: GridPoint(-2, 1))

    let netlist = try SpiceNetlistBuilder.build(from: document)
    #expect(netlist.contains("Q1 "))
    #expect(netlist.contains(".model QMOD1 PNP(IS=1E-15 BF=100 BR=1)"))
}

@Test func diagnosticsRejectInvalidForwardBeta() {
    var bjt = SymbolInstance(descriptorId: "npn-transistor", refDes: "Q1", position: GridPoint(0, 0))
    bjt.parameters = ComponentRegistry.shared.descriptor(for: "npn-transistor")!.defaultParameterValues
    bjt.parameters["forwardBeta"] = 1
    let ground = SymbolInstance(descriptorId: "ground", refDes: "GND1", position: GridPoint(-2, 1))

    let diagnostics = CircuitDiagnostics.analyze(symbols: [bjt, ground], wires: [], labels: [])
    #expect(diagnostics.contains {
        $0.severity == .error && $0.message.localizedCaseInsensitiveContains("forward beta")
    })
}

// MARK: - Phase 5: subcircuits

@Test func netlistParserFlattensSubcircuitInstance() throws {
    let netlist = """
    .subckt DIV a b mid
    R1 a mid 1k
    R2 mid b 1k
    .ends
    V1 in 0 DC 10
    X1 in 0 out DIV
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist)
    let names = parsed.circuit.elements.map(\.name)
    #expect(names.contains("X1.R1"))
    #expect(names.contains("X1.R2"))
    // Ports bind to the external nodes given on the X line.
    let r1 = try #require(parsed.circuit.elements.first { $0.name == "X1.R1" })
    #expect(parsed.circuit.nodeNames[r1.nodeA] == "in")
    #expect(parsed.circuit.nodeNames[r1.nodeB] == "out")
}

@Test func netlistSolvesSubcircuitVoltageDivider() throws {
    let netlist = """
    .subckt DIV a b mid
    R1 a mid 1k
    R2 mid b 1k
    .ends
    V1 in 0 DC 10
    X1 in 0 out DIV
    .end
    """
    let result = try SimulationEngine.solve(netlist: netlist, settings: .default)
    let out = try #require(result.dc?.nodes.first { $0.name == "out" }?.voltage)
    #expect(abs(out - 5) < 1e-6)
}

@Test func netlistSubcircuitScopesInternalNodesPerInstance() throws {
    let netlist = """
    .subckt DIV a b
    R1 a n 1k
    R2 n b 1k
    .ends
    V1 in 0 DC 10
    X1 in 0 DIV
    X2 in 0 DIV
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist)
    let names = Set(parsed.circuit.nodeNames)
    #expect(names.contains("X1.n"))
    #expect(names.contains("X2.n"))
    #expect(!names.contains("n"))
    #expect(Set(parsed.circuit.elements.map(\.name)).isSuperset(of: ["X1.R1", "X2.R1"]))
}

@Test func netlistSubcircuitParametersOverrideDefaults() throws {
    let netlist = """
    .subckt DIVP a b mid params: RA=1k RB=1k
    R1 a mid {RA}
    R2 mid b {RB}
    .ends
    V1 in 0 DC 10
    X1 in 0 out DIVP RA=3k RB=1k
    .end
    """
    let result = try SimulationEngine.solve(netlist: netlist, settings: .default)
    let out = try #require(result.dc?.nodes.first { $0.name == "out" }?.voltage)
    // 10 * RB / (RA + RB) = 10 * 1k / 4k = 2.5
    #expect(abs(out - 2.5) < 1e-6)
}

@Test func netlistSubcircuitParametersUseDefaults() throws {
    let netlist = """
    .subckt DIVP a b mid params: RA=1k RB=1k
    R1 a mid {RA}
    R2 mid b {RB}
    .ends
    V1 in 0 DC 10
    X1 in 0 out DIVP
    .end
    """
    let result = try SimulationEngine.solve(netlist: netlist, settings: .default)
    let out = try #require(result.dc?.nodes.first { $0.name == "out" }?.voltage)
    #expect(abs(out - 5) < 1e-6)
}

@Test func netlistSubcircuitExpressionsUseParameters() throws {
    let netlist = """
    .subckt HALF a b params: R=2k
    R1 a 0 {R/2}
    R2 b 0 {R + R}
    .ends
    V1 a 0 DC 8
    X1 a b HALF
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist)
    let r1 = try #require(parsed.circuit.elements.first { $0.name == "X1.R1" })
    let r2 = try #require(parsed.circuit.elements.first { $0.name == "X1.R2" })
    #expect(abs(r1.value - 1_000) < 1e-9)
    #expect(abs(r2.value - 4_000) < 1e-9)
}

@Test func netlistNestedSubcircuitsFlatten() throws {
    let netlist = """
    .subckt HALF a b
    R1 a mid 1k
    R2 mid b 1k
    .ends
    .subckt UNIT a b
    X1 a b HALF
    X2 a b HALF
    .ends
    V1 in 0 DC 12
    X0 in 0 UNIT
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist)
    let names = Set(parsed.circuit.elements.map(\.name))
    #expect(names.contains("X0.X1.R1"))
    #expect(names.contains("X0.X2.R2"))
    let result = try SimulationEngine.solve(netlist: netlist, settings: .default)
    #expect(result.dc != nil)
}

@Test func netlistSubcircuitSourceParameterSubstitution() throws {
    let netlist = """
    .subckt DRV p n params: AMP=5
    V1 p n DC {AMP}
    .ends
    R1 out 0 1k
    X1 out 0 DRV AMP=3
    .end
    """
    let result = try SimulationEngine.solve(netlist: netlist, settings: .default)
    let out = try #require(result.dc?.nodes.first { $0.name == "out" }?.voltage)
    #expect(abs(out - 3) < 1e-6)
}

@Test func netlistParseRejectsUnknownSubcircuit() {
    #expect(throws: (any Error).self) {
        _ = try SpiceNetlistParser.parse("V1 1 0 DC 5\nX1 1 0 NOPE\n.end")
    }
}

@Test func netlistParseRejectsSubcircuitPortMismatch() {
    let netlist = """
    .subckt DIV a b
    R1 a b 1k
    .ends
    V1 1 0 DC 5
    X1 1 DIV
    .end
    """
    #expect(throws: (any Error).self) {
        _ = try SpiceNetlistParser.parse(netlist)
    }
}

@Test func netlistParseRejectsRecursiveSubcircuit() {
    let netlist = """
    .subckt LOOP a b
    X1 a b LOOP
    .ends
    V1 1 0 DC 5
    X9 1 0 LOOP
    .end
    """
    #expect(throws: (any Error).self) {
        _ = try SpiceNetlistParser.parse(netlist)
    }
}

@Test func netlistParseRejectsUnterminatedSubcircuit() {
    let netlist = """
    .subckt DIV a b
    R1 a b 1k
    V1 1 0 DC 5
    .end
    """
    #expect(throws: (any Error).self) {
        _ = try SpiceNetlistParser.parse(netlist)
    }
}

// MARK: - Phase 6: MOSFET (Level 1 Shichman-Hodges)

@Test func mosfetNmosBiasesInSaturation() throws {
    // +5 V through 1k to the drain; gate held at 3 V; source and bulk grounded.
    let circuit = LinearCircuit(
        nodeNames: ["0", "vdd", "drain", "gate"],
        elements: [
            .init(kind: .voltageSource, nodeA: 1, nodeB: 0, value: 5, name: "VDD"),
            .init(kind: .resistor, nodeA: 1, nodeB: 2, value: 1_000, name: "RD"),
            .init(kind: .voltageSource, nodeA: 3, nodeB: 0, value: 3, name: "VG"),
            .init(
                kind: .mosfet, nodeA: 2, nodeB: 0, nodeC: 3, nodeD: 0, value: 0,
                mosfet: LinearCircuit.MOSFETParameters(
                    polarity: .nmos, thresholdVoltage: 1, transconductanceParameter: 1e-3
                ),
                name: "M1"
            ),
        ]
    )
    let solution = try circuit.solveDC()
    let vd = solution.nodeVoltages[2].re
    let drainCurrent = solution.elementCurrents[3].re
    // Saturation: Id = 0.5·KP·(Vgs − Vt)² = 0.5·1e-3·4 = 2 mA.
    #expect(drainCurrent > 0)
    #expect(abs(drainCurrent - 2e-3) < 1e-5)
    #expect(abs(vd - (5 - 2e-3 * 1_000)) < 1e-3)
}

@Test func mosfetPmosBiasesInSaturation() throws {
    // Source at +5 V, gate at 2 V, drain returned to ground through 1k.
    let circuit = LinearCircuit(
        nodeNames: ["0", "vdd", "drain", "gate"],
        elements: [
            .init(kind: .voltageSource, nodeA: 1, nodeB: 0, value: 5, name: "VDD"),
            .init(kind: .resistor, nodeA: 2, nodeB: 0, value: 1_000, name: "RD"),
            .init(kind: .voltageSource, nodeA: 3, nodeB: 0, value: 2, name: "VG"),
            .init(
                kind: .mosfet, nodeA: 2, nodeB: 1, nodeC: 3, nodeD: 1, value: 0,
                mosfet: LinearCircuit.MOSFETParameters(
                    polarity: .pmos, thresholdVoltage: -1, transconductanceParameter: 1e-3
                ),
                name: "M1"
            ),
        ]
    )
    let solution = try circuit.solveDC()
    let vd = solution.nodeVoltages[2].re
    let drainCurrent = solution.elementCurrents[3].re
    // |Vsg| = 3, |Vt| = 1, overdrive 2; current flows out of the drain.
    #expect(abs(drainCurrent + 2e-3) < 1e-5)
    #expect(abs(vd - 2.0) < 1e-3)
}

@Test func mosfetBodyEffectLowersDrainCurrent() throws {
    func drainCurrent(bulkVoltage: Double) throws -> Double {
        let circuit = LinearCircuit(
            nodeNames: ["0", "vdd", "drain", "gate", "bulk"],
            elements: [
                .init(kind: .voltageSource, nodeA: 1, nodeB: 0, value: 5, name: "VDD"),
                .init(kind: .resistor, nodeA: 1, nodeB: 2, value: 1_000, name: "RD"),
                .init(kind: .voltageSource, nodeA: 3, nodeB: 0, value: 3, name: "VG"),
                .init(kind: .voltageSource, nodeA: 4, nodeB: 0, value: bulkVoltage, name: "VB"),
                .init(
                    kind: .mosfet, nodeA: 2, nodeB: 0, nodeC: 3, nodeD: 4, value: 0,
                    mosfet: LinearCircuit.MOSFETParameters(
                        polarity: .nmos, thresholdVoltage: 1,
                        transconductanceParameter: 1e-3, bodyEffect: 0.5, surfacePotential: 0.6
                    ),
                    name: "M1"
                ),
            ]
        )
        return try circuit.solveDC().elementCurrents[4].re
    }
    let zeroBias = try drainCurrent(bulkVoltage: 0)
    let reverseBias = try drainCurrent(bulkVoltage: -2)
    // Reverse body bias raises the threshold, lowering the drain current.
    #expect(reverseBias > 0)
    #expect(reverseBias < zeroBias)
}

@Test func netlistParserReadsMOSFETModelAndElement() throws {
    let netlist = """
    VDD 1 0 DC 5
    VG 3 0 DC 3
    RD 1 2 1k
    M1 2 3 0 0 NMOS1
    .model NMOS1 NMOS(VTO=1 KP=1m LAMBDA=0.02)
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist)
    let mosfet = try #require(parsed.circuit.elements.first { $0.name == "M1" })
    #expect(mosfet.kind == .mosfet)
    #expect(mosfet.mosfet?.polarity == .nmos)
    #expect(abs((mosfet.mosfet?.thresholdVoltage ?? 0) - 1) < 1e-9)
    #expect(abs((mosfet.mosfet?.transconductanceParameter ?? 0) - 1e-3) < 1e-15)
    #expect(abs((mosfet.mosfet?.channelLengthModulation ?? 0) - 0.02) < 1e-15)
    // Node convention: nodeA = drain, nodeB = source, nodeC = gate, nodeD = bulk.
    #expect(parsed.circuit.nodeNames[mosfet.nodeA] == "2")
    #expect(parsed.circuit.nodeNames[mosfet.nodeB] == "0")
    #expect(parsed.circuit.nodeNames[try #require(mosfet.nodeC)] == "3")
    #expect(parsed.circuit.nodeNames[try #require(mosfet.nodeD)] == "0")
}

@Test func netlistParserReadsPMOSModel() throws {
    let netlist = """
    VDD 1 0 DC 5
    M1 1 2 0 0 PMOS1
    .model PMOS1 PMOS(VTO=-1.5 KP=2m)
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist)
    let mosfet = try #require(parsed.circuit.elements.first { $0.name == "M1" })
    #expect(mosfet.mosfet?.polarity == .pmos)
    #expect(abs((mosfet.mosfet?.thresholdVoltage ?? 0) + 1.5) < 1e-9)
}

@Test func netlistParseRejectsMOSFETWithUnknownModel() {
    #expect(throws: (any Error).self) {
        _ = try SpiceNetlistParser.parse("V1 1 0 DC 5\nM1 1 1 0 0 NOPE\n.end")
    }
}

@Test func mosfetNetlistSolvesCommonSource() throws {
    let netlist = """
    VDD 1 0 DC 5
    VG 3 0 DC 3
    RD 1 2 1k
    M1 2 3 0 0 NMOS1
    .model NMOS1 NMOS(VTO=1 KP=1m)
    .end
    """
    let result = try SimulationEngine.solve(netlist: netlist, settings: .default)
    let drain = try #require(result.dc?.nodes.first { $0.name == "2" }?.voltage)
    #expect(abs(drain - 3) < 1e-2)
}

@Test func mosfetSmallSignalACProducesFiniteGain() throws {
    var settings = AnalysisSettings.default
    settings.runDC = false
    settings.runAC = true
    settings.acStartFrequency = 100
    settings.acStopFrequency = 10_000
    settings.acPointsPerDecade = 2

    let netlist = """
    VDD 1 0 DC 5 AC 0
    VG 3 0 DC 3 AC 1
    RD 1 2 1k
    M1 2 3 0 0 NMOS1
    .model NMOS1 NMOS(VTO=1 KP=1m)
    .end
    """
    let result = try SimulationEngine.solve(netlist: netlist, settings: settings)
    let ac = try #require(result.ac)
    let drain = try #require(ac.nodes.first { $0.name == "2" })
    #expect(drain.response.allSatisfy { $0.magnitudeDb.isFinite })
    // Small-signal gain ~ gm·RD = (1e-3·2)·1e3 = 2.
    #expect((drain.response.first?.magnitudeDb ?? -1_000) > -60)
}

@Test func mosfetTransientRespondsToGatePulse() throws {
    var settings = AnalysisSettings.default
    settings.runDC = false
    settings.runAC = false
    settings.runTransient = true
    settings.tranStep = 1e-5
    settings.tranStop = 1e-3

    let netlist = """
    VDD 1 0 DC 5
    VG 3 0 PULSE(0 5 0 1n 1n 5 10)
    RD 1 2 1k
    M1 2 3 0 0 NMOS1
    .model NMOS1 NMOS(VTO=1 KP=1m)
    .end
    """
    let result = try SimulationEngine.solve(netlist: netlist, settings: settings)
    let transient = try #require(result.transient)
    let drain = try #require(transient.nodes.first { $0.name == "2" }?.values)
    // While the gate is driven high the drain is pulled low.
    #expect((drain.last ?? 5) < 1.5)
    #expect((drain.last ?? 0) < (drain.first ?? 5))
}

@Test func compilerMapsMOSFETParametersAndPolarity() throws {
    let mosfet = SymbolInstance(
        descriptorId: "pmos-transistor",
        refDes: "M1",
        position: GridPoint(0, 0),
        parameters: [
            "thresholdVoltage": -1.5,
            "transconductanceParameter": 5e-3,
            "channelLengthModulation": 0.05,
            "bodyEffect": 0.4,
            "surfacePotential": 0.7,
        ]
    )
    let ground = SymbolInstance(descriptorId: "ground", refDes: "GND1", position: GridPoint(-2, 1))

    let circuit = try CircuitCompiler.compile(symbols: [mosfet, ground], wires: [], labels: [])
    let element = try #require(circuit.elements.first { $0.name == "M1" })
    #expect(element.kind == .mosfet)
    #expect(element.mosfet?.polarity == .pmos)
    #expect(abs((element.mosfet?.thresholdVoltage ?? 0) + 1.5) < 1e-9)
    #expect(abs((element.mosfet?.transconductanceParameter ?? 0) - 5e-3) < 1e-15)
    #expect(abs((element.mosfet?.bodyEffect ?? 0) - 0.4) < 1e-9)
}

@Test @MainActor func netlistBuilderEmitsMOSFETAndModel() throws {
    let document = SchematicDocument()
    _ = document.addComponent(descriptorId: "nmos-transistor", at: GridPoint(0, 0))
    _ = document.addComponent(descriptorId: "ground", at: GridPoint(-2, 1))

    let netlist = try SpiceNetlistBuilder.build(from: document)
    #expect(netlist.contains("M1 "))
    #expect(netlist.contains(".model MMOD1 NMOS(VTO=1 KP=2E-05 LAMBDA=0 GAMMA=0 PHI=0.6)"))
}

@Test func netlistSubcircuitScopesMOSFETInstances() throws {
    let netlist = """
    .subckt INV vin vout vdd
    M1 vout vin 0 0 NMOS1
    RD vdd vout 1k
    .ends
    VDD vdd 0 DC 5
    Vin in 0 DC 5
    X1 in out vdd INV
    .model NMOS1 NMOS(VTO=1 KP=1m)
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist)
    #expect(Set(parsed.circuit.elements.map(\.name)).isSuperset(of: ["X1.M1", "X1.RD"]))
    let result = try SimulationEngine.solve(netlist: netlist, settings: .default)
    let out = try #require(result.dc?.nodes.first { $0.name == "out" }?.voltage)
    // The driven-high gate pulls the drain low through the pull-up resistor.
    #expect(out > 0 && out < 1.5)
}

@Test func diagnosticsRejectInvalidTransconductance() {
    var mosfet = SymbolInstance(descriptorId: "nmos-transistor", refDes: "M1", position: GridPoint(0, 0))
    mosfet.parameters = ComponentRegistry.shared.descriptor(for: "nmos-transistor")!.defaultParameterValues
    mosfet.parameters["transconductanceParameter"] = 0
    let ground = SymbolInstance(descriptorId: "ground", refDes: "GND1", position: GridPoint(-2, 1))

    let diagnostics = CircuitDiagnostics.analyze(symbols: [mosfet, ground], wires: [], labels: [])
    #expect(diagnostics.contains {
        $0.severity == .error && $0.message.localizedCaseInsensitiveContains("transconductance parameter")
    })
}

// MARK: - Phase 7: SPICE dialect breadth

@Test func netlistParamCardSubstitutesBracedAndBareValues() throws {
    let netlist = """
    .param R=1k
    V1 1 0 DC 1
    R1 1 0 {R}
    R2 2 0 2k
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist)
    let r1 = try #require(parsed.circuit.elements.first { $0.name == "R1" })
    #expect(abs(r1.value - 1000) < 1e-9)

    let bare = try SpiceNetlistParser.parse(".param R=2k\nV1 1 0 DC 1\nR1 1 0 R\n.end")
    #expect(abs((bare.circuit.elements.first { $0.name == "R1" }?.value ?? 0) - 2000) < 1e-9)
}

@Test func netlistParamReachesSourcesAndSubcircuits() throws {
    let netlist = """
    .param VB=5
    .param RB=2k
    V1 1 0 DC {VB}
    .subckt DIV a b
    R1 a b {RB}
    .ends
    X1 1 0 DIV
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist)
    let source = try #require(parsed.circuit.elements.first { $0.name == "V1" })
    #expect(abs((source.dcValue ?? 0) - 5) < 1e-9)
    let resistor = try #require(parsed.circuit.elements.first { $0.name == "X1.R1" })
    #expect(abs(resistor.value - 2000) < 1e-9)
}

@Test func netlistOptionsCardIsAccepted() throws {
    let netlist = """
    V1 1 0 DC 1
    R1 1 0 1k
    .options reltol=1e-3 abstol=1e-12 gmin=1e-12
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist)
    #expect(parsed.circuit.elements.count == 2)
}

@Test func netlistIncludeResolverInlinesFileContents() throws {
    let resolver: SpiceIncludeResolver = { path in
        path == "part.lib" ? "R1 1 0 1k\n" : nil
    }
    let netlist = """
    V1 1 0 DC 1
    .include part.lib
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist, include: resolver)
    #expect(Set(parsed.circuit.elements.map(\.name)) == ["V1", "R1"])
    #expect(parsed.warnings.isEmpty)
}

@Test func netlistIncludeWithoutResolverWarnsAndSkips() throws {
    let netlist = "V1 1 0 DC 1\nR1 1 0 1k\n.lib missing.lib\n.end"
    let parsed = try SpiceNetlistParser.parse(netlist)
    #expect(Set(parsed.circuit.elements.map(\.name)) == ["V1", "R1"])
    #expect(parsed.warnings.contains { $0.contains("missing.lib") })
}

@Test func netlistIcSeedsTransientInitialCondition() throws {
    let netlist = """
    V1 1 0 DC 10
    R1 1 2 1k
    C1 2 0 1e-6
    .ic V(2)=2
    .tran 1e-5 1e-4
    .end
    """
    let result = try SimulationEngine.solve(netlist: netlist, settings: .default)
    let transient = try #require(result.transient)
    let node = try #require(transient.nodes.first { $0.name == "2" })
    // The recorded initial point reflects the `.ic` override, not the 10 V
    // operating point.
    #expect(abs(node.values[0] - 2) < 1e-9)
}

@Test func netlistDCRunsSingleSourceSweep() throws {
    let netlist = """
    V1 1 0 DC 0
    R1 1 0 1k
    .dc V1 0 4 1
    .end
    """
    let result = try SimulationEngine.solve(netlist: netlist, settings: .default)
    let sweep = try #require(result.sweep)
    #expect(sweep.axes.count == 1)
    #expect(sweep.axes[0].name == "V1")
    #expect(sweep.points.count == 5)
    let last = try #require(sweep.points.last?.nodes.first { $0.name == "1" }?.voltage)
    #expect(abs(last - 4) < 1e-9)
}

@Test func netlistDCNestedSweepProducesTwoAxes() throws {
    let netlist = """
    V1 1 0 DC 0
    V2 2 0 DC 0
    R1 1 0 1k
    R2 2 0 1k
    .dc V1 0 2 1 V2 0 2 1
    .end
    """
    let result = try SimulationEngine.solve(netlist: netlist, settings: .default)
    let sweep = try #require(result.sweep)
    #expect(sweep.axes.map(\.name) == ["V1", "V2"])
    #expect(sweep.points.count == 9)
    #expect(sweep.points.first?.coordinates.count == 2)
}

@Test func netlistDCSweepRejectsUnknownSource() {
    let netlist = """
    V1 1 0 DC 1
    R1 1 0 1k
    .dc NOPE 0 1 1
    .end
    """
    #expect(throws: CircuitSimulationError.self) {
        _ = try SimulationEngine.solve(netlist: netlist, settings: .default)
    }
}

@Test func netlistStepParamReParsesEachValue() throws {
    let netlist = """
    .param RV=1k
    V1 1 0 DC 1
    R1 1 0 {RV}
    .step param RV list 1k 2k
    .end
    """
    let result = try SimulationEngine.solve(netlist: netlist, settings: .default)
    let sweep = try #require(result.sweep)
    #expect(sweep.axes.count == 1)
    #expect(sweep.axes[0].name == "RV")
    #expect(sweep.axes[0].values == [1000, 2000])
    #expect(sweep.points.count == 2)
    let first = try #require(sweep.points[0].components.first { $0.name == "R1" }?.current)
    let second = try #require(sweep.points[1].components.first { $0.name == "R1" }?.current)
    #expect(abs(first - 1e-3) < 1e-9)
    #expect(abs(second - 5e-4) < 1e-9)
}

@Test func schematicStyleSweepUsesSettings() throws {
    let netlist = """
    V1 1 0 DC 0
    R1 1 0 1k
    .end
    """
    var settings = AnalysisSettings.default
    settings.runDCSweep = true
    settings.dcSweepSource = "V1"
    settings.dcSweepStart = 0
    settings.dcSweepStop = 4
    settings.dcSweepStep = 1
    let result = try SimulationEngine.solve(netlist: netlist, settings: settings)
    let sweep = try #require(result.sweep)
    #expect(sweep.points.count == 5)
}

@Test func netlistGroundAliasNormalizesToNodeZero() throws {
    let netlist = """
    V1 1 gnd DC 5
    R1 1 gnd 1k
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist)
    #expect(parsed.circuit.nodeNames.contains("0"))
    #expect(parsed.circuit.elements.allSatisfy { $0.nodeB == 0 })
    #expect(parsed.warnings.contains { $0.localizedCaseInsensitiveContains("ground") })
}

@Test func netlistTempCardSetsOperatingTemperature() throws {
    let netlist = "V1 1 0 DC 1\nR1 1 0 1k\n.temp 50\n.end"
    let parsed = try SpiceNetlistParser.parse(netlist)
    #expect(parsed.warnings.isEmpty)
    #expect(abs(parsed.circuit.solverOptions.temperatureCelsius - 50) < 1e-9)
}

@Test func csvIncludesSweepSection() throws {
    let netlist = """
    V1 1 0 DC 0
    R1 1 0 1k
    .dc V1 0 2 1
    .end
    """
    let result = try SimulationEngine.solve(netlist: netlist, settings: .default)
    let csv = CircuitResultExport.csv(result)
    #expect(csv.contains("time_s,sweep"))
    #expect(csv.contains("sweep,"))
    #expect(csv.contains("V1="))
}

// MARK: - KiCad interchange

/// A schema-free, KiCad-flavoured netlist: benign control cards, `/`-prefixed
/// labels, and `Net-_<ref>-Pad<n>_` auto nets, exactly as `kicad-cli` emits.
private let kicadStyleNetlist = """
.title KiCad schematic
.date 2026-01-01
.save all
.probe v(out)
V1 1 0 DC 10
R1 1 Net-_R2-Pad1_ 1k
R2 Net-_R2-Pad1_ 0 1k
.end
"""

@Test func kicadControlCardsAreToleratedSilently() throws {
    let parsed = try SpiceNetlistParser.parse(kicadStyleNetlist)
    #expect(parsed.warnings.isEmpty)
    #expect(parsed.circuit.nodeNames.contains("Net-_R2-Pad1_"))
}

@Test func kicadStyledNetlistSolves() throws {
    let result = try SimulationEngine.solve(netlist: kicadStyleNetlist, settings: .default)
    let dc = try #require(result.dc)
    let midpoint = try #require(dc.nodes.first { $0.name == "Net-_R2-Pad1_" })
    #expect(abs(midpoint.voltage - 5) < 1e-9)
}

@Test func kicadLabeledNetNameIsPreserved() throws {
    let parsed = try SpiceNetlistParser.parse("V1 /in 0 DC 1\nR1 /in 0 1k\n.end")
    #expect(parsed.circuit.nodeNames.contains("/in"))
}

@Test func kicadUnsupportedSymbolIsReported() {
    // Connector-only symbols export as `<ref> <net>` with no model.
    #expect(throws: SpiceParseError.self) {
        try SpiceNetlistParser.parse("J1 __J1\n.end")
    }
}

@Test func kicadQuotedIncludePathIsUnquoted() throws {
    var requested: [String] = []
    let netlist = """
    .include "models/divider.lib"
    V1 1 0 DC 1
    R1 1 0 1k
    .end
    """
    _ = try SpiceNetlistParser.parse(netlist) { path in
        requested.append(path)
        return "R2 1 0 2k"
    }
    #expect(requested == ["models/divider.lib"])
}

@Test func nodesetCodeIsAcceptedWithWarning() throws {
    let parsed = try SpiceNetlistParser.parse("V1 1 0 DC 1\nR1 1 0 1k\n.nodeset v(1)=0.5\n.end")
    #expect(parsed.warnings.contains { $0.contains(".nodeset") })
}

@Test @MainActor func importNetlistSwitchesToNetlistMode() {
    let document = CircuitDocument()
    document.importNetlist("V1 1 0 DC 1\nR1 1 0 1k\n.end")
    #expect(document.usesSchematic == false)
    #expect(document.netlistText.contains("V1"))
}

@Test @MainActor func importDesignLoadsNetlistFile() throws {
    let document = CircuitDocument()
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("divider-\(UUID().uuidString).cir")
    try "V1 1 0 DC 2\nR1 1 0 1k\n.end".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    try document.importDesign(at: url)
    #expect(document.usesSchematic == false)
    #expect(document.name == url.deletingPathExtension().lastPathComponent)
    #expect(document.netlistText.contains("DC 2"))
}

@Test @MainActor func importDesignRejectsUnknownExtension() throws {
    let document = CircuitDocument()
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mystery-\(UUID().uuidString).xyz")
    try "not a netlist".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(throws: KiCadInterchangeError.self) { try document.importDesign(at: url) }
}

@Test @MainActor func interchangeExportMatchesBuilder() throws {
    let document = SchematicDocument()
    let source = try #require(document.addComponent(descriptorId: "voltage-source", at: GridPoint(0, 0)))
    document.setParameter(id: source.id, key: "dcVoltage", value: 5)
    _ = document.addComponent(descriptorId: "ground", at: GridPoint(-2, 1))

    let netlist = try KiCadInterchange.exportNetlist(from: document)
    #expect(netlist.contains("DC 5"))
}

@Test @MainActor func netlistForExportPrefersSchematicProjection() throws {
    let document = CircuitDocument()
    let source = try #require(document.schematic.addComponent(descriptorId: "voltage-source", at: GridPoint(0, 0)))
    document.schematic.setParameter(id: source.id, key: "dcVoltage", value: 7)
    _ = document.schematic.addComponent(descriptorId: "ground", at: GridPoint(-2, 1))
    document.usesSchematic = true

    #expect(try document.netlistForExport().contains("DC 7"))
}

@Test @MainActor func netlistForExportUsesNetlistText() throws {
    let document = CircuitDocument()
    document.importNetlist("V1 1 0 DC 9\nR1 1 0 1k\n.end")
    #expect(try document.netlistForExport().contains("DC 9"))
}

@Test @MainActor func importNetlistRecordsProvenance() {
    let document = CircuitDocument()
    let source = CircuitDocument.ImportSource(fileName: "amp.cir", kind: .spiceNetlist)
    document.importNetlist("V1 1 0 DC 1\nR1 1 0 1k\n.end", source: source)
    #expect(document.usesSchematic == false)
    #expect(document.importSource == source)
}

@Test @MainActor func editingNetlistClearsImportProvenance() {
    let document = CircuitDocument()
    document.importNetlist(
        "V1 1 0 DC 1\nR1 1 0 1k\n.end",
        source: CircuitDocument.ImportSource(fileName: "amp.cir", kind: .spiceNetlist)
    )
    #expect(document.importSource != nil)
    document.netlistText += "\n* edited"
    #expect(document.importSource == nil)
}

@Test @MainActor func importNetlistCollectsParserWarnings() {
    let document = CircuitDocument()
    document.importNetlist("V1 1 0 DC 1\nR1 1 0 1k\n.nodeset v(1)=0.5\n.end")
    #expect(document.importWarnings.contains { $0.contains(".nodeset") })
}

@Test @MainActor func importDesignRecordsSourceFileName() throws {
    let document = CircuitDocument()
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("amp-\(UUID().uuidString).cir")
    try "V1 1 0 DC 4\nR1 1 0 1k\n.end".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    try document.importDesign(at: url)
    #expect(document.importSource?.kind == .spiceNetlist)
    #expect(document.importSource?.fileName == url.lastPathComponent)
}

@Test func writeNetlistRoundTrips() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("netlist-\(UUID().uuidString).cir")
    defer { try? FileManager.default.removeItem(at: url) }
    let text = "V1 1 0 DC 3\nR1 1 0 1k\n.end"
    try KiCadInterchange.writeNetlist(text, to: url)
    #expect(try KiCadInterchange.readNetlist(at: url) == text)
}

#if os(macOS)
@Test func kicadCLIExportArgumentsAreExact() {
    let schematic = URL(fileURLWithPath: "/tmp/x.kicad_sch")
    let output = URL(fileURLWithPath: "/tmp/x.cir")
    #expect(KiCadCLIClient.exportArguments(schematic: schematic, output: output) == [
        "sch", "export", "netlist", "--format", "spice",
        "--output", "/tmp/x.cir", "/tmp/x.kicad_sch"
    ])
}

@Test func kicadCLILocatePrefersExplicitExecutable() {
    #expect(KiCadCLIClient.locate(explicitPath: "/bin/ls", searchPATH: false)?.path == "/bin/ls")
}

private let kicadTemplateSchematicPath =
    "/Applications/KiCad/KiCad.app/Contents/SharedSupport/template/API_Series-500/API_Series-500.kicad_sch"

private var kicadLiveExportAvailable: Bool {
    KiCadCLIClient.isAvailable && FileManager.default.fileExists(atPath: kicadTemplateSchematicPath)
}

@Test(.enabled(if: kicadLiveExportAvailable))
func kicadCLIExportsARealSchematic() throws {
    let text = try KiCadCLIClient.exportSpiceNetlist(
        from: URL(fileURLWithPath: kicadTemplateSchematicPath)
    )
    #expect(text.contains(".title"))
    // The bundled template is connector-only, which we surface as unsupported.
    #expect(throws: SpiceParseError.self) { try KiCadInterchange.parseNetlist(text) }
}
#endif

// MARK: - Phase 10: numerical robustness & fidelity

@Test func solverOptionsCardIsParsed() throws {
    let netlist = """
    V1 1 0 DC 1
    R1 1 0 1k
    .options reltol=1e-4 abstol=1e-14 vntol=1e-8 gmin=1e-10 itl1=42 temp=75 tnom=25
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist)
    let options = parsed.circuit.solverOptions
    #expect(abs(options.relativeTolerance - 1e-4) < 1e-18)
    #expect(abs(options.absoluteCurrentTolerance - 1e-14) < 1e-24)
    #expect(abs(options.absoluteVoltageTolerance - 1e-8) < 1e-22)
    #expect(abs(options.minimumConductance - 1e-10) < 1e-20)
    #expect(options.maximumIterations == 42)
    #expect(abs(options.temperatureCelsius - 75) < 1e-9)
    #expect(abs(options.nominalTemperatureCelsius - 25) < 1e-9)
}

@Test func unknownOptionsAreAcceptedSilently() throws {
    let netlist = "V1 1 0 DC 1\nR1 1 0 1k\n.options acct op list\n.end"
    let parsed = try SpiceNetlistParser.parse(netlist)
    #expect(parsed.warnings.isEmpty)
}

@Test func defaultSolverOptionsMatchSpiceDefaults() {
    let options = SolverOptions.default
    #expect(abs(options.relativeTolerance - 1e-3) < 1e-18)
    #expect(abs(options.absoluteCurrentTolerance - 1e-12) < 1e-24)
    #expect(abs(options.absoluteVoltageTolerance - 1e-6) < 1e-18)
    #expect(abs(options.minimumConductance - 1e-12) < 1e-24)
    #expect(abs(options.temperatureCelsius - 27) < 1e-9)
    // At the nominal temperature the model thermal voltage is unchanged.
    #expect(abs(options.thermalScale - 1) < 1e-12)
}

@Test func nonsensicalOptionsAreSanitized() {
    let options = SolverOptions(
        relativeTolerance: -1,
        absoluteCurrentTolerance: 0,
        absoluteVoltageTolerance: .nan,
        minimumConductance: -3,
        maximumIterations: 0,
        temperatureCelsius: -500,
        nominalTemperatureCelsius: 27
    ).sanitized()
    #expect(options.relativeTolerance == SolverOptions.default.relativeTolerance)
    #expect(options.absoluteCurrentTolerance == SolverOptions.default.absoluteCurrentTolerance)
    #expect(options.absoluteVoltageTolerance == SolverOptions.default.absoluteVoltageTolerance)
    #expect(options.minimumConductance == SolverOptions.default.minimumConductance)
    #expect(options.maximumIterations == 1)
    #expect(options.temperatureCelsius == SolverOptions.default.temperatureCelsius)
}

@Test func gminOptionSetsDiodeReverseLeakage() throws {
    let netlist = """
    V1 1 0 DC -1
    D1 1 0 DMOD
    .model DMOD D(IS=1e-14 N=1)
    .options gmin=1e-6
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist)
    let solution = try parsed.circuit.solveDC()
    let index = try #require(parsed.circuit.elements.firstIndex { $0.name == "D1" })
    // Reverse bias: the current is dominated by the gmin leakage, -gmin·V.
    #expect(abs(solution.elementCurrents[index].re - (-1e-6)) < 1e-9)
}

@Test func iterationCapForcesNonConvergence() throws {
    let netlist = """
    I1 0 1 DC 1m
    D1 1 0 DMOD
    .model DMOD D(IS=1e-14 N=1)
    .options itl1=1
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist)
    #expect(throws: CircuitSolveError.self) {
        _ = try parsed.circuit.solveDC()
    }
}

@Test func diodeForwardDropFallsWithTemperature() throws {
    func diodeNodeVoltage(temperature: Double) throws -> Double {
        let netlist = """
        I1 0 1 DC 1m
        D1 1 0 DMOD
        .model DMOD D(IS=1e-14 N=1)
        .temp \(temperature)
        .end
        """
        let parsed = try SpiceNetlistParser.parse(netlist)
        return try parsed.circuit.solveDC().voltage(node: 1).re
    }
    let cold = try diodeNodeVoltage(temperature: 27)
    let hot = try diodeNodeVoltage(temperature: 127)
    // A fixed forward current needs a smaller drop when hot: IS(T) grows faster
    // than the thermal voltage, giving the diode its negative temperature
    // coefficient.
    #expect(hot < cold - 0.1)
}

@Test func diodeReverseLeakageRisesWithTemperature() throws {
    func reverseCurrent(temperature: Double) throws -> Double {
        let netlist = """
        V1 1 0 DC -1
        D1 1 0 DMOD
        .model DMOD D(IS=1e-14 N=1)
        .temp \(temperature)
        .end
        """
        let parsed = try SpiceNetlistParser.parse(netlist)
        let solution = try parsed.circuit.solveDC()
        let index = try #require(parsed.circuit.elements.firstIndex { $0.name == "D1" })
        return solution.elementCurrents[index].re
    }
    let cold = try reverseCurrent(temperature: 27)
    let hot = try reverseCurrent(temperature: 127)
    // Reverse leakage is dominated by -IS(T), which rises sharply with heat.
    #expect(abs(hot) > 100 * abs(cold))
}

@Test func temperatureDependenceIsIdentityAtNominalTemperature() throws {
    let netlist = """
    V1 1 0 DC -1
    D1 1 0 DMOD
    .model DMOD D(IS=1e-14 N=1)
    .options gmin=1e-18
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist)
    #expect(abs(parsed.circuit.solverOptions.temperatureCelsius - 27) < 1e-9)
    let solution = try parsed.circuit.solveDC()
    let index = try #require(parsed.circuit.elements.firstIndex { $0.name == "D1" })
    // At the nominal temperature IS(T) = IS, so the reverse current is -IS.
    #expect(abs(solution.elementCurrents[index].re - (-1e-14)) < 1e-17)
}

@Test func modelTemperatureParametersAreParsed() throws {
    let netlist = """
    V1 1 0 DC 1
    D1 1 0 DMOD
    Q1 1 1 0 QMOD
    M1 1 1 0 0 MMOD
    .model DMOD D(IS=1e-14 N=1 XTI=2.5 EG=1.2)
    .model QMOD NPN(IS=1e-15 BF=100 XTI=3.5 EG=1.1 XTB=1.5)
    .model MMOD NMOS(VTO=1 KP=1m BEX=-2 TCV=-2m)
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist)
    let diode = try #require(parsed.circuit.elements.first { $0.name == "D1" }?.diode)
    #expect(abs(diode.saturationCurrentTemperatureExponent - 2.5) < 1e-9)
    #expect(abs(diode.activationEnergy - 1.2) < 1e-9)
    let bjt = try #require(parsed.circuit.elements.first { $0.name == "Q1" }?.bjt)
    #expect(abs(bjt.saturationCurrentTemperatureExponent - 3.5) < 1e-9)
    #expect(abs(bjt.activationEnergy - 1.1) < 1e-9)
    #expect(abs(bjt.betaTemperatureExponent - 1.5) < 1e-9)
    let mosfet = try #require(parsed.circuit.elements.first { $0.name == "M1" }?.mosfet)
    #expect(abs(mosfet.mobilityTemperatureExponent - (-2)) < 1e-9)
    #expect(abs(mosfet.thresholdTemperatureCoefficient - (-2e-3)) < 1e-12)
}

@Test func bjtCollectorCurrentRisesWithTemperature() throws {
    func collectorCurrent(temperature: Double) throws -> Double {
        let netlist = """
        VCC 2 0 DC 5
        VBB 1 0 DC 0.65
        RC 2 3 1k
        Q1 3 1 0 QMOD
        .model QMOD NPN(IS=1e-15 BF=100)
        .temp \(temperature)
        .end
        """
        let parsed = try SpiceNetlistParser.parse(netlist)
        let solution = try parsed.circuit.solveDC()
        let index = try #require(parsed.circuit.elements.firstIndex { $0.name == "Q1" })
        return solution.elementCurrents[index].re
    }
    let cold = try collectorCurrent(temperature: 27)
    let hot = try collectorCurrent(temperature: 100)
    // IS(T) rises with heat, so a fixed base bias drives more collector current.
    #expect(hot > cold)
}

@Test func mosfetDrainCurrentFallsWithTemperature() throws {
    func drainCurrent(temperature: Double) throws -> Double {
        let netlist = """
        VDD 1 0 DC 5
        VG 2 0 DC 2
        M1 1 2 0 0 MMOD
        .model MMOD NMOS(VTO=1 KP=1m LAMBDA=0)
        .temp \(temperature)
        .end
        """
        let parsed = try SpiceNetlistParser.parse(netlist)
        let solution = try parsed.circuit.solveDC()
        let index = try #require(parsed.circuit.elements.firstIndex { $0.name == "M1" })
        return solution.elementCurrents[index].re
    }
    let cold = try drainCurrent(temperature: 27)
    let hot = try drainCurrent(temperature: 127)
    // The default mobility exponent BEX = -1.5 lowers KP as temperature rises.
    #expect(hot < cold)
    #expect(hot > 0)
}

@Test func stepTempSweepProducesTemperatureAxis() throws {
    let netlist = """
    I1 0 1 DC 1m
    D1 1 0 DMOD
    .model DMOD D(IS=1e-14 N=1)
    .step temp 27 127 100
    .end
    """
    var settings = AnalysisSettings.default
    settings.runAC = false
    let result = try SimulationEngine.solve(netlist: netlist, settings: settings)
    let sweep = try #require(result.sweep)
    #expect(sweep.axes.count == 1)
    #expect(sweep.axes[0].name == "TEMP")
    #expect(sweep.axes[0].values == [27, 127])
    #expect(sweep.points.count == 2)
    #expect(sweep.points[0].coordinates.map(\.name) == ["TEMP"])
    #expect(sweep.points[0].coordinates.map(\.value) == [27])
    let first = try #require(sweep.points.first?.nodes.first { $0.name == "1" }?.voltage)
    let second = try #require(sweep.points.last?.nodes.first { $0.name == "1" }?.voltage)
    #expect(second < first)
}

// MARK: - Phase 11: Fourier (`.four`) analysis

@Test func fourierCardIsParsed() throws {
    let netlist = """
    V1 1 0 DC 1
    R1 1 0 1k
    .four 1k v(1) i(V1)
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist)
    #expect(parsed.warnings.isEmpty)
    #expect(parsed.analysis.fourier.count == 1)
    let spec = try #require(parsed.analysis.fourier.first)
    #expect(abs(spec.frequency - 1000) < 1e-9)
    #expect(spec.variables == ["v(1)", "i(V1)"])
}

@Test func invalidFourierCardIsRejected() {
    #expect(throws: SpiceParseError.self) {
        _ = try SpiceNetlistParser.parse("V1 1 0 DC 1\nR1 1 0 1k\n.four 0 v(1)\n.end")
    }
    #expect(throws: SpiceParseError.self) {
        _ = try SpiceNetlistParser.parse("V1 1 0 DC 1\nR1 1 0 1k\n.four 1k\n.end")
    }
}

@Test func fourierOfPureCosineHasUnityFundamental() throws {
    let frequency = 1000.0
    let period = 1.0 / frequency
    let count = 6000
    var times: [Double] = []
    var values: [Double] = []
    for index in 0...count {
        let time = Double(index) / Double(count) * (3 * period)
        times.append(time)
        values.append(2.0 * cos(2 * Double.pi * frequency * time))
    }
    let result = try #require(FourierAnalysis.analyze(
        times: times,
        values: values,
        fundamentalFrequency: frequency
    ))
    #expect(abs(result.dcComponent) < 1e-9)
    let fundamental = try #require(result.harmonics.first)
    #expect(abs(fundamental.magnitude - 2.0) < 1e-4)
    #expect(abs(fundamental.phaseDegrees) < 1e-3)
    #expect(abs(fundamental.normalizedMagnitude - 1.0) < 1e-9)
    #expect(result.totalHarmonicDistortion < 1e-3)
}

@Test func fourierOfSineReportsMinusNinetyDegreePhase() throws {
    let frequency = 1000.0
    let period = 1.0 / frequency
    let count = 6000
    var times: [Double] = []
    var values: [Double] = []
    for index in 0...count {
        let time = Double(index) / Double(count) * (3 * period)
        times.append(time)
        values.append(sin(2 * Double.pi * frequency * time))
    }
    let result = try #require(FourierAnalysis.analyze(
        times: times,
        values: values,
        fundamentalFrequency: frequency
    ))
    let fundamental = try #require(result.harmonics.first)
    #expect(abs(fundamental.magnitude - 1.0) < 1e-4)
    #expect(abs(fundamental.phaseDegrees - (-90)) < 0.05)
}

@Test func fourierOfSquareWaveMatchesTheoreticalThd() throws {
    let frequency = 1000.0
    let period = 1.0 / frequency
    let count = 40000
    var times: [Double] = []
    var values: [Double] = []
    for index in 0...count {
        let time = Double(index) / Double(count) * (2 * period)
        times.append(time)
        values.append(sin(2 * Double.pi * frequency * time) >= 0 ? 1.0 : -1.0)
    }
    let result = try #require(FourierAnalysis.analyze(
        times: times,
        values: values,
        fundamentalFrequency: frequency
    ))
    // Ideal square wave: THD over harmonics 3, 5, 7, 9.
    let expected = 100.0 * (1.0/9 + 1.0/25 + 1.0/49 + 1.0/81).squareRoot()
    #expect(abs(result.totalHarmonicDistortion - expected) < 0.5)
}

@Test func fourierAnalysisRejectsShortTrace() {
    let result = FourierAnalysis.analyze(
        times: [0, 1e-6, 2e-6],
        values: [0, 1, 0],
        fundamentalFrequency: 1000
    )
    #expect(result == nil)
}

@Test func fourierRunsOnTransientSine() throws {
    let netlist = """
    V1 1 0 SIN(0 1 1k)
    R1 1 0 1k
    .tran 1u 5m
    .four 1k v(1)
    .end
    """
    var settings = AnalysisSettings.default
    settings.runDC = false
    settings.runAC = false
    let result = try SimulationEngine.solve(netlist: netlist, settings: settings)
    let fourier = try #require(result.fourier.first)
    #expect(fourier.variable == "v(1)")
    #expect(abs(fourier.fundamentalFrequency - 1000) < 1e-9)
    let fundamental = try #require(fourier.spectrum.harmonics.first)
    #expect(abs(fundamental.magnitude - 1.0) < 1e-3)
    #expect(fourier.spectrum.totalHarmonicDistortion < 1.0)
}

@Test func fourierUnknownVariableWarns() throws {
    let netlist = """
    V1 1 0 SIN(0 1 1k)
    R1 1 0 1k
    .tran 1u 5m
    .four 1k v(99)
    .end
    """
    var settings = AnalysisSettings.default
    settings.runDC = false
    settings.runAC = false
    let result = try SimulationEngine.solve(netlist: netlist, settings: settings)
    #expect(result.fourier.isEmpty)
    #expect(result.warnings.contains { $0.localizedCaseInsensitiveContains("Fourier") })
}

@Test func fourierWithoutTransientWarns() throws {
    let netlist = """
    V1 1 0 DC 1
    R1 1 0 1k
    .four 1k v(1)
    .end
    """
    var settings = AnalysisSettings.default
    settings.runAC = false
    let result = try SimulationEngine.solve(netlist: netlist, settings: settings)
    #expect(result.fourier.isEmpty)
    #expect(result.warnings.contains { $0.localizedCaseInsensitiveContains("Fourier") })
}

@Test func csvIncludesFourierSection() throws {
    let netlist = """
    V1 1 0 SIN(0 1 1k)
    R1 1 0 1k
    .tran 1u 5m
    .four 1k v(1)
    .end
    """
    var settings = AnalysisSettings.default
    settings.runDC = false
    settings.runAC = false
    let result = try SimulationEngine.solve(netlist: netlist, settings: settings)
    let csv = CircuitResultExport.csv(result)
    #expect(csv.contains("four,"))
    #expect(csv.contains("thd_percent"))
    #expect(csv.contains("harmonic_magnitude"))
}

// MARK: - Phase 12: Model libraries & JFET devices

@Test func jfetCardIsParsed() throws {
    let netlist = """
    VDD 1 0 DC 10
    J1 1 0 0 JMOD
    .model JMOD NJF(VTO=-2 BETA=1m LAMBDA=0 IS=1e-14)
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist)
    let element = try #require(parsed.circuit.elements.first { $0.name == "J1" })
    #expect(element.kind == .jfet)
    #expect(element.jfet?.polarity == .njf)
    #expect(abs((element.jfet?.thresholdVoltage ?? 0) + 2) < 1e-9)
    #expect(abs((element.jfet?.transconductanceParameter ?? 0) - 1e-3) < 1e-12)
}

@Test func jfetDrainCurrentMatchesSquareLaw() throws {
    let netlist = """
    VDD 1 0 DC 10
    J1 1 0 0 JMOD
    .model JMOD NJF(VTO=-2 BETA=1m LAMBDA=0)
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist)
    let solution = try parsed.circuit.solveDC()
    let index = try #require(parsed.circuit.elements.firstIndex { $0.name == "J1" })
    // Saturation: Id = BETA*(Vgs - Vt)^2 = 1e-3 * 2^2 = 4 mA.
    #expect(abs(solution.elementCurrents[index].re - 4e-3) < 5e-5)
}

@Test func pjfetMirrorsNjfet() throws {
    let netlist = """
    VDD 1 0 DC -10
    J1 1 0 0 JMOD
    .model JMOD PJF(VTO=2 BETA=1m LAMBDA=0)
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist)
    let solution = try parsed.circuit.solveDC()
    let index = try #require(parsed.circuit.elements.firstIndex { $0.name == "J1" })
    // The polarity sign flips the drain current for the P-device.
    #expect(abs(solution.elementCurrents[index].re + 4e-3) < 5e-5)
}

@Test func jfetConductionIsSymmetricInDrainAndSource() throws {
    func drainCurrent(drain: String, source: String) throws -> Double {
        let netlist = """
        VDD 1 0 DC 10
        J1 \(drain) 0 \(source) JMOD
        .model JMOD NJF(VTO=-2 BETA=1m)
        .end
        """
        let parsed = try SpiceNetlistParser.parse(netlist)
        let solution = try parsed.circuit.solveDC()
        let index = try #require(parsed.circuit.elements.firstIndex { $0.name == "J1" })
        return solution.elementCurrents[index].re
    }
    let forward = try drainCurrent(drain: "1", source: "0")
    let reverse = try drainCurrent(drain: "0", source: "1")
    #expect(abs(forward + reverse) < 5e-5)
}

@Test func jfetDrainCurrentFallsWithTemperature() throws {
    func drainCurrent(temperature: Double) throws -> Double {
        let netlist = """
        VDD 1 0 DC 10
        J1 1 0 0 JMOD
        .model JMOD NJF(VTO=-2 BETA=1m LAMBDA=0)
        .temp \(temperature)
        .end
        """
        let parsed = try SpiceNetlistParser.parse(netlist)
        let solution = try parsed.circuit.solveDC()
        let index = try #require(parsed.circuit.elements.firstIndex { $0.name == "J1" })
        return solution.elementCurrents[index].re
    }
    let cold = try drainCurrent(temperature: 27)
    let hot = try drainCurrent(temperature: 127)
    // BEX = -1.5 lowers BETA as the temperature rises.
    #expect(hot < cold)
    #expect(hot > 0)
}

@Test func compilerMapsJFETParametersAndPolarity() throws {
    let jfet = SymbolInstance(
        descriptorId: "pjfet-transistor",
        refDes: "J1",
        position: GridPoint(0, 0),
        parameters: [
            "thresholdVoltage": 1.5,
            "transconductanceParameter": 2e-3,
            "channelLengthModulation": 0.02,
            "gateSaturationCurrent": 1e-13,
        ]
    )
    let ground = SymbolInstance(descriptorId: "ground", refDes: "GND1", position: GridPoint(-2, 1))

    let circuit = try CircuitCompiler.compile(symbols: [jfet, ground], wires: [], labels: [])
    let element = try #require(circuit.elements.first { $0.name == "J1" })
    #expect(element.kind == .jfet)
    #expect(element.jfet?.polarity == .pjf)
    #expect(abs((element.jfet?.thresholdVoltage ?? 0) - 1.5) < 1e-9)
    #expect(abs((element.jfet?.transconductanceParameter ?? 0) - 2e-3) < 1e-15)
    #expect(abs((element.jfet?.channelLengthModulation ?? 0) - 0.02) < 1e-12)
}

@Test @MainActor func netlistBuilderEmitsJFETAndModel() throws {
    let document = SchematicDocument()
    _ = document.addComponent(descriptorId: "njfet-transistor", at: GridPoint(0, 0))
    _ = document.addComponent(descriptorId: "ground", at: GridPoint(-2, 1))

    let netlist = try SpiceNetlistBuilder.build(from: document)
    #expect(netlist.contains("J1 "))
    #expect(netlist.contains(".model JMOD1 NJF("))
}

@Test func registryExposesJFETDescriptors() {
    #expect(ComponentRegistry.shared.descriptor(for: "njfet-transistor")?.symbol == .njfTransistor)
    #expect(ComponentRegistry.shared.descriptor(for: "pjfet-transistor")?.symbol == .pjfTransistor)
}

@Test func diagnosticsRejectInvalidGateSaturationCurrent() {
    var jfet = SymbolInstance(descriptorId: "njfet-transistor", refDes: "J1", position: GridPoint(0, 0))
    jfet.parameters = ComponentRegistry.shared.descriptor(for: "njfet-transistor")!.defaultParameterValues
    jfet.parameters["gateSaturationCurrent"] = 0
    let ground = SymbolInstance(descriptorId: "ground", refDes: "GND1", position: GridPoint(-2, 1))

    let diagnostics = CircuitDiagnostics.analyze(symbols: [jfet, ground], wires: [], labels: [])
    #expect(diagnostics.contains {
        $0.severity == .error && $0.message.localizedCaseInsensitiveContains("gate saturation current")
    })
}

@Test func modelLibraryScansModelsAndSubcircuits() throws {
    let text = """
    * Vendor models
    .model BC547 NPN(IS=1e-14 BF=200)
    .model 2N5457 NJF(VTO=-2 BETA=1m)
    .subckt opamp in out
    R1 in out 1k
    .ends
    """
    let library = try SpiceModelLibrary.parse(text, name: "Vendor")
    #expect(library.name == "Vendor")
    #expect(library.models.count == 2)
    #expect(library.models.contains { $0.name == "BC547" && $0.kind == .bjt })
    #expect(library.models.contains { $0.name == "2N5457" && $0.kind == .jfet })
    #expect(library.subcircuitNames == ["OPAMP"])
    #expect(!library.isEmpty)
}

@Test func modelLibraryWithNoDefinitionsThrows() {
    #expect(throws: SpiceModelLibraryError.self) {
        _ = try SpiceModelLibrary.parse("* just a comment\n", name: "Empty")
    }
}

@Test func importedLibraryModelIsVisibleWithoutInclude() throws {
    let library = try SpiceModelLibrary.parse(
        ".model VENDORJ NJF(VTO=-2 BETA=1m LAMBDA=0)",
        name: "vendor"
    )
    let netlist = """
    VDD 1 0 DC 10
    J1 1 0 0 VENDORJ
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist, libraries: [library])
    let element = try #require(parsed.circuit.elements.first { $0.name == "J1" })
    #expect(abs((element.jfet?.thresholdVoltage ?? 0) + 2) < 1e-9)
}

@Test func netlistModelOverridesImportedLibrary() throws {
    let library = try SpiceModelLibrary.parse(".model QMOD NPN(IS=1e-15 BF=100)", name: "vendor")
    let netlist = """
    Q1 1 0 0 QMOD
    .model QMOD NPN(IS=1e-15 BF=250)
    .end
    """
    let parsed = try SpiceNetlistParser.parse(netlist, libraries: [library])
    let element = try #require(parsed.circuit.elements.first { $0.name == "Q1" })
    #expect(abs((element.bjt?.forwardBeta ?? 0) - 250) < 1e-9)
}

@Test @MainActor func documentImportsModelLibraryFromFile() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("vendor-\(UUID().uuidString).lib")
    try ".model JTEST NJF(VTO=-2 BETA=1m)\n".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let document = CircuitDocument()
    let count = try document.importModelLibrary(at: url)
    #expect(count == 1)
    #expect(document.modelLibraries.count == 1)
    #expect(document.modelLibraries.first?.models.first?.name == "JTEST")
}

@Test @MainActor func importDesignLoadsModelLibraryFile() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("design-\(UUID().uuidString).lib")
    try ".model DLIB D(IS=1e-14)\n".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let document = CircuitDocument()
    try document.importDesign(at: url)
    #expect(document.modelLibraries.count == 1)
    #expect(document.modelLibraries.first?.models.first?.name == "DLIB")
    #expect(document.name == url.deletingPathExtension().lastPathComponent)
}

// MARK: - Phase 13: Waveform viewer, FFT, and overlays

private func toneSamples(
    amplitude: Double,
    frequency: Double,
    sampleRate: Double,
    count: Int
) -> (times: [Double], values: [Double]) {
    let times = (0..<count).map { Double($0) / sampleRate }
    let values = times.map { amplitude * cos(2 * .pi * frequency * $0) }
    return (times, values)
}

@Test func spectrumFindsToneFrequencyAndAmplitude() throws {
    let samples = toneSamples(amplitude: 2, frequency: 1_000, sampleRate: 8_000, count: 1_024)
    let spectrum = try #require(SpectrumAnalyzer.analyze(
        times: samples.times,
        values: samples.values,
        window: .rectangular
    ))
    let peak = try #require(spectrum.peakFrequency)
    #expect(abs(peak - 1_000) < spectrum.binWidth)
    let peakBin = try #require(spectrum.frequencies.firstIndex { abs($0 - peak) < spectrum.binWidth / 2 })
    #expect(abs(spectrum.magnitudes[peakBin] - 2) < 0.05)
}

@Test func spectrumNormalizesAcrossWindows() throws {
    let samples = toneSamples(amplitude: 1.5, frequency: 1_000, sampleRate: 8_000, count: 1_024)
    for window in SpectrumWindow.allCases {
        let spectrum = try #require(SpectrumAnalyzer.analyze(
            times: samples.times,
            values: samples.values,
            window: window
        ))
        let peak = try #require(spectrum.peakFrequency)
        #expect(abs(peak - 1_000) < spectrum.binWidth * 2)
        let peakBin = try #require(spectrum.frequencies.firstIndex { abs($0 - peak) < spectrum.binWidth / 2 })
        #expect(abs(spectrum.magnitudes[peakBin] - 1.5) < 0.1)
    }
}

@Test func spectrumRejectsShortTraces() {
    #expect(SpectrumAnalyzer.analyze(times: [0], values: [1]) == nil)
    #expect(SpectrumAnalyzer.analyze(times: [], values: []) == nil)
}

@Test func spectrumHandlesNonUniformSampling() throws {
    let count = 1_024
    let sampleRate = 8_000.0
    var times = (0..<count).map { Double($0) / sampleRate }
    // Perturb the interior samples so the grid is not exactly uniform.
    for index in stride(from: 1, to: count - 1, by: 7) {
        times[index] += 1e-7 * Double(index % 3)
    }
    let values = times.map { cos(2 * .pi * 1_000 * $0) }
    let spectrum = try #require(SpectrumAnalyzer.analyze(times: times, values: values, window: .hann))
    let peak = try #require(spectrum.peakFrequency)
    #expect(abs(peak - 1_000) < 20)
}

@Test func spectrumIgnoresDCByDefault() throws {
    let samples = toneSamples(amplitude: 1, frequency: 1_000, sampleRate: 8_000, count: 1_024)
    let shifted = samples.values.map { $0 + 5 }
    let spectrum = try #require(SpectrumAnalyzer.analyze(
        times: samples.times,
        values: shifted,
        window: .rectangular
    ))
    // The DC bin is removed, so the peak is the tone, not the offset.
    #expect(abs((spectrum.peakFrequency ?? 0) - 1_000) < spectrum.binWidth)
    #expect(spectrum.magnitudes[0] < 0.05)
}

@Test func plotTransformRoundTrips() throws {
    let transform = PlotTransform(
        viewport: PlotViewport(
            x: PlotDomain(lower: 0, upper: 10),
            y: PlotDomain(lower: -5, upper: 5)
        ),
        xScale: .linear,
        yScale: .linear
    )
    let unitX = try #require(transform.unitX(2.5))
    #expect(abs(unitX - 0.25) < 1e-12)
    #expect(abs(transform.dataX(unit: unitX) - 2.5) < 1e-12)
    let unitY = try #require(transform.unitY(0))
    #expect(abs(unitY - 0.5) < 1e-12)
    #expect(abs(transform.dataY(unit: 0) + 5) < 1e-12)
}

@Test func logTransformHandlesDecades() throws {
    let transform = PlotTransform(
        viewport: PlotViewport(
            x: PlotDomain(lower: 1, upper: 1_000),
            y: PlotDomain(lower: 1, upper: 100)
        ),
        xScale: .logarithmic,
        yScale: .linear
    )
    #expect(abs((transform.unitX(10) ?? 0) - 1.0 / 3.0) < 1e-12)
    #expect(abs(transform.dataX(unit: 2.0 / 3.0) - 100) < 1e-6)
    #expect(transform.unitX(0) == nil)
}

@Test func viewportZoomKeepsAnchorFixed() {
    var viewport = PlotViewport(
        x: PlotDomain(lower: 0, upper: 100),
        y: PlotDomain(lower: 0, upper: 100)
    )
    viewport.zoomX(by: 0.5, about: 25)
    #expect(abs(viewport.x.lower - 12.5) < 1e-12)
    #expect(abs(viewport.x.upper - 62.5) < 1e-12)
    // The anchor value still maps to the same unit position.
    let before = PlotTransform(viewport: PlotViewport(
        x: PlotDomain(lower: 0, upper: 100), y: viewport.y
    ), xScale: .linear, yScale: .linear).unitX(25)
    let after = PlotTransform(viewport: viewport, xScale: .linear, yScale: .linear).unitX(25)
    #expect(abs((before ?? 0) - (after ?? 0)) < 1e-12)
}

@Test func viewportTranslateShiftsDomain() {
    var viewport = PlotViewport(
        x: PlotDomain(lower: 0, upper: 10),
        y: PlotDomain(lower: 0, upper: 10)
    )
    viewport.translate(xByFraction: 0.5, yByFraction: -0.1)
    #expect(abs(viewport.x.lower - 5) < 1e-12)
    #expect(abs(viewport.y.upper - 9) < 1e-12)
}

@Test func autoFitEnclosesVisibleSeries() {
    let series = [
        PlotSeries(id: "a", name: "a", points: [
            PlotPoint(x: 0, y: 1), PlotPoint(x: 4, y: 9),
        ]),
        PlotSeries(id: "b", name: "b", points: [
            PlotPoint(x: 1, y: -2), PlotPoint(x: 3, y: 5),
        ]),
    ]
    let viewport = PlotViewport.autoFit(series: series)
    #expect(viewport.x.lower <= 0 && viewport.x.upper >= 4)
    #expect(viewport.y.lower <= -2 && viewport.y.upper >= 9)
}

@Test func seriesInterpolatesValues() throws {
    let series = PlotSeries(id: "s", name: "s", points: [
        PlotPoint(x: 0, y: 0),
        PlotPoint(x: 2, y: 4),
        PlotPoint(x: 4, y: 8),
    ])
    #expect(abs((series.value(atX: 1) ?? 0) - 2) < 1e-12)
    #expect(abs((series.value(atX: 3) ?? 0) - 6) < 1e-12)
    #expect(series.value(atX: -1) == nil)
    #expect(series.value(atX: 5) == nil)
}

@Test func axisTicksStayWithinDomain() {
    let ticks = AxisTicks.linear(PlotDomain(lower: 0, upper: 10), target: 5)
    #expect(!ticks.isEmpty)
    #expect(ticks.allSatisfy { $0.value >= 0 && $0.value <= 10 })
    let logTicks = AxisTicks.logarithmic(PlotDomain(lower: 1, upper: 1_000))
    #expect(logTicks.contains { abs($0.value - 10) < 1e-9 })
    #expect(logTicks.contains { abs($0.value - 100) < 1e-9 })
}

// MARK: - Phase 14: netlist import / hierarchy / buses

@Test func schematicImporterDrawsFlatNetlist() throws {
    let netlist = """
    V1 1 0 DC 5
    R1 1 2 1k
    C1 2 0 1u
    .end
    """
    let result = SchematicImporter.importNetlist(netlist)
    let snapshot = result.snapshot

    #expect(snapshot.sheets.isEmpty)
    let references = Set(snapshot.symbols.map(\.refDes))
    #expect(references.contains("V1"))
    #expect(references.contains("R1"))
    #expect(references.contains("C1"))
    #expect(snapshot.symbols.contains { $0.descriptorId == "ground" })

    let nets = ConnectivityBuilder.build(
        symbols: snapshot.symbols,
        wires: snapshot.wires,
        labels: snapshot.netLabels
    )
    let v1 = try #require(snapshot.symbols.first { $0.refDes == "V1" })
    let r1 = try #require(snapshot.symbols.first { $0.refDes == "R1" })
    let v1Pos = try #require(net(containing: PinRef(symbolId: v1.id, pinId: "1"), in: nets))
    let r1Pos = try #require(net(containing: PinRef(symbolId: r1.id, pinId: "1"), in: nets))
    #expect(v1Pos.id == r1Pos.id)
    #expect(v1Pos.name == "1")
    #expect(nets.contains { $0.isGround })

    let circuit = try CircuitCompiler.compile(snapshot: snapshot)
    #expect(circuit.elements.count == 3)
    #expect(circuit.elements.contains { $0.name == "V1" && $0.dcValue == 5 })
}

@Test func schematicImporterRebuildsSubcircuitHierarchy() throws {
    let netlist = """
    V1 in 0 DC 1
    R1 in out 1k
    X1 out 0 divider
    .subckt divider a b
    R2 a b 1k
    .ends
    .end
    """
    let result = SchematicImporter.importNetlist(netlist)
    let snapshot = result.snapshot

    #expect(snapshot.sheets.count == 1)
    let sheet = try #require(snapshot.sheets.first)
    #expect(sheet.name == "divider")
    #expect(sheet.portNames == ["a", "b"])
    #expect(sheet.symbols.contains { $0.refDes == "R2" })

    let instance = try #require(snapshot.symbols.first { $0.isSubcircuitInstance })
    #expect(instance.refDes == "X1")
    #expect(instance.sheetRef == sheet.id)

    // Compiling the imported hierarchy flattens through the SPICE parser.
    let circuit = try CircuitCompiler.compile(snapshot: snapshot)
    #expect(circuit.elements.count == 3)
}

@Test func schematicImporterPreservesNodeNamesOnRoundTrip() throws {
    let netlist = """
    V1 input 0 DC 1
    R1 input output 1k
    C1 output 0 1u
    .end
    """
    let result = SchematicImporter.importNetlist(netlist)
    let text = try SpiceNetlistBuilder.build(snapshot: result.snapshot)
    let parsed = try SpiceNetlistParser.parse(text)

    #expect(parsed.circuit.elements.count == 3)
    let nodeNames = Set(parsed.circuit.nodeNames)
    #expect(nodeNames.contains("input"))
    #expect(nodeNames.contains("output"))
    #expect(nodeNames.contains("0"))
}

@Test func schematicImporterWarnsAboutUnknownDevices() throws {
    let netlist = """
    V1 1 0 DC 1
    R1 1 0 1k
    K1 1 2 3
    .end
    """
    let result = SchematicImporter.importNetlist(netlist)
    #expect(result.warnings.contains { $0.contains("K1") })
}

@Test @MainActor func documentImportsNetlistAsSchematic() throws {
    let document = CircuitDocument()
    document.importSchematic("V1 1 0 DC 5\nR1 1 0 1k\n.end")

    #expect(document.usesSchematic)
    #expect(!document.schematic.symbols.isEmpty)
    #expect(document.schematic.symbols.contains { $0.refDes == "R1" })
}

@Test func busNameParsesDeclarationsAndMembers() throws {
    let declaration = try #require(BusName.parse("DATA[7:0]"))
    #expect(declaration.isDeclaration)
    #expect(!declaration.isBitSelect)
    #expect(declaration.range == 0...7)
    #expect(declaration.members == ["DATA[0]", "DATA[1]", "DATA[2]", "DATA[3]",
                                    "DATA[4]", "DATA[5]", "DATA[6]", "DATA[7]"])

    let member = try #require(BusName.parse("DATA[3]"))
    #expect(member.isBitSelect)
    #expect(member.bit == 3)
    #expect(member.base == "DATA")

    #expect(BusName.parse("OUT") == nil)
}

@Test func connectivityMergesBitSelectsAndDropsDeclarations() throws {
    let resistorA = SymbolInstance(descriptorId: "resistor", refDes: "R1", position: GridPoint(0, 0))
    let resistorB = SymbolInstance(descriptorId: "resistor", refDes: "R2", position: GridPoint(0, 10))
    let wires = [
        WireSegment(points: [GridPoint(-2, 0), GridPoint(-6, 0)]),
        WireSegment(points: [GridPoint(-2, 10), GridPoint(-6, 10)]),
        WireSegment(points: [GridPoint(20, 0), GridPoint(26, 0)], isBus: true),
    ]
    let labels = [
        NetLabel(name: "DATA[3]", position: GridPoint(-6, 0)),
        NetLabel(name: "DATA[3]", position: GridPoint(-6, 10)),
        NetLabel(name: "DATA[7:0]", position: GridPoint(20, 0)),
    ]
    let nets = ConnectivityBuilder.build(symbols: [resistorA, resistorB], wires: wires, labels: labels)

    #expect(!nets.contains { $0.name == "DATA[7:0]" })
    let memberNet = try #require(nets.first { $0.name == "DATA[3]" })
    #expect(memberNet.connectedPins.contains(PinRef(symbolId: resistorA.id, pinId: "1")))
    #expect(memberNet.connectedPins.contains(PinRef(symbolId: resistorB.id, pinId: "1")))
}

@Test func importedHierarchyEmitsSubcircuitNetlist() throws {
    let netlist = """
    V1 in 0 DC 1
    R1 in out 1k
    X1 out 0 divider
    .subckt divider a b
    R2 a b 1k
    .ends
    .end
    """
    let result = SchematicImporter.importNetlist(netlist)
    let text = try SpiceNetlistBuilder.build(snapshot: result.snapshot)
    #expect(text.contains(".subckt divider"))
    #expect(text.contains(".ends"))
    #expect(text.contains("X1 "))
}

@Test func importedHierarchySimulatesThroughFlattening() throws {
    let netlist = """
    V1 in 0 DC 1
    R1 in out 1k
    X1 out 0 divider
    .subckt divider a b
    R2 a b 1k
    .ends
    .end
    """
    let result = SchematicImporter.importNetlist(netlist)
    let simulation = try SimulationEngine.solve(snapshot: result.snapshot, settings: .default)
    let out = try #require(simulation.dc?.nodes.first { $0.name == "out" }?.voltage)
    #expect(abs(out - 0.5) < 1e-6)
}

@Test @MainActor func documentMultiSheetNavigationAndPorts() throws {
    let document = SchematicDocument()
    let child = document.addSheet(named: "AMP")
    document.addSheetPort(sheetId: child.id, name: "IN")
    document.addSheetPort(sheetId: child.id, name: "OUT", isInput: false)
    _ = document.addSubcircuitInstance(sheetId: child.id, at: GridPoint(0, 0))

    #expect(document.sheets.count == 2)
    #expect(document.isAtRoot)
    #expect(document.hierarchyPath.map(\.name) == ["Main"])

    document.enterSheet(id: child.id)
    #expect(document.activeSheet.name == "AMP")
    #expect(document.hierarchyPath.map(\.name) == ["Main", "AMP"])
    #expect(document.activeSheet.ports.map(\.name) == ["IN", "OUT"])
    #expect(document.activeSheet.ports.first?.isInput == true)
    #expect(document.activeSheet.ports.last?.isInput == false)

    document.goToRoot()
    #expect(document.isAtRoot)

    let restored = SchematicDocument()
    restored.replaceContents(with: document.snapshot())
    #expect(restored.sheets.count == 2)
    #expect(restored.symbols.contains { $0.isSubcircuitInstance })
}

@Test @MainActor func diagnosticsAnalyzeEverySheet() throws {
    let document = SchematicDocument()
    let child = document.addSheet(named: "STAGE")
    document.enterSheet(id: child.id)
    let resistor = try #require(document.addComponent(descriptorId: "resistor", at: GridPoint(0, 0)))
    document.setParameter(id: resistor.id, key: "resistance", value: -1)
    document.goToRoot()

    let diagnostics = CircuitDiagnostics.analyze(document)

    #expect(diagnostics.contains {
        $0.message.hasPrefix("STAGE: ") && $0.message.localizedCaseInsensitiveContains("greater than zero")
    })
    // The ground/source checks are top-level only, so a child sheet with no
    // ground must not be reported.
    #expect(!diagnostics.contains {
        $0.message.hasPrefix("STAGE: ") && $0.message.localizedCaseInsensitiveContains("no ground")
    })
}

@Test @MainActor func diagnosticsReportUnboundSheetPort() throws {
    let document = SchematicDocument()
    let child = document.addSheet(named: "BLOCK")
    document.addSheetPort(sheetId: child.id, name: "IN")
    _ = document.addSubcircuitInstance(sheetId: child.id, at: GridPoint(0, 0))
    _ = document.addComponent(descriptorId: "ground", at: GridPoint(-4, 2))

    let diagnostics = CircuitDiagnostics.analyze(document)
    #expect(diagnostics.contains {
        $0.severity == .warning && $0.message.contains("Port IN of BLOCK")
    })
}

// MARK: - Engine backend façade (Phase 15)

/// A stub backend that tags its results, used to prove the façade dispatches to
/// whichever backend is registered. It delegates the actual solve to the native
/// engine and prepends a marker warning, so a concurrent test that briefly
/// observes it still gets numerically correct results.
private struct StubEngineBackend: SimulationEngineBackend {
    let identifier = "stub"
    let capabilities = SimulationBackendCapabilities(
        backendIdentifier: "stub",
        analyses: [.dcOperatingPoint],
        devices: CircuitIR.DeviceKind.allCases,
        features: [.spiceNetlistInput]
    )
    private let reference = NativeMNAEngine()

    func solve(
        netlist: String,
        settings: AnalysisSettings,
        libraries: [SpiceModelLibrary]
    ) throws -> CircuitSimResult {
        var result = try reference.solve(netlist: netlist, settings: settings, libraries: libraries)
        result.warnings.insert("stub ran", at: 0)
        return result
    }
}

@Test func engineFacadeDefaultsToNativeBackend() {
    SimulationEngine.resetToDefaultBackend()
    #expect(SimulationEngine.backendIdentifier == "native-mna")
}

@Test func engineFacadeDispatchesToRegisteredBackend() throws {
    defer { SimulationEngine.resetToDefaultBackend() }
    SimulationEngine.register(StubEngineBackend(), makeDefault: true)
    #expect(SimulationEngine.backendIdentifier == "stub")

    let settings = AnalysisSettings(
        runDC: true,
        runAC: false,
        acStartFrequency: 1,
        acStopFrequency: 1e3,
        acPointsPerDecade: 10
    )
    let result = try SimulationEngine.solve(
        netlist: "V1 1 0 DC 5\nR1 1 2 1k\nR2 2 0 1k\n",
        settings: settings
    )
    #expect(result.warnings.contains("stub ran"))
    let node2 = result.dc?.nodes.first { $0.name == "2" }?.voltage
    #expect(abs((node2 ?? 0) - 2.5) < 1e-9)
}

@Test func engineFacadeDefaultBackendSolvesDivider() throws {
    SimulationEngine.resetToDefaultBackend()
    let settings = AnalysisSettings(
        runDC: true,
        runAC: false,
        acStartFrequency: 1,
        acStopFrequency: 1e3,
        acPointsPerDecade: 10
    )
    let result = try SimulationEngine.solve(
        netlist: "V1 1 0 DC 5\nR1 1 2 1k\nR2 2 0 1k\n",
        settings: settings
    )
    let node2 = result.dc?.nodes.first { $0.name == "2" }?.voltage
    #expect(node2 != nil)
    #expect(abs((node2 ?? 0) - 2.5) < 1e-9)
}

// MARK: - Headless / batch (Phase 15)

private let dividerNetlist = "V1 1 0 DC 5\nR1 1 2 1k\nR2 2 0 1k\n"

private func dcOnlySettings() -> AnalysisSettings {
    AnalysisSettings(
        runDC: true,
        runAC: false,
        acStartFrequency: 1,
        acStopFrequency: 1e3,
        acPointsPerDecade: 10
    )
}

@Test func batchRunnerEmitsCSV() throws {
    let outcome = try BatchRunner.run(BatchRequest(
        input: .netlist(dividerNetlist),
        format: .csv,
        settingsOverride: dcOnlySettings()
    ))
    #expect(outcome.engine == "native-mna")
    #expect(outcome.text.contains("analysis,frequency_hz,signal,quantity,value,time_s,sweep"))
    #expect(outcome.text.contains("dc,,2,voltage,2.5,"))
}

@Test func batchRunnerEmitsJSON() throws {
    let outcome = try BatchRunner.run(BatchRequest(
        input: .netlist(dividerNetlist),
        format: .json,
        settingsOverride: dcOnlySettings()
    ))
    let object = try JSONSerialization.jsonObject(with: Data(outcome.text.utf8)) as? [String: Any]
    let dc = object?["dc"] as? [String: Any]
    #expect(dc?["converged"] as? Bool == true)
    let nodes = dc?["nodes"] as? [[String: Any]]
    let node2 = nodes?.first { $0["name"] as? String == "2" }
    #expect(abs(((node2?["voltage"] as? Double) ?? 0) - 2.5) < 1e-9)
}

@Test func batchRunnerDocumentNetlistMode() throws {
    let file = CircuitFile(
        name: "Divider",
        schematic: SchematicSnapshot(),
        analysis: dcOnlySettings(),
        netlistText: dividerNetlist,
        usesSchematic: false
    )
    let outcome = try BatchRunner.run(BatchRequest(input: .document(file), format: .csv))
    #expect(outcome.text.contains("dc,,2,voltage,2.5,"))
}

@Test func batchRunnerEmptyNetlistThrows() {
    #expect(throws: BatchError.self) {
        try BatchRunner.run(BatchRequest(input: .netlist("   \n")))
    }
}

@Test func batchRunnerUnknownEngineThrows() {
    #expect(throws: BatchError.self) {
        try BatchRunner.run(BatchRequest(input: .netlist(dividerNetlist), engine: "nope"))
    }
    SimulationEngine.resetToDefaultBackend()
}

@Test func engineBackendsKnowNative() throws {
    try EngineBackends.activate("native")
    #expect(EngineBackends.isActive("native"))
    #expect(EngineBackends.available.contains("native"))
    SimulationEngine.resetToDefaultBackend()
}

@Test func spiceNumberParsesSuffixes() {
    #expect(SpiceNumber.parse("1k") == 1000)
    #expect(SpiceNumber.parse("1meg") == 1e6)
    #expect(abs((SpiceNumber.parse("10uF") ?? 0) - 1e-5) < 1e-18)
    #expect(SpiceNumber.parse("-5") == -5)
    #expect(SpiceNumber.parse("abc") == nil)
}

// MARK: - Plugin API (Phase 15)

/// A processor that always tags the result, so the result-processor hook can be
/// asserted without a contrived circuit.
private struct TaggerProcessor: SimulationResultProcessor {
    let id = "test.tagger"
    func process(_ result: CircuitSimResult, context: SimulationPostContext) -> CircuitSimResult {
        var updated = result
        updated.warnings.append("tagged:\(context.source)")
        return updated
    }
}

@Suite(.serialized)
struct PluginAPITests {
    @Test func samplePluginRegistersComponentAndExporter() throws {
        defer {
            PluginManager.shared.reset()
            ComponentRegistry.shared.unregister(id: "net-tie")
        }
        PluginManager.shared.register(SamplePartsPlugin())
        #expect(ComponentRegistry.shared.descriptor(for: "net-tie")?.displayName == "Net Tie")
        #expect(PluginManager.shared.exporterFormatNames.contains("kv"))
        #expect(PluginManager.shared.plugins.contains { $0.id == SamplePartsPlugin.pluginID })
    }

    @Test func netlistProcessorExpandsCustomDevice() throws {
        defer {
            PluginManager.shared.reset()
            ComponentRegistry.shared.unregister(id: "thermistor")
        }
        PluginManager.shared.register(ThermistorPlugin())
        // T1 expands to R1; a 5 V source across 100 Ω gives 50 mA.
        let result = try SimulationEngine.solve(
            netlist: "V1 1 0 5\nT1 1 0 100\n",
            settings: dcOnlySettings()
        )
        let current = result.dc?.components.first { $0.name == "R1" }?.current
        #expect(abs((current ?? 0) - 0.05) < 1e-9)
    }

    @Test func resultProcessorAnnotatesResult() throws {
        defer { PluginManager.shared.reset() }
        PluginManager.shared.register(TaggerOnlyPlugin())
        let result = try SimulationEngine.solve(
            netlist: dividerNetlist,
            settings: dcOnlySettings()
        )
        #expect(result.warnings.contains("tagged:netlist"))
    }

    @Test func pluginExporterProvidesBatchFormat() throws {
        defer { PluginManager.shared.reset() }
        PluginManager.shared.register(SamplePartsPlugin())
        let outcome = try BatchRunner.run(BatchRequest(
            input: .netlist(dividerNetlist),
            format: .plugin("kv"),
            settingsOverride: dcOnlySettings()
        ))
        #expect(outcome.text.contains("dc.node.2.voltage="))
    }

    @Test func batchRejectsUnknownFormat() {
        #expect(throws: BatchError.self) {
            try BatchRunner.run(BatchRequest(input: .netlist(dividerNetlist), format: .plugin("nope")))
        }
    }

    @Test func manifestLoadsDeclarativeComponents() throws {
        defer {
            PluginManager.shared.reset()
            ComponentRegistry.shared.unregister(id: "manifest-resistor")
        }
        let directory = try makeManifestDirectory(json: Self.validManifest)
        defer { try? FileManager.default.removeItem(at: directory) }

        let added = try PluginManager.shared.loadManifests(in: directory)
        #expect(added.contains("manifest-resistor"))
        #expect(ComponentRegistry.shared.descriptor(for: "manifest-resistor")?.displayName == "Manifest Resistor")
        #expect(PluginManager.shared.plugins.contains { $0.id == "test.manifest" })
    }

    @Test func manifestRejectsUnknownSymbol() throws {
        let directory = try makeManifestDirectory(json: Self.badSymbolManifest)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: PluginManifestError.self) {
            try PluginManager.shared.loadManifests(in: directory)
        }
    }

    private static let validManifest = """
    {
      "id": "test.manifest",
      "name": "Test Manifest",
      "version": "1.0",
      "components": [
        {
          "id": "manifest-resistor",
          "prefix": "R",
          "displayName": "Manifest Resistor",
          "symbol": "resistor",
          "pins": [ {"id":"1","name":"1","x":-40,"y":0}, {"id":"2","name":"2","x":40,"y":0} ],
          "parameters": [ {"id":"resistance","name":"Resistance","unit":"Ω","defaultValue":1000} ]
        }
      ]
    }
    """

    private static let badSymbolManifest = """
    {
      "id": "test.bad",
      "name": "Bad",
      "components": [
        {
          "id": "spaceship",
          "prefix": "S",
          "displayName": "Spaceship",
          "symbol": "teleporter",
          "pins": [ {"id":"1","name":"1","x":0,"y":0} ]
        }
      ]
    }
    """

    private func makeManifestDirectory(json: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohm-plugins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try json.write(to: directory.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        return directory
    }
}

/// A plugin whose only extension is a result tagger.
private struct TaggerOnlyPlugin: CircuitPlugin {
    let id = "test.tagger-plugin"
    let name = "Tagger"
    let version = "1.0"
    func register(into manager: PluginManager) {
        manager.addResultProcessor(TaggerProcessor())
    }
}

// MARK: - Project bundles (Phase 16)

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ohmlab-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private var sampleNetlistDocument: CircuitFile {
    var file = CircuitFile(name: "Main", schematic: SchematicSnapshot(), analysis: .default)
    file.netlistText = "V1 1 0 DC 5\nR1 1 0 1k\n"
    file.usesSchematic = false
    return file
}

@Suite struct ProjectBundleTests {
    @Test func zipRoundTripsStoredEntries() throws {
        let entries = [
            ZipArchive.Entry(name: "project.json", data: Data("{}".utf8)),
            ZipArchive.Entry(name: "Sheets/main.ohmlab", data: Data([0, 1, 2, 255]))
        ]
        let archive = ZipArchive.create(entries)
        #expect(try ZipArchive.read(archive) == entries)
    }

    @Test func zipRejectsGarbage() {
        #expect(throws: ZipArchiveError.self) { try ZipArchive.read(Data([1, 2, 3])) }
    }

    @Test func bundleRoundTripsThroughFolder() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try ProjectBundleStore.write(ProjectBundle.single(sampleNetlistDocument), to: directory)
        let read = try ProjectBundleStore.read(from: directory)
        #expect(read.manifest.name == "Main")
        #expect(read.activeDocument?.netlistText == sampleNetlistDocument.netlistText)
        #expect(read.isWellFormed)
    }

    @Test func bundleRoundTripsThroughArchive() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archiveURL = directory.appendingPathComponent("proj.\(ProjectBundleStore.archiveExtension)")

        let bundle = ProjectBundle.single(sampleNetlistDocument)
        try ProjectBundleStore.archive(bundle, to: archiveURL)
        let read = try ProjectBundleStore.unarchive(from: archiveURL)
        #expect(read.manifest.name == bundle.manifest.name)
        #expect(read.activeDocument?.netlistText == sampleNetlistDocument.netlistText)
    }

    @Test func missingManifestIsReported() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: ProjectBundleError.self) { try ProjectBundleStore.read(from: directory) }
    }

    @Test func kiCadProjectResolvesTopSchematic() {
        #expect(
            KiCadProjectInterchange.topSchematic(for: URL(fileURLWithPath: "/tmp/Demo.kicad_pro"))?
                .lastPathComponent == "Demo.kicad_sch"
        )
        #expect(
            KiCadProjectInterchange.topSchematic(for: URL(fileURLWithPath: "/tmp/Demo.kicad_sch"))?
                .lastPathComponent == "Demo.kicad_sch"
        )
        #expect(KiCadProjectInterchange.topSchematic(for: URL(fileURLWithPath: "/tmp/Demo.cir")) == nil)
    }

    @Test func kiCadImportMapsNetlistToSingleSheetBundle() {
        let bundle = KiCadProjectInterchange.makeImportedBundle(
            name: "Demo",
            netlist: "V1 1 0 DC 5\nR1 1 0 1k\n",
            sourceURL: URL(fileURLWithPath: "/tmp/Demo.kicad_pro"),
            topSchematic: URL(fileURLWithPath: "/tmp/Demo.kicad_sch"),
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(bundle.manifest.kicadSource?.topSchematic == "/tmp/Demo.kicad_sch")
        #expect(bundle.activeDocument?.usesSchematic == false)
        #expect(bundle.activeDocument?.netlistText?.contains("R1") == true)
    }

    @Test func kiCadExportWritesBundleAndNetlists() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try KiCadProjectInterchange.exportProject(ProjectBundle.single(sampleNetlistDocument), to: directory)
        let fileManager = FileManager.default
        #expect(fileManager.fileExists(
            atPath: directory.appendingPathComponent(ProjectBundleStore.manifestFileName).path
        ))
        let top = try String(contentsOf: directory.appendingPathComponent("top.cir"), encoding: .utf8)
        #expect(top.contains("R1"))
    }

    @Test func exportProjectsSchematicModeDocument() throws {
        let source = SymbolInstance(
            descriptorId: "voltage-source", refDes: "V1", position: GridPoint(0, 0),
            parameters: ["dcVoltage": 5, "acMagnitude": 1, "acPhaseDegrees": 0]
        )
        let resistor = SymbolInstance(
            descriptorId: "resistor", refDes: "R1", position: GridPoint(4, 0),
            parameters: ["resistance": 1_000]
        )
        let ground = SymbolInstance(descriptorId: "ground", refDes: "GND1", position: GridPoint(-2, 1))
        var file = CircuitFile(
            name: "Schematic",
            schematic: SchematicSnapshot(symbols: [source, resistor, ground]),
            analysis: .default
        )
        file.usesSchematic = true
        file.netlistText = "stale-text-should-be-ignored"

        let netlist = try KiCadProjectInterchange.netlist(for: file)
        #expect(!netlist.contains("stale-text-should-be-ignored"))
        #expect(netlist.contains("R1"))
    }
}

// MARK: - Project sync (Phase 16)

@Suite struct ProjectSyncTests {
    private func makeBackends() throws -> (local: LocalFolderBackend, remote: LocalFolderBackend) {
        let base = try makeTempDirectory()
        let localRoot = base.appendingPathComponent("local", isDirectory: true)
        let remoteRoot = base.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
        return (
            LocalFolderBackend(rootURL: localRoot, name: "local"),
            LocalFolderBackend(rootURL: remoteRoot, name: "remote")
        )
    }

    private func write(_ text: String, to backend: LocalFolderBackend, path: String) throws {
        try backend.write(Data(text.utf8), to: path)
    }

    private func read(_ backend: LocalFolderBackend, _ path: String) throws -> String {
        String(decoding: try backend.read(relativePath: path), as: UTF8.self)
    }

    @Test func newLocalFileUploads() throws {
        let (local, remote) = try makeBackends()
        try write("hello", to: local, path: "project.json")

        let outcome = try ProjectSync.sync(local: local, remote: remote, state: SyncState())
        #expect(outcome.report.uploaded == ["project.json"])
        #expect(try read(remote, "project.json") == "hello")
    }

    @Test func newRemoteFileDownloads() throws {
        let (local, remote) = try makeBackends()
        try write("remote", to: remote, path: "Sheets/main.ohmlab")

        let outcome = try ProjectSync.sync(local: local, remote: remote, state: SyncState())
        #expect(outcome.report.downloaded == ["Sheets/main.ohmlab"])
        #expect(try read(local, "Sheets/main.ohmlab") == "remote")
    }

    @Test func secondSyncIsNoOp() throws {
        let (local, remote) = try makeBackends()
        try write("v1", to: local, path: "project.json")

        let first = try ProjectSync.sync(local: local, remote: remote, state: SyncState())
        let second = try ProjectSync.sync(local: local, remote: remote, state: first.state)
        #expect(second.report.isEmpty)
        #expect(second.report.unchanged == 1)
    }

    @Test func localChangeUploadsRemoteChangeDownloads() throws {
        let (local, remote) = try makeBackends()
        try write("v1", to: local, path: "a.txt")
        try write("v1", to: local, path: "b.txt")
        let synced = try ProjectSync.sync(local: local, remote: remote, state: SyncState())

        try write("v2-local", to: local, path: "a.txt")
        try write("v2-remote", to: remote, path: "b.txt")

        let outcome = try ProjectSync.sync(local: local, remote: remote, state: synced.state)
        #expect(outcome.report.uploaded == ["a.txt"])
        #expect(outcome.report.downloaded == ["b.txt"])
        #expect(try read(remote, "a.txt") == "v2-local")
        #expect(try read(local, "b.txt") == "v2-remote")
    }

    @Test func conflictingEditsPreserveBothVersions() throws {
        let (local, remote) = try makeBackends()
        try write("base", to: local, path: "a.txt")
        let synced = try ProjectSync.sync(local: local, remote: remote, state: SyncState())

        try write("local-edit", to: local, path: "a.txt")
        try write("remote-edit", to: remote, path: "a.txt")

        let outcome = try ProjectSync.sync(
            local: local, remote: remote, state: synced.state,
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(outcome.report.conflicts == ["a.txt"])
        #expect(try read(local, "a.txt") == "local-edit")   // local stays canonical
        #expect(try read(remote, "a.txt") == "local-edit")

        let copies = try local.snapshot().keys.filter { $0.contains("conflict") }
        #expect(copies.count == 1)
        let copy = try #require(copies.first)
        #expect(try read(local, copy) == "remote-edit")      // losing version preserved
        #expect(try read(remote, copy) == "remote-edit")
    }

    @Test func localDeletionPropagatesToRemote() throws {
        let (local, remote) = try makeBackends()
        try write("x", to: local, path: "a.txt")
        let synced = try ProjectSync.sync(local: local, remote: remote, state: SyncState())

        try local.remove(relativePath: "a.txt")
        let outcome = try ProjectSync.sync(local: local, remote: remote, state: synced.state)
        #expect(outcome.report.removedRemote == ["a.txt"])
        #expect(try remote.snapshot()["a.txt"] == nil)
    }

    @Test func remoteDeletionPropagatesToLocal() throws {
        let (local, remote) = try makeBackends()
        try write("x", to: local, path: "a.txt")
        let synced = try ProjectSync.sync(local: local, remote: remote, state: SyncState())

        try remote.remove(relativePath: "a.txt")
        let outcome = try ProjectSync.sync(local: local, remote: remote, state: synced.state)
        #expect(outcome.report.removedLocal == ["a.txt"])
        #expect(try local.snapshot()["a.txt"] == nil)
    }

    @Test func stateFileIsNotSynced() throws {
        let (local, remote) = try makeBackends()
        try write("v1", to: local, path: "project.json")
        let outcome = try ProjectSync.sync(local: local, remote: remote, state: SyncState())
        try SyncStateStore.save(outcome.state, to: local.rootURL)

        #expect(try local.snapshot()[SyncStateStore.fileName] == nil)
        let reloaded = SyncStateStore.load(from: local.rootURL)
        #expect(reloaded.entries["project.json"] != nil)
    }
}

// MARK: - Optimisation & worst-case (Phase 16)

@Suite struct AnalysisTests {
    private let divider = "V1 1 0 DC 5\nR1 1 2 1k\nR2 2 0 1k\n"

    @Test func probeParsingAndDescription() {
        #expect(CircuitProbe.parse("v(out)") == .nodeVoltage("out"))
        #expect(CircuitProbe.parse("I(R1)") == .elementCurrent("R1"))
        #expect(CircuitProbe.parse("vi(R1)") == .elementVoltage("R1"))
        #expect(CircuitProbe.parse("out") == nil)
        #expect(CircuitProbe.nodeVoltage("out").description == "v(out)")
    }

    @Test func valueRewriterEnumeratesAndRewritesDevices() {
        let devices = NetlistValueRewriter.devices(in: divider)
        #expect(devices.map(\.designator) == ["V1", "R1", "R2"])
        #expect(devices.first { $0.designator == "R1" }?.kind == .resistor)
        #expect(NetlistValueRewriter.nominalValues(in: divider)["R2"] == 1_000)

        let rewritten = NetlistValueRewriter.rewrite(divider, values: ["R1": 2_000])
        #expect(rewritten.contains("R1 1 2 2000"))
        #expect(rewritten.contains("R2 2 0 1k"))
    }

    @Test func rewriterLeavesSubcircuitsUntouched() {
        let netlist = ".subckt div a b\nR1 a b 1k\n.ends\nX1 1 0 div\n"
        let rewritten = NetlistValueRewriter.rewrite(netlist, values: ["R1": 5_000])
        #expect(rewritten.contains("R1 a b 1k"))
    }

    @Test func monteCarloIsDeterministicAndCentredOnNominal() throws {
        let request = MonteCarloRequest(
            netlist: divider,
            defaultTolerance: ComponentTolerance(designator: "*", relative: 0.05),
            samples: 200,
            seed: 42,
            probes: [.nodeVoltage("2")]
        )
        let first = try MonteCarloAnalysis.run(request)
        let second = try MonteCarloAnalysis.run(request)
        #expect(first == second)

        let statistic = try #require(first.statistics.first)
        #expect(abs(statistic.nominal - 2.5) < 1e-9)
        #expect(abs(statistic.mean - 2.5) < 0.02)
        #expect(statistic.minimum < 2.5 && statistic.maximum > 2.5)
        #expect(statistic.standardDeviation > 0)
        #expect(first.failures == 0)
    }

    @Test func monteCarloYieldUsesLimits() throws {
        let result = try MonteCarloAnalysis.run(MonteCarloRequest(
            netlist: divider,
            defaultTolerance: ComponentTolerance(designator: "*", relative: 0.01),
            samples: 200,
            seed: 7,
            probes: [.nodeVoltage("2")],
            limits: [ProbeLimit(probe: .nodeVoltage("2"), minimum: 2.49, maximum: 2.51)]
        ))
        let statistic = try #require(result.statistics.first)
        let yield = try #require(statistic.yield)
        #expect(yield > 0 && yield <= 1)
    }

    @Test func monteCarloWarnsOnUnknownTolerance() throws {
        let result = try MonteCarloAnalysis.run(MonteCarloRequest(
            netlist: divider,
            tolerances: [ComponentTolerance(designator: "R99", relative: 0.1)],
            samples: 10,
            seed: 1,
            probes: [.nodeVoltage("2")]
        ))
        #expect(result.warnings.contains { $0.contains("R99") })
    }

    @Test func monteCarloRejectsUnknownProbe() {
        #expect(throws: CircuitProbeError.self) {
            try MonteCarloAnalysis.run(MonteCarloRequest(
                netlist: divider, samples: 5, seed: 1, probes: [.nodeVoltage("nope")]
            ))
        }
    }

    @Test func cornerAnalysisFindsWorstCases() throws {
        let result = try CornerAnalysis.run(CornerRequest(
            netlist: divider,
            tolerances: [
                ComponentTolerance(designator: "R1", relative: 0.05),
                ComponentTolerance(designator: "R2", relative: 0.05)
            ],
            probes: [.nodeVoltage("2")]
        ))
        let extremes = try #require(result.extremes.first)
        #expect(result.cornersEvaluated == 4)
        #expect(abs(extremes.minimum - 2.375) < 1e-9)
        #expect(abs(extremes.maximum - 2.625) < 1e-9)
        #expect(abs((extremes.minimumCorner["R1"] ?? 0) - 1050) < 1e-6)
        #expect(abs((extremes.minimumCorner["R2"] ?? 0) - 950) < 1e-6)
    }

    @Test func cornerAnalysisGuardsCornerCount() {
        #expect(throws: AnalysisError.self) {
            try CornerAnalysis.run(CornerRequest(
                netlist: divider,
                tolerances: [
                    ComponentTolerance(designator: "R1", relative: 0.05),
                    ComponentTolerance(designator: "R2", relative: 0.05)
                ],
                probes: [.nodeVoltage("2")],
                maxCorners: 2
            ))
        }
    }

    @Test func cornerAnalysisHonoursTemperatureCorners() throws {
        // A plain resistive divider is temperature-independent, so the
        // temperature corner must not change the result; it only exercises the
        // `.temp` injection and corner enumeration.
        let result = try CornerAnalysis.run(CornerRequest(
            netlist: divider,
            temperature: 27,
            temperatureTolerance: 10,
            probes: [.nodeVoltage("2")]
        ))
        let extremes = try #require(result.extremes.first)
        #expect(result.cornersEvaluated == 2)
        #expect(abs(extremes.minimum - 2.5) < 1e-9)
        #expect(abs(extremes.maximum - 2.5) < 1e-9)
    }

    @Test func optimiserHitsATarget() throws {
        let result = try Optimization.run(OptimizeRequest(
            netlist: divider,
            variables: [OptimizeVariable(designator: "R1", minimum: 100, maximum: 10_000)],
            objective: .nodeVoltage("2"),
            goal: .target(1.5),
            gridDivisions: 20
        ))
        #expect(abs(result.bestObjective - 1.5) < 1e-2)
        #expect(abs((result.bestValues["R1"] ?? 0) - 2_333.33) < 10)
    }

    @Test func optimiserMaximisesWithinBounds() throws {
        let result = try Optimization.run(OptimizeRequest(
            netlist: divider,
            variables: [OptimizeVariable(designator: "R1", minimum: 100, maximum: 10_000)],
            objective: .nodeVoltage("2"),
            goal: .maximize,
            gridDivisions: 20
        ))
        #expect(abs(result.bestObjective - 5 * 1000.0 / 1100.0) < 1e-2)
        #expect(abs((result.bestValues["R1"] ?? 0) - 100) < 1)
    }

    @Test func optimiserRejectsUnknownVariable() {
        #expect(throws: AnalysisError.self) {
            try Optimization.run(OptimizeRequest(
                netlist: divider,
                variables: [OptimizeVariable(designator: "R9", minimum: 1, maximum: 2)],
                objective: .nodeVoltage("2")
            ))
        }
    }
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
