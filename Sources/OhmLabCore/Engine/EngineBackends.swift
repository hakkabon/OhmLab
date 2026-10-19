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
        SimulationEngine.register(factory(), makeDefault: true)
    }

    /// Whether `name` refers to the currently active backend.
    public static func isActive(_ name: String) -> Bool {
        let canonical: String
        switch name.lowercased() {
        case "native", "native-mna": canonical = "native-mna"
        case "rust", "ohm-core": canonical = "ohm-core"
        default: canonical = name.lowercased()
        }
        return SimulationEngine.backendIdentifier.caseInsensitiveCompare(canonical) == .orderedSame
    }

    private static func builtins() -> [String: Factory] {
        var map: [String: Factory] = [
            "native": { NativeMNAEngine() },
            "native-mna": { NativeMNAEngine() },
        ]
        #if canImport(CCOhmCore)
        map["rust"] = { RustEngineBackend() }
        map["ohm-core"] = { RustEngineBackend() }
        #endif
        return map
    }
}
