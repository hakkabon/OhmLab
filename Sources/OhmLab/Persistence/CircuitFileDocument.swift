// CircuitFileDocument.swift
// The `FileDocument` backing the DocumentGroup-based app.
//
// A `.ohmlab` file is the JSON `CircuitFile` handled elsewhere; this type only
// adapts it to SwiftUI's document lifecycle so the app gets open-in-place,
// automatic saving, and iCloud support on both macOS and iPadOS.

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// The OhmLab circuit document type (`.ohmlab`).
    public static let ohmlabCircuit = UTType(filenameExtension: CircuitFileStore.fileExtension) ?? .json
}

struct CircuitFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.ohmlabCircuit, .json] }
    static var writableContentTypes: [UTType] { [.ohmlabCircuit] }

    var file: CircuitFile

    init(file: CircuitFile) {
        self.file = file
    }

    /// A blank document: an empty schematic with the default analysis settings.
    init() {
        self.file = CircuitFile(
            name: "Untitled Circuit",
            schematic: SchematicSnapshot(),
            analysis: .default
        )
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        file = try CircuitFileStore.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try CircuitFileStore.encode(file))
    }
}
