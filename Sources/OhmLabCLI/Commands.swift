// Commands.swift
// Subcommands for `ohm`: project bundles, KiCad projects, sync, and the
// statistical / worst-case / optimisation analyses.
//
// The flat "run a netlist" behaviour stays in main.swift; these are dispatched
// when the first argument is a known subcommand.

import Foundation
import OhmLabCore

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
    static let names: Set<String> = ["project", "kicad", "sync", "monte-carlo", "corner", "optimize"]

    static func isCommand(_ token: String) -> Bool { names.contains(token) }

    static func run(_ arguments: [String]) -> Int32 {
        do {
            return try dispatch(arguments)
        } catch let error as CommandError {
            writeStderr("ohm: \(error.localizedDescription)\n")
            return error.exitCode
        } catch {
            writeStderr("ohm: \(error.localizedDescription)\n")
            return 1
        }
    }

    private static func dispatch(_ arguments: [String]) throws -> Int32 {
        switch arguments[0] {
        case "project": return try runProject(Array(arguments.dropFirst()))
        case "kicad": return try runKicad(Array(arguments.dropFirst()))
        case "sync": return try runSync(Array(arguments.dropFirst()))
        case "monte-carlo": return try runMonteCarlo(Array(arguments.dropFirst()))
        case "corner": return try runCorner(Array(arguments.dropFirst()))
        case "optimize": return try runOptimize(Array(arguments.dropFirst()))
        default:
            throw CommandError.usage("unknown command \(arguments[0])")
        }
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
            throw CommandError.usage("usage: ohm kicad <import|export> …")
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
        default:
            throw CommandError.usage("unknown kicad action \(action)")
        }
        return 0
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
            limits: limits
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
            probes: probes
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
        var goal: OptimizeGoal = .maximize
        var grid = 5
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
            case "--goal": goal = try parseGoal(try next(argument))
            case "--grid": grid = try intValue(try next(argument), flag: "--grid")
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

        guard let objective else { throw CommandError.usage("--probe is required (e.g. --probe v(out))") }
        let input = try loadInput(path: path, netlistText: netlistText, stdin: stdin)
        let result = try Optimization.run(OptimizeRequest(
            netlist: input.netlist,
            settings: input.settings,
            variables: variables,
            objective: objective,
            goal: goal,
            gridDivisions: grid
        ))

        if format == "json" {
            writeStdout(jsonString([
                "bestObjective": result.bestObjective,
                "bestValues": result.bestValues.mapKeys { $0 },
                "evaluations": result.evaluations,
                "failures": result.failures
            ]) + "\n")
        } else {
            writeStdout("Best \(objective.description) = \(number(result.bestObjective))"
                + "  (\(result.evaluations) evaluations, \(result.failures) failures)\n")
            for (name, value) in result.bestValues.sorted(by: { $0.key < $1.key }) {
                writeStdout("  \(name) = \(number(value))\n")
            }
        }
        return 0
    }

    // MARK: - Shared input

    private static func loadInput(
        path: String?,
        netlistText: String?,
        stdin: Bool
    ) throws -> (netlist: String, settings: AnalysisSettings) {
        let sources = [netlistText != nil, stdin, path != nil].filter { $0 }.count
        guard sources == 1 else {
            throw CommandError.usage(sources == 0
                ? "no input: pass a file, --netlist <text>, or - for stdin"
                : "provide exactly one input (file, --netlist, or stdin)")
        }
        if let netlistText { return (netlistText, .default) }
        if stdin {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else {
                throw CommandError.runtime("standard input is not valid UTF-8")
            }
            return (text, .default)
        }
        guard let path else { throw CommandError.usage("no input") }
        let url = URL(fileURLWithPath: path)

        // A project bundle is a directory, so dispatch on the extension before
        // trying to read it as a file.
        if url.pathExtension.lowercased() == ProjectBundleStore.bundleExtension {
            do {
                let bundle = try ProjectBundleStore.read(from: url)
                guard let file = bundle.activeDocument else {
                    throw CommandError.runtime("\(path) has no sheets")
                }
                return (try netlist(of: file), file.analysis)
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
                return (try netlist(of: file), file.analysis)
            } catch {
                throw CommandError.runtime("cannot open \(path): \(error.localizedDescription)")
            }
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw CommandError.runtime("\(path) is not valid UTF-8")
        }
        return (text, .default)
    }

    private static func netlist(of file: CircuitFile) throws -> String {
        if let text = file.netlistText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           file.usesSchematic != true {
            return text
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
        usage: ohm optimize <input> --var NAME=min:max --probe v(out) [options]

          --var R1=1k:10k          a variable range (repeatable)
          --probe v(out)           objective probe
          --goal max|min|target=V  optimisation goal (default max)
          --grid N                 coarse grid divisions per variable (default 5)
          -f, --format text|json   output format (default text)

        """)
    }
}

private extension Dictionary where Key == String, Value == Double {
    func mapKeys(_ transform: (String) -> String) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}
