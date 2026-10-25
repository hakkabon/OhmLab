// main.swift
// `ohm` — OhmLab's headless / batch front end.
//
// Runs a `.ohmlab` document or a SPICE netlist without launching the UI, and
// writes CSV or JSON results to stdout or a file. Exit status: 0 success,
// 1 simulation error, 2 usage error.

import Foundation
import OhmLabCore

private let toolVersion = OhmLabRelease.version

private let usage = """
ohm \(toolVersion) — OhmLab headless circuit simulator

USAGE:
  ohm [<input>] [options]

INPUT:
  <input>                  A .ohmlab document or a SPICE netlist file.
  --netlist <text>         Inline netlist text instead of a file.
  -                        Read the netlist from standard input.

OUTPUT:
  -o, --output <file>      Write results to <file> (default: stdout).
  -f, --format <fmt>       csv (default), json, or a plugin-provided format name.

PLUGINS:
  --plugins <dir>          Load JSON plugin manifests from <dir>.
  --no-plugins             Do not install the built-in sample plugins.

ANALYSIS:
  --analysis <list>        Comma-separated subset of dc, ac, tran.
                           Default: the document's settings, or the netlist's
                           .ac/.tran/.dc cards plus a DC operating point.
  --ac <type> <pts> <f1> <f2>   AC sweep type (dec|oct|lin), points, start, stop.
  --tran <step> <stop> [start]  Transient step, stop time, optional start.
  --dc <src> <start> <stop> <step>   DC sweep of an independent source.
                           Values accept SPICE suffixes (e.g. 1k, 10m, 1meg).

ENGINE:
  -e, --engine <name>      native (default) or numeric-core.
  -q, --quiet              Suppress warnings on stderr.
  -h, --help               Show this help.
  -V, --version            Show the version.

PROJECTS & ANALYSES:
  ohm engines                               Show backend capability matrix.
  ohm doctor [--json]                       Verify the stable production boundary.
  ohm verify [--json] [--seed <n>]          Run the numerical trust suite.
  ohm qualify-linear [--json]               Verify the linear-production backend.
  ohm qualify-nonlinear [--json]            Verify the nonlinear-production backend.
  ohm qualify-scale [--json]                Verify scaling, residuals, and dense limits.
  ohm qualify-platform [--json]             Verify the 2.0 portable protocol.
  ohm qualify-host [--json]                 Verify the 2.1 extracted host.
  ohm platform manifest [--pretty]          Describe the portable host.
  ohm platform run [--pretty] [--timeout-ms n]  Run one JSON request.
  ohm platform batch [--max-parallel n]     Run a bounded JSON request batch.
  ohm project info <bundle>                 Show a .ohmlabproj manifest.
  ohm project pack <bundle> -o <zip>        Pack a bundle into .ohmlabzip.
  ohm project unpack <zip> <dir>            Unpack an archive.
  ohm kicad import <file> -o <bundle>       Import a KiCad project.
  ohm kicad export <bundle> <dir>           Export a bundle + netlists.
  ohm sync <localDir> <remoteDir>           Two-way folder sync.
  ohm monte-carlo <input> --probe v(out)    Tolerance Monte Carlo.
  ohm corner <input> --probe v(out)         Worst-case corner sweep.
  ohm optimize <input> --var R1=1k:10k --probe v(out)
  (run `ohm <command> --help` for that command's options)

EXAMPLES:
  ohm divider.cir --analysis dc --format json
  ohm amp.ohmlab -f csv -o amp.csv
  cat filter.cir | ohm - --ac dec 20 1 1meg
  ohm --netlist "V1 1 0 5\\nR1 1 0 1k" --engine numeric-core
  ohm monte-carlo amp.cir --default-tol 5% --samples 500 --probe v(out)
  ohm optimize amp.cir --var R2=100:10k --probe v(out) --goal target=2.5
"""

// MARK: - Configuration

private struct Configuration {
    var inputPath: String?
    var netlistText: String?
    var readStdin = false
    var outputPath: String?
    var format: BatchOutputFormat = .csv
    var engine: String?
    var quiet = false
    var loadBuiltins = true
    var pluginsDirectory: String?

    /// Analysis selections parsed from flags; `nil` fields mean "not specified".
    var analyses: Set<String>?
    var ac: (type: FrequencySweepType, points: Int, start: Double, stop: Double)?
    var tran: (step: Double, stop: Double, start: Double)?
    var dcSweep: (source: String, start: Double, stop: Double, step: Double)?
}

private enum CLIError: LocalizedError {
    case usage(String)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message), .runtime(let message): return message
        }
    }
}

// MARK: - Parsing

private func parse(_ arguments: [String]) throws -> Configuration {
    var config = Configuration()
    var index = 0

    func next(_ flag: String) throws -> String {
        index += 1
        guard index < arguments.count else {
            throw CLIError.usage("missing value for \(flag)")
        }
        return arguments[index]
    }

    func number(_ token: String, flag: String) throws -> Double {
        guard let value = SpiceNumber.parse(token) else {
            throw CLIError.usage("\(flag): “\(token)” is not a number")
        }
        return value
    }

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "-h", "--help":
            print(usage)
            exit(0)
        case "-V", "--version":
            print("ohm \(toolVersion)")
            exit(0)
        case "--netlist":
            config.netlistText = try next(argument)
        case "-", "--stdin":
            config.readStdin = true
        case "-o", "--output":
            config.outputPath = try next(argument)
        case "-f", "--format":
            config.format = BatchOutputFormat(name: try next(argument))
        case "-e", "--engine":
            config.engine = try next(argument)
        case "-q", "--quiet":
            config.quiet = true
        case "--plugins":
            config.pluginsDirectory = try next(argument)
        case "--no-plugins":
            config.loadBuiltins = false
        case "--analysis":
            let raw = try next(argument).lowercased()
            let items = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            let valid: Set<String> = ["dc", "ac", "tran"]
            guard items.isSubset(of: valid), !items.isEmpty else {
                throw CLIError.usage("--analysis expects a comma-separated subset of dc, ac, tran")
            }
            config.analyses = items
        case "--ac":
            let typeToken = try next(argument).lowercased()
            let type: FrequencySweepType
            switch typeToken {
            case "dec": type = .dec
            case "oct": type = .oct
            case "lin": type = .lin
            default: throw CLIError.usage("--ac: sweep type must be dec, oct, or lin")
            }
            let pointsToken = try next(argument)
            guard let points = Int(pointsToken), points > 0 else {
                throw CLIError.usage("--ac: “\(pointsToken)” is not a positive point count")
            }
            let start = try number(next(argument), flag: "--ac")
            let stop = try number(next(argument), flag: "--ac")
            config.ac = (type, points, start, stop)
        case "--tran":
            let step = try number(next(argument), flag: "--tran")
            let stop = try number(next(argument), flag: "--tran")
            // An optional third argument is the start time; only consume it when
            // it looks like a number (otherwise it belongs to the next flag).
            var start = 0.0
            if index + 1 < arguments.count,
               !arguments[index + 1].hasPrefix("-"),
               let parsed = SpiceNumber.parse(arguments[index + 1]) {
                index += 1
                start = parsed
            }
            config.tran = (step, stop, start)
        case "--dc":
            let source = try next(argument)
            let start = try number(next(argument), flag: "--dc")
            let stop = try number(next(argument), flag: "--dc")
            let step = try number(next(argument), flag: "--dc")
            config.dcSweep = (source, start, stop, step)
        default:
            if argument.hasPrefix("-") && argument != "-" {
                throw CLIError.usage("unknown option \(argument)")
            }
            guard config.inputPath == nil else {
                throw CLIError.usage("more than one input was provided")
            }
            config.inputPath = argument
        }
        index += 1
    }

    return config
}

// MARK: - Input

private func loadInput(_ config: Configuration) throws -> BatchInput {
    let sources = [config.netlistText != nil, config.readStdin, config.inputPath != nil]
        .filter { $0 }.count
    guard sources == 1 else {
        throw CLIError.usage(sources == 0
            ? "no input: pass a file, --netlist <text>, or - for stdin"
            : "provide exactly one input (file, --netlist, or stdin)")
    }

    if let text = config.netlistText {
        return .netlist(text)
    }
    if config.readStdin {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            throw CLIError.runtime("standard input is not valid UTF-8")
        }
        return .netlist(text)
    }

    guard let path = config.inputPath else {
        throw CLIError.usage("no input")
    }
    let url = URL(fileURLWithPath: path)
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        throw CLIError.runtime("cannot read \(path): \(error.localizedDescription)")
    }

    if url.pathExtension.lowercased() == CircuitFileStore.fileExtension {
        do {
            return .document(try CircuitFileStore.decode(data))
        } catch {
            throw CLIError.runtime("cannot open \(path): \(error.localizedDescription)")
        }
    }
    guard let text = String(data: data, encoding: .utf8) else {
        throw CLIError.runtime("\(path) is not valid UTF-8")
    }
    return .netlist(text)
}

// MARK: - Settings

private func settings(for config: Configuration, input: BatchInput) -> AnalysisSettings? {
    let hasOverrides = config.analyses != nil || config.ac != nil
        || config.tran != nil || config.dcSweep != nil
    guard hasOverrides else { return nil }

    var settings: AnalysisSettings
    switch input {
    case .document(let file):
        settings = file.analysis
    case .netlist:
        settings = AnalysisSettings(
            runDC: true,
            runAC: false,
            acStartFrequency: 1,
            acStopFrequency: 1_000_000,
            acPointsPerDecade: 20
        )
    }

    if let analyses = config.analyses {
        settings.runDC = analyses.contains("dc")
        settings.runAC = analyses.contains("ac")
        settings.runTransient = analyses.contains("tran")
        settings.runDCSweep = false
    }
    if let ac = config.ac {
        settings.runAC = true
        settings.acSweepType = ac.type
        settings.acPointsPerDecade = ac.points
        settings.acStartFrequency = ac.start
        settings.acStopFrequency = ac.stop
    }
    if let tran = config.tran {
        settings.runTransient = true
        settings.tranStep = tran.step
        settings.tranStop = tran.stop
        settings.tranStart = tran.start
    }
    if let dc = config.dcSweep {
        settings.runDCSweep = true
        settings.dcSweepSource = dc.source
        settings.dcSweepStart = dc.start
        settings.dcSweepStop = dc.stop
        settings.dcSweepStep = dc.step
    }
    return settings
}

// MARK: - Main

private func execute(_ arguments: [String]) throws -> Int {
    let config = try parse(arguments)

    if config.loadBuiltins {
        PluginManager.shared.installBuiltins()
    }
    if let directory = config.pluginsDirectory {
        do {
            let added = try PluginManager.shared.loadManifests(in: URL(fileURLWithPath: directory))
            if !config.quiet {
                FileHandle.standardError.write(Data(
                    "ohm: loaded \(added.count) plugin component(s) from \(directory)\n".utf8
                ))
            }
        } catch {
            throw CLIError.runtime("cannot load plugins from \(directory): \(error.localizedDescription)")
        }
    }

    let input = try loadInput(config)

    let request = BatchRequest(
        input: input,
        format: config.format,
        engine: config.engine,
        settingsOverride: settings(for: config, input: input)
    )
    let outcome = try BatchRunner.run(request)

    if let outputPath = config.outputPath {
        do {
            try outcome.text.write(toFile: outputPath, atomically: true, encoding: .utf8)
        } catch {
            throw CLIError.runtime("cannot write \(outputPath): \(error.localizedDescription)")
        }
    } else {
        print(outcome.text)
    }

    if !config.quiet {
        for warning in outcome.warnings {
            FileHandle.standardError.write(Data("ohm: warning: \(warning)\n".utf8))
        }
    }
    return 0
}

let cliArguments = Array(CommandLine.arguments.dropFirst())
if let command = cliArguments.first, Subcommand.isCommand(command) {
    exit(await Subcommand.run(cliArguments))
}

do {
    exit(Int32(try execute(cliArguments)))
} catch let error as CLIError {
    FileHandle.standardError.write(Data("ohm: \(error.localizedDescription)\n".utf8))
    if case .usage = error {
        FileHandle.standardError.write(Data("\n\(usage)\n".utf8))
        exit(2)
    }
    exit(1)
} catch {
    FileHandle.standardError.write(Data("ohm: \(error.localizedDescription)\n".utf8))
    exit(1)
}
