// Batch1P0Tests.swift
// Regression tests for the first review batch: numeric-overflow crash guards,
// project-bundle data loss, the parameter-edit dirty flag, and netlist export
// type/file-name handling.

import Foundation
import Testing
@testable import OhmLabCore

@Suite("Batch 1 P0 regressions")
struct Batch1P0Tests {
    // MARK: - Numeric overflow guards

    @Test func linearSweepRejectsOverflowingRanges() {
        // span / step overflows to infinity before the old Int conversion.
        #expect(SpiceNetlistParser.linearSweep(from: 0, to: 1e300, step: 1e-300).isEmpty)
        #expect(SpiceNetlistParser.linearSweep(from: -1e308, to: 1e308, step: 1).isEmpty)
        #expect(SpiceNetlistParser.linearSweep(from: 0, to: 1, step: 1e-300).isEmpty)
    }

    @Test func frequencySweepRejectsOverflowingSpan() {
        // stop / start overflows, so log(span) is infinite.
        #expect(
            FrequencySweep.pointCount(from: 1e-300, to: 1e300, count: 20, type: .dec) == 0
        )
        #expect(
            FrequencySweep.points(from: 1e-300, to: 1e300, count: 20, type: .dec).isEmpty
        )
        #expect(
            FrequencySweep.pointCount(from: 1e-300, to: 1e300, count: 20, type: .oct) == 0
        )
    }

    @Test func transientSolverRejectsOversizedStepCount() throws {
        let parsed = try SpiceNetlistParser.parse("V1 1 0 1\nR1 1 0 1k\n.end")
        let solver = TransientSolver(circuit: parsed.circuit, timestep: 1e-300)
        #expect(throws: CircuitSolveError.self) {
            _ = try solver.run(startTime: 0, stopTime: 1e300, maxSteps: FrequencySweep.maxPointCount)
        }
    }

    @Test func hugeTranCardThrowsInsteadOfTrapping() throws {
        let netlist = """
        V1 1 0 1
        R1 1 0 1k
        .tran 1e-300 1e300
        .end
        """
        let parsed = try SpiceNetlistParser.parse(netlist)
        #expect(parsed.analysis.hasTransient)
        #expect(throws: CircuitSimulationError.self) {
            _ = try SimulationEngine.solve(netlist: netlist, settings: .default)
        }
    }

    @Test func hugeDCCardIsRejectedWhileParsing() {
        let netlist = """
        V1 1 0 1
        R1 1 0 1k
        .dc V1 0 1e300 1e-300
        .end
        """
        #expect(throws: SpiceParseError.self) {
            _ = try SpiceNetlistParser.parse(netlist)
        }
    }

    @Test func hugeACCardThrowsInsteadOfTrapping() throws {
        let netlist = """
        V1 1 0 AC 1
        R1 1 0 1k
        .ac dec 20 1e-300 1e300
        .end
        """
        let parsed = try SpiceNetlistParser.parse(netlist)
        #expect(parsed.analysis.hasAC)
        #expect(throws: CircuitSimulationError.self) {
            _ = try SimulationEngine.solve(netlist: netlist, settings: .default)
        }
    }

    @Test func numericCoreTransientRejectsOversizedStepCount() {
        var settings = AnalysisSettings.default
        settings.runDC = false
        settings.runAC = false
        settings.runTransient = true
        settings.tranStart = 0
        settings.tranStop = 1e300
        settings.tranStep = 1e-300

        let netlist = "V1 1 0 1\nR1 1 0 1k\n.end"
        #expect(throws: CircuitSimulationError.self) {
            _ = try NumericCoreEngineBackend().solve(
                netlist: netlist,
                settings: settings,
                libraries: []
            )
        }
    }

    // MARK: - Project bundle writes

    @Test func projectWritePreservesUnrelatedDocuments() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmlab-batch1-write-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = parent.appendingPathComponent("Project.ohmlabproj", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let unrelated = bundleURL.appendingPathComponent("KeepMe.ohmlab")
        try CircuitFileStore.write(
            CircuitFile(name: "KeepMe", schematic: .init(), analysis: .default),
            to: unrelated
        )

        let bundle = makeBundle(name: "Project", sheetFile: "Sheets/top-abc12345.ohmlab")
        try ProjectBundleStore.write(bundle, to: bundleURL)

        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent("Sheets/top-abc12345.ohmlab").path
        ))
    }

    @Test func projectWriteRemovesOnlyStaleManifestSheets() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmlab-batch1-stale-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = parent.appendingPathComponent("Project.ohmlabproj", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let unrelated = bundleURL.appendingPathComponent("KeepMe.ohmlab")
        try CircuitFileStore.write(
            CircuitFile(name: "KeepMe", schematic: .init(), analysis: .default),
            to: unrelated
        )

        let first = makeBundle(name: "Project", sheetFile: "Sheets/first-11111111.ohmlab")
        try ProjectBundleStore.write(first, to: bundleURL)

        let second = makeBundle(name: "Project", sheetFile: "Sheets/second-22222222.ohmlab")
        try ProjectBundleStore.write(second, to: bundleURL)

        #expect(!FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent("Sheets/first-11111111.ohmlab").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent("Sheets/second-22222222.ohmlab").path
        ))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func projectPathsResolveUnderSymlinkedTemporaryDirectory() throws {
        // `FileManager.default.temporaryDirectory` is `/var/folders/…`, which is
        // a symlink to `/private/var/folders/…`; the old resolver compared the
        // resolved root against an unresolved candidate and rejected every path.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmlab-batch1-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = try ProjectPath.resolve("Sheets/new-12345678.ohmlab", under: root)
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        #expect(resolved.path.hasPrefix(canonicalRoot.path + "/"))

        let bundle = makeBundle(name: "Nested", sheetFile: "Sheets/new-12345678.ohmlab")
        try ProjectBundleStore.write(bundle, to: root.appendingPathComponent("Nested.ohmlabproj"))
    }

    @Test func projectPathStillRejectsTraversalUnderSymlinkedRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmlab-batch1-escape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: ProjectBundleError.self) {
            _ = try ProjectPath.resolve("../escaped.ohmlab", under: root)
        }
    }

    // MARK: - Editing dirtiness

    @Test @MainActor func setParameterMarksDocumentDirty() {
        let document = CircuitDocument()
        let resistor = document.schematic.addComponent(
            descriptorId: "resistor",
            at: GridPoint(0, 0)
        )
        let symbol = resistor!
        document.isDirty = false
        let version = document.schematic.contentVersion

        document.schematic.setParameter(id: symbol.id, key: "resistance", value: 4_700)

        #expect(document.schematic.symbols.first?.parameters["resistance"] == 4_700)
        #expect(document.schematic.contentVersion > version)
        #expect(document.isDirty)
    }

    // MARK: - Netlist export identity

    @Test func netlistFileNameAlwaysUsesCir() {
        #expect(KiCadInterchange.netlistFileName(for: "amp") == "amp.cir")
        #expect(KiCadInterchange.netlistFileName(for: "amp.cir") == "amp.cir")
        #expect(KiCadInterchange.netlistFileName(for: "amp.net") == "amp.net")
        #expect(KiCadInterchange.netlistFileName(for: "  amp  ") == "amp.cir")
        #expect(KiCadInterchange.netlistFileName(for: "") == "netlist.cir")
    }

    @Test func packagingDeclaresSpiceNetlistType() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // OhmLabTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
        let plistURL = repositoryRoot.appendingPathComponent("Packaging/Info.plist.in")
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dictionary = try #require(plist as? [String: Any])

        let exported = try #require(dictionary["UTExportedTypeDeclarations"] as? [[String: Any]])
        let netlist = try #require(exported.first {
            $0["UTTypeIdentifier"] as? String == "com.hakkabon.ohmlab.spice-netlist"
        })
        let tags = try #require(netlist["UTTypeTagSpecification"] as? [String: Any])
        #expect((tags["public.filename-extension"] as? [String])?.contains("cir") == true)

        let documentTypes = try #require(dictionary["CFBundleDocumentTypes"] as? [[String: Any]])
        #expect(documentTypes.contains {
            ($0["LSItemContentTypes"] as? [String])?
                .contains("com.hakkabon.ohmlab.spice-netlist") == true
        })
    }

    // MARK: - Helpers

    private func makeBundle(name: String, sheetFile: String) -> ProjectBundle {
        let sheet = ProjectSheet(id: "sheet-1", name: "Top", fileName: sheetFile)
        return ProjectBundle(
            manifest: ProjectManifest(name: name, sheets: [sheet], activeSheetID: sheet.id),
            documents: [
                sheet.id: CircuitFile(name: "Top", schematic: .init(), analysis: .default)
            ]
        )
    }
}
