// AnalysisError.swift
// Errors shared by the statistical / worst-case / optimisation analyses.

import Foundation

public enum AnalysisError: LocalizedError, Equatable {
    case noProbes
    case allTrialsFailed(Int)
    case unknownVariable(String)
    case invalidRange(String)
    case tooManyCorners(Int)
    case invalidObjective(String)
    case noVariables

    public var errorDescription: String? {
        switch self {
        case .noProbes:
            return "Select at least one probe (e.g. v(out)) to report on."
        case .allTrialsFailed(let count):
            return "All \(count) trials failed to solve; check the netlist and analysis settings."
        case .unknownVariable(let name):
            return "No editable component named \(name)."
        case .invalidRange(let name):
            return "\(name) has an invalid range (the start must not exceed the stop)."
        case .tooManyCorners(let count):
            return "The worst-case corner sweep would evaluate \(count) corners, which exceeds the limit; reduce the number of toleranced components."
        case .invalidObjective(let name):
            return "The objective \(name) is not a valid probe."
        case .noVariables:
            return "No optimisation variables were given."
        }
    }
}

/// The DC-only settings used by the trial-based analyses: they isolate a single
/// operating point per trial regardless of the document's UI settings.
extension AnalysisSettings {
    func dcOnly() -> AnalysisSettings {
        var settings = self
        settings.runDC = true
        settings.runAC = false
        settings.runTransient = false
        settings.runDCSweep = false
        return settings
    }
}
