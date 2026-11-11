import Foundation
import Testing
@testable import OhmLabCore

@Suite("KiCad companion")
struct KiCadCompanionTests {
    private var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/KiCad/RC_Filter", isDirectory: true)
    }

    private func makeWorkspace() throws -> (root: URL, kicad: URL, bundle: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmlab-companion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let kicad = root.appendingPathComponent("kicad", isDirectory: true)
        try FileManager.default.copyItem(at: fixtureDirectory, to: kicad)
        let bundle = root.appendingPathComponent("RC_Filter.ohmlabproj", isDirectory: true)
        return (root, kicad, bundle)
    }

    private func mutateActiveDocument(
        at bundle: URL,
        _ body: (inout CircuitFile) -> Void
    ) throws {
        var value = try ProjectBundleStore.read(from: bundle)
        guard let sheet = value.manifest.sheets.first,
              var document = value.documents[sheet.id] else { return }
        body(&document)
        value.documents[sheet.id] = document
        try ProjectBundleStore.write(value, to: bundle)
    }

    @Test func manifestPublishesTheCompanionContract() {
        let manifest = KiCadCompanion.manifest()
        #expect(manifest.contractVersion == KiCadCompanionManifest.currentContractVersion)
        #expect(manifest.productVersion == OhmLabRelease.version)
        #expect(manifest.productionBoundary == OhmLabRelease.productionBoundaryVersion)
        #expect(manifest.digestExtensions == ["kicad_pro", "kicad_sch", "kicad_sym", "kicad_mod", "lib"])
        #expect(manifest.directions == ["import", "export", "auto"])
        #expect(manifest.preferences == ["kicad", "ohmlab"])
        #expect(manifest.stateFileName == ".ohmlab-companion.json")
        #expect(manifest.capabilities.bidirectionalSync)
        #expect(manifest.capabilities.conflictDetection)
    }

    @Test func projectDigestIsStableAndContentSensitive() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let first = try KiCadCompanion.digest(ofKiCadProjectAt: workspace.kicad)
        let second = try KiCadCompanion.digest(ofKiCadProjectAt: workspace.kicad)
        #expect(first == second)
        #expect(first.count == 64)

        // Files outside the project-extension set do not participate.
        try "notes".write(
            to: workspace.kicad.appendingPathComponent("notes.txt"),
            atomically: true,
            encoding: .utf8
        )
        #expect(try KiCadCompanion.digest(ofKiCadProjectAt: workspace.kicad) == first)

        // A project-native file does.
        try "(kicad_symbol_lib)".write(
            to: workspace.kicad.appendingPathComponent("extra.kicad_sym"),
            atomically: true,
            encoding: .utf8
        )
        #expect(try KiCadCompanion.digest(ofKiCadProjectAt: workspace.kicad) != first)
    }

    @Test func bundleDigestIgnoresVolatileImportMetadata() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let imported = try KiCadProjectInterchange.importProject(
            at: workspace.kicad.appendingPathComponent("RC_Filter.kicad_pro")
        )
        try ProjectBundleStore.write(imported, to: workspace.bundle)
        let baseline = try KiCadCompanion.digest(ofBundleAt: workspace.bundle)

        var volatile = try ProjectBundleStore.read(from: workspace.bundle)
        volatile.manifest.kicadSource?.importedAt = "2030-01-01T00:00:00Z"
        volatile.manifest.metadata["volatile"] = "ignored"
        if let sheet = volatile.manifest.sheets.first, var document = volatile.documents[sheet.id] {
            document.resolvedNetlistText = "* volatile"
            document.importBaseDirectory = "/tmp/volatile"
            volatile.documents[sheet.id] = document
        }
        try ProjectBundleStore.write(volatile, to: workspace.bundle)
        #expect(try KiCadCompanion.digest(ofBundleAt: workspace.bundle) == baseline)

        try mutateActiveDocument(at: workspace.bundle) { $0.analysis.acPointsPerDecade = 33 }
        #expect(try KiCadCompanion.digest(ofBundleAt: workspace.bundle) != baseline)
    }

    @Test func autoImportsAFreshBundleAndThenReportsInSync() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let result = try KiCadCompanion.sync(
            kicad: workspace.kicad,
            bundle: workspace.bundle,
            direction: .auto
        )
        #expect(result.direction == "import")
        #expect(result.state.direction == "import")
        #expect(FileManager.default.fileExists(
            atPath: workspace.bundle.appendingPathComponent("project.json").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: workspace.bundle.appendingPathComponent(KiCadCompanionManifest.stateFileName).path
        ))

        let status = try KiCadCompanion.status(kicad: workspace.kicad, bundle: workspace.bundle)
        #expect(status.inSync)
        #expect(status.recommendation == .upToDate)
        #expect(!status.kicadChanged)
        #expect(!status.bundleChanged)
    }

    @Test func repeatedSyncIsIdempotent() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        _ = try KiCadCompanion.sync(kicad: workspace.kicad, bundle: workspace.bundle)
        let state = try #require(try KiCadCompanion.readState(from: workspace.bundle))
        let second = try KiCadCompanion.sync(kicad: workspace.kicad, bundle: workspace.bundle)
        #expect(second.direction == "none")
        #expect(second.writtenFiles.isEmpty)
        #expect(second.state == state)
    }

    @Test func kicadOnlyChangeAutoImports() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        _ = try KiCadCompanion.sync(kicad: workspace.kicad, bundle: workspace.bundle)
        try "(kicad_symbol_lib)".write(
            to: workspace.kicad.appendingPathComponent("extra.kicad_sym"),
            atomically: true,
            encoding: .utf8
        )
        let status = try KiCadCompanion.status(kicad: workspace.kicad, bundle: workspace.bundle)
        #expect(status.recommendation == .importKiCad)

        let result = try KiCadCompanion.sync(kicad: workspace.kicad, bundle: workspace.bundle)
        #expect(result.direction == "import")
        let after = try KiCadCompanion.status(kicad: workspace.kicad, bundle: workspace.bundle)
        #expect(after.inSync)
    }

    @Test func bundleOnlyChangeAutoExports() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        _ = try KiCadCompanion.sync(kicad: workspace.kicad, bundle: workspace.bundle)
        try mutateActiveDocument(at: workspace.bundle) { $0.analysis.acPointsPerDecade = 33 }
        let status = try KiCadCompanion.status(kicad: workspace.kicad, bundle: workspace.bundle)
        #expect(status.recommendation == .exportOhmLab)

        let result = try KiCadCompanion.sync(kicad: workspace.kicad, bundle: workspace.bundle)
        #expect(result.direction == "export")
        #expect(result.writtenFiles.contains { $0.hasSuffix("RC_Filter.kicad_pro") })
        let after = try KiCadCompanion.status(kicad: workspace.kicad, bundle: workspace.bundle)
        #expect(after.inSync)
    }

    @Test func conflictingChangesRequireAPreference() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        _ = try KiCadCompanion.sync(kicad: workspace.kicad, bundle: workspace.bundle)
        try mutateActiveDocument(at: workspace.bundle) { $0.analysis.acPointsPerDecade = 44 }
        try "(kicad_symbol_lib)".write(
            to: workspace.kicad.appendingPathComponent("extra.kicad_sym"),
            atomically: true,
            encoding: .utf8
        )
        let status = try KiCadCompanion.status(kicad: workspace.kicad, bundle: workspace.bundle)
        #expect(status.recommendation == .conflict)

        #expect(throws: KiCadCompanionError.self) {
            _ = try KiCadCompanion.sync(kicad: workspace.kicad, bundle: workspace.bundle)
        }
        let resolved = try KiCadCompanion.sync(
            kicad: workspace.kicad,
            bundle: workspace.bundle,
            direction: .auto,
            prefer: .kicad
        )
        #expect(resolved.direction == "import")
        let after = try KiCadCompanion.status(kicad: workspace.kicad, bundle: workspace.bundle)
        #expect(after.inSync)
    }

    @Test func existingBundleWithoutStateRequiresADirection() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        _ = try KiCadCompanion.sync(kicad: workspace.kicad, bundle: workspace.bundle)
        try FileManager.default.removeItem(
            at: workspace.bundle.appendingPathComponent(KiCadCompanionManifest.stateFileName)
        )
        #expect(throws: KiCadCompanionError.self) {
            _ = try KiCadCompanion.sync(kicad: workspace.kicad, bundle: workspace.bundle)
        }
        let explicit = try KiCadCompanion.sync(
            kicad: workspace.kicad,
            bundle: workspace.bundle,
            direction: .importKiCad
        )
        #expect(explicit.direction == "import")
    }

    @Test func exportRequiresASchematicBackedDocument() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let netlist = CircuitFile(
            name: "netlist-only",
            schematic: SchematicSnapshot(),
            analysis: .default,
            netlistText: "V1 in 0 DC 1\nR1 in 0 1k\n",
            usesSchematic: false
        )
        try ProjectBundleStore.write(ProjectBundle.single(netlist), to: workspace.bundle)
        #expect(throws: KiCadCompanionError.self) {
            _ = try KiCadCompanion.sync(
                kicad: workspace.kicad,
                bundle: workspace.bundle,
                direction: .exportOhmLab
            )
        }
    }

    @Test func corruptStateFailsClosed() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        _ = try KiCadCompanion.sync(kicad: workspace.kicad, bundle: workspace.bundle)
        try Data("{}".utf8).write(
            to: workspace.bundle.appendingPathComponent(KiCadCompanionManifest.stateFileName)
        )
        #expect(throws: KiCadCompanionError.self) {
            _ = try KiCadCompanion.readState(from: workspace.bundle)
        }
    }

    @Test func stateAndResultRoundTripThroughJSON() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        let result = try KiCadCompanion.sync(kicad: workspace.kicad, bundle: workspace.bundle)
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(KiCadSyncResult.self, from: data)
        #expect(decoded == result)
    }
}
