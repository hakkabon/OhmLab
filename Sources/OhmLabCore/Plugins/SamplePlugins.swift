// SamplePlugins.swift
// Example plugins that exercise every extension point, and double as
// documentation for the plugin API.

import CoreGraphics
import Foundation

// MARK: - Built-in parts catalog

/// A small, safe built-in plugin: a Net Tie component (a 1 µΩ resistor used to
/// join two nets), a `kv` output exporter, and a high-voltage sanity check.
///
/// It never rewrites netlists, so installing it cannot change simulation
/// results — only add parts, a format, and (occasionally) a warning.
public struct SamplePartsPlugin: CircuitPlugin {
    public static let pluginID = "com.ohmlab.sample-parts"

    public init() {}

    public var id: String { Self.pluginID }
    public var name: String { "Sample Parts" }
    public var version: String { "1.0" }

    public func register(into manager: PluginManager) {
        manager.addComponent(ComponentDescriptor(
            id: "net-tie",
            prefix: "R",
            displayName: "Net Tie",
            symbol: .resistor,
            pins: [
                PinDescriptor(id: "1", name: "1", position: CGPoint(x: -40, y: 0)),
                PinDescriptor(id: "2", name: "2", position: CGPoint(x: 40, y: 0)),
            ],
            parameters: [
                ComponentParameterDescriptor(id: "resistance", name: "Resistance", unit: "Ω", defaultValue: 1e-6)
            ]
        ))
        manager.addExporter(KeyValueExporter())
        manager.addResultProcessor(HighVoltageSanityProcessor())
    }
}

/// Exports results as flat `key=value` lines — a minimal custom format that
/// demonstrates the exporter hook.
struct KeyValueExporter: ResultExporter {
    let id = "com.ohmlab.sample-parts.kv"
    let formatName = "kv"

    func export(_ result: CircuitSimResult) throws -> String {
        var lines: [String] = []
        if let dc = result.dc {
            for node in dc.nodes {
                lines.append("dc.node.\(node.name).voltage=\(node.voltage)")
            }
            for component in dc.components {
                lines.append("dc.\(component.name).current=\(component.current)")
            }
        }
        if let ac = result.ac {
            for signal in ac.nodes {
                for point in signal.response {
                    lines.append(
                        "ac.node.\(signal.name).\(point.freqHz).magnitudeDb=\(point.magnitudeDb)"
                    )
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Warns when any DC node magnitude looks physically implausible (a floating
/// node or a near-short), illustrating the result-processor hook.
struct HighVoltageSanityProcessor: SimulationResultProcessor {
    let id = "com.ohmlab.sample-parts.high-voltage"

    func process(_ result: CircuitSimResult, context: SimulationPostContext) -> CircuitSimResult {
        guard let dc = result.dc else { return result }
        let worst = dc.nodes.map { abs($0.voltage) }.max() ?? 0
        guard worst > 1e6 else { return result }
        var updated = result
        updated.warnings.append(
            "Sample plugin: a DC node reached \(String(format: "%.3g", worst)) V; check for floating nodes or shorts."
        )
        return updated
    }
}

// MARK: - Element-handler example (opt-in)

/// Demonstrates the netlist-processor hook: expands a custom `T<ref>` thermistor
/// device into an ordinary resistor so the engine can solve it.
///
/// This is intentionally **not** installed by default — rewriting `T…` lines
/// would shadow a legitimate SPICE transmission line — so it must be installed
/// explicitly (e.g. `PluginManager.shared.register(ThermistorPlugin())`).
public struct ThermistorPlugin: CircuitPlugin {
    public init() {}

    public var id: String { "com.ohmlab.thermistor-example" }
    public var name: String { "Thermistor (example)" }
    public var version: String { "1.0" }

    public func register(into manager: PluginManager) {
        manager.addComponent(ComponentDescriptor(
            id: "thermistor",
            prefix: "R",
            displayName: "Thermistor",
            symbol: .resistor,
            pins: [
                PinDescriptor(id: "1", name: "1", position: CGPoint(x: -40, y: 0)),
                PinDescriptor(id: "2", name: "2", position: CGPoint(x: 40, y: 0)),
            ],
            parameters: [
                ComponentParameterDescriptor(id: "resistance", name: "Resistance", unit: "Ω", defaultValue: 10_000)
            ]
        ))
        manager.addNetlistProcessor(ThermistorExpander())
    }
}

/// Rewrites `T<digits> <n+> <n-> <value>` lines to `R<digits> …`.
struct ThermistorExpander: SpiceNetlistProcessor {
    let id = "com.ohmlab.thermistor-example.expander"

    func process(_ netlist: String) throws -> String {
        let lines = netlist.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first, first == "T" || first == "t" else { return String(line) }
            let leading = String(line.prefix { $0 == " " || $0 == "\t" })
            let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // Require a reference like T1/T2 and at least a value token.
            guard tokens.count >= 4 else { return String(line) }
            let ref = String(tokens[0].dropFirst())
            guard !ref.isEmpty, ref.allSatisfy(\.isNumber) else { return String(line) }
            var rewritten = tokens
            rewritten[0] = "R" + ref
            return leading + rewritten.joined(separator: " ")
        }
        return lines.joined(separator: "\n")
    }
}

public extension PluginManager {
    /// Installs the built-in sample plugins. Idempotent.
    func installBuiltins() {
        if !plugins.contains(where: { $0.id == SamplePartsPlugin.pluginID }) {
            register(SamplePartsPlugin())
        }
    }
}
