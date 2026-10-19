// ExampleCircuitsTests.swift
// Health checks driven by the example circuits shipped in `Examples/`.
//
// Each example carries a small header of directives in its comment block:
//
//     * @analysis dc
//     * @check dc v(2) = 5
//     * @check ac v(2) mag_db @ 1000 = -1.44507
//     * @check tran v(1) @ 500u = 0.5 rel=1e-2
//
// This suite discovers every `*.cir` file, solves it with the reference native
// engine (bypassing the process-global engine/plugin registries so the result is
// deterministic), and asserts the checks. `swift test` therefore doubles as an
// end-to-end health check of the example circuits and the engine.

import Foundation
import Testing
@testable import OhmLabCore

@Suite("Example circuits")
struct ExampleCircuitsTests {

    // MARK: - Discovery

    /// `…/Tests/OhmLabTests/ExampleCircuitsTests.swift` -> `…/Examples`.
    static var examplesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OhmLabTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Examples", isDirectory: true)
    }

    static func urls(withExtension ext: String) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: examplesDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return entries
            .filter { $0.pathExtension.lowercased() == ext }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static let exampleCircuitURLs = urls(withExtension: "cir")

    @Test("the Examples directory ships circuits")
    func examplesArePresent() {
        #expect(
            !Self.exampleCircuitURLs.isEmpty,
            "No .cir examples found under \(Self.examplesDirectory.path)"
        )
    }

    @Test(
        "each example solves and satisfies its @check directives",
        arguments: exampleCircuitURLs
    )
    func exampleIsHealthy(url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let file = url.lastPathComponent
        let directives = ExampleDirectives.parse(text)

        #expect(!directives.analyses.isEmpty, "\(file) declares no @analysis directive")
        #expect(!directives.checks.isEmpty, "\(file) declares no @check directive")

        let result = try NativeMNAEngine().solve(
            netlist: text,
            settings: directives.settings,
            libraries: []
        )

        for check in directives.checks {
            let value = try check.read(from: result, file: file)
            #expect(
                check.matches(value),
                "\(file): \(check.source) — got \(value), expected \(check.expected)"
            )
        }
    }

    @Test("the project bundle example is well formed and runs")
    func projectBundleExampleRuns() throws {
        let bundleURL = Self.examplesDirectory.appendingPathComponent(
            "07-project-bundle.ohmlabproj",
            isDirectory: true
        )
        let bundle = try ProjectBundleStore.read(from: bundleURL)
        #expect(bundle.isWellFormed, "the example bundle is missing a sheet")

        let document = try #require(bundle.activeDocument, "the bundle has no active document")
        let text = try #require(document.netlistText, "the sheet has no netlist text")

        let result = try NativeMNAEngine().solve(
            netlist: text,
            settings: AnalysisSettings.default,
            libraries: []
        )
        let midpoint = try #require(
            result.dc?.nodes.first { $0.name == "2" }?.voltage,
            "the bundle netlist produced no node 2 voltage"
        )
        #expect(abs(midpoint - 5) < 1e-9, "expected a 5 V midpoint, got \(midpoint)")
    }
}

// MARK: - Directive parsing

/// The `@analysis` / `@check` directives collected from one example's header.
struct ExampleDirectives {
    var analyses: [String] = []
    var checks: [ExampleCheck] = []

    static func parse(_ text: String) -> ExampleDirectives {
        var directives = ExampleDirectives()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("*") else { continue }
            var body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard body.hasPrefix("@") else { continue }
            body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)

            let tokens = body
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard let keyword = tokens.first?.lowercased() else { continue }

            switch keyword {
            case "analysis":
                if tokens.count >= 2 { directives.analyses.append(tokens[1].lowercased()) }
            case "check":
                if let check = ExampleCheck(tokens: Array(tokens.dropFirst()), source: line) {
                    directives.checks.append(check)
                }
            default:
                continue
            }
        }
        return directives
    }

    /// Analysis settings that run exactly the analyses the example declares,
    /// leaving the AC/transient parameters at their defaults so the netlist's own
    /// `.ac`/`.tran` cards drive the sweep.
    var settings: AnalysisSettings {
        var settings = AnalysisSettings.default
        settings.runDC = analyses.contains("dc")
        settings.runAC = analyses.contains("ac")
        settings.runTransient = analyses.contains("tran")
        settings.runDCSweep = false
        return settings
    }
}

/// One asserted probe value, e.g. `dc v(2) = 5` or `ac v(2) mag_db @ 1000 = -3`.
struct ExampleCheck {
    let analysis: String          // dc | ac | tran
    let probe: CircuitProbe
    let field: String?            // ac: mag_db | mag | phase_deg
    let dimension: Double?        // ac frequency, or transient time
    let expected: Double
    let absoluteTolerance: Double?
    let relativeTolerance: Double?
    let source: String

    init?(tokens: [String], source: String) {
        guard tokens.count >= 4 else { return nil }
        let analysis = tokens[0].lowercased()
        guard let probe = CircuitProbe.parse(tokens[1]) else { return nil }

        var index = 2
        var field: String?
        if tokens.indices.contains(index), tokens[index] != "=", tokens[index] != "@" {
            field = tokens[index].lowercased()
            index += 1
        }
        var dimension: Double?
        if tokens.indices.contains(index), tokens[index] == "@" {
            guard tokens.indices.contains(index + 1),
                  let value = SpiceNumber.parse(tokens[index + 1]) else { return nil }
            dimension = value
            index += 2
        }
        guard tokens.indices.contains(index), tokens[index] == "=",
              tokens.indices.contains(index + 1),
              let expected = SpiceNumber.parse(tokens[index + 1]) else { return nil }
        index += 2

        var absolute: Double?
        var relative: Double?
        while index < tokens.count {
            let token = tokens[index]
            if let equals = token.firstIndex(of: "=") {
                let key = String(token[..<equals]).lowercased()
                let raw = String(token[token.index(after: equals)...])
                if let value = SpiceNumber.parse(raw) {
                    switch key {
                    case "tol", "abs": absolute = value
                    case "rel": relative = value
                    default: break
                    }
                }
            }
            index += 1
        }

        self.analysis = analysis
        self.probe = probe
        self.field = field
        self.dimension = dimension
        self.expected = expected
        self.absoluteTolerance = absolute
        self.relativeTolerance = relative
        self.source = source
    }

    func matches(_ actual: Double) -> Bool {
        let tolerance: Double
        switch (absoluteTolerance, relativeTolerance) {
        case let (absolute?, relative?):
            tolerance = absolute + relative * abs(expected)
        case let (absolute?, nil):
            tolerance = absolute
        case let (nil, relative?):
            tolerance = relative * abs(expected)
        case (nil, nil):
            tolerance = 1e-3 * max(abs(expected), 1e-3)
        }
        return abs(actual - expected) <= tolerance
    }

    func read(from result: CircuitSimResult, file: String) throws -> Double {
        switch analysis {
        case "dc":
            guard let dc = result.dc else {
                throw ExampleCheckError("\(file): \(source) needs a DC operating point")
            }
            switch probe {
            case .nodeVoltage(let name):
                guard let node = dc.nodes.first(where: { Self.matches($0.name, name) }) else {
                    throw ExampleCheckError("\(file): no node \(name) in DC results")
                }
                return node.voltage
            case .elementCurrent(let name):
                if let component = dc.components.first(where: { Self.matches($0.name, name) }) {
                    return component.current
                }
                guard let source = dc.sources.first(where: { Self.matches($0.name, name) }) else {
                    throw ExampleCheckError("\(file): no element \(name) in DC results")
                }
                return source.current
            case .elementVoltage(let name):
                guard let component = dc.components.first(where: { Self.matches($0.name, name) }) else {
                    throw ExampleCheckError("\(file): no element \(name) in DC results")
                }
                return component.voltage
            }

        case "ac":
            guard let ac = result.ac else {
                throw ExampleCheckError("\(file): \(source) needs an AC sweep")
            }
            let response: [FreqPoint]
            switch probe {
            case .nodeVoltage(let name):
                guard let series = ac.nodes.first(where: { Self.matches($0.name, name) }) else {
                    throw ExampleCheckError("\(file): no node \(name) in AC results")
                }
                response = series.response
            case .elementCurrent(let name), .elementVoltage(let name):
                guard let series = ac.components.first(where: { Self.matches($0.name, name) }) else {
                    throw ExampleCheckError("\(file): no element \(name) in AC results")
                }
                response = series.response
            }
            guard let frequency = dimension else {
                throw ExampleCheckError("\(file): \(source) has no @ <frequency>")
            }
            guard let point = response.min(by: {
                abs($0.freqHz - frequency) < abs($1.freqHz - frequency)
            }) else {
                throw ExampleCheckError("\(file): AC response for \(probe) is empty")
            }
            switch field ?? "mag_db" {
            case "mag_db": return point.magnitudeDb
            case "mag": return pow(10, point.magnitudeDb / 20)
            case "phase_deg", "phase": return point.phaseDeg
            default:
                throw ExampleCheckError("\(file): unknown AC field \(field ?? "")")
            }

        case "tran":
            guard let transient = result.transient else {
                throw ExampleCheckError("\(file): \(source) needs a transient analysis")
            }
            let series: [Double]
            switch probe {
            case .nodeVoltage(let name):
                guard let found = transient.nodes.first(where: { Self.matches($0.name, name) }) else {
                    throw ExampleCheckError("\(file): no node \(name) in transient results")
                }
                series = found.values
            case .elementCurrent(let name), .elementVoltage(let name):
                guard let found = transient.components.first(where: { Self.matches($0.name, name) }) else {
                    throw ExampleCheckError("\(file): no element \(name) in transient results")
                }
                series = found.values
            }
            guard let time = dimension else {
                throw ExampleCheckError("\(file): \(source) has no @ <time>")
            }
            guard let index = transient.times.indices.min(by: {
                abs(transient.times[$0] - time) < abs(transient.times[$1] - time)
            }), series.indices.contains(index) else {
                throw ExampleCheckError("\(file): transient series for \(probe) is empty")
            }
            return series[index]

        default:
            throw ExampleCheckError("\(file): unknown analysis \(analysis)")
        }
    }

    private static func matches(_ candidate: String, _ target: String) -> Bool {
        candidate.caseInsensitiveCompare(target) == .orderedSame
    }
}

/// A failure while evaluating an `@check` directive.
struct ExampleCheckError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
