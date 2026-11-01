// IncludePipelineTests.swift
// Regression tests for the import-time include pipeline: `.include`/`.lib`
// resolution, persistence, export, and the base-directory fallback.

import Foundation
import Testing
@testable import OhmLabCore

@Suite("Include pipeline")
struct IncludePipelineTests {
    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmlab-includes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func dcSettings() -> AnalysisSettings {
        AnalysisSettings(
            runDC: true,
            runAC: false,
            acStartFrequency: 1,
            acStopFrequency: 1_000_000,
            acPointsPerDecade: 20
        )
    }

    private let diodeNetlist = """
    V1 1 0 DC 1
    R1 1 2 1k
    D1 2 0 DMOD
    .include "diodes.lib"
    .end
    """

    // MARK: - Resolution

    @Test func inlineResolvesSiblingInclude() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(".model DMOD D(IS=1e-14 RS=1)\n", to: directory.appendingPathComponent("diodes.lib"))

        let inlined = SpiceIncludePipeline.inline(diodeNetlist, baseDirectory: directory)
        #expect(inlined.isFullyResolved)
        #expect(!inlined.text.contains(".include"))
        #expect(inlined.text.contains(".model DMOD"))
        #expect(inlined.warnings.isEmpty)

        let parsed = try SpiceNetlistLoader.parse(diodeNetlist, baseDirectory: directory)
        #expect(parsed.circuit.elements.contains { $0.name == "D1" })
    }

    @Test func inlineResolvesNestedIncludesRelativeToEachFile() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let subdirectory = directory.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)

        try write(".model DMOD D(IS=2e-14 RS=2)\n", to: subdirectory.appendingPathComponent("models.lib"))
        try write(".include \"models.lib\"\n", to: subdirectory.appendingPathComponent("diodes.inc"))
        try write(".include \"sub/diodes.inc\"\n", to: directory.appendingPathComponent("amp.cir"))

        let netlist = """
        V1 1 0 DC 1
        R1 1 2 1k
        D1 2 0 DMOD
        .include "amp.cir"
        .end
        """

        let inlined = SpiceIncludePipeline.inline(netlist, baseDirectory: directory)
        #expect(inlined.isFullyResolved)
        #expect(inlined.text.contains("IS=2e-14"))
        #expect(!inlined.text.contains(".include"))
    }

    @Test func inlineExtractsOnlyTheRequestedLibSection() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = """
        .lib Diodes
        .model DMOD D(IS=2e-14)
        .endl

        .lib Alternate
        .model DMOD D(IS=9e-9)
        .endl
        """
        try write(library, to: directory.appendingPathComponent("models.lib"))

        let netlist = """
        V1 1 0 DC 1
        R1 1 2 1k
        D1 2 0 DMOD
        .lib "models.lib" "Diodes"
        .end
        """

        let inlined = SpiceIncludePipeline.inline(netlist, baseDirectory: directory)
        #expect(inlined.isFullyResolved)
        #expect(inlined.text.contains("IS=2e-14"))
        #expect(!inlined.text.contains("IS=9e-9"))
    }

    @Test func wholeFileIncludeDropsSectionMarkers() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = """
        .lib Diodes
        .model DMOD D(IS=2e-14)
        .endl
        """
        try write(library, to: directory.appendingPathComponent("models.lib"))

        let netlist = """
        V1 1 0 DC 1
        R1 1 2 1k
        D1 2 0 DMOD
        .include "models.lib"
        .end
        """

        let inlined = SpiceIncludePipeline.inline(netlist, baseDirectory: directory)
        #expect(inlined.isFullyResolved)
        #expect(inlined.text.contains(".model DMOD"))
        #expect(!inlined.text.contains(".lib Diodes"))
        #expect(!inlined.text.contains(".endl"))

        let parsed = try SpiceNetlistLoader.parse(netlist, baseDirectory: directory)
        #expect(parsed.circuit.elements.contains { $0.name == "D1" })
    }

    @Test func missingIncludeIsLeftInPlaceWithAWarning() {
        let netlist = """
        V1 1 0 DC 1
        R1 1 0 1k
        .include "does-not-exist.lib"
        .end
        """

        let inlined = SpiceIncludePipeline.inline(netlist, baseDirectory: nil)
        #expect(!inlined.isFullyResolved)
        #expect(inlined.text.contains(".include \"does-not-exist.lib\""))
        #expect(inlined.warnings.contains { $0.contains("could not be resolved") })
    }

    @Test func cyclicIncludeTerminatesAndIsReported() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(".include \"b.inc\"\n", to: directory.appendingPathComponent("a.inc"))
        try write(".include \"a.inc\"\n", to: directory.appendingPathComponent("b.inc"))

        let netlist = """
        V1 1 0 DC 1
        R1 1 0 1k
        .include "a.inc"
        .end
        """

        let inlined = SpiceIncludePipeline.inline(netlist, baseDirectory: directory)
        #expect(!inlined.isFullyResolved)
        #expect(inlined.warnings.contains { $0.contains("cyclic") })
        #expect(inlined.text.contains("Skipped cyclic"))
    }

    @Test func oversizedIncludeIsLeftInPlace() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(String(repeating: "* filler\n", count: 200), to: directory.appendingPathComponent("big.lib"))

        let netlist = """
        V1 1 0 DC 1
        R1 1 0 1k
        .include "big.lib"
        .end
        """

        let inlined = SpiceIncludePipeline.inline(
            netlist,
            baseDirectory: directory,
            maximumBytes: 100
        )
        #expect(!inlined.isFullyResolved)
        #expect(inlined.text.contains(".include \"big.lib\""))
        #expect(inlined.warnings.contains { $0.contains("too large") })
    }

    // MARK: - Persistence

    @Test func circuitFilePersistsResolvedNetlistAndBaseDirectory() throws {
        let file = CircuitFile(
            name: "amp",
            schematic: SchematicSnapshot(),
            analysis: .default,
            netlistText: "V1 1 0 DC 1\n.include \"diodes.lib\"\n.end",
            resolvedNetlistText: "V1 1 0 DC 1\n.model DMOD D(IS=1e-14)\n.end",
            usesSchematic: false,
            importBaseDirectory: "/tmp/amp"
        )

        let decoded = try CircuitFileStore.decode(CircuitFileStore.encode(file))
        #expect(decoded == file)
        #expect(decoded.schemaVersion == CircuitFile.currentSchemaVersion)
        #expect(decoded.resolvedNetlistText == file.resolvedNetlistText)
        #expect(decoded.importBaseDirectory == "/tmp/amp")
    }

    @Test func versionThreeFileMigratesWithoutIncludeFields() throws {
        let legacy = CircuitFile(
            schemaVersion: 3,
            name: "legacy",
            schematic: SchematicSnapshot(),
            analysis: .default,
            netlistText: "V1 1 0 DC 1\n.end",
            usesSchematic: false
        )

        let decoded = try CircuitFileStore.decode(CircuitFileStore.encode(legacy))
        #expect(decoded.schemaVersion == 4)
        #expect(decoded.resolvedNetlistText == nil)
        #expect(decoded.importBaseDirectory == nil)
        #expect(decoded.netlistText == legacy.netlistText)
    }

    @Test func singleSheetBundleCopiesIncludeFields() {
        let file = CircuitFile(
            name: "amp",
            schematic: SchematicSnapshot(),
            analysis: .default,
            netlistText: "V1 1 0 DC 1\n.include \"diodes.lib\"\n.end",
            resolvedNetlistText: "V1 1 0 DC 1\n.model DMOD D(IS=1e-14)\n.end",
            usesSchematic: false,
            importBaseDirectory: "/tmp/amp"
        )

        let bundle = ProjectBundle.single(file)
        #expect(bundle.activeDocument?.resolvedNetlistText == file.resolvedNetlistText)
        #expect(bundle.activeDocument?.importBaseDirectory == "/tmp/amp")
    }

    // MARK: - Export

    @Test func projectExportPrefersTheResolvedNetlist() throws {
        let resolved = "V1 1 0 DC 1\n.model DMOD D(IS=1e-14)\n.end"
        let file = CircuitFile(
            name: "amp",
            schematic: SchematicSnapshot(),
            analysis: .default,
            netlistText: "V1 1 0 DC 1\n.include \"diodes.lib\"\n.end",
            resolvedNetlistText: resolved,
            usesSchematic: false,
            importBaseDirectory: "/tmp/amp"
        )

        #expect(try KiCadProjectInterchange.netlist(for: file) == resolved)

        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try KiCadProjectInterchange.exportProject(ProjectBundle.single(file), to: directory)
        let top = try String(
            contentsOf: directory.appendingPathComponent("top.cir"),
            encoding: .utf8
        )
        #expect(top == resolved)
        #expect(!top.contains(".include"))
    }

    // MARK: - Engine fallback

    @Test func engineResolvesSiblingIncludeThroughBaseDirectory() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(".model DMOD D(IS=1e-14 RS=1)\n", to: directory.appendingPathComponent("diodes.lib"))

        let result = try SimulationEngine.solve(
            netlist: diodeNetlist,
            settings: dcSettings(),
            baseDirectory: directory
        )
        let dc = try #require(result.dc)
        #expect(dc.components.contains { $0.name == "D1" })
    }

    @Test func batchRunnerUsesTheRequestBaseDirectory() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(".model DMOD D(IS=1e-14 RS=1)\n", to: directory.appendingPathComponent("diodes.lib"))

        let outcome = try BatchRunner.run(BatchRequest(
            input: .netlist(diodeNetlist),
            format: .json,
            baseDirectory: directory
        ))
        #expect(outcome.result.dc?.components.contains { $0.name == "D1" } == true)
    }

    @Test func cornerAnalysisUsesTheBaseDirectory() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(".model DMOD D(IS=1e-14 RS=1)\n", to: directory.appendingPathComponent("diodes.lib"))

        let result = try CornerAnalysis.run(CornerRequest(
            netlist: diodeNetlist,
            settings: dcSettings(),
            probes: [.nodeVoltage("2")],
            baseDirectory: directory
        ))
        #expect(result.cornersEvaluated == 1)
        #expect(result.failures == 0)
        #expect(result.extremes.count == 1)
    }

    @Test func batchRunnerUsesTheDocumentImportDirectory() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(".model DMOD D(IS=1e-14 RS=1)\n", to: directory.appendingPathComponent("diodes.lib"))

        // No resolvedNetlistText: this exercises the non-inlined fallback.
        let file = CircuitFile(
            name: "amp",
            schematic: SchematicSnapshot(),
            analysis: dcSettings(),
            netlistText: diodeNetlist,
            usesSchematic: false,
            importBaseDirectory: directory.path
        )

        let outcome = try BatchRunner.run(BatchRequest(input: .document(file), format: .json))
        #expect(outcome.result.dc?.components.contains { $0.name == "D1" } == true)
    }

    // MARK: - Document integration

    @Test @MainActor func importInlinesPersistsAndExports() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(".model DMOD D(IS=1e-14 RS=1)\n", to: directory.appendingPathComponent("diodes.lib"))
        let netlistURL = directory.appendingPathComponent("amp.cir")
        try write(diodeNetlist, to: netlistURL)

        let document = CircuitDocument()
        try document.importDesign(at: netlistURL)

        #expect(document.importBaseDirectory?.standardizedFileURL == directory.standardizedFileURL)
        #expect(document.netlistText.contains(".include"))
        let resolved = try #require(document.resolvedNetlistText)
        #expect(resolved.contains(".model DMOD"))
        #expect(!resolved.contains(".include"))
        #expect(try document.netlistForExport().contains(".model DMOD"))

        let saved = document.makeFile()
        #expect(saved.resolvedNetlistText == resolved)
        #expect(saved.importBaseDirectory == directory.path)
    }

    @Test @MainActor func editingRebuildsTheExportFromTheImportDirectory() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(".model DMOD D(IS=1e-14 RS=1)\n", to: directory.appendingPathComponent("diodes.lib"))
        let netlistURL = directory.appendingPathComponent("amp.cir")
        try write(diodeNetlist, to: netlistURL)

        let document = CircuitDocument()
        try document.importDesign(at: netlistURL)
        #expect(document.resolvedNetlistText != nil)

        document.netlistText += "\n* edited"
        #expect(document.resolvedNetlistText == nil)
        #expect(document.importBaseDirectory == directory)

        // The import directory is still available, so export re-inlines.
        let exported = try document.netlistForExport()
        #expect(exported.contains(".model DMOD"))
        #expect(!exported.contains(".include"))
    }

    @Test @MainActor func loadingRestoresTheResolvedNetlist() throws {
        let file = CircuitFile(
            name: "amp",
            schematic: SchematicSnapshot(),
            analysis: .default,
            netlistText: "V1 1 0 DC 1\n.include \"diodes.lib\"\n.end",
            resolvedNetlistText: "V1 1 0 DC 1\n.model DMOD D(IS=1e-14)\n.end",
            usesSchematic: false,
            importBaseDirectory: "/tmp/amp"
        )

        let document = CircuitDocument()
        document.load(file)
        #expect(document.resolvedNetlistText == file.resolvedNetlistText)
        #expect(document.importBaseDirectory?.path == "/tmp/amp")
        #expect(try document.netlistForExport() == file.resolvedNetlistText)
    }

    @Test @MainActor func loadingAnOldDocumentInlinesFromItsDirectory() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(".model DMOD D(IS=1e-14 RS=1)\n", to: directory.appendingPathComponent("diodes.lib"))

        // A pre-v4 document: netlist text but no resolved text or import path.
        let file = CircuitFile(
            schemaVersion: 3,
            name: "amp",
            schematic: SchematicSnapshot(),
            analysis: .default,
            netlistText: diodeNetlist,
            usesSchematic: false
        )

        let document = CircuitDocument()
        document.load(file, fallbackBaseDirectory: directory)
        #expect(document.importBaseDirectory?.standardizedFileURL == directory.standardizedFileURL)
        let resolved = try #require(document.resolvedNetlistText)
        #expect(resolved.contains(".model DMOD"))
        #expect(try document.netlistForExport().contains(".model DMOD"))
    }
}
