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
    case noObjective
    case noYieldLimits
    case invalidYieldSamples
    case invalidMetric(String)
    case metricOutOfRange(String)
    case noDCOperatingPoint
    case noThermalComponents
    case unknownThermalComponent(String)
    case invalidThermalSpecification(String)
    case missingThermalResistance(String)
    case thermalSolveFailed(String)

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
        case .noObjective:
            return "Provide an objective probe or an analysis metric to optimise."
        case .noYieldLimits:
            return "Yield estimation needs at least one design limit (e.g. v(out)=min:max)."
        case .invalidYieldSamples:
            return "Yield estimation needs at least one Monte Carlo sample."
        case .invalidMetric(let name):
            return "The design metric \(name) is not supported."
        case .metricOutOfRange(let name):
            return "\(name)."
        case .noDCOperatingPoint:
            return "Thermal analysis needs a converged DC operating point."
        case .noThermalComponents:
            return "Thermal analysis needs at least one component thermal model."
        case .unknownThermalComponent(let name):
            return "No DC operating-point component is named \(name)."
        case .invalidThermalSpecification(let reason):
            return "The thermal specification is invalid: \(reason)."
        case .missingThermalResistance(let name):
            return "\(name) has no thermal resistance to ambient; set a junctionToAmbient or defaultJunctionToAmbient."
        case .thermalSolveFailed(let reason):
            return "The thermal network could not be solved: \(reason)"
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
