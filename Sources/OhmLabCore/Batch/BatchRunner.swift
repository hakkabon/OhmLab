// BatchRunner.swift
// Headless, in-process batch simulation used by the `ohm` command-line tool.
//
// It is deliberately free of any I/O beyond the values it is handed so it can be
// unit-tested directly: the CLI does argument parsing, file reading, and output
// writing, and this type does the analysis and serialization.

import Foundation

/// What to simulate.
public enum BatchInput: Sendable {
    /// A SPICE netlist body. Analysis is driven by the netlist's own cards
    /// (`.ac`, `.tran`, …), unless a settings override is supplied.
    case netlist(String)
    /// A decoded `.ohmlab` document: its schematic or netlist, its settings, and
    /// its embedded model libraries.
    case document(CircuitFile)
}

public enum BatchFormat: String, Sendable, CaseIterable {
    case csv
    case json
}

/// A headless run request.
public struct BatchRequest: Sendable {
    public var input: BatchInput
    public var format: BatchFormat
    /// Backend name to activate (`native`, `rust`, …); `nil` keeps the default.
    public var engine: String?
    /// Replaces the document's own analysis settings when non-nil.
    public var settingsOverride: AnalysisSettings?

    public init(
        input: BatchInput,
        format: BatchFormat = .csv,
        engine: String? = nil,
        settingsOverride: AnalysisSettings? = nil
    ) {
        self.input = input
        self.format = format
        self.engine = engine
        self.settingsOverride = settingsOverride
    }
}

/// The outcome of a headless run.
public struct BatchOutcome: Sendable {
    public let result: CircuitSimResult
    public let text: String
    public let engine: String
    public var warnings: [String] { result.warnings }
}

public enum BatchError: LocalizedError, Equatable {
    case emptyInput
    case unsupportedEngine(String)
    case unreadableInput(String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "No netlist was provided."
        case .unsupportedEngine(let name):
            return "Unknown engine “\(name)”. Available: \(EngineBackends.available.joined(separator: ", "))."
        case .unreadableInput(let reason):
            return "Could not read the input: \(reason)"
        }
    }
}

public enum BatchRunner {
    /// Runs `request`, returning the serialized results (CSV or JSON) plus the
    /// raw `CircuitSimResult`.
    public static func run(_ request: BatchRequest) throws -> BatchOutcome {
        if let engine = request.engine {
            try EngineBackends.activate(engine)
        }

        let result: CircuitSimResult
        switch request.input {
        case .netlist(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BatchError.emptyInput
            }
            let settings = request.settingsOverride ?? netlistDefaults()
            result = try SimulationEngine.solve(netlist: text, settings: settings)

        case .document(let file):
            let settings = request.settingsOverride ?? file.analysis
            let libraries = (file.modelLibraries ?? []).compactMap {
                try? SpiceModelLibrary.parse($0.text, name: $0.name)
            }
            if file.usesSchematic == true {
                result = try SimulationEngine.solve(snapshot: file.schematic, settings: settings)
            } else {
                result = try SimulationEngine.solve(
                    netlist: file.netlistText ?? "",
                    settings: settings,
                    libraries: libraries
                )
            }
        }

        let text: String
        switch request.format {
        case .csv: text = CircuitResultExport.csv(result)
        case .json: text = CircuitResultJSON.encode(result)
        }
        return BatchOutcome(result: result, text: text, engine: SimulationEngine.backendIdentifier)
    }

    /// Default settings for a bare netlist: DC on, everything else left to the
    /// netlist's own cards (the façade adopts `.ac`/`.tran` when present).
    private static func netlistDefaults() -> AnalysisSettings {
        AnalysisSettings(
            runDC: true,
            runAC: false,
            acStartFrequency: 1,
            acStopFrequency: 1_000_000,
            acPointsPerDecade: 20
        )
    }
}
