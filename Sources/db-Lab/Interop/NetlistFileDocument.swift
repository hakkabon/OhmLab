// NetlistFileDocument.swift
// A minimal `FileDocument` so a projected netlist can be exported through the
// system save/share sheet on iPadOS (macOS uses an `NSSavePanel` instead).

import SwiftUI
import UniformTypeIdentifiers

struct NetlistFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.spiceNetlist, .plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
