// db_LabApp.swift
// db-Lab — SwiftUI frontend for the db-Engine simulation backend.
//
// Circuit simulator entry point.
//
// Entry point: this file contains the @main App struct.
// Swift requires exactly one file named "main.swift" OR one @main struct
// in an executable target. We use @main here.

import SwiftUI

@main
struct DbLabApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Circuit") {
                    appState.newCircuit()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
        }
    }
}
