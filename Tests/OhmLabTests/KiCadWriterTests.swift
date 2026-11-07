// KiCadWriterTests.swift
// Exercises the native `.kicad_sch` writer without invoking KiCad.
//
// The writer must produce a complete, deterministic KiCad project: one
// schematic per OhmLab sheet, a project-local symbol library, a generated SPICE
// model library, a `sym-lib-table`, and a `.kicad_pro`. These tests prove that
// the files are structurally valid, that KiCad's pin conventions are honoured,
// and that the round trip preserves UUIDs, references, values, parameters,
// hierarchy, ports, and the electrical solution.

import Foundation
import Testing
@testable import OhmLabCore

@Suite("KiCad schematic writer")
struct KiCadWriterTests {
    private var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/KiCad/RC_Filter", isDirectory: true)
    }

    private var projectURL: URL {
        fixtureDirectory.appendingPathComponent("RC_Filter.kicad_pro")
    }

    private var kicadCLI: String {
        "/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli"
    }

    private var hasKiCadCLI: Bool {
        FileManager.default.isExecutableFile(atPath: kicadCLI)
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmlab-kicad-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fixtureSnapshot() throws -> SchematicSnapshot {
        try KiCadSchematicReader.readProject(at: projectURL).snapshot
    }

    private func writeFixtureProject(
        name: String = "RC_Filter"
    ) throws -> (directory: URL, result: KiCadSchematicWriteResult) {
        let directory = try makeTempDirectory()
        let snapshot = try fixtureSnapshot()
        let result = try KiCadSchematicWriter.writeProject(
            snapshot: snapshot,
            name: name,
            to: directory
        )
        return (directory, result)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// Counts parentheses while ignoring quoted strings and escaped characters.
    private func parenthesesBalanced(_ text: String) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for character in text {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" && inString {
                escaped = true
                continue
            }
            if character == "\"" {
                inString.toggle()
                continue
            }
            if inString { continue }
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0 && !inString
    }

    private func symbol(_ snapshot: SchematicSnapshot, refDes: String) -> SymbolInstance? {
        snapshot.symbols.first { $0.refDes == refDes }
            ?? snapshot.sheets.flatMap(\.symbols).first { $0.refDes == refDes }
    }

    private func dcResult(
        for snapshot: SchematicSnapshot,
        libraries: [SpiceModelLibrary]
    ) throws -> CircuitSimResult {
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
            libraryTexts: libraries.map(\.rawText)
        )
        return try NativeMNAEngine().solve(
            netlist: netlist,
            settings: AnalysisSettings(
                runDC: true,
                runAC: false,
                acStartFrequency: 1,
                acStopFrequency: 1_000,
                acPointsPerDecade: 10
            ),
            libraries: libraries
        )
    }

    private func dcVoltage(_ result: CircuitSimResult, _ name: String) -> Double? {
        result.dc?.nodes.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.voltage
    }

    private func runKiCadCLI(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: kicadCLI)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: - Project layout

    @Test func writesTheCompleteProjectLayout() throws {
        let (directory, result) = try writeFixtureProject()
        defer { try? FileManager.default.removeItem(at: directory) }

        let names = Set(result.files.map(\.lastPathComponent))
        #expect(names.contains("RC_Filter.kicad_sch"))
        #expect(names.contains("filter.kicad_sch"))
        #expect(names.contains("load.kicad_sch"))
        #expect(names.contains("OhmLab.kicad_sym"))
        #expect(names.contains("sym-lib-table"))
        #expect(names.contains("ohmlab_models.lib"))
        #expect(names.contains("RC_Filter.kicad_pro"))

        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("models/ohmlab_models.lib").path
        ))
        #expect(result.warnings.isEmpty)

        for file in result.files where file.pathExtension != "pro" {
            let text = try read(file)
            #expect(parenthesesBalanced(text), "\(file.lastPathComponent) has unbalanced parentheses")
        }
    }

    @Test func writesIdenticalBytesAcrossRuns() throws {
        let first = try writeFixtureProject()
        let second = try writeFixtureProject()
        defer {
            try? FileManager.default.removeItem(at: first.directory)
            try? FileManager.default.removeItem(at: second.directory)
        }

        let firstFiles = first.result.files
        let secondFiles = second.result.files
        #expect(firstFiles.count == secondFiles.count)

        for (firstFile, secondFile) in zip(firstFiles, secondFiles) {
            let firstRelative = firstFile.path.replacingOccurrences(
                of: first.directory.path + "/",
                with: ""
            )
            let secondRelative = secondFile.path.replacingOccurrences(
                of: second.directory.path + "/",
                with: ""
            )
            #expect(firstRelative == secondRelative, "file order changed")
            let firstText = try read(firstFile)
            let secondText = try read(secondFile)
            #expect(firstText == secondText, "\(firstRelative) is not deterministic")
        }
    }

    // MARK: - Symbol library

    @Test func symbolLibraryUsesKiCadPinConventions() throws {
        let (directory, _) = try writeFixtureProject()
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = try read(directory.appendingPathComponent("OhmLab.kicad_sym"))
        #expect(library.contains("(symbol \"R\""))
        #expect(library.contains("(symbol \"VDC\""))
        #expect(library.contains("(symbol \"D\""))
        #expect(library.contains("(symbol \"0\""))

        // The diode follows KiCad: pin 1 is the cathode on the left and pin 2
        // is the anode on the right.
        let diodeStart = try #require(library.range(of: "(symbol \"D\""))
        let diode = String(library[diodeStart.lowerBound...].prefix(3_000))
        #expect(diode.contains("(name \"K\""))
        #expect(diode.contains("(name \"A\""))
        #expect(diode.contains("(at -2.54 0 0)"))
        #expect(diode.contains("(at 2.54 0 180)"))
        #expect(diode.contains("(property \"Sim.Pins\" \"1=K 2=A\""))

        // Sources are vertical, matching KiCad's own Simulation_SPICE symbols.
        let sourceStart = try #require(library.range(of: "(symbol \"VDC\""))
        let source = String(library[sourceStart.lowerBound...].prefix(3_000))
        #expect(source.contains("(at 0 5.08 270)"))
        #expect(source.contains("(at 0 -5.08 90)"))
        #expect(source.contains("(property \"Sim.Pins\" \"1=+ 2=-\""))
        #expect(source.contains("(property \"Sim.Device\" \"V\""))
    }

    @Test func modelLibraryHasDeterministicCards() throws {
        let (directory, _) = try writeFixtureProject()
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = try read(
            directory.appendingPathComponent("models/ohmlab_models.lib")
        )
        #expect(library.hasPrefix("* OhmLab generated simulation models\n"))
        #expect(library.contains(".model DMOD_D1 D(IS=1E-14 N=1 RS=0.01)"))
        #expect(library.contains("\n") && library.hasSuffix("\n"))
    }

    // MARK: - Round trip

    @Test func roundTripsUuidsReferencesValuesAndParameters() throws {
        let (directory, _) = try writeFixtureProject()
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = try fixtureSnapshot()
        let generated = try KiCadSchematicReader.readProject(
            at: directory.appendingPathComponent("RC_Filter.kicad_sch")
        ).snapshot

        let references = ["V1", "R1", "C1", "R2", "R3", "D1"]
        for reference in references {
            let before = try #require(symbol(original, refDes: reference))
            let after = try #require(symbol(generated, refDes: reference))
            #expect(before.id == after.id, "\(reference) UUID changed")
            #expect(before.descriptorId == after.descriptorId)
            #expect(before.parameters == after.parameters, "\(reference) parameters changed")
        }

        // Ground symbols are synthetic, but their UUIDs still survive.
        let beforeGrounds = Set(
            original.symbols.filter { $0.descriptorId == "ground" }.map(\.id)
        )
        let afterGrounds = Set(
            generated.symbols.filter { $0.descriptorId == "ground" }.map(\.id)
        )
        #expect(!beforeGrounds.isEmpty)
        #expect(afterGrounds.isSuperset(of: beforeGrounds))

        // KiCad UUIDs for child-sheet components also survive.
        let childBefore = try #require(original.sheets.first { $0.name == "Load" })
        let childAfter = try #require(generated.sheets.first { $0.name == "Load" })
        #expect(childBefore.id == childAfter.id)
        #expect(childBefore.portNames == childAfter.portNames)
    }

    @Test func roundTripsHierarchyAndPorts() throws {
        let (directory, _) = try writeFixtureProject()
        defer { try? FileManager.default.removeItem(at: directory) }

        let root = try read(directory.appendingPathComponent("RC_Filter.kicad_sch"))
        #expect(root.contains("(sheet"))
        #expect(root.contains("(property \"Sheetname\" \"Filter\""))
        #expect(root.contains("(property \"Sheetfile\" \"filter.kicad_sch\""))

        let filter = try read(directory.appendingPathComponent("filter.kicad_sch"))
        #expect(filter.contains("(hierarchical_label \"MID\""))
        #expect(filter.contains("(hierarchical_label \"OUT\""))

        let generated = try KiCadSchematicReader.readProject(
            at: directory.appendingPathComponent("RC_Filter.kicad_sch")
        )
        #expect(generated.snapshot.sheets.count == 2)
        let filterSheet = try #require(generated.snapshot.sheets.first { $0.name == "Filter" })
        #expect(Set(filterSheet.portNames) == ["MID", "OUT"])
        let loadSheet = try #require(generated.snapshot.sheets.first { $0.name == "Load" })
        #expect(loadSheet.portNames == ["OUT"])
        #expect(generated.sourceFiles.count == 3)
    }

    @Test func roundTripKeepsTheDcSolution() throws {
        let (directory, _) = try writeFixtureProject()
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = try KiCadSchematicReader.readProject(at: projectURL)
        let generated = try KiCadSchematicReader.readProject(
            at: directory.appendingPathComponent("RC_Filter.kicad_sch")
        )

        let expected = try dcResult(
            for: original.snapshot,
            libraries: original.modelLibraries
        )
        let actual = try dcResult(
            for: generated.snapshot,
            libraries: generated.modelLibraries
        )

        for name in ["IN", "MID", "OUT"] {
            let before = try #require(dcVoltage(expected, name))
            let after = try #require(dcVoltage(actual, name))
            #expect(abs(before - after) < 1e-9, "\(name) differs")
        }
    }

    // MARK: - Optional local KiCad validation

    @Test func kicadCliAcceptsTheGeneratedProject() throws {
        guard hasKiCadCLI else { return }

        let (directory, _) = try writeFixtureProject()
        defer { try? FileManager.default.removeItem(at: directory) }

        let output = directory.appendingPathComponent("generated.cir")
        let run = try runKiCadCLI([
            "sch", "export", "netlist",
            "--format", "spice",
            directory.appendingPathComponent("RC_Filter.kicad_sch").path,
            "-o", output.path
        ])
        #expect(run.status == 0, "kicad-cli failed: \(run.output)")

        let netlist = try read(output)
        #expect(netlist.contains("V1 /IN 0 DC 5"))
        #expect(netlist.contains("D1 /OUT 0 DMOD_D1"))
    }
}
