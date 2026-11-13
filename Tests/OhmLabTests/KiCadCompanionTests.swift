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
        #expect(manifest.baseFileName == KiCadCompanionBase.fileName)
        #expect(manifest.capabilities.bidirectionalSync)
        #expect(manifest.capabilities.conflictDetection)
        #expect(manifest.capabilities.threeWayMerge)
        #expect(manifest.capabilities.dryRun)
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
        #expect(result.writtenFiles.contains { $0.hasSuffix("RC_Filter.kicad_sch") })
        #expect(FileManager.default.fileExists(
            atPath: workspace.kicad.appendingPathComponent("RC_Filter.kicad_pro").path
        ))
        let after = try KiCadCompanion.status(kicad: workspace.kicad, bundle: workspace.bundle)
        #expect(after.inSync)
    }

    @Test func exportSyncPreservesTheDrawing() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        _ = try KiCadCompanion.sync(kicad: workspace.kicad, bundle: workspace.bundle)
        let schematic = workspace.kicad.appendingPathComponent("RC_Filter.kicad_sch")
        let before = try String(contentsOf: schematic, encoding: .utf8)
        let beforeDocument = try KiCadSchematicSourceDocument(text: before)

        try mutateActiveDocument(at: workspace.bundle) { document in
            guard let index = document.schematic.symbols.firstIndex(where: {
                $0.refDes == "R1"
            }) else { return }
            document.schematic.symbols[index].parameters["resistance"] = 2_200
        }

        let result = try KiCadCompanion.sync(kicad: workspace.kicad, bundle: workspace.bundle)
        #expect(result.direction == "export")

        let after = try String(contentsOf: schematic, encoding: .utf8)
        for node in beforeDocument.nodes where node.kind == "wire" {
            #expect(after.contains(node.raw), "Companion export rewrote wire geometry")
        }
        #expect(after.contains("\"Value\" \"2200\""))
        #expect(after.contains("(paper \"A4\")"))
    }

    private func setKiCadValue(
        in workspace: (root: URL, kicad: URL, bundle: URL),
        file: String,
        from old: String,
        to new: String
    ) throws {
        let url = workspace.kicad.appendingPathComponent(file)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"Value\" \"\(old)\""))
        try text.replacingOccurrences(of: "\"Value\" \"\(old)\"", with: "\"Value\" \"\(new)\"")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func threeWayMergeCombinesNonConflictingChanges() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        _ = try KiCadCompanion.sync(kicad: workspace.kicad, bundle: workspace.bundle)
        try mutateActiveDocument(at: workspace.bundle) { document in
            let index = document.schematic.symbols.firstIndex { $0.refDes == "R1" }!
            document.schematic.symbols[index].parameters["resistance"] = 2_200
        }
        try setKiCadValue(in: workspace, file: "filter.kicad_sch", from: "1k", to: "3k")

        let plan = try KiCadCompanion.plan(kicad: workspace.kicad, bundle: workspace.bundle)
        #expect(plan.direction == "merge")
        #expect(plan.applicable)
        #expect(plan.conflicts.isEmpty)
        #expect(plan.changes.contains { $0.identifier == "R1" && $0.source == "ohmlab" })
        #expect(plan.changes.contains { $0.identifier == "R2" && $0.source == "kicad" })

        let result = try KiCadCompanion.sync(kicad: workspace.kicad, bundle: workspace.bundle)
        #expect(result.direction == "merge")
        #expect(result.warnings.isEmpty)

        let merged = try ProjectBundleStore.read(from: workspace.bundle)
        let symbols = merged.activeDocument!.schematic.symbols
            + merged.activeDocument!.schematic.sheets.flatMap(\.symbols)
        let r1 = symbols.first { $0.refDes == "R1" }
        let r2 = symbols.first { $0.refDes == "R2" }
        #expect(r1?.parameters["resistance"] == 2_200)
        #expect(r2?.parameters["resistance"] == 3_000)

        let status = try KiCadCompanion.status(kicad: workspace.kicad, bundle: workspace.bundle)
        #expect(status.inSync)

        // Both edits are now in the KiCad drawing too.
        let reread = try KiCadSchematicReader.readProject(
            at: workspace.kicad.appendingPathComponent("RC_Filter.kicad_pro")
        )
        let rereadSymbols = reread.snapshot.symbols + reread.snapshot.sheets.flatMap(\.symbols)
        #expect(rereadSymbols.first { $0.refDes == "R1" }?.parameters["resistance"] == 2_200)
        #expect(rereadSymbols.first { $0.refDes == "R2" }?.parameters["resistance"] == 3_000)
    }

    @Test func conflictingChangesRequireAPreference() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        _ = try KiCadCompanion.sync(kicad: workspace.kicad, bundle: workspace.bundle)
        try mutateActiveDocument(at: workspace.bundle) { document in
            let index = document.schematic.symbols.firstIndex { $0.refDes == "R1" }!
            document.schematic.symbols[index].parameters["resistance"] = 2_200
        }
        try setKiCadValue(in: workspace, file: "RC_Filter.kicad_sch", from: "1k", to: "3k")

        let status = try KiCadCompanion.status(kicad: workspace.kicad, bundle: workspace.bundle)
        #expect(status.recommendation == .merge)

        let plan = try KiCadCompanion.plan(kicad: workspace.kicad, bundle: workspace.bundle)
        #expect(plan.direction == "merge")
        #expect(!plan.applicable)
        #expect(plan.conflicts.contains { $0.field == "parameters.resistance" })

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

    @Test func legacyStateWithoutABaseCannotMerge() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        _ = try KiCadCompanion.sync(kicad: workspace.kicad, bundle: workspace.bundle)
        try FileManager.default.removeItem(
            at: workspace.bundle.appendingPathComponent(KiCadCompanionBase.fileName)
        )
        try mutateActiveDocument(at: workspace.bundle) { document in
            let index = document.schematic.symbols.firstIndex { $0.refDes == "R1" }!
            document.schematic.symbols[index].parameters["resistance"] = 2_200
        }
        try setKiCadValue(in: workspace, file: "filter.kicad_sch", from: "1k", to: "3k")

        let status = try KiCadCompanion.status(kicad: workspace.kicad, bundle: workspace.bundle)
        #expect(status.recommendation == .conflict)

        #expect(throws: KiCadCompanionError.self) {
            _ = try KiCadCompanion.sync(kicad: workspace.kicad, bundle: workspace.bundle)
        }
    }

    @Test func dryRunPlanReportsChangesWithoutWriting() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }

        _ = try KiCadCompanion.sync(kicad: workspace.kicad, bundle: workspace.bundle)
        try mutateActiveDocument(at: workspace.bundle) { document in
            let index = document.schematic.symbols.firstIndex { $0.refDes == "R1" }!
            document.schematic.symbols[index].parameters["resistance"] = 2_200
        }
        let stateBefore = try KiCadCompanion.readState(from: workspace.bundle)
        let digestBefore = try KiCadCompanion.digest(ofBundleAt: workspace.bundle)

        let plan = try KiCadCompanion.plan(kicad: workspace.kicad, bundle: workspace.bundle)
        #expect(plan.direction == "export")
        #expect(plan.applicable)
        #expect(plan.changes == [KiCadObjectChange(
            sheet: "RC_Filter",
            kind: "symbol",
            identifier: "R1",
            change: .updated,
            fields: ["parameters.resistance"],
            source: "ohmlab",
            uuid: plan.changes.first!.uuid
        )])

        #expect(try KiCadCompanion.readState(from: workspace.bundle) == stateBefore)
        #expect(try KiCadCompanion.digest(ofBundleAt: workspace.bundle) == digestBefore)
        let schematic = try String(
            contentsOf: workspace.kicad.appendingPathComponent("RC_Filter.kicad_sch"),
            encoding: .utf8
        )
        #expect(!schematic.contains("\"Value\" \"2200\""))
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
