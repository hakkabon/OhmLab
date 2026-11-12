// KiCadWriteFidelityTests.swift
// Phase 4.1: non-destructive write-back.
//
// Preservation mode must keep a KiCad drawing intact while OhmLab edits a
// value or adds a component. An untouched project is copied byte-for-byte; a
// changed symbol is patched in place and every other node keeps its bytes.

import Foundation
import Testing
@testable import OhmLabCore

@Suite("KiCad write fidelity")
struct KiCadWriteFidelityTests {
    private var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/KiCad/RC_Filter", isDirectory: true)
    }

    private var projectURL: URL {
        fixtureDirectory.appendingPathComponent("RC_Filter.kicad_pro")
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmlab-kicad-fidelity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fixtureSnapshot() throws -> SchematicSnapshot {
        try KiCadSchematicReader.readProject(at: projectURL).snapshot
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// The exact source node for a symbol with `reference`, including its
    /// leading whitespace, so a preserved node can be compared byte-for-byte.
    private func sourceSymbolNode(reference: String) throws -> String {
        let text = try read(fixtureDirectory.appendingPathComponent("RC_Filter.kicad_sch"))
        let document = try KiCadSchematicSourceDocument(text: text)
        for node in document.nodes where node.kind == "symbol" {
            if node.value.property("Reference") == reference {
                return node.raw
            }
        }
        Issue.record("Missing fixture symbol \(reference)")
        return ""
    }

    private func editResistance(
        _ snapshot: inout SchematicSnapshot,
        reference: String,
        to resistance: Double
    ) {
        guard let index = snapshot.symbols.firstIndex(where: { $0.refDes == reference }) else {
            Issue.record("Missing symbol \(reference)")
            return
        }
        snapshot.symbols[index].parameters["resistance"] = resistance
    }

    private func dcVoltages(
        for snapshot: SchematicSnapshot,
        libraries: [String] = []
    ) throws -> [String: Double] {
        let netlist = try SpiceNetlistBuilder.export(
            snapshot: snapshot,
            title: "RC_Filter",
            analysis: AnalysisSettings(
                runDC: true,
                runAC: false,
                acStartFrequency: 1,
                acStopFrequency: 1_000,
                acPointsPerDecade: 10
            ),
            libraryTexts: libraries
        )
        let result = try NativeMNAEngine().solve(
            netlist: netlist,
            settings: AnalysisSettings(
                runDC: true,
                runAC: false,
                acStartFrequency: 1,
                acStopFrequency: 1_000,
                acPointsPerDecade: 10
            )
        )
        var values: [String: Double] = [:]
        for node in result.dc?.nodes ?? [] {
            values[node.name.uppercased()] = node.voltage
        }
        return values
    }

    @Test func untouchedProjectIsCopiedByteForByte() throws {
        let directory = try makeTempDirectory()
        let snapshot = try fixtureSnapshot()
        let result = try KiCadSchematicWriter.writeProject(
            snapshot: snapshot,
            name: "RC_Filter",
            to: directory,
            preserving: projectURL
        )
        #expect(result.warnings.isEmpty)

        // Every source schematic is reproduced under its original name.
        let sourceFiles = ["RC_Filter.kicad_sch", "filter.kicad_sch", "load.kicad_sch"]
        for name in sourceFiles {
            let source = try read(fixtureDirectory.appendingPathComponent(name))
            let written = try read(directory.appendingPathComponent(name))
            #expect(written == source, "\(name) was not preserved byte-for-byte")
        }

        // The source project's own metadata survives too.
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("RC_Filter.kicad_pro").path
        ))
    }

    @Test func editingAValueKeepsTheDrawingAndUnrelatedSymbols() throws {
        let directory = try makeTempDirectory()
        var snapshot = try fixtureSnapshot()
        editResistance(&snapshot, reference: "R1", to: 2_000)

        _ = try KiCadSchematicWriter.writeProject(
            snapshot: snapshot,
            name: "RC_Filter",
            to: directory,
            preserving: projectURL
        )

        let output = try read(directory.appendingPathComponent("RC_Filter.kicad_sch"))
        let source = try read(fixtureDirectory.appendingPathComponent("RC_Filter.kicad_sch"))
        let sourceDocument = try KiCadSchematicSourceDocument(text: source)

        // Untouched top-level nodes keep their exact source text.
        let untouchedKinds: Set<String> = ["paper", "title_block", "junction", "no_connect", "wire"]
        for node in sourceDocument.nodes where untouchedKinds.contains(node.kind) {
            #expect(output.contains(node.raw), "A preserved \(node.kind) node changed")
        }

        // An unrelated symbol (V1) is not re-serialised.
        let v1 = try sourceSymbolNode(reference: "V1")
        #expect(!v1.isEmpty)
        #expect(output.contains(v1), "V1 was rewritten even though it did not change")

        // The edited resistor's value changed in place.
        #expect(output.contains("\"Value\" \"2000\"") || output.contains("\"Value\" \"2k\""))

        // The edited symbol kept its UUID and footprint property.
        let r1 = try sourceSymbolNode(reference: "R1")
        let r1UUID = (try? SExpressionParser.parse(r1))?
            .first("uuid")?.ownArguments.first?.text
        #expect(r1UUID != nil)
        if let r1UUID {
            #expect(output.contains(r1UUID))
        }
        #expect(output.contains("(property \"Footprint\""))
    }

    @Test func repeatedPreservingWritesAreIdentical() throws {
        let first = try makeTempDirectory()
        let second = try makeTempDirectory()
        var snapshot = try fixtureSnapshot()
        editResistance(&snapshot, reference: "R1", to: 1_500)

        _ = try KiCadSchematicWriter.writeProject(
            snapshot: snapshot, name: "RC_Filter", to: first, preserving: projectURL
        )
        _ = try KiCadSchematicWriter.writeProject(
            snapshot: snapshot, name: "RC_Filter", to: second, preserving: projectURL
        )

        for name in ["RC_Filter.kicad_sch", "filter.kicad_sch", "load.kicad_sch"] {
            #expect(try read(first.appendingPathComponent(name))
                == (try read(second.appendingPathComponent(name))))
        }
    }

    @Test func addedSymbolKeepsExistingGeometry() throws {
        let directory = try makeTempDirectory()
        var snapshot = try fixtureSnapshot()
        let source = try read(fixtureDirectory.appendingPathComponent("RC_Filter.kicad_sch"))
        let sourceDocument = try KiCadSchematicSourceDocument(text: source)

        snapshot.symbols.append(SymbolInstance(
            descriptorId: "resistor",
            refDes: "R99",
            position: GridPoint(20, 20),
            parameters: ["resistance": 10_000]
        ))

        _ = try KiCadSchematicWriter.writeProject(
            snapshot: snapshot,
            name: "RC_Filter",
            to: directory,
            preserving: projectURL
        )

        let output = try read(directory.appendingPathComponent("RC_Filter.kicad_sch"))
        for node in sourceDocument.nodes where node.kind == "wire" {
            #expect(output.contains(node.raw), "Adding a symbol changed existing wire geometry")
        }
        #expect(output.contains("R99"))
        #expect(output.contains("\"Value\" \"10000\"") || output.contains("\"Value\" \"10k\""))
    }

    @Test func editedExportReadsBackWithTheSameSolution() throws {
        let directory = try makeTempDirectory()
        var snapshot = try fixtureSnapshot()
        editResistance(&snapshot, reference: "R1", to: 2_000)
        _ = try KiCadSchematicWriter.writeProject(
            snapshot: snapshot, name: "RC_Filter", to: directory, preserving: projectURL
        )

        let reread = try KiCadSchematicReader.readProject(
            at: directory.appendingPathComponent("RC_Filter.kicad_pro")
        )
        let sourceLibraries = try KiCadSchematicReader.readProject(at: projectURL)
            .modelLibraries.map(\.rawText)
        let exported = try dcVoltages(
            for: reread.snapshot,
            libraries: reread.modelLibraries.map(\.rawText)
        )
        let original = try dcVoltages(for: snapshot, libraries: sourceLibraries)
        #expect(abs((exported["MID"] ?? .nan) - (original["MID"] ?? .nan)) < 1e-6)
        #expect(abs((exported["OUT"] ?? .nan) - (original["OUT"] ?? .nan)) < 1e-6)
    }

    @Test func missingSourceFallsBackToFreshGeneration() throws {
        let directory = try makeTempDirectory()
        let missing = directory.appendingPathComponent("Absent.kicad_pro")
        let snapshot = try fixtureSnapshot()
        let result = try KiCadSchematicWriter.writeProject(
            snapshot: snapshot,
            name: "RC_Filter",
            to: directory,
            preserving: missing
        )
        #expect(result.warnings.contains { $0.contains("Could not preserve") })
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("RC_Filter.kicad_sch").path
        ))
    }
}
