import Foundation
import Testing
@testable import OhmLabCore

@Suite("OhmLab 1.0.x release hardening")
struct ReleaseHardeningTests {
    private static let compatibilityDirectory = Bundle.module.resourceURL!
        .appendingPathComponent("Fixtures/Compatibility", isDirectory: true)

    @Test func frozenPersistenceVersionsRemainCompatible() {
        #expect(CircuitFile.currentSchemaVersion == 3)
        #expect(SchematicSnapshot.currentSchemaVersion == 2)
        #expect(ProjectManifest.currentSchemaVersion == 1)
        #expect(OhmLabRelease.productionBoundaryVersion == 1)
        #expect(CircuitIR.currentSchemaVersion == 1)
        #expect(SimulationResultContract.currentVersion == 1)
        #expect(RustCircuitTransport.currentVersion == 1)
        #expect(NumericalTrust.currentContractVersion == 1)
    }

    @Test func genuineVersionOneFixtureMigratesWithoutDataLoss() throws {
        let data = try Data(contentsOf: Self.compatibilityDirectory.appendingPathComponent("circuit-v1.ohmlab"))
        let migrated = try CircuitFileStore.decode(data)

        #expect(migrated.schemaVersion == CircuitFile.currentSchemaVersion)
        #expect(migrated.schematic.schemaVersion == SchematicSnapshot.currentSchemaVersion)
        #expect(migrated.schematic.sheets.isEmpty)
        let source = try #require(migrated.schematic.symbols.first)
        #expect(source.parameters["voltage"] == nil)
        #expect(source.parameters["dcVoltage"] == 5)
        #expect(source.parameters["acMagnitude"] == 5)
        #expect(source.parameters["acPhaseDegrees"] == 0)
        #expect(migrated.analysis.acSweepType == .dec)
        #expect(migrated.analysis.runTransient == false)

        let reopened = try CircuitFileStore.decode(CircuitFileStore.encode(migrated))
        #expect(reopened == migrated)
    }

    @Test func newerNestedSchematicVersionFailsClosed() throws {
        let file = CircuitFile(
            name: "Future schematic",
            schematic: SchematicSnapshot(
                schemaVersion: SchematicSnapshot.currentSchemaVersion + 1
            ),
            analysis: .default
        )
        #expect(throws: CircuitFileError.self) {
            _ = try CircuitFileStore.decode(CircuitFileStore.encode(file))
        }
    }

    @Test func recoverySlotsAreIsolatedAndIgnoreCorruption() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmlab-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let first = CircuitFile(name: "First", schematic: .init(), analysis: .default)
        let second = CircuitFile(name: "Second", schematic: .init(), analysis: .default)

        CircuitFileStore.saveRecovery(first, id: firstID, directory: directory)
        CircuitFileStore.saveRecovery(second, id: secondID, directory: directory)
        try Data("not-json".utf8).write(
            to: directory.appendingPathComponent("recovery-broken.ohmlab")
        )

        #expect(CircuitFileStore.loadRecovery(id: firstID, directory: directory) == first)
        #expect(CircuitFileStore.loadAllRecoveries(directory: directory).map(\.name) == ["First", "Second"])
        CircuitFileStore.clearRecovery(id: firstID, directory: directory)
        #expect(CircuitFileStore.loadRecovery(id: firstID, directory: directory) == nil)
        #expect(CircuitFileStore.loadRecovery(id: secondID, directory: directory) == second)
    }

    @Test func largeDocumentRoundTripsAtReleaseScale() throws {
        let count = 2_000
        let symbols = (0..<count).map { index in
            SymbolInstance(
                descriptorId: "resistor",
                refDes: "R\(index + 1)",
                position: GridPoint(index % 100, index / 100),
                parameters: ["resistance": Double(index + 1)]
            )
        }
        let wires = (0..<(count - 1)).map { index in
            WireSegment(points: [GridPoint(index % 100, index / 100), GridPoint((index + 1) % 100, (index + 1) / 100)])
        }
        let file = CircuitFile(
            name: "Large release fixture",
            schematic: SchematicSnapshot(symbols: symbols, wires: wires),
            analysis: .default
        )

        let encoded = try CircuitFileStore.encode(file)
        let decoded = try CircuitFileStore.decode(encoded)
        #expect(decoded == file)
        #expect(decoded.schematic.symbols.count == count)
        #expect(decoded.schematic.wires.count == count - 1)
        #expect(encoded.count < 2_000_000)
    }

    @Test func projectArchiveDetectsPayloadCorruption() throws {
        var archive = ZipArchive.create([.init(name: "payload", data: Data("release-data".utf8))])
        let payload = try #require(archive.range(of: Data("release-data".utf8)))
        archive[payload.lowerBound] ^= 0xff
        #expect(throws: ZipArchiveError.self) {
            _ = try ZipArchive.read(archive)
        }
    }
}
