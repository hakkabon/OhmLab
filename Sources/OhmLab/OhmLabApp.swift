// OhmLabApp.swift
// OhmLab — SwiftUI frontend for the db-Engine simulation backend.
//
// Circuit simulator entry point.
//
// Entry point: this file contains the @main App struct.
// Swift requires exactly one file named "main.swift" OR one @main struct
// in an executable target. We use @main here.

import SwiftUI

@main
struct OhmLabApp: App {
    var body: some Scene {
        // A document-based scene gives open-in-place, automatic saving to the
        // file's location, iCloud support, and the standard File menu
        // (New/Open/Save/Save As/Revert) on macOS and iPadOS for free.
        DocumentGroup(newDocument: CircuitFileDocument()) { configuration in
            DocumentWorkspaceView(configuration: configuration)
        }
    }
}
