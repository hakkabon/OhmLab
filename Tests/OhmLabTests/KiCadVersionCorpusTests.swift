// KiCadVersionCorpusTests.swift
// Phase 4.2: a broader KiCad format-version corpus.
//
// The main fixture is a KiCad 10 project. These entries carry the same
// three-level RC filter with KiCad 7, 8, and 9 format headers. They prove that
// direct reading, preservation, and value patching are driven by the
// S-expression structure rather than by a single release number, including
// KiCad 7's older unquoted UUID tokens.

import Foundation
import Testing
@testable import OhmLabCore

@Suite("KiCad version corpus")
struct KiCadVersionCorpusTests {
    private struct Corpus {
        let name: String
        let version: Int
        let generatorVersion: String
    }

    private let corpora = [
        Corpus(name: "RC_Filter_KiCad7", version: 20230121, generatorVersion: "7.0"),
        Corpus(name: "RC_Filter_KiCad8", version: 20231120, generatorVersion: "8.0"),
        Corpus(name: "RC_Filter_KiCad9", version: 20250114, generatorVersion: "9.0"),
    ]

    private var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/KiCad", isDirectory: true)
    }

    private func directory(_ corpus: Corpus) -> URL {
        fixturesDirectory.appendingPathComponent(corpus.name, isDirectory: true)
    }

    private func projectURL(_ corpus: Corpus) -> URL {
        directory(corpus).appendingPathComponent("RC_Filter.kicad_pro")
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmlab-kicad-version-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test func eachVersionReadsTheSameElectricalContent() throws {
        for corpus in corpora {
            let reading = try KiCadSchematicReader.readProject(at: projectURL(corpus))
            let symbols = reading.snapshot.symbols + reading.snapshot.sheets.flatMap(\.symbols)

            #expect(reading.snapshot.sheets.count == 2, "\(corpus.name): hierarchy depth changed")
            #expect(symbols.contains { $0.refDes == "R1" }, "\(corpus.name): missing R1")
            #expect(symbols.contains { $0.refDes == "R2" }, "\(corpus.name): missing R2")
            #expect(symbols.contains { $0.refDes == "R3" }, "\(corpus.name): missing R3")
            #expect(symbols.contains { $0.refDes == "D1" }, "\(corpus.name): missing D1")

            let r1 = symbols.first { $0.refDes == "R1" }
            #expect(r1?.parameters["resistance"] == 1_000, "\(corpus.name): R1 value was lost")
            let r2 = symbols.first { $0.refDes == "R2" }
            #expect(r2?.parameters["resistance"] == 1_000, "\(corpus.name): R2 value was lost")
        }
    }

    @Test func eachVersionPreservesAnUntouchedProjectByteForByte() throws {
        for corpus in corpora {
            let output = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: output) }
            let reading = try KiCadSchematicReader.readProject(at: projectURL(corpus))

            let result = try KiCadSchematicWriter.writeProject(
                snapshot: reading.snapshot,
                name: "RC_Filter",
                to: output,
                preserving: projectURL(corpus)
            )
            #expect(result.warnings.isEmpty, "\(corpus.name): \(result.warnings)")

            for file in ["RC_Filter.kicad_sch", "filter.kicad_sch", "load.kicad_sch"] {
                let source = try read(directory(corpus).appendingPathComponent(file))
                let written = try read(output.appendingPathComponent(file))
                #expect(written == source, "\(corpus.name): \(file) was not preserved byte-for-byte")
            }
        }
    }

    @Test func eachVersionPatchesOnlyTheEditedValue() throws {
        for corpus in corpora {
            let output = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: output) }
            var reading = try KiCadSchematicReader.readProject(at: projectURL(corpus))
            guard let index = reading.snapshot.symbols.firstIndex(where: { $0.refDes == "R1" }) else {
                Issue.record("\(corpus.name): missing R1")
                continue
            }
            reading.snapshot.symbols[index].parameters["resistance"] = 2_200

            _ = try KiCadSchematicWriter.writeProject(
                snapshot: reading.snapshot,
                name: "RC_Filter",
                to: output,
                preserving: projectURL(corpus)
            )

            let sourceText = try read(directory(corpus).appendingPathComponent("RC_Filter.kicad_sch"))
            let outputText = try read(output.appendingPathComponent("RC_Filter.kicad_sch"))
            let sourceDocument = try KiCadSchematicSourceDocument(text: sourceText)

            for node in sourceDocument.nodes where node.kind == "wire" {
                #expect(
                    outputText.contains(node.raw),
                    "\(corpus.name): editing a value rewrote wire geometry"
                )
            }
            #expect(
                outputText.contains("(version \(corpus.version))"),
                "\(corpus.name): the format version header was lost"
            )
            #expect(
                outputText.contains("(generator \(corpus.version == 20230121 ? "eeschema" : "\"eeschema\""))"),
                "\(corpus.name): the generator header was lost"
            )
            #expect(
                outputText.contains("\"Value\" \"2200\""),
                "\(corpus.name): the edited value was not written"
            )

            // Unchanged child and grandchild sheets stay byte-identical.
            for file in ["filter.kicad_sch", "load.kicad_sch"] {
                #expect(
                    try read(output.appendingPathComponent(file))
                        == read(directory(corpus).appendingPathComponent(file)),
                    "\(corpus.name): \(file) changed during a root-sheet edit"
                )
            }
        }
    }
}
