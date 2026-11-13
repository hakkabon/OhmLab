// KiCadPluginTests.swift
// Validates the committed KiCad IPC action plugin without launching KiCad.
//
// The plugin is an `exec`-runtime action bridge over `ohm kicad sync`. These
// checks pin the parts KiCad reads before launch: schema-shaped metadata, an
// executable entrypoint, the two actions, and a parseable example config. They
// also keep the plugin's claims tied to the companion contract.

import Foundation
import Testing
@testable import OhmLabCore

@Suite("KiCad action plugin")
struct KiCadPluginTests {
    private var pluginDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // OhmLabTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("integrations/kicad", isDirectory: true)
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("\(url.lastPathComponent) is not a JSON object")
            return [:]
        }
        return object
    }

    @Test func pluginManifestIsLaunchableByKiCad() throws {
        let manifest = try jsonObject(at: pluginDirectory.appendingPathComponent("plugin.json"))

        let identifier = try #require(manifest["identifier"] as? String)
        #expect(
            identifier.range(
                of: "^[a-zA-Z][-_a-zA-Z0-9.]{0,98}[a-zA-Z0-9]$",
                options: .regularExpression
            ) != nil,
            "plugin identifier does not match the KiCad schema"
        )
        #expect((manifest["name"] as? String)?.isEmpty == false)
        #expect((manifest["description"] as? String)?.isEmpty == false)

        let runtime = try #require(manifest["runtime"] as? [String: Any])
        #expect(runtime["type"] as? String == "exec")

        let actions = try #require(manifest["actions"] as? [[String: Any]])
        #expect(actions.count == 2)

        var identifiers = Set<String>()
        var launchedPreview = false
        var launchedSync = false
        for action in actions {
            let actionIdentifier = try #require(action["identifier"] as? String)
            #expect(
                actionIdentifier.range(
                    of: "^[a-zA-Z][-_a-zA-Z0-9.]{0,48}[a-zA-Z0-9]$",
                    options: .regularExpression
                ) != nil,
                "\(actionIdentifier): identifier does not match the KiCad schema"
            )
            #expect(identifiers.insert(actionIdentifier).inserted, "duplicate action identifier")
            #expect((action["name"] as? String)?.isEmpty == false)
            #expect((action["description"] as? String)?.isEmpty == false)

            let entrypoint = try #require(action["entrypoint"] as? String)
            let entrypointURL = pluginDirectory.appendingPathComponent(entrypoint)
            #expect(
                FileManager.default.fileExists(atPath: entrypointURL.path),
                "\(actionIdentifier): missing entrypoint \(entrypoint)"
            )
            #expect(
                FileManager.default.isExecutableFile(atPath: entrypointURL.path),
                "\(actionIdentifier): entrypoint \(entrypoint) is not executable"
            )

            let scopes = try #require(action["scopes"] as? [String])
            let allowed: Set<String> = [
                "pcb", "schematic", "footprint", "symbol", "project_manager", "footprint_wizard",
            ]
            #expect(scopes.allSatisfy(allowed.contains), "\(actionIdentifier): unknown scope")
            #expect(scopes.contains("schematic"), "\(actionIdentifier): not available in the schematic editor")

            let args = (action["args"] as? [String]) ?? []
            #expect(args.first == "--config")
            #expect(args.dropFirst().first == "ohmlab.json")
            if args.contains("--dry-run") {
                launchedPreview = true
            } else {
                launchedSync = true
            }
        }

        #expect(launchedSync, "missing the apply action")
        #expect(launchedPreview, "missing the preview action")
        #expect(KiCadCompanion.manifest().capabilities.dryRun)
    }

    @Test func launcherAndExampleConfigMatchTheManifest() throws {
        let launcher = try String(
            contentsOf: pluginDirectory.appendingPathComponent("ohmlab_sync.py"),
            encoding: .utf8
        )
        #expect(launcher.hasPrefix("#!/usr/bin/env python3"))
        #expect(launcher.contains("\"kicad\""))
        #expect(launcher.contains("\"sync\""))
        #expect(launcher.contains("--dry-run"))
        #expect(launcher.contains("--prefer"))

        let config = try jsonObject(at: pluginDirectory.appendingPathComponent("ohmlab.example.json"))
        #expect(config["kicad"] is String)
        #expect(config["bundle"] is String)
        #expect(config["direction"] as? String == "auto")
        #expect(config["prefer"] is NSNull)
        #expect(config["force"] as? Bool == false)
        #expect(config["ohm"] is String)
    }
}
