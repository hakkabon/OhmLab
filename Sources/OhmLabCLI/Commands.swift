// Commands.swift
// Subcommands for `ohm`: project bundles, KiCad projects, sync, and the
// statistical / worst-case / optimisation analyses.
//
// The flat "run a netlist" behaviour stays in main.swift; these are dispatched
// when the first argument is a known subcommand.

import Foundation
import OhmLabCore
import OhmLabSimulationHost

enum CommandError: LocalizedError {
    case usage(String)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message), .runtime(let message): return message
        }
    }

    var exitCode: Int32 {
        if case .usage = self { return 2 }
        return 1
    }
}

enum Subcommand {
    static let names: Set<String> = [
        "engines", "doctor", "verify", "qualify-linear", "qualify-nonlinear", "qualify-scale", "qualify-platform", "qualify-host", "platform", "project", "kicad", "sync", "monte-carlo", "corner", "optimize", "thermal",
    ]

    static func isCommand(_ token: String) -> Bool { names.contains(token) }

    static func run(_ arguments: [String]) async -> Int32 {
        do {
            return try await dispatch(arguments)
        } catch let error as CommandError {
            writeStderr("ohm: \(error.localizedDescription)\n")
            return error.exitCode
        } catch {
            writeStderr("ohm: \(error.localizedDescription)\n")
            return 1
        }
    }

    private static func dispatch(_ arguments: [String]) async throws -> Int32 {
        switch arguments[0] {
        case "engines": return try runEngines(Array(arguments.dropFirst()))
        case "doctor": return try runDoctor(Array(arguments.dropFirst()))
        case "verify": return try runVerify(Array(arguments.dropFirst()))
        case "qualify-linear": return try runLinearQualification(Array(arguments.dropFirst()))
        case "qualify-nonlinear": return try runNonlinearQualification(Array(arguments.dropFirst()))
        case "qualify-scale": return try runScaleQualification(Array(arguments.dropFirst()))
        case "qualify-platform": return try runPlatformQualification(Array(arguments.dropFirst()))
        case "qualify-host": return try await runHostQualification(Array(arguments.dropFirst()))
        case "platform": return try await runPlatform(Array(arguments.dropFirst()))
        case "project": return try runProject(Array(arguments.dropFirst()))
        case "kicad": return try runKicad(Array(arguments.dropFirst()))
        case "sync": return try runSync(Array(arguments.dropFirst()))
        case "monte-carlo": return try runMonteCarlo(Array(arguments.dropFirst()))
        case "corner": return try runCorner(Array(arguments.dropFirst()))
        case "optimize": return try runOptimize(Array(arguments.dropFirst()))
        case "thermal": return try runThermal(Array(arguments.dropFirst()))
        default:
            throw CommandError.usage("unknown command \(arguments[0])")
        }
    }

    // MARK: - production boundary

    private static func runDoctor(_ arguments: [String]) throws -> Int32 {
        guard arguments.isEmpty || arguments == ["--json"] else {
            throw CommandError.usage("usage: ohm doctor [--json]")
        }
        let report = ProductionBoundary.report()
        if arguments == ["--json"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            guard let text = String(data: data, encoding: .utf8) else {
                throw CommandError.runtime("could not encode the production readiness report")
            }
            writeStdout(text + "\n")
        } else {
            writeStdout("OhmLab \(report.productVersion) production boundary\n")
            writeStdout("  default: \(report.defaultBackend)\n")
            for backend in report.backends {
                let state = backend.maturity.rawValue
                let version = backend.implementationVersion.map { " \($0)" } ?? ""
                writeStdout("  \(backend.identifier): \(state)\(version)\n")
                if backend.lifecycle == .deprecated {
                    let removal = backend.removalVersion.map { ", removal \($0)" } ?? ""
                    writeStdout("    deprecated\(removal): \(backend.deprecationMessage ?? "migration required")\n")
                }
                for issue in backend.issues { writeStdout("    issue: \(issue)\n") }
            }
            writeStdout(report.ready ? "READY\n" : "NOT READY\n")
        }
        return report.ready ? 0 : 1
    }

    // MARK: - numerical trust

    private static func runVerify(_ arguments: [String]) throws -> Int32 {
        var json = false
        var seed = NumericalTrust.defaultSeed
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--json":
                json = true
            case "--seed":
                index += 1
                guard index < arguments.count, let parsed = UInt64(arguments[index]) else {
                    throw CommandError.usage("usage: ohm verify [--json] [--seed <unsigned-integer>]")
                }
                seed = parsed
            default:
                throw CommandError.usage("usage: ohm verify [--json] [--seed <unsigned-integer>]")
            }
            index += 1
        }

        let report = NumericalTrust.evaluate(seed: seed)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            guard let text = String(data: data, encoding: .utf8) else {
                throw CommandError.runtime("could not encode the numerical-trust report")
            }
            writeStdout(text + "\n")
        } else {
            writeStdout("OhmLab numerical trust v\(report.contractVersion)\n")
            writeStdout("  seed: \(report.seed), cases: \(report.caseCount)\n")
            for backend in report.backends {
                let passed = backend.cases.filter(\.passed).count
                let role = backend.required ? "required" : "informational"
                writeStdout("  \(backend.identifier): \(passed)/\(backend.cases.count) (\(role))\n")
            }
            for issue in report.issues { writeStdout("  issue: \(issue)\n") }
            writeStdout(report.ready ? "TRUSTED\n" : "NOT TRUSTED\n")
        }
        return report.ready ? 0 : 1
    }

    // MARK: - linear backend graduation

    private static func runLinearQualification(_ arguments: [String]) throws -> Int32 {
        guard arguments.isEmpty || arguments == ["--json"] else {
            throw CommandError.usage("usage: ohm qualify-linear [--json]")
        }
        let report = LinearBackendGraduation.evaluate()
        if arguments == ["--json"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            guard let text = String(data: data, encoding: .utf8) else {
                throw CommandError.runtime("could not encode the linear-backend qualification report")
            }
            writeStdout(text + "\n")
        } else {
            writeStdout("OhmLab linear backend graduation v\(report.contractVersion)\n")
            for backend in report.backends {
                let passed = backend.transientCases.filter(\.passed).count
                writeStdout("  \(backend.identifier): DC/AC \(backend.numericalTrustPassed ? "pass" : "fail"), transient \(passed)/\(backend.transientCases.count)\n")
            }
            for issue in report.issues { writeStdout("  issue: \(issue)\n") }
            writeStdout(report.ready ? "GRADUATED\n" : "NOT GRADUATED\n")
        }
        return report.ready ? 0 : 1
    }

    // MARK: - nonlinear convergence

    private static func runNonlinearQualification(_ arguments: [String]) throws -> Int32 {
        guard arguments.isEmpty || arguments == ["--json"] else {
            throw CommandError.usage("usage: ohm qualify-nonlinear [--json]")
        }
        let report = NonlinearConvergence.evaluate()
        if arguments == ["--json"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            guard let text = String(data: data, encoding: .utf8) else {
                throw CommandError.runtime("could not encode the nonlinear-convergence report")
            }
            writeStdout(text + "\n")
        } else {
            let passed = report.cases.filter(\.passed).count
            writeStdout("OhmLab nonlinear convergence v\(report.contractVersion)\n")
            writeStdout("  \(report.backend): \(passed)/\(report.cases.count) cases\n")
            for issue in report.issues { writeStdout("  issue: \(issue)\n") }
            writeStdout(report.ready ? "CONVERGED\n" : "NOT CONVERGED\n")
        }
        return report.ready ? 0 : 1
    }

    // MARK: - scale and numerical robustness

    private static func runScaleQualification(_ arguments: [String]) throws -> Int32 {
        guard arguments.isEmpty || arguments == ["--json"] else {
            throw CommandError.usage("usage: ohm qualify-scale [--json]")
        }
        let report = ScaleAndNumericalRobustness.evaluate()
        if arguments == ["--json"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            guard let text = String(data: data, encoding: .utf8) else {
                throw CommandError.runtime("could not encode the scale qualification report")
            }
            writeStdout(text + "\n")
        } else {
            let passed = report.cases.filter(\.passed).count
            writeStdout("OhmLab scale and numerical robustness v\(report.contractVersion)\n")
            writeStdout("  \(report.backend): \(passed)/\(report.cases.count), dense limit \(report.maximumDenseUnknowns)\n")
            for issue in report.issues { writeStdout("  issue: \(issue)\n") }
            writeStdout(report.ready ? "ROBUST\n" : "NOT ROBUST\n")
        }
        return report.ready ? 0 : 1
    }

    // MARK: - portable simulation platform

    private static func runPlatformQualification(_ arguments: [String]) throws -> Int32 {
        guard arguments.isEmpty || arguments == ["--json"] else {
            throw CommandError.usage("usage: ohm qualify-platform [--json]")
        }
        let report = PortablePlatformQualification.evaluate()
        if arguments == ["--json"] {
            let data = try PortableSimulationPlatform.encode(report, pretty: true)
            writeStdout(String(decoding: data, as: UTF8.self) + "\n")
        } else {
            let passed = report.cases.filter(\.passed).count
            writeStdout("OhmLab portable platform qualification v\(report.contractVersion)\n")
            writeStdout("  protocol v\(report.protocolVersion): \(passed)/\(report.cases.count) cases\n")
            for issue in report.issues { writeStdout("  issue: \(issue)\n") }
            writeStdout(report.ready ? "PORTABLE\n" : "NOT PORTABLE\n")
        }
        return report.ready ? 0 : 1
    }

    private static func runHostQualification(_ arguments: [String]) async throws -> Int32 {
        guard arguments.isEmpty || arguments == ["--json"] else {
            throw CommandError.usage("usage: ohm qualify-host [--json]")
        }
        let report = await PlatformExtractionQualification.evaluate()
        if arguments == ["--json"] {
            let data = try SimulationHostContract.encode(report, pretty: true)
            writeStdout(String(decoding: data, as: UTF8.self) + "\n")
        } else {
            let passed = report.cases.filter(\.passed).count
            writeStdout("OhmLab platform extraction v\(report.contractVersion)\n")
            writeStdout("  \(passed)/\(report.cases.count) cases\n")
            for issue in report.issues { writeStdout("  issue: \(issue)\n") }
            writeStdout(report.ready ? "HOST READY\n" : "HOST NOT READY\n")
        }
        return report.ready ? 0 : 1
    }

    private static func runPlatform(_ arguments: [String]) async throws -> Int32 {
        guard let action = arguments.first else {
            throw CommandError.usage("usage: ohm platform <manifest|run|batch> [options]")
        }
        let options = Array(arguments.dropFirst())
        var pretty = false
        var timeoutMilliseconds: Int?
        var maximumParallelism = 1
        var index = 0
        while index < options.count {
            switch options[index] {
            case "--pretty": pretty = true
            case "--timeout-ms":
                index += 1
                guard index < options.count, let value = Int(options[index]), value > 0 else {
                    throw CommandError.usage("--timeout-ms requires a positive integer")
                }
                timeoutMilliseconds = value
            case "--max-parallel":
                index += 1
                guard index < options.count, let value = Int(options[index]), (1...32).contains(value) else {
                    throw CommandError.usage("--max-parallel requires an integer from 1 through 32")
                }
                maximumParallelism = value
            default:
                throw CommandError.usage("usage: ohm platform <manifest|run|batch> [options]")
            }
            index += 1
        }
        let policy = SimulationExecutionPolicy(
            timeoutMilliseconds: timeoutMilliseconds,
            maximumParallelism: maximumParallelism
        )
        switch action {
        case "manifest":
            guard timeoutMilliseconds == nil, maximumParallelism == 1 else {
                throw CommandError.usage("platform manifest accepts only --pretty")
            }
            let data = try PortableSimulationPlatform.encode(OhmLabSimulationHost.manifest, pretty: pretty)
            writeStdout(String(decoding: data, as: UTF8.self) + "\n")
            return 0
        case "run":
            let input = try readPortableRequest()
            let response = await OhmLabSimulationHost.execute(input, policy: policy)
            let data = try PortableSimulationPlatform.encode(response, pretty: pretty)
            writeStdout(String(decoding: data, as: UTF8.self) + "\n")
            return response.succeeded ? 0 : 1
        case "batch":
            let input = try readPortableRequest()
            let batch = try SimulationHostContract.decode(PortableSimulationBatchRequest.self, from: input)
            let response = await OhmLabSimulationHost.executeBatch(batch, policy: policy)
            let data = try SimulationHostContract.encode(response, pretty: pretty)
            writeStdout(String(decoding: data, as: UTF8.self) + "\n")
            let allSucceeded = response.error == nil && response.items.allSatisfy {
                $0.state == .executed && $0.response?.succeeded == true
            }
            return allSucceeded ? 0 : 1
        default:
            throw CommandError.usage("usage: ohm platform <manifest|run|batch> [options]")
        }
    }

    /// Reads no more than the contract limit plus one sentinel byte. This
    /// prevents an untrusted stdin producer from forcing unbounded allocation
    /// before the protocol's size check can run.
    private static func readPortableRequest() throws -> Data {
        let maximum = PortableSimulationPlatform.limits.maximumRequestBytes
        var data = Data()
        while data.count <= maximum {
            let remaining = maximum + 1 - data.count
            guard let chunk = try FileHandle.standardInput.read(upToCount: min(64 * 1_024, remaining)),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data
    }

    // MARK: - engines

    private static func runEngines(_ arguments: [String]) throws -> Int32 {
        guard arguments.isEmpty || arguments == ["--json"] else {
            throw CommandError.usage("usage: ohm engines [--json]")
        }
        let matrix = EngineBackends.capabilityMatrix
        if arguments == ["--json"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(matrix)
            guard let text = String(data: data, encoding: .utf8) else {
                throw CommandError.runtime("could not encode the engine capability matrix")
            }
            writeStdout(text + "\n")
            return 0
        }
        for entry in matrix {
            let marker = entry.backendIdentifier == "native-mna" ? " (default)" : ""
            writeStdout("\(entry.backendIdentifier)\(marker)\n")
            writeStdout("  analyses: \(entry.analyses.map(\.rawValue).joined(separator: ", "))\n")
            writeStdout("  devices:  \(entry.devices.map(\.rawValue).joined(separator: ", "))\n")
            writeStdout("  features: \(entry.features.map(\.rawValue).joined(separator: ", "))\n")
        }
        return 0
    }

    // MARK: - project

    private static func runProject(_ arguments: [String]) throws -> Int32 {
        guard let action = arguments.first else {
            throw CommandError.usage("usage: ohm project <info|pack|unpack> …")
        }
        let rest = Array(arguments.dropFirst())
        switch action {
        case "info":
            guard let path = rest.first else { throw CommandError.usage("usage: ohm project info <bundle>") }
            let bundle = try ProjectBundleStore.read(from: URL(fileURLWithPath: path))
            printManifest(bundle.manifest)
        case "pack":
            guard let path = rest.first else {
                throw CommandError.usage("usage: ohm project pack <bundle> -o <out.ohmlabzip>")
            }
            let output = try optionValue(rest, ["-o", "--output"])
                ?? (path as NSString).deletingPathExtension + "." + ProjectBundleStore.archiveExtension
            let bundle = try ProjectBundleStore.read(from: URL(fileURLWithPath: path))
            try ProjectBundleStore.archive(bundle, to: URL(fileURLWithPath: output))
            writeStdout("Wrote \(output)\n")
        case "unpack":
            guard rest.count >= 2 else {
                throw CommandError.usage("usage: ohm project unpack <archive.ohmlabzip> <directory>")
            }
            let bundle = try ProjectBundleStore.unarchive(from: URL(fileURLWithPath: rest[0]))
            try ProjectBundleStore.write(bundle, to: URL(fileURLWithPath: rest[1]))
            writeStdout("Wrote \(rest[1])\n")
        default:
            throw CommandError.usage("unknown project action \(action)")
        }
        return 0
    }

    // MARK: - kicad

    private static func runKicad(_ arguments: [String]) throws -> Int32 {
        guard let action = arguments.first else {
            throw CommandError.usage("usage: ohm kicad <import|export|companion|status|sync> …")
        }
        let rest = Array(arguments.dropFirst())
        switch action {
        case "import":
            guard let path = rest.first else {
                throw CommandError.usage("usage: ohm kicad import <project.kicad_pro|.kicad_sch> -o <bundle.ohmlabproj>")
            }
            let source = URL(fileURLWithPath: path)
            let output = try optionValue(rest, ["-o", "--output"])
                ?? source.deletingPathExtension().lastPathComponent + "." + ProjectBundleStore.bundleExtension
            let bundle = try KiCadProjectInterchange.importProject(at: source)
            try ProjectBundleStore.write(bundle, to: URL(fileURLWithPath: output))
            writeStdout("Imported \(path) → \(output)\n")
        case "export":
            guard rest.count >= 2 else {
                throw CommandError.usage("usage: ohm kicad export <bundle> <directory>")
            }
            let bundle = try ProjectBundleStore.read(from: URL(fileURLWithPath: rest[0]))
            let written = try KiCadProjectInterchange.exportProject(bundle, to: URL(fileURLWithPath: rest[1]))
            for url in written { writeStdout("\(url.path)\n") }
        case "companion":
            guard rest.isEmpty || rest == ["--json"] else {
                throw CommandError.usage("usage: ohm kicad companion [--json]")
            }
            let manifest = KiCadCompanion.manifest()
            if rest == ["--json"] {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(manifest)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw CommandError.runtime("could not encode the KiCad companion manifest")
                }
                writeStdout(text + "\n")
            } else {
                writeStdout("OhmLab \(manifest.productVersion) KiCad companion v\(manifest.contractVersion)\n")
                writeStdout("  production boundary: v\(manifest.productionBoundary)\n")
                writeStdout("  project: \(manifest.projectExtensions.joined(separator: ", "))\n")
                writeStdout("  schematic: \(manifest.schematicExtensions.joined(separator: ", "))\n")
                writeStdout("  directions: \(manifest.directions.joined(separator: ", "))\n")
                writeStdout("  preferences: \(manifest.preferences.joined(separator: ", "))\n")
                writeStdout("  state: \(manifest.stateFileName)\n")
            }
        case "status":
            let (positionals, json) = try kicadPositionals(rest, flags: ["--json"])
            guard positionals.count == 2 else {
                throw CommandError.usage("usage: ohm kicad status <kicadPath> <bundle> [--json]")
            }
            let status = try KiCadCompanion.status(
                kicad: URL(fileURLWithPath: positionals[0]),
                bundle: URL(fileURLWithPath: positionals[1])
            )
            if json {
                writeStdout(try encodeJSON(status) + "\n")
            } else {
                writeStdout("KiCad  \(shortDigest(status.kicadDigest))  \(status.kicadPath)\n")
                writeStdout("OhmLab \(shortDigest(status.bundleDigest))  \(status.bundlePath)\n")
                if let state = status.state {
                    writeStdout("State  \(state.direction) at \(state.syncedAt)\n")
                } else {
                    writeStdout("State  none\n")
                }
                writeStdout("Changes  KiCad \(status.kicadChanged ? "changed" : "unchanged"), OhmLab \(status.bundleChanged ? "changed" : "unchanged")\n")
                writeStdout("Recommendation  \(status.recommendation.rawValue)\n")
            }
        case "sync":
            let (positionals, options) = try kicadSyncOptions(rest)
            guard positionals.count == 2 else {
                throw CommandError.usage("usage: ohm kicad sync <kicadPath> <bundle> [--direction import|export|auto] [--prefer kicad|ohmlab] [--force] [--dry-run] [--json]")
            }
            let direction: KiCadSyncDirection
            if let raw = options.direction {
                guard let parsed = KiCadSyncDirection(rawValue: raw) else {
                    throw CommandError.usage("--direction expects import, export, or auto (got “\(raw)”)")
                }
                direction = parsed
            } else {
                direction = .auto
            }
            let prefer: KiCadSyncPreference?
            if let raw = options.prefer {
                guard let parsed = KiCadSyncPreference(rawValue: raw) else {
                    throw CommandError.usage("--prefer expects kicad or ohmlab (got “\(raw)”)")
                }
                prefer = parsed
            } else {
                prefer = nil
            }
            if options.dryRun {
                let plan = try KiCadCompanion.plan(
                    kicad: URL(fileURLWithPath: positionals[0]),
                    bundle: URL(fileURLWithPath: positionals[1]),
                    direction: direction,
                    prefer: prefer,
                    force: options.force
                )
                if options.json {
                    writeStdout(try encodeJSON(plan) + "\n")
                } else {
                    writeStdout("Plan  \(plan.direction)\n")
                    writeStdout("  KiCad \(plan.kicadChanged ? "changed" : "unchanged"), OhmLab \(plan.bundleChanged ? "changed" : "unchanged")\n")
                    for change in plan.changes {
                        writeStdout("  \(planSymbol(change)) \(change.kind) \(change.identifier) [\(change.sheet)]\(planFields(change)) — \(change.source)\n")
                    }
                    for conflict in plan.conflicts {
                        writeStdout("  ! \(conflict.description)\n")
                    }
                    writeStdout(plan.applicable ? "Applicable\n" : "Not applicable\n")
                }
                for warning in plan.warnings { writeStderr("ohm: warning: \(warning)\n") }
                return plan.applicable ? 0 : 2
            }

            let result = try KiCadCompanion.sync(
                kicad: URL(fileURLWithPath: positionals[0]),
                bundle: URL(fileURLWithPath: positionals[1]),
                direction: direction,
                prefer: prefer,
                force: options.force
            )
            if options.json {
                writeStdout(try encodeJSON(result) + "\n")
            } else if result.direction == "none" {
                writeStdout("Already in sync; companion state refreshed.\n")
            } else {
                writeStdout("Synced \(result.direction)  \(positionals[0]) ↔ \(positionals[1])\n")
                writeStdout("  KiCad  \(shortDigest(result.kicadDigest))\n")
                writeStdout("  OhmLab \(shortDigest(result.bundleDigest))\n")
                writeStdout("  wrote \(result.writtenFiles.count) file(s)\n")
            }
            for warning in result.warnings { writeStderr("ohm: warning: \(warning)\n") }
        default:
            throw CommandError.usage("unknown kicad action \(action)")
        }
        return 0
    }

    private struct KiCadSyncOptions {
        var direction: String?
        var prefer: String?
        var force = false
        var dryRun = false
        var json = false
    }

    private static func planSymbol(_ change: KiCadObjectChange) -> String {
        switch change.change {
        case .added: return "+"
        case .updated: return "~"
        case .removed: return "-"
        }
    }

    private static func planFields(_ change: KiCadObjectChange) -> String {
        change.fields.isEmpty ? "" : " (\(change.fields.joined(separator: ", ")))"
    }

    private static func kicadPositionals(
        _ arguments: [String],
        flags: Set<String>
    ) throws -> ([String], Bool) {
        var positionals: [String] = []
        var json = false
        for argument in arguments {
            if flags.contains(argument) {
                json = argument == "--json" || json
            } else if argument.hasPrefix("-") {
                throw CommandError.usage("unknown option \(argument)")
            } else {
                positionals.append(argument)
            }
        }
        return (positionals, json)
    }

    private static func kicadSyncOptions(
        _ arguments: [String]
    ) throws -> ([String], KiCadSyncOptions) {
        var positionals: [String] = []
        var options = KiCadSyncOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json":
                options.json = true
            case "--force":
                options.force = true
            case "--dry-run":
                options.dryRun = true
            case "--direction", "--prefer":
                index += 1
                guard index < arguments.count else {
                    throw CommandError.usage("missing value for \(argument)")
                }
                if argument == "--direction" {
                    options.direction = arguments[index]
                } else {
                    options.prefer = arguments[index]
                }
            default:
                if argument.hasPrefix("-") {
                    throw CommandError.usage("unknown option \(argument)")
                }
                positionals.append(argument)
            }
            index += 1
        }
        return (positionals, options)
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CommandError.runtime("could not encode the JSON result")
        }
        return text
    }

    private static func shortDigest(_ digest: String) -> String {
        String(digest.prefix(12))
    }

    // MARK: - sync

    private static func runSync(_ arguments: [String]) throws -> Int32 {
        guard arguments.count >= 2 else {
            throw CommandError.usage("usage: ohm sync <localDir> <remoteDir>")
        }
        let localURL = URL(fileURLWithPath: arguments[0])
        let remoteURL = URL(fileURLWithPath: arguments[1])
        let local = LocalFolderBackend(rootURL: localURL, name: "local")
        let remote = LocalFolderBackend(rootURL: remoteURL, name: "remote")
        let state = SyncStateStore.load(from: localURL)

        let outcome = try ProjectSync.sync(local: local, remote: remote, state: state)
        try SyncStateStore.save(outcome.state, to: localURL)

        let report = outcome.report
        writeStdout(report.summary + "\n")
        for path in report.uploaded { writeStdout("  ↑ \(path)\n") }
        for path in report.downloaded { writeStdout("  ↓ \(path)\n") }
        for path in report.removedRemote { writeStdout("  ✗ remote \(path)\n") }
        for path in report.removedLocal { writeStdout("  ✗ local \(path)\n") }
        for path in report.conflicts { writeStdout("  ⚠ conflict \(path)\n") }
        return 0
    }

    // MARK: - analyses

    private static func runMonteCarlo(_ arguments: [String]) throws -> Int32 {
        var path: String?
        var netlistText: String?
        var stdin = false
        var tolerances: [ComponentTolerance] = []
        var defaultTolerance: ComponentTolerance?
        var samples = 1000
        var seed: UInt64 = 1
        var temperature: Double?
        var temperatureTolerance: Double?
        var probes: [CircuitProbe] = []
        var limits: [ProbeLimit] = []
        var format = "text"

        var index = 0
        func next(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw CommandError.usage("missing value for \(flag)") }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help": printMonteCarloUsage(); return 0
            case "--netlist": netlistText = try next(argument)
            case "-", "--stdin": stdin = true
            case "--tol": tolerances.append(try parseTolerance(try next(argument)))
            case "--default-tol": defaultTolerance = try parseTolerance("x=" + (try next(argument)))
            case "--samples": samples = try intValue(try next(argument), flag: "--samples")
            case "--seed": seed = try uintValue(try next(argument), flag: "--seed")
            case "--temp": temperature = try number(try next(argument), flag: "--temp")
            case "--temp-tol": temperatureTolerance = try number(try next(argument), flag: "--temp-tol")
            case "--probe": probes.append(try probe(try next(argument)))
            case "--limit": limits.append(try parseLimit(try next(argument)))
            case "-f", "--format": format = try next(argument).lowercased()
            default:
                if argument.hasPrefix("-") && argument != "-" {
                    throw CommandError.usage("unknown option \(argument)")
                }
                guard path == nil else { throw CommandError.usage("more than one input was provided") }
                path = argument
            }
            index += 1
        }

        let input = try loadInput(path: path, netlistText: netlistText, stdin: stdin)
        let request = MonteCarloRequest(
            netlist: input.netlist,
            settings: input.settings,
            tolerances: tolerances,
            defaultTolerance: defaultTolerance,
            samples: samples,
            seed: seed,
            temperature: temperature,
            temperatureTolerance: temperatureTolerance,
            probes: probes,
            limits: limits,
            baseDirectory: input.baseDirectory
        )
        let result = try MonteCarloAnalysis.run(request)
        for warning in result.warnings { writeStderr("ohm: warning: \(warning)\n") }

        if format == "json" {
            let statistics = result.statistics.map { statistic -> [String: Any] in
                var entry: [String: Any] = [
                    "probe": statistic.probe.description,
                    "nominal": statistic.nominal,
                    "mean": statistic.mean,
                    "stddev": statistic.standardDeviation,
                    "min": statistic.minimum,
                    "max": statistic.maximum
                ]
                if let yield = statistic.yield { entry["yield"] = yield }
                return entry
            }
            writeStdout(jsonString([
                "trials": result.trials,
                "failures": result.failures,
                "seed": result.seed,
                "statistics": statistics
            ]) + "\n")
        } else {
            writeStdout("Monte Carlo: \(result.trials) trials, \(result.failures) failures, seed \(result.seed)\n")
            for statistic in result.statistics {
                let label = statistic.probe.description.padding(toLength: 12, withPad: " ", startingAt: 0)
                let yieldText = statistic.yield.map { "  yield=" + String(format: "%.1f%%", $0 * 100) } ?? ""
                writeStdout("\(label)  n=\(statistic.values.count)  nominal=\(number(statistic.nominal))"
                    + "  mean=\(number(statistic.mean))  sd=\(number(statistic.standardDeviation))"
                    + "  min=\(number(statistic.minimum))  max=\(number(statistic.maximum))"
                    + "\(yieldText)\n")
            }
        }
        return 0
    }

    private static func runCorner(_ arguments: [String]) throws -> Int32 {
        var path: String?
        var netlistText: String?
        var stdin = false
        var tolerances: [ComponentTolerance] = []
        var defaultTolerance: ComponentTolerance?
        var temperature: Double?
        var temperatureTolerance: Double?
        var probes: [CircuitProbe] = []
        var format = "text"

        var index = 0
        func next(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw CommandError.usage("missing value for \(flag)") }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help": printCornerUsage(); return 0
            case "--netlist": netlistText = try next(argument)
            case "-", "--stdin": stdin = true
            case "--tol": tolerances.append(try parseTolerance(try next(argument)))
            case "--default-tol": defaultTolerance = try parseTolerance("x=" + (try next(argument)))
            case "--temp": temperature = try number(try next(argument), flag: "--temp")
            case "--temp-tol": temperatureTolerance = try number(try next(argument), flag: "--temp-tol")
            case "--probe": probes.append(try probe(try next(argument)))
            case "-f", "--format": format = try next(argument).lowercased()
            default:
                if argument.hasPrefix("-") && argument != "-" {
                    throw CommandError.usage("unknown option \(argument)")
                }
                guard path == nil else { throw CommandError.usage("more than one input was provided") }
                path = argument
            }
            index += 1
        }

        let input = try loadInput(path: path, netlistText: netlistText, stdin: stdin)
        let result = try CornerAnalysis.run(CornerRequest(
            netlist: input.netlist,
            settings: input.settings,
            tolerances: tolerances,
            defaultTolerance: defaultTolerance,
            temperature: temperature,
            temperatureTolerance: temperatureTolerance,
            probes: probes,
            baseDirectory: input.baseDirectory
        ))
        for warning in result.warnings { writeStderr("ohm: warning: \(warning)\n") }

        if format == "json" {
            let extremes = result.extremes.map { extreme -> [String: Any] in
                [
                    "probe": extreme.probe.description,
                    "min": extreme.minimum,
                    "max": extreme.maximum,
                    "minCorner": extreme.minimumCorner.mapKeys { $0 },
                    "maxCorner": extreme.maximumCorner.mapKeys { $0 }
                ]
            }
            writeStdout(jsonString([
                "cornersEvaluated": result.cornersEvaluated,
                "failures": result.failures,
                "extremes": extremes
            ]) + "\n")
        } else {
            writeStdout("Worst-case corners: \(result.cornersEvaluated) evaluated, \(result.failures) failures\n")
            for extreme in result.extremes {
                let label = extreme.probe.description.padding(toLength: 12, withPad: " ", startingAt: 0)
                writeStdout("\(label)  min=\(number(extreme.minimum))  max=\(number(extreme.maximum))\n")
                writeStdout("    min corner: \(formatCorner(extreme.minimumCorner))\n")
                writeStdout("    max corner: \(formatCorner(extreme.maximumCorner))\n")
            }
        }
        return 0
    }

    private static func runOptimize(_ arguments: [String]) throws -> Int32 {
        var path: String?
        var netlistText: String?
        var stdin = false
        var variables: [OptimizeVariable] = []
        var objective: CircuitProbe?
        var metric: OptimizeMetric?
        var goal: OptimizeGoal = .maximize
        var grid = 5
        var tolerances: [ComponentTolerance] = []
        var defaultTolerance: ComponentTolerance?
        var temperature: Double?
        var temperatureTolerance: Double?
        var limits: [MetricLimit] = []
        var yieldSamples = 64
        var yieldSeed: UInt64 = 1
        var refineYield = true
        var format = "text"

        var index = 0
        func next(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw CommandError.usage("missing value for \(flag)") }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help": printOptimizeUsage(); return 0
            case "--netlist": netlistText = try next(argument)
            case "-", "--stdin": stdin = true
            case "--var": variables.append(try parseVariable(try next(argument)))
            case "--probe": objective = try probe(try next(argument))
            case "--metric": metric = try parseMetric(try next(argument))
            case "--goal": goal = try parseGoal(try next(argument))
            case "--grid": grid = try intValue(try next(argument), flag: "--grid")
            case "--tol": tolerances.append(try parseTolerance(try next(argument)))
            case "--default-tol": defaultTolerance = try parseTolerance("x=" + (try next(argument)))
            case "--temp": temperature = try number(try next(argument), flag: "--temp")
            case "--temp-tol": temperatureTolerance = try number(try next(argument), flag: "--temp-tol")
            case "--limit": limits.append(try parseMetricLimit(try next(argument)))
            case "--yield-samples": yieldSamples = try intValue(try next(argument), flag: "--yield-samples")
            case "--yield-seed": yieldSeed = try uintValue(try next(argument), flag: "--yield-seed")
            case "--no-yield-refine": refineYield = false
            case "-f", "--format": format = try next(argument).lowercased()
            default:
                if argument.hasPrefix("-") && argument != "-" {
                    throw CommandError.usage("unknown option \(argument)")
                }
                guard path == nil else { throw CommandError.usage("more than one input was provided") }
                path = argument
            }
            index += 1
        }

        guard metric != nil || objective != nil else {
            throw CommandError.usage(
                "an objective is required: --metric v(out), ac:v(out)@1k, "
                + "acdb:v(out)@1k, acph:v(out)@1k, or tran:v(out)@1m"
            )
        }
        let input = try loadInput(path: path, netlistText: netlistText, stdin: stdin)
        let specification = limits.isEmpty ? nil : YieldSpecification(
            tolerances: tolerances,
            defaultTolerance: defaultTolerance,
            samples: yieldSamples,
            seed: yieldSeed,
            temperature: temperature,
            temperatureTolerance: temperatureTolerance,
            limits: limits,
            refine: refineYield
        )
        let result = try Optimization.run(OptimizeRequest(
            netlist: input.netlist,
            settings: input.settings,
            variables: variables,
            objective: objective,
            metric: metric,
            goal: goal,
            yield: specification,
            gridDivisions: grid,
            baseDirectory: input.baseDirectory
        ))
        for warning in result.nominalYield?.warnings ?? [] {
            writeStderr("ohm: warning: \(warning)\n")
        }

        if format == "json" {
            var object: [String: Any] = [
                "metric": result.metric.description,
                "bestObjective": result.bestObjective,
                "bestValues": result.bestValues.mapKeys { $0 },
                "evaluations": result.evaluations,
                "failures": result.failures,
                "nominalBestObjective": result.nominalBestObjective,
                "nominalBestValues": result.nominalBestValues.mapKeys { $0 }
            ]
            if let nominalYield = result.nominalYield { object["nominalYield"] = jsonYield(nominalYield) }
            if let yield = result.yield { object["yield"] = jsonYield(yield) }
            writeStdout(jsonString(object) + "\n")
        } else {
            writeStdout("Best \(result.metric.description) = \(number(result.bestObjective))"
                + "  (\(result.evaluations) evaluations, \(result.failures) failures)\n")
            for (name, value) in result.bestValues.sorted(by: { $0.key < $1.key }) {
                writeStdout("  \(name) = \(number(value))\n")
            }
            if let nominalYield = result.nominalYield {
                writeStdout("Nominal yield: \(percent(nominalYield.overallYield))\n")
            }
            if let yield = result.yield {
                if result.nominalYield.map({ $0.overallYield != yield.overallYield }) == true {
                    writeStdout("Centred yield: \(percent(yield.overallYield))  (seed \(yield.seed),"
                        + " \(yield.trials) trials, \(yield.failures) failures)\n")
                } else {
                    writeStdout("Yield: \(percent(yield.overallYield))  (seed \(yield.seed),"
                        + " \(yield.trials) trials, \(yield.failures) failures)\n")
                }
                for statistic in yield.statistics {
                    writeStdout("  \(statistic.metric.description)  mean=\(number(statistic.mean))"
                        + "  min=\(number(statistic.minimum))  max=\(number(statistic.maximum))"
                        + "  yield=\(percent(statistic.yield))\n")
                }
            }
        }
        return 0
    }

    private static func jsonYield(_ report: YieldReport) -> [String: Any] {
        func finite(_ value: Double) -> Any {
            value.isFinite ? value : NSNull()
        }
        return [
            "overallYield": report.overallYield,
            "trials": report.trials,
            "failures": report.failures,
            "seed": report.seed,
            "limits": report.statistics.map { statistic -> [String: Any] in
                [
                    "metric": statistic.metric.description,
                    "mean": finite(statistic.mean),
                    "min": finite(statistic.minimum),
                    "max": finite(statistic.maximum),
                    "yield": statistic.yield
                ]
            },
            "warnings": report.warnings
        ]
    }

    private static func percent(_ value: Double) -> String {
        value.isFinite ? String(format: "%.1f%%", value * 100) : "—"
    }

    // MARK: - thermal

    private static func runThermal(_ arguments: [String]) throws -> Int32 {
        var path: String?
        var netlistText: String?
        var stdin = false
        var ambient = ThermalSpecification.defaultAmbientCelsius
        var defaultRja: Double?
        var format = "text"
        var componentOrder: [String] = []
        var componentMap: [String: ThermalComponent] = [:]
        var heatsinkOrder: [String] = []
        var heatsinkMap: [String: ThermalHeatsink] = [:]

        func updateComponent(_ designator: String, _ body: (inout ThermalComponent) -> Void) {
            let key = designator.uppercased()
            if componentMap[key] == nil { componentOrder.append(key) }
            var component = componentMap[key] ?? ThermalComponent(designator: designator)
            body(&component)
            componentMap[key] = component
        }

        var index = 0
        func next(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw CommandError.usage("missing value for \(flag)") }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                printThermalUsage()
                return 0
            case "--netlist":
                netlistText = try next(argument)
            case "-", "--stdin":
                stdin = true
            case "--ambient":
                ambient = try number(try next(argument), flag: "--ambient")
            case "--default-rja":
                defaultRja = try number(try next(argument), flag: "--default-rja")
            case "--rja":
                let (name, value) = try namedNumber(try next(argument), flag: "--rja")
                updateComponent(name) { $0.junctionToAmbient = value }
            case "--power":
                let (name, value) = try namedNumber(try next(argument), flag: "--power")
                updateComponent(name) { $0.powerWatts = value }
            case "--max-temp":
                let (name, value) = try namedNumber(try next(argument), flag: "--max-temp")
                updateComponent(name) { $0.maxTemperatureCelsius = value }
            case "--heatsink":
                let (name, value) = try namedNumber(try next(argument), flag: "--heatsink")
                let key = name.uppercased()
                if heatsinkMap[key] == nil { heatsinkOrder.append(key) }
                heatsinkMap[key] = ThermalHeatsink(name: name, thermalResistance: value)
            case "--mount":
                let (designator, heatsink, resistance) = try mountSpec(try next(argument))
                updateComponent(designator) {
                    $0.heatsink = heatsink
                    $0.junctionToCase = resistance
                }
            case "-f", "--format":
                format = try next(argument).lowercased()
            default:
                if argument.hasPrefix("-") && argument != "-" {
                    throw CommandError.usage("unknown option \(argument)")
                }
                guard path == nil else { throw CommandError.usage("more than one input was provided") }
                path = argument
            }
            index += 1
        }

        guard format == "text" || format == "json" else {
            throw CommandError.usage("--format expects text or json")
        }
        let components = componentOrder.compactMap { componentMap[$0] }
        guard !components.isEmpty else {
            throw CommandError.usage(
                "thermal analysis needs at least one --rja, --power, --max-temp, or --mount component"
            )
        }
        let specification = ThermalSpecification(
            ambientCelsius: ambient,
            defaultJunctionToAmbient: defaultRja,
            components: components,
            heatsinks: heatsinkOrder.compactMap { heatsinkMap[$0] }
        )
        let input = try loadInput(path: path, netlistText: netlistText, stdin: stdin)
        let result = try ThermalAnalysis.run(ThermalRequest(
            netlist: input.netlist,
            settings: input.settings,
            specification: specification,
            baseDirectory: input.baseDirectory
        ))
        if format == "json" {
            writeStdout(try encodeJSON(result) + "\n")
        } else {
            printThermalReport(result)
        }
        for warning in result.warnings { writeStderr("ohm: warning: \(warning)\n") }
        return 0
    }

    private static func printThermalReport(_ result: ThermalResult) {
        writeStdout("Thermal analysis (ambient \(number(result.ambientCelsius)) °C)\n")
        writeStdout("  designator\tpower(W)\ttemp(C)\trise(C)\trth(K/W)\tlimit\n")
        for component in result.components {
            let limit: String
            if let maximum = component.maxTemperatureCelsius {
                limit = number(maximum) + (component.exceedsLimit ? " EXCEEDED" : "")
            } else {
                limit = "—"
            }
            writeStdout("  \(component.designator)\t\(number(component.powerWatts))"
                + "\t\(number(component.temperatureCelsius))"
                + "\t\(number(component.temperatureRiseCelsius))"
                + "\t\(number(component.thermalResistance))"
                + "\t\(limit)\n")
        }
        for heatsink in result.heatsinks {
            writeStdout("  heatsink \(heatsink.name)\t\(number(heatsink.powerWatts)) W"
                + "\t\(number(heatsink.temperatureCelsius)) °C"
                + "\t\(number(heatsink.thermalResistance)) K/W\n")
        }
        writeStdout("Total power: \(number(result.totalPowerWatts)) W\n")
        if !result.components.contains(where: \.exceedsLimit) {
            writeStdout("All junction temperatures are within their limits.\n")
        }
    }

    // MARK: - Shared input

    private static func loadInput(
        path: String?,
        netlistText: String?,
        stdin: Bool
    ) throws -> (netlist: String, settings: AnalysisSettings, baseDirectory: URL?) {
        let sources = [netlistText != nil, stdin, path != nil].filter { $0 }.count
        guard sources == 1 else {
            throw CommandError.usage(sources == 0
                ? "no input: pass a file, --netlist <text>, or - for stdin"
                : "provide exactly one input (file, --netlist, or stdin)")
        }
        if let netlistText { return (netlistText, .default, nil) }
        if stdin {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else {
                throw CommandError.runtime("standard input is not valid UTF-8")
            }
            return (text, .default, nil)
        }
        guard let path else { throw CommandError.usage("no input") }
        let url = URL(fileURLWithPath: path)
        let containingDirectory = url.deletingLastPathComponent()

        // A project bundle is a directory, so dispatch on the extension before
        // trying to read it as a file.
        if url.pathExtension.lowercased() == ProjectBundleStore.bundleExtension {
            do {
                let bundle = try ProjectBundleStore.read(from: url)
                guard let file = bundle.activeDocument else {
                    throw CommandError.runtime("\(path) has no sheets")
                }
                let baseDirectory = file.importBaseDirectory.map {
                    URL(fileURLWithPath: $0)
                } ?? containingDirectory
                return (try netlist(of: file), file.analysis, baseDirectory)
            } catch let error as CommandError {
                throw error
            } catch {
                throw CommandError.runtime("cannot open \(path): \(error.localizedDescription)")
            }
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CommandError.runtime("cannot read \(path): \(error.localizedDescription)")
        }

        if url.pathExtension.lowercased() == CircuitFileStore.fileExtension {
            do {
                let file = try CircuitFileStore.decode(data)
                let baseDirectory = file.importBaseDirectory.map {
                    URL(fileURLWithPath: $0)
                } ?? containingDirectory
                return (try netlist(of: file), file.analysis, baseDirectory)
            } catch {
                throw CommandError.runtime("cannot open \(path): \(error.localizedDescription)")
            }
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw CommandError.runtime("\(path) is not valid UTF-8")
        }
        return (text, .default, containingDirectory)
    }

    private static func netlist(of file: CircuitFile) throws -> String {
        if file.usesSchematic != true {
            if let text = file.resolvedNetlistText,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            if let text = file.netlistText,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return try SpiceNetlistBuilder.build(snapshot: file.schematic)
    }

    // MARK: - Token parsing

    private static func optionValue(_ arguments: [String], _ flags: [String]) throws -> String? {
        guard let index = arguments.firstIndex(where: { flags.contains($0) }) else { return nil }
        guard index + 1 < arguments.count else {
            throw CommandError.usage("missing value for \(arguments[index])")
        }
        return arguments[index + 1]
    }

    private static func number(_ token: String, flag: String) throws -> Double {
        guard let value = SpiceNumber.parse(token) else {
            throw CommandError.usage("\(flag): “\(token)” is not a number")
        }
        return value
    }

    /// `NAME=VALUE` where value accepts SPICE numeric suffixes.
    private static func namedNumber(_ token: String, flag: String) throws -> (String, Double) {
        let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty else {
            throw CommandError.usage("\(flag) expects NAME=VALUE (got “\(token)”)")
        }
        guard let value = SpiceNumber.parse(parts[1]) else {
            throw CommandError.usage("\(flag): “\(parts[1])” is not a number")
        }
        return (parts[0], value)
    }

    /// `DESIGNATOR=HEATSINK:RESISTANCE` for `--mount`.
    private static func mountSpec(_ token: String) throws -> (String, String, Double) {
        let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty else {
            throw CommandError.usage("--mount expects DESIGNATOR=HEATSINK:K/W (got “\(token)”)")
        }
        let mount = parts[1].split(separator: ":", maxSplits: 1).map(String.init)
        guard mount.count == 2, !mount[0].isEmpty, let resistance = SpiceNumber.parse(mount[1]) else {
            throw CommandError.usage("--mount expects DESIGNATOR=HEATSINK:K/W (got “\(token)”)")
        }
        return (parts[0], mount[0], resistance)
    }

    private static func intValue(_ token: String, flag: String) throws -> Int {
        guard let value = Int(token) else { throw CommandError.usage("\(flag): “\(token)” is not an integer") }
        return value
    }

    private static func uintValue(_ token: String, flag: String) throws -> UInt64 {
        guard let value = UInt64(token) else { throw CommandError.usage("\(flag): “\(token)” is not a positive integer") }
        return value
    }

    /// `R1=5%` (relative) or `R1=10` (absolute), optional `,normal`/`,uniform`.
    static func parseTolerance(_ token: String) throws -> ComponentTolerance {
        let parts = token.split(separator: ",", maxSplits: 1).map(String.init)
        guard let pair = parts.first?.split(separator: "=", maxSplits: 1), pair.count == 2 else {
            throw CommandError.usage("--tol expects NAME=5% (got “\(token)”)")
        }
        let designator = String(pair[0])
        var raw = String(pair[1])
        var relative = 0.0
        var absolute = 0.0
        if raw.hasSuffix("%") {
            raw.removeLast()
            guard let value = Double(raw) else { throw CommandError.usage("bad tolerance “\(token)”") }
            relative = value / 100
        } else {
            guard let value = Double(raw) else { throw CommandError.usage("bad tolerance “\(token)”") }
            absolute = value
        }
        var distribution: ToleranceDistribution = .uniform
        if parts.count == 2 {
            guard let parsed = ToleranceDistribution(rawValue: parts[1].lowercased()) else {
                throw CommandError.usage("unknown distribution “\(parts[1])”")
            }
            distribution = parsed
        }
        return ComponentTolerance(
            designator: designator, relative: relative, absolute: absolute, distribution: distribution
        )
    }

    static func parseLimit(_ token: String) throws -> ProbeLimit {
        guard let equals = token.firstIndex(of: "=") else {
            throw CommandError.usage("--limit expects v(out)=min:max (got “\(token)”)")
        }
        let probeText = String(token[token.startIndex..<equals])
        guard let probe = CircuitProbe.parse(probeText) else {
            throw CommandError.usage("bad probe in --limit “\(probeText)”")
        }
        let range = token[token.index(after: equals)...]
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        guard range.count == 2 else { throw CommandError.usage("--limit expects min:max") }
        let minimum = range[0].isEmpty ? nil : Double(range[0])
        let maximum = range[1].isEmpty ? nil : Double(range[1])
        return ProbeLimit(probe: probe, minimum: minimum, maximum: maximum)
    }

    /// `v(out)`, `ac:v(out)@1k`, `acdb:v(out)@1k`, `acph:v(out)@1k`, or
    /// `tran:v(out)@1m`.
    static func parseMetric(_ token: String) throws -> OptimizeMetric {
        guard let metric = OptimizeMetric.parse(token) else {
            throw CommandError.usage(
                "--metric expects v(out), ac:v(out)@1k, acdb:v(out)@1k, "
                + "acph:v(out)@1k, or tran:v(out)@1m (got “\(token)”)"
            )
        }
        return metric
    }

    /// `ac:v(out)@1k=0.4:0.6` — a metric and its allowed range.
    static func parseMetricLimit(_ token: String) throws -> MetricLimit {
        guard let equals = token.firstIndex(of: "=") else {
            throw CommandError.usage("--limit expects METRIC=min:max (got “\(token)”)")
        }
        let metric = try parseMetric(String(token[token.startIndex..<equals]))
        let range = token[token.index(after: equals)...]
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        guard range.count == 2 else { throw CommandError.usage("--limit expects min:max") }
        var minimum: Double?
        var maximum: Double?
        if !range[0].isEmpty {
            guard let value = SpiceNumber.parse(range[0]) else {
                throw CommandError.usage("--limit: “\(range[0])” is not a number")
            }
            minimum = value
        }
        if !range[1].isEmpty {
            guard let value = SpiceNumber.parse(range[1]) else {
                throw CommandError.usage("--limit: “\(range[1])” is not a number")
            }
            maximum = value
        }
        return MetricLimit(metric: metric, minimum: minimum, maximum: maximum)
    }

    static func parseVariable(_ token: String) throws -> OptimizeVariable {
        guard let equals = token.firstIndex(of: "="),
              let colon = token[token.index(after: equals)...].firstIndex(of: ":") else {
            throw CommandError.usage("--var expects NAME=min:max (got “\(token)”)")
        }
        let designator = String(token[token.startIndex..<equals])
        let minText = String(token[token.index(after: equals)..<colon])
        let maxText = String(token[token.index(after: colon)...])
        guard let minimum = SpiceNumber.parse(minText), let maximum = SpiceNumber.parse(maxText) else {
            throw CommandError.usage("bad range in --var “\(token)”")
        }
        return OptimizeVariable(designator: designator, minimum: minimum, maximum: maximum)
    }

    static func parseGoal(_ token: String) throws -> OptimizeGoal {
        let lowered = token.lowercased()
        if lowered == "max" || lowered == "maximize" { return .maximize }
        if lowered == "min" || lowered == "minimize" { return .minimize }
        if lowered.hasPrefix("target=") {
            let raw = String(token.dropFirst("target=".count))
            guard let value = SpiceNumber.parse(raw) else { throw CommandError.usage("bad target “\(raw)”") }
            return .target(value)
        }
        throw CommandError.usage("--goal expects max, min, or target=VALUE")
    }

    private static func probe(_ token: String) throws -> CircuitProbe {
        guard let probe = CircuitProbe.parse(token) else {
            throw CommandError.usage("bad probe “\(token)” (expected v(node), i(element), or vi(element))")
        }
        return probe
    }

    // MARK: - Output helpers

    private static func printManifest(_ manifest: ProjectManifest) {
        writeStdout("Project: \(manifest.name)  (schema \(manifest.schemaVersion))\n")
        writeStdout("Sheets (\(manifest.sheets.count)):\n")
        for sheet in manifest.sheets {
            let active = sheet.id == manifest.activeSheetID ? " *" : ""
            writeStdout("  - \(sheet.name) [\(sheet.id)]  \(sheet.fileName)\(active)\n")
        }
        if !manifest.modelLibraries.isEmpty {
            writeStdout("Model libraries: \(manifest.modelLibraries.count)\n")
        }
        if let source = manifest.kicadSource {
            writeStdout("KiCad source: \(source.projectPath ?? source.topSchematic ?? "unknown")\n")
        }
    }

    private static func formatCorner(_ corner: [String: Double]) -> String {
        corner.keys.sorted()
            .map { "\($0)=\(number(corner[$0]!))" }
            .joined(separator: ", ")
    }

    /// A compact, locale-independent rendering of a value for console output.
    private static func number(_ value: Double) -> String {
        String(format: "%.6g", value)
    }

    private static func jsonString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private static func writeStdout(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    private static func writeStderr(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    // MARK: - Usage

    private static func printMonteCarloUsage() {
        writeStdout("""
        usage: ohm monte-carlo <input> --probe <p> [options]

          --tol NAME=5%[,normal]   tolerance for one component (repeatable)
          --default-tol 5%         tolerance for every unlisted passive
          --samples N              number of trials (default 1000)
          --seed N                 RNG seed (default 1)
          --temp T / --temp-tol D  ambient temperature (and its ± tolerance)
          --probe v(out)           probe to report (repeatable)
          --limit v(out)=min:max   yield band for a probe
          -f, --format text|json   output format (default text)

        """)
    }

    private static func printCornerUsage() {
        writeStdout("""
        usage: ohm corner <input> --probe <p> [options]

          --tol NAME=5%[,normal]   tolerance for one component (repeatable)
          --default-tol 5%         tolerance for every unlisted passive
          --temp T / --temp-tol D  ambient temperature (and its ± tolerance)
          --probe v(out)           probe to report (repeatable)
          -f, --format text|json   output format (default text)

        """)
    }

    private static func printOptimizeUsage() {
        writeStdout("""
        usage: ohm optimize <input> --var NAME=min:max --metric <m> [options]

          --var R1=1k:10k          a variable range (repeatable)
          --metric <m>             objective: v(out), ac:v(out)@1k,
                                   acdb:v(out)@1k, acph:v(out)@1k, tran:v(out)@1m
          --probe v(out)           DC objective probe (equivalent to --metric v(out))
          --goal max|min|target=V  optimisation goal (default max)
          --grid N                 coarse grid divisions per variable (default 5)

          Yield centring (enabled by --limit):
          --limit <m>=min:max      design specification for a metric (repeatable)
          --tol NAME=5%[,normal]   tolerance for one component (repeatable)
          --default-tol 5%         tolerance for every unlisted passive
          --temp T / --temp-tol D  ambient temperature (and its ± tolerance)
          --yield-samples N        trials per yield estimate (default 64)
          --yield-seed N           deterministic seed (default 1)
          --no-yield-refine        report yield without refining for it

          -f, --format text|json   output format (default text)

        """)
    }

    private static func printThermalUsage() {
        writeStdout("""
        usage: ohm thermal <input> [options]

          --ambient T              ambient temperature in °C (default 25)
          --default-rja K/W        junction-to-ambient for unlisted components
          --rja NAME=K/W           junction-to-ambient for one component (repeatable)
          --power NAME=W           explicit dissipated power (repeatable)
          --max-temp NAME=C        junction-temperature limit (repeatable)
          --heatsink NAME=K/W      shared heatsink resistance to ambient (repeatable)
          --mount NAME=HS:K/W      mount a component on a heatsink (repeatable)
          -f, --format text|json   output format (default text)

        Without --power, each component's power is abs(v * i) from the DC
        operating point. Every listed component needs a thermal path to ambient,
        either directly (--rja/--default-rja) or through --mount.

        """)
    }
}

private extension Dictionary where Key == String, Value == Double {
    func mapKeys(_ transform: (String) -> String) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}
