// KiCadDirectReaderTests.swift
// Exercises the native `.kicad_sch` reader without invoking `kicad-cli`.
//
// The committed RC_Filter fixture is a real three-level KiCad 10 project. These
// tests prove that the direct reader preserves the hierarchy, KiCad UUIDs,
// references, values, and model-library references, derives connectivity from
// KiCad's own geometry, and produces a netlist whose DC result matches the
// golden `kicad-cli` export.

import Foundation
import Testing
@testable import OhmLabCore

@Suite("KiCad direct reader")
struct KiCadDirectReaderTests {
    private var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/KiCad/RC_Filter", isDirectory: true)
    }

    private var projectURL: URL {
        fixtureDirectory.appendingPathComponent("RC_Filter.kicad_pro")
    }

    private var rootURL: URL {
        fixtureDirectory.appendingPathComponent("RC_Filter.kicad_sch")
    }

    private var childURL: URL {
        fixtureDirectory.appendingPathComponent("filter.kicad_sch")
    }

    private var expectedNetlistURL: URL {
        fixtureDirectory.appendingPathComponent("expected.cir")
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmlab-kicad-direct-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func projectedNetlist(_ read: KiCadSchematicReadResult) throws -> String {
        try SpiceNetlistBuilder.export(
            snapshot: read.snapshot,
            title: "RC_Filter",
            analysis: AnalysisSettings(
                runDC: true,
                runAC: false,
                acStartFrequency: 1,
                acStopFrequency: 1_000,
                acPointsPerDecade: 10
            ),
            libraryTexts: read.modelLibraries.map(\.rawText)
        )
    }

    private func dcVoltage(_ result: CircuitSimResult, _ name: String) -> Double? {
        result.dc?.nodes.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.voltage
    }

    // MARK: - Hierarchy and identity

    @Test func readsTheWholeHierarchyFromAProjectOrChildSheet() throws {
        let read = try KiCadSchematicReader.readProject(at: projectURL)
        #expect(read.rootSchematic.standardizedFileURL == rootURL.standardizedFileURL)
        #expect(
            read.sourceFiles.map(\.lastPathComponent)
                == ["RC_Filter.kicad_sch", "filter.kicad_sch", "load.kicad_sch"]
        )
        #expect(read.snapshot.sheets.count == 2)

        // Opening any child still reads the whole project.
        let fromChild = try KiCadSchematicReader.readSchematic(at: childURL)
        #expect(fromChild.rootSchematic.standardizedFileURL == rootURL.standardizedFileURL)
        #expect(fromChild.sourceFiles.count == 3)
    }

    @Test func preservesKiCadUuidsReferencesAndValues() throws {
        let read = try KiCadSchematicReader.readProject(at: projectURL)

        let source = try #require(read.snapshot.symbols.first { $0.refDes == "V1" })
        #expect(source.id == UUID(uuidString: "8647168f-66ac-54d8-833c-2c62eb959144"))
        #expect(source.descriptorId == "voltage-source")
        #expect(abs((source.parameters["dcVoltage"] ?? 0) - 5) < 1e-12)

        let resistor = try #require(read.snapshot.symbols.first { $0.refDes == "R1" })
        #expect(resistor.id == UUID(uuidString: "89873b93-f826-517c-84a5-b452d821cf82"))
        #expect(resistor.descriptorId == "resistor")
        #expect(abs((resistor.parameters["resistance"] ?? 0) - 1_000) < 1e-9)

        let filter = try #require(read.snapshot.sheets.first { $0.name == "Filter" })
        #expect(filter.id == UUID(uuidString: "c06bdfc1-1312-5f04-9739-a8a2cc75d652"))
        #expect(Set(filter.portNames) == ["MID", "OUT"])

        let capacitor = try #require(filter.symbols.first { $0.refDes == "C1" })
        #expect(capacitor.id == UUID(uuidString: "b21c91c7-c343-52d5-bb36-2ba329c553bf"))
        #expect(abs((capacitor.parameters["capacitance"] ?? 0) - 1e-6) < 1e-18)

        let load = try #require(read.snapshot.sheets.first { $0.name == "Load" })
        #expect(load.id == UUID(uuidString: "90f3124d-6cb2-5c00-bf84-fe0d35128625"))
        #expect(load.portNames == ["OUT"])

        let diode = try #require(load.symbols.first { $0.refDes == "D1" })
        #expect(diode.id == UUID(uuidString: "8ab92271-8d49-5663-9b83-e272a307af3c"))
        #expect(diode.descriptorId == "diode")
        #expect(abs((diode.parameters["saturationCurrent"] ?? 0) - 1e-14) < 1e-20)
        #expect(abs((diode.parameters["emissionCoefficient"] ?? 0) - 1) < 1e-12)
        #expect(abs((diode.parameters["seriesResistance"] ?? 0) - 0.01) < 1e-12)

        // The referenced model library is retained with the document.
        #expect(read.modelLibraries.count == 1)
        let library = try #require(read.modelLibraries.first)
        #expect(library.name == "rc_models")
        #expect(library.models.contains { $0.name == "DMOD" && $0.kind == .diode })
    }

    // MARK: - Connectivity

    @Test func derivesConnectivityFromKiCadWiresJunctionsLabelsAndPins() throws {
        let read = try KiCadSchematicReader.readProject(at: projectURL)
        let netlist = try projectedNetlist(read)
        let parsed = try KiCadInterchange.parseNetlist(netlist)
        #expect(parsed.warnings.isEmpty)

        let circuit = parsed.circuit
        let nodes = circuit.nodeNames

        func element(_ name: String) -> LinearCircuit.Element? {
            circuit.elements.first { $0.name == name }
        }

        func nodeNames(_ element: LinearCircuit.Element) -> [String] {
            [element.nodeA, element.nodeB].map { nodes[$0] }
        }

        let source = try #require(element("V1"))
        #expect(nodeNames(source) == ["IN", "0"])
        #expect(abs((source.dcValue ?? 0) - 5) < 1e-12)

        let r1 = try #require(element("R1"))
        #expect(nodeNames(r1) == ["MID", "IN"])
        #expect(abs(r1.value - 1_000) < 1e-9)

        let c1 = try #require(element("X2.C1"))
        #expect(nodeNames(c1) == ["MID", "0"])
        #expect(abs(c1.value - 1e-6) < 1e-18)

        let r2 = try #require(element("X2.R2"))
        #expect(nodeNames(r2) == ["MID", "OUT"])
        #expect(abs(r2.value - 1_000) < 1e-9)

        let r3 = try #require(element("X2.X1.R3"))
        #expect(nodeNames(r3) == ["OUT", "0"])
        #expect(abs(r3.value - 2_000) < 1e-9)

        // KiCad's RS=0.01 model parameter becomes an internal series resistor,
        // exactly as the golden `kicad-cli` netlist does.
        let series = try #require(circuit.elements.first {
            $0.kind == .resistor && abs($0.value - 0.01) < 1e-12
        })
        #expect(nodeNames(series).contains("OUT"))

        let diode = try #require(element("X2.X1.D1"))
        #expect(abs((diode.diode?.saturationCurrent ?? 0) - 1e-14) < 1e-20)
        #expect(abs((diode.diode?.emissionCoefficient ?? 0) - 1) < 1e-12)
        #expect(nodeNames(diode).last == "0")

        #expect(Set(nodes).isSuperset(of: ["IN", "MID", "OUT", "0"]))
    }

    @Test func matchesTheGoldenKiCadCliDcResult() throws {
        let read = try KiCadSchematicReader.readProject(at: projectURL)
        let generated = try projectedNetlist(read)
        let golden = try String(contentsOf: expectedNetlistURL, encoding: .utf8)
        let settings = AnalysisSettings(
            runDC: true,
            runAC: false,
            acStartFrequency: 1,
            acStopFrequency: 1_000,
            acPointsPerDecade: 10
        )

        let goldenResult = try NativeMNAEngine().solve(
            netlist: golden,
            settings: settings,
            libraries: read.modelLibraries
        )
        let generatedResult = try NativeMNAEngine().solve(
            netlist: generated,
            settings: settings,
            libraries: read.modelLibraries
        )

        // KiCad prefixes hierarchical net names; OhmLab uses the sheet-local
        // names. The electrical solution must be identical.
        let pairs = [("/IN", "IN"), ("/MID", "MID"), ("/Filter/OUT", "OUT")]
        for (goldenName, generatedName) in pairs {
            let expected = try #require(dcVoltage(goldenResult, goldenName))
            let actual = try #require(dcVoltage(generatedResult, generatedName))
            #expect(abs(expected - actual) < 1e-9, "\(goldenName) differs")
        }
        let goldenSeries = try #require(dcVoltage(goldenResult, "D1_SER"))
        let generatedSeries = try #require(dcVoltage(generatedResult, "X2.X1.D1_SER"))
        #expect(abs(goldenSeries - generatedSeries) < 1e-9)
    }

    // MARK: - Project import and export

    @Test func importsAsASchematicProjectBundle() throws {
        let bundle = try KiCadProjectInterchange.importProject(
            at: projectURL,
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(bundle.manifest.kicadSource?.projectPath == projectURL.path)
        #expect(bundle.manifest.kicadSource?.topSchematic == rootURL.path)
        #expect(bundle.manifest.kicadSource?.importedAt == "1970-01-01T00:00:00Z")

        let document = try #require(bundle.activeDocument)
        #expect(document.usesSchematic == true)
        #expect(document.schematic.sheets.count == 2)
        #expect(document.modelLibraries?.count == 1)
        #expect(document.schematic.symbols.contains { $0.refDes == "V1" })

        let netlist = try KiCadProjectInterchange.netlist(for: document)
        #expect(netlist.contains(".model DMOD D(IS=1e-14 N=1 RS=0.01)"))
        #expect(!netlist.contains(".include"))
    }

    @Test func exportedProjectKeepsTheModelLibraryInline() throws {
        let bundle = try KiCadProjectInterchange.importProject(at: projectURL)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try KiCadProjectInterchange.exportProject(bundle, to: directory)
        let top = try String(
            contentsOf: directory.appendingPathComponent("top.cir"),
            encoding: .utf8
        )
        #expect(top.contains(".model DMOD D(IS=1e-14 N=1 RS=0.01)"))
        #expect(!top.contains(".include"))
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("netlists/rc-filter.cir").path
        ))
    }

    // MARK: - Robustness

    @Test func skipsUnsupportedSymbolsWithWarnings() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Partial.kicad_sch")
        let text = """
        (kicad_sch
          (version 20250114)
          (generator "eeschema")
          (uuid "11111111-1111-4111-8111-111111111111")
          (lib_symbols
            (symbol "Device:R"
              (property "Reference" "R" (at 0 0 0))
              (property "Value" "R" (at 0 0 0))
              (symbol "R_1_1"
                (pin passive line (at 0 3.81 270) (length 2.54) (name "~") (number "1"))
                (pin passive line (at 0 -3.81 90) (length 2.54) (name "~") (number "2"))
              )
            )
          )
          (symbol
            (lib_id "Device:R")
            (at 10 10 0)
            (unit 1)
            (uuid "22222222-2222-4222-8222-222222222222")
            (property "Reference" "R1" (at 0 0 0))
            (property "Value" "1k" (at 0 0 0))
          )
          (symbol
            (lib_id "Custom:Widget")
            (at 20 10 0)
            (unit 1)
            (uuid "33333333-3333-4333-8333-333333333333")
            (property "Reference" "U1" (at 0 0 0))
            (property "Value" "Widget" (at 0 0 0))
          )
        )
        """
        try text.write(to: url, atomically: true, encoding: .utf8)

        let read = try KiCadSchematicReader.readProject(at: url)
        #expect(read.snapshot.symbols.map(\.refDes) == ["R1"])
        #expect(read.warnings.contains { $0.contains("U1") })
        let resistor = try #require(read.snapshot.symbols.first)
        #expect(abs((resistor.parameters["resistance"] ?? 0) - 1_000) < 1e-9)
    }

    @Test func reportsMalformedOrNonSchematicInput() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let truncated = directory.appendingPathComponent("Broken.kicad_sch")
        try "(kicad_sch (version 20250114)".write(to: truncated, atomically: true, encoding: .utf8)
        #expect(throws: KiCadSchematicReaderError.self) {
            try KiCadSchematicReader.readProject(at: truncated)
        }

        let wrong = directory.appendingPathComponent("Wrong.kicad_sch")
        try "not a schematic".write(to: wrong, atomically: true, encoding: .utf8)
        #expect(throws: KiCadSchematicReaderError.self) {
            try KiCadSchematicReader.readProject(at: wrong)
        }
    }
}
