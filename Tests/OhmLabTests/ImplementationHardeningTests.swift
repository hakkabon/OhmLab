import Foundation
import Testing
@testable import OhmLabCore

@Suite("Implementation hardening")
struct ImplementationHardeningTests {
    @Test func projectReadRejectsParentTraversal() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmlab-path-read-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = parent.appendingPathComponent("Unsafe.ohmlabproj", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let manifest = ProjectManifest(
            name: "Unsafe",
            sheets: [ProjectSheet(id: "top", name: "Top", fileName: "../outside.ohmlab")],
            activeSheetID: "top"
        )
        try ProjectBundleStore.encodeManifest(manifest).write(
            to: bundleURL.appendingPathComponent(ProjectBundleStore.manifestFileName)
        )
        try CircuitFileStore.write(
            CircuitFile(name: "Outside", schematic: .init(), analysis: .default),
            to: parent.appendingPathComponent("outside.ohmlab")
        )

        #expect(throws: ProjectBundleError.self) {
            _ = try ProjectBundleStore.read(from: bundleURL)
        }
    }

    @Test func projectWriteRejectsParentTraversal() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmlab-path-write-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = parent.appendingPathComponent("Unsafe.ohmlabproj", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let sheet = ProjectSheet(id: "top", name: "Top", fileName: "../escaped.ohmlab")
        let bundle = ProjectBundle(
            manifest: ProjectManifest(name: "Unsafe", sheets: [sheet], activeSheetID: sheet.id),
            documents: [sheet.id: CircuitFile(name: "Top", schematic: .init(), analysis: .default)]
        )
        #expect(throws: ProjectBundleError.self) {
            try ProjectBundleStore.write(bundle, to: bundleURL)
        }
        #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("escaped.ohmlab").path))
    }

    @Test func syncBackendRejectsEscapingPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmlab-sync-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = LocalFolderBackend(rootURL: root)

        #expect(throws: SyncBackendError.self) {
            try backend.write(Data("nope".utf8), to: "../escaped.txt")
        }
    }

    @Test func syncBackendRejectsSymlinkEscape() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmlab-sync-link-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("root", isDirectory: true)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: outside
        )
        defer { try? FileManager.default.removeItem(at: parent) }

        let backend = LocalFolderBackend(rootURL: root)
        #expect(throws: SyncBackendError.self) {
            try backend.write(Data("nope".utf8), to: "link/escaped.txt")
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("escaped.txt").path))
    }

    @Test func numericCoreBackendIsRegistered() throws {
        #expect(EngineBackends.available.contains("numeric-core"))
        try EngineBackends.activate("numericcore")
        #expect(EngineBackends.isActive("numeric-core"))
        SimulationEngine.resetToDefaultBackend()
    }

    @Test func numericCoreMatchesNativeDividerDC() throws {
        let netlist = "V1 in 0 DC 10\nR1 in out 2k\nR2 out 0 1k\n.end"
        var settings = AnalysisSettings.default
        settings.runDC = true
        settings.runAC = false
        settings.runTransient = false

        let native = try NativeMNAEngine().solve(netlist: netlist, settings: settings, libraries: [])
        let numeric = try NumericCoreEngineBackend().solve(netlist: netlist, settings: settings, libraries: [])
        let nativeOut = try #require(native.dc?.nodes.first { $0.name == "out" }?.voltage)
        let numericOut = try #require(numeric.dc?.nodes.first { $0.name == "out" }?.voltage)
        #expect(abs(nativeOut - numericOut) < 1e-9)

        for name in ["R1", "R2", "V1"] {
            let lhs = try #require(native.dc?.components.first { $0.name == name }?.current)
            let rhs = try #require(numeric.dc?.components.first { $0.name == name }?.current)
            #expect(abs(lhs - rhs) < 1e-9, "current mismatch for \(name)")
        }
    }

    @Test func numericCoreMatchesNativeRCLowPassAC() throws {
        let netlist = "V1 in 0 DC 0 AC 1\nR1 in out 1k\nC1 out 0 1u\n.end"
        var settings = AnalysisSettings.default
        settings.runDC = true
        settings.runAC = true
        settings.runTransient = false
        settings.acSweepType = .dec
        settings.acStartFrequency = 10
        settings.acStopFrequency = 10_000
        settings.acPointsPerDecade = 8

        let native = try NativeMNAEngine().solve(netlist: netlist, settings: settings, libraries: [])
        let numeric = try NumericCoreEngineBackend().solve(netlist: netlist, settings: settings, libraries: [])
        let nativeSeries = try #require(native.ac?.nodes.first { $0.name == "out" }?.response)
        let numericSeries = try #require(numeric.ac?.nodes.first { $0.name == "out" }?.response)
        #expect(nativeSeries.count == numericSeries.count)
        for (lhs, rhs) in zip(nativeSeries, numericSeries) {
            #expect(abs(lhs.freqHz - rhs.freqHz) < 1e-12)
            #expect(abs(lhs.magnitudeDb - rhs.magnitudeDb) < 1e-7)
            #expect(abs(lhs.phaseDeg - rhs.phaseDeg) < 1e-7)
        }
    }

    @Test @MainActor func editingInvalidatesRunningSimulation() async throws {
        let document = CircuitDocument()
        document.usesSchematic = false
        document.netlistText = "V1 in 0 AC 1\nR1 in out 1k\nC1 out 0 1u\n.end"
        document.settings.runDC = false
        document.settings.runAC = true
        document.settings.acSweepType = .lin
        document.settings.acStartFrequency = 1
        document.settings.acStopFrequency = 1_000_000
        document.settings.acPointsPerDecade = FrequencySweep.maxPointCount

        document.startSimulation()
        await Task.yield()
        document.netlistText += "\n* edited while solving"

        for _ in 0..<100 where document.isSimulating {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!document.isSimulating)
        #expect(document.simulationResult == nil)
        #expect(document.simulationError == nil)
    }
}
