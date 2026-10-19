// PluginManifest.swift
// Declarative (JSON) plugins.
//
// A manifest declares a plugin whose components are pure data: an id, prefix,
// display name, a symbol (one of the built-in shapes), pins, and typed
// parameters. This makes it possible to ship parts catalogs without shipping
// code — useful for iPadOS, where dynamic loading is unavailable.

import CoreGraphics
import Foundation

public enum PluginManifestError: LocalizedError, Equatable {
    case invalidSymbol(component: String, symbol: String)

    public var errorDescription: String? {
        switch self {
        case .invalidSymbol(let component, let symbol):
            return "Plugin component “\(component)” uses unknown symbol “\(symbol)”."
        }
    }
}

/// The on-disk shape of a declarative plugin.
public struct PluginManifest: Decodable, Sendable {
    public struct Component: Decodable, Sendable {
        public struct Pin: Decodable, Sendable {
            public let id: String
            public let name: String?
            public let x: Double
            public let y: Double
        }

        public struct Parameter: Decodable, Sendable {
            public let id: String
            public let name: String
            public let unit: String?
            public let defaultValue: Double
        }

        public let id: String
        public let prefix: String
        public let displayName: String
        /// A `ComponentSymbol` raw value (e.g. `"resistor"`, `"capacitor"`).
        public let symbol: String
        public let pins: [Pin]
        public let parameters: [Parameter]?
    }

    public let id: String
    public let name: String
    public let version: String?
    public let components: [Component]
}

/// A plugin built purely from a manifest.
struct DeclarativePlugin: CircuitPlugin {
    let manifest: PluginManifest

    var id: String { manifest.id }
    var name: String { manifest.name }
    var version: String { manifest.version ?? "1.0" }

    /// Validates and converts the manifest's components into descriptors.
    func makeDescriptors() throws -> [ComponentDescriptor] {
        try manifest.components.map { component in
            guard let symbol = ComponentSymbol(rawValue: component.symbol) else {
                throw PluginManifestError.invalidSymbol(component: component.id, symbol: component.symbol)
            }
            let pins = component.pins.map {
                PinDescriptor(
                    id: $0.id,
                    name: $0.name ?? $0.id,
                    position: CGPoint(x: $0.x, y: $0.y)
                )
            }
            let parameters = (component.parameters ?? []).map {
                ComponentParameterDescriptor(
                    id: $0.id,
                    name: $0.name,
                    unit: $0.unit ?? "",
                    defaultValue: $0.defaultValue
                )
            }
            return ComponentDescriptor(
                id: component.id,
                prefix: component.prefix,
                displayName: component.displayName,
                symbol: symbol,
                pins: pins,
                parameters: parameters
            )
        }
    }

    func register(into manager: PluginManager) {
        // Validation happens in `loadManifests` before this is called; a
        // manifest that fails validation is never registered.
        for descriptor in (try? makeDescriptors()) ?? [] {
            manager.addComponent(descriptor)
        }
    }
}

public extension PluginManager {
    /// Loads every `*.json` manifest in `directory` (non-recursive, name-sorted)
    /// as a declarative plugin. Returns the component ids that were added.
    @discardableResult
    func loadManifests(in directory: URL) throws -> [String] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var added: [String] = []
        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension.lowercased() == "json" {
            let data = try Data(contentsOf: url)
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
            let plugin = DeclarativePlugin(manifest: manifest)
            _ = try plugin.makeDescriptors() // validate before installing
            register(plugin)
            added += manifest.components.map(\.id)
        }
        return added
    }
}
