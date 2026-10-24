// EngineBackends.swift
// A named registry of engine backends.
//
// The façade (`SimulationEngine`) dispatches to whichever backend is *active*;
// this registry lets front ends select one by name (the CLI's `--engine`) and
// lets plugins contribute their own, without linking a concrete type.

import Foundation

/// Names and activates the simulation backends available to the process.
///
/// Built-ins: `native` (the Swift MNA engine, also `native-mna`) and — when the
/// optional Rust core has been linked — `rust` (also `ohm-core`).
public enum EngineBackends {
    public typealias Factory = @Sendable () -> any SimulationEngineBackend

    private static let lock = NSLock()
    nonisolated(unsafe) private static var factories: [String: Factory] = builtins()

    /// The known backend names, sorted.
    public static var available: [String] {
        lock.lock(); defer { lock.unlock() }
        return factories.keys.sorted()
    }

    /// One capability declaration per canonical backend identifier. Aliases
    /// are intentionally collapsed so this is directly usable as a support
    /// matrix in diagnostics, CLI output, and compatibility tests.
    public static var capabilityMatrix: [SimulationBackendCapabilities] {
        lock.lock()
        let factories = Array(factories.values)
        lock.unlock()
        var unique: [String: SimulationBackendCapabilities] = [:]
        for factory in factories {
            let backend = factory()
            unique[backend.identifier.lowercased()] = backend.capabilities
        }
        return unique.values.sorted { $0.backendIdentifier < $1.backendIdentifier }
    }

    /// Canonical backend declarations, including maturity, implementation
    /// version, and production-boundary validation findings.
    public static var descriptorMatrix: [SimulationBackendDescriptor] {
        lock.lock()
        let factories = Array(factories.values)
        lock.unlock()
        var unique: [String: SimulationBackendDescriptor] = [:]
        for factory in factories {
            let descriptor = ProductionBoundary.descriptor(for: factory())
            unique[descriptor.identifier.lowercased()] = descriptor
        }
        return unique.values.sorted { $0.identifier < $1.identifier }
    }

    /// One live instance per canonical backend. Kept internal so conformance
    /// tooling can exercise every linked implementation without changing the
    /// process-wide active backend.
    static var canonicalBackends: [any SimulationEngineBackend] {
        lock.lock()
        let factories = Array(factories.values)
        lock.unlock()
        var unique: [String: any SimulationEngineBackend] = [:]
        for factory in factories {
            let backend = factory()
            unique[backend.identifier.lowercased()] = backend
        }
        return unique.values.sorted { $0.identifier < $1.identifier }
    }

    /// Capabilities for a registered name or alias.
    public static func capabilities(for name: String) -> SimulationBackendCapabilities? {
        lock.lock()
        let factory = factories[name.lowercased()]
        lock.unlock()
        return factory?().capabilities
    }

    /// Registers (or replaces) a backend factory under `name` (case-insensitive).
    public static func register(name: String, factory: @escaping Factory) {
        lock.lock(); defer { lock.unlock() }
        factories[name.lowercased()] = factory
    }

    /// Makes the named backend active. Throws `BatchError.unsupportedEngine` for
    /// an unknown name.
    public static func activate(_ name: String) throws {
        lock.lock()
        let factory = factories[name.lowercased()]
        lock.unlock()
        guard let factory else { throw BatchError.unsupportedEngine(name) }
        try SimulationEngine.registerValidated(factory(), makeDefault: true)
    }

    /// Whether `name` refers to the currently active backend.
    public static func isActive(_ name: String) -> Bool {
        let canonical: String
        switch name.lowercased() {
        case "native", "native-mna": canonical = "native-mna"
        case "rust", "ohm-core": canonical = "ohm-core"
        case "numericcore", "numeric-core": canonical = "numeric-core"
        default: canonical = name.lowercased()
        }
        return SimulationEngine.backendIdentifier.caseInsensitiveCompare(canonical) == .orderedSame
    }

    private static func builtins() -> [String: Factory] {
        var map: [String: Factory] = [
            "native": { NativeMNAEngine() },
            "native-mna": { NativeMNAEngine() },
            "numeric-core": { NumericCoreEngineBackend() },
            "numericcore": { NumericCoreEngineBackend() },
        ]
        #if canImport(CCOhmCore)
        map["rust"] = { RustEngineBackend() }
        map["ohm-core"] = { RustEngineBackend() }
        #endif
        return map
    }
}
