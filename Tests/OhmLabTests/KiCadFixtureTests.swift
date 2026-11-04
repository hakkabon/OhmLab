// KiCadFixtureTests.swift
// Exercises the committed KiCad 10 fixture corpus without invoking KiCad.
//
// The fixture is a real three-level project (root -> filter -> load) with a
// simulation model library and a golden `kicad-cli` SPICE export. These tests
// prove the compatibility claim in docs/compatibility/kicad.md: root-sheet
// resolution, hierarchy references, model-library inlining, project import,
// and self-contained export all work from the committed files alone.

import Foundation
import Testing
@testable import OhmLabCore

@Suite("KiCad fixtures")
struct KiCadFixtureTests {
    private var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    private var fixtureDirectory: URL {
        fixturesDirectory
            .appendingPathComponent("KiCad", isDirectory: true)
            .appendingPathComponent("RC_Filter", isDirectory: true)
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

    private var grandchildURL: URL {
        fixtureDirectory.appendingPathComponent("load.kicad_sch")
    }

    private var expectedNetlistURL: URL {
        fixtureDirectory.appendingPathComponent("expected.cir")
    }

    private var modelLibraryURL: URL {
        fixtureDirectory.appendingPathComponent("models/rc_models.lib")
    }

    private func expectedNetlist() throws -> String {
        try String(contentsOf: expectedNetlistURL, encoding: .utf8)
    }

    private func modelLibraryText() throws -> String {
        try String(contentsOf: modelLibraryURL, encoding: .utf8)
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmlab-kicad-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    // MARK: - Root discovery

    @Test func fixtureResolvesTheRootFromEveryEntryPoint() {
        let root = rootURL.standardizedFileURL
        #expect(
            KiCadProjectInterchange.topSchematic(for: projectURL)?.standardizedFileURL
                == root
        )
        #expect(
            KiCadProjectInterchange.rootSchematic(for: projectURL)?.standardizedFileURL
                == root
        )
        #expect(
            KiCadProjectInterchange.rootSchematic(for: rootURL)?.standardizedFileURL
                == root
        )
        #expect(
            KiCadProjectInterchange.rootSchematic(for: childURL)?.standardizedFileURL
                == root
        )
        #expect(
            KiCadProjectInterchange.rootSchematic(for: grandchildURL)?.standardizedFileURL
                == root
        )
    }

    @Test func fixtureSheetReferencesDescribeTheHierarchy() {
        #expect(
            KiCadProjectInterchange.sheetReferences(in: rootURL).map(\.lastPathComponent)
                == ["filter.kicad_sch"]
        )
        #expect(
            KiCadProjectInterchange.sheetReferences(in: childURL).map(\.lastPathComponent)
                == ["load.kicad_sch"]
        )
        #expect(KiCadProjectInterchange.sheetReferences(in: grandchildURL).isEmpty)
    }

    // MARK: - Golden netlist

    @Test func goldenNetlistCarriesTheWholeHierarchy() throws {
        let netlist = try expectedNetlist()
        #expect(netlist.contains("V1 /IN 0 DC 5"))
        #expect(netlist.contains("R1 /MID /IN 1k"))
        #expect(netlist.contains("C1 /MID 0 1u"))
        #expect(netlist.contains("R2 /MID /Filter/OUT 1k"))
        #expect(netlist.contains("D1 /Filter/OUT 0 DMOD"))
        #expect(netlist.contains("R3 /Filter/OUT 0 2k"))
        #expect(netlist.contains(#".include "models/rc_models.lib""#))
        #expect(netlist.hasSuffix(".end\n"))
    }

    @Test func goldenNetlistParsesWithItsModelLibrary() throws {
        let parsed = try KiCadInterchange.parseNetlist(
            try expectedNetlist(),
            include: KiCadInterchange.fileIncludeResolver(relativeTo: fixtureDirectory)
        )

        // `RS` expands to an internal series resistor, so the element count is
        // one higher than the six visible schematic devices.
        #expect(parsed.circuit.elements.count >= 6)
        #expect(parsed.warnings.isEmpty)
        #expect(
            Set(parsed.circuit.elements.map(\.name))
                .isSuperset(of: ["V1", "R1", "C1", "R2", "D1", "R3"])
        )

        let diode = try #require(parsed.circuit.elements.first { $0.name == "D1" })
        let parameters = try #require(diode.diode)
        #expect(abs(parameters.saturationCurrent - 1e-14) < 1e-20)
        #expect(abs(parameters.emissionCoefficient - 1) < 1e-12)

        let resistor = try #require(parsed.circuit.elements.first { $0.name == "R1" })
        #expect(abs(resistor.value - 1_000) < 1e-9)
    }

    @Test func goldenNetlistRunsOnTheNativeEngine() throws {
        let library = try SpiceModelLibrary.parse(
            try modelLibraryText(),
            name: "rc_models"
        )
        let result = try NativeMNAEngine().solve(
            netlist: try expectedNetlist(),
            settings: AnalysisSettings(
                runDC: true,
                runAC: false,
                acStartFrequency: 1,
                acStopFrequency: 1_000,
                acPointsPerDecade: 10
            ),
            libraries: [library]
        )
        #expect(result.dc != nil)
        #expect(result.dc?.nodes.isEmpty == false)
    }

    @Test func fixtureModelLibraryIsValid() throws {
        let library = try SpiceModelLibrary.parse(
            try modelLibraryText(),
            name: "rc_models"
        )
        #expect(library.models.contains { $0.name == "DMOD" && $0.kind == .diode })
    }

    // MARK: - Project import and export

    @Test func fixtureImportsAsASelfContainedProjectBundle() throws {
        let expected = try expectedNetlist()
        let bundle = KiCadProjectInterchange.makeImportedBundle(
            name: "RC_Filter",
            netlist: expected,
            sourceURL: projectURL,
            topSchematic: rootURL,
            now: Date(timeIntervalSince1970: 0)
        )

        #expect(bundle.manifest.kicadSource?.projectPath == projectURL.path)
        #expect(bundle.manifest.kicadSource?.topSchematic == rootURL.path)
        #expect(bundle.manifest.kicadSource?.importedAt == "1970-01-01T00:00:00Z")

        let document = try #require(bundle.activeDocument)
        #expect(document.usesSchematic == false)
        #expect(document.netlistText == expected)
        #expect(document.importBaseDirectory == fixtureDirectory.path)
        let resolved = try #require(document.resolvedNetlistText)
        #expect(resolved.contains(".model DMOD D(IS=1e-14 N=1 RS=0.01)"))
        #expect(!resolved.contains(".include"))
    }

    @Test func fixtureProjectExportKeepsTheModelLibraryInline() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = KiCadProjectInterchange.makeImportedBundle(
            name: "RC_Filter",
            netlist: try expectedNetlist(),
            sourceURL: projectURL,
            topSchematic: rootURL,
            now: Date(timeIntervalSince1970: 0)
        )
        try KiCadProjectInterchange.exportProject(bundle, to: directory)

        let top = try String(
            contentsOf: directory.appendingPathComponent("top.cir"),
            encoding: .utf8
        )
        #expect(top.contains("D1 /Filter/OUT 0 DMOD"))
        #expect(top.contains(".model DMOD D(IS=1e-14 N=1 RS=0.01)"))
        #expect(!top.contains(".include"))

        let perSheet = directory.appendingPathComponent("netlists/rc-filter.cir")
        #expect(FileManager.default.fileExists(atPath: perSheet.path))
        #expect(try String(contentsOf: perSheet, encoding: .utf8) == top)
    }

    @Test func schematicExportInlinesTheFixtureModelLibrary() throws {
        let source = SymbolInstance(
            descriptorId: "voltage-source", refDes: "V1", position: GridPoint(0, 0),
            parameters: ["dcVoltage": 5, "acMagnitude": 1, "acPhaseDegrees": 0]
        )
        let resistor = SymbolInstance(
            descriptorId: "resistor", refDes: "R1", position: GridPoint(4, 0),
            parameters: ["resistance": 1_000]
        )
        let diode = SymbolInstance(
            descriptorId: "diode", refDes: "D1", position: GridPoint(8, 0),
            parameters: ["saturationCurrent": 1e-14, "emissionCoefficient": 1]
        )
        let ground = SymbolInstance(
            descriptorId: "ground", refDes: "GND1", position: GridPoint(-2, 1)
        )
        let loadGround = SymbolInstance(
            descriptorId: "ground", refDes: "GND2", position: GridPoint(10, 1)
        )
        var file = CircuitFile(
            name: "RC_Filter",
            schematic: SchematicSnapshot(
                symbols: [source, resistor, diode, ground, loadGround]
            ),
            analysis: .default,
            usesSchematic: true,
            modelLibraries: [
                StoredModelLibrary(name: "rc_models", text: try modelLibraryText())
            ]
        )
        file.netlistText = "stale text must not be exported"

        let netlist = try KiCadProjectInterchange.netlist(for: file)
        #expect(netlist.hasPrefix(".title \"RC_Filter\""))
        #expect(netlist.contains("D1"))
        #expect(netlist.contains(".model DMOD D(IS=1e-14 N=1 RS=0.01)"))
        #expect(!netlist.contains(".include"))
        #expect(!netlist.contains("stale text must not be exported"))
        #expect(netlist.components(separatedBy: ".end").count == 2)
    }
}
