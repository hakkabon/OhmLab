// CircuitPlugin.swift
// OhmLab's extension points.
//
// A plugin is a small, `Sendable` value that declares a set of extensions when
// it is installed. Plugins are registered in process (no dynamic loading, which
// is not available on iPadOS); a plugin can be compiled into the app, the CLI,
// or a manifest loaded from disk (see `PluginManifest`).
//
// Four extension points are supported, each aimed at a real seam in the core:
//
//   • Components     — custom `ComponentDescriptor`s appear in the palette.
//   • Netlist         — `SpiceNetlistProcessor`s rewrite the netlist text before
//                       it is parsed, so custom devices can be macro-expanded
//                       into primitives the engine already understands.
//   • Results         — `SimulationResultProcessor`s annotate a finished result
//                       (e.g. add warnings).
//   • Export          — `ResultExporter`s add named output formats.

import Foundation

/// A bundle of extensions to the simulator.
public protocol CircuitPlugin: Sendable {
    /// A stable, unique identifier (reverse-DNS recommended).
    var id: String { get }
    /// A human-readable name.
    var name: String { get }
    /// The plugin's version string.
    var version: String { get }
    /// Install the plugin's extensions into `manager`.
    func register(into manager: PluginManager)
}

/// Rewrites a netlist before it is parsed. Return the replacement text; drop
/// nothing unless that is intended. Throwing aborts the simulation.
public protocol SpiceNetlistProcessor: Sendable {
    var id: String { get }
    func process(_ netlist: String) throws -> String
}

/// Where a finished result came from.
public struct SimulationPostContext: Sendable {
    /// `"netlist"` or `"schematic"`.
    public let source: String
    /// The identifier of the backend that produced the result.
    public let engine: String

    public init(source: String, engine: String) {
        self.source = source
        self.engine = engine
    }
}

/// Inspects and optionally annotates a finished result. Return the original
/// result unchanged, or a modified copy (typically with added warnings).
public protocol SimulationResultProcessor: Sendable {
    var id: String { get }
    func process(_ result: CircuitSimResult, context: SimulationPostContext) -> CircuitSimResult
}

/// Adds a named output format (e.g. Touchstone, raw files) that the CLI and
/// other front ends can select by name.
public protocol ResultExporter: Sendable {
    var id: String { get }
    /// The name callers use to select this format (e.g. `"kv"`).
    var formatName: String { get }
    func export(_ result: CircuitSimResult) throws -> String
}

/// A description of an installed plugin.
public struct PluginInfo: Sendable, Equatable {
    public let id: String
    public let name: String
    public let version: String
}

/// The process-wide plugin host. Install plugins before simulating; the façade
/// consults it on every solve.
public final class PluginManager: @unchecked Sendable {
    public static let shared = PluginManager()

    private let lock = NSLock()
    private var installed: [String: PluginInfo] = [:]
    private var netlistProcessors: [any SpiceNetlistProcessor] = []
    private var resultProcessors: [any SimulationResultProcessor] = []
    private var exporters: [String: any ResultExporter] = [:]

    private init() {}

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    // MARK: - Introspection

    public var plugins: [PluginInfo] {
        withLock { installed.values.sorted { $0.id < $1.id } }
    }

    public var netlistProcessorIDs: [String] {
        withLock { netlistProcessors.map(\.id) }
    }

    public var resultProcessorIDs: [String] {
        withLock { resultProcessors.map(\.id) }
    }

    public var exporterFormatNames: [String] {
        withLock { exporters.keys.sorted() }
    }

    // MARK: - Registration

    /// Installs `plugin`, then records it.
    public func register(_ plugin: any CircuitPlugin) {
        plugin.register(into: self)
        withLock {
            installed[plugin.id] = PluginInfo(id: plugin.id, name: plugin.name, version: plugin.version)
        }
    }

    /// Adds (or replaces) a component descriptor.
    @discardableResult
    public func addComponent(_ descriptor: ComponentDescriptor) -> Bool {
        ComponentRegistry.shared.register(descriptor)
    }

    public func addNetlistProcessor(_ processor: any SpiceNetlistProcessor) {
        withLock { netlistProcessors.append(processor) }
    }

    public func addResultProcessor(_ processor: any SimulationResultProcessor) {
        withLock { resultProcessors.append(processor) }
    }

    public func addExporter(_ exporter: any ResultExporter) {
        withLock { exporters[exporter.formatName.lowercased()] = exporter }
    }

    // MARK: - Execution

    /// Applies every netlist processor in registration order.
    public func processNetlist(_ netlist: String) throws -> String {
        let processors = withLock { netlistProcessors }
        var text = netlist
        for processor in processors {
            text = try processor.process(text)
        }
        return text
    }

    /// Applies every result processor in registration order.
    public func processResult(
        _ result: CircuitSimResult,
        context: SimulationPostContext
    ) -> CircuitSimResult {
        let processors = withLock { resultProcessors }
        return processors.reduce(result) { $0.apply($1.process($0, context: context)) }
    }

    /// The exporter registered for `formatName` (case-insensitive), if any.
    public func exporter(named formatName: String) -> (any ResultExporter)? {
        withLock { exporters[formatName.lowercased()] }
    }

    // MARK: - Lifecycle

    /// Removes every installed plugin extension. Component descriptors must be
    /// released separately via `ComponentRegistry.unregister(id:)`.
    public func reset() {
        withLock {
            installed.removeAll()
            netlistProcessors.removeAll()
            resultProcessors.removeAll()
            exporters.removeAll()
        }
    }
}

private extension CircuitSimResult {
    /// Adopts `other` as the new value (identity replacement). Kept as a named
    /// operation so the reduce in `processResult` reads clearly.
    func apply(_ other: CircuitSimResult) -> CircuitSimResult { other }
}
