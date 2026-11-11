// ThermalAnalysis.swift
// Steady-state electro-thermal analysis.
//
// The electrical operating point is solved first, each component's dissipated
// power is derived from that DC solution (or supplied explicitly), and the
// resulting heat flow is solved on a small linear thermal-resistance network.
// Temperatures are rises above the specified ambient, so the network matrix is
// symmetric, sparse, and deterministic.
//
// This is deliberately a one-shot coupling: power is taken from the nominal DC
// operating point and does not feed back into the electrical model. That keeps
// the analysis reproducible and additive on top of the existing result
// contract.

import Foundation

/// A shared thermal node (heatsink) referenced by one or more components.
///
/// `thermalResistance` is the total resistance from the heatsink to ambient in
/// kelvin per watt. Component junction-to-case resistances connect to it.
public struct ThermalHeatsink: Codable, Equatable, Sendable {
    public var name: String
    public var thermalResistance: Double

    public init(name: String, thermalResistance: Double) {
        self.name = name
        self.thermalResistance = thermalResistance
    }
}

/// One component's thermal description.
///
/// `designator` matches a DC operating-point component by name (case
/// insensitive). When `powerWatts` is omitted the power is `abs(v * i)` from
/// the solved operating point. A component is connected either directly to
/// ambient (`junctionToAmbient`) or, via `junctionToCase`, to a shared
/// `heatsink`.
public struct ThermalComponent: Codable, Equatable, Sendable {
    public var designator: String
    /// Explicit dissipated power in watts. Defaults to the DC operating point.
    public var powerWatts: Double?
    /// Junction-to-ambient thermal resistance in K/W.
    public var junctionToAmbient: Double?
    /// Junction-to-case thermal resistance in K/W, used with `heatsink`.
    public var junctionToCase: Double?
    /// Name of a `ThermalHeatsink` this component is mounted on.
    public var heatsink: String?
    /// Optional junction-temperature limit in °C, reported in the result.
    public var maxTemperatureCelsius: Double?

    public init(
        designator: String,
        powerWatts: Double? = nil,
        junctionToAmbient: Double? = nil,
        junctionToCase: Double? = nil,
        heatsink: String? = nil,
        maxTemperatureCelsius: Double? = nil
    ) {
        self.designator = designator
        self.powerWatts = powerWatts
        self.junctionToAmbient = junctionToAmbient
        self.junctionToCase = junctionToCase
        self.heatsink = heatsink
        self.maxTemperatureCelsius = maxTemperatureCelsius
    }
}

/// The complete thermal model for one analysis.
public struct ThermalSpecification: Codable, Equatable, Sendable {
    public static let currentContractVersion = 1
    public static let defaultAmbientCelsius = 25.0

    public var contractVersion: Int
    public var ambientCelsius: Double
    /// Junction-to-ambient resistance used when a component omits its own and
    /// is not mounted on a heatsink.
    public var defaultJunctionToAmbient: Double?
    public var components: [ThermalComponent]
    public var heatsinks: [ThermalHeatsink]

    public init(
        ambientCelsius: Double = ThermalSpecification.defaultAmbientCelsius,
        defaultJunctionToAmbient: Double? = nil,
        components: [ThermalComponent] = [],
        heatsinks: [ThermalHeatsink] = [],
        contractVersion: Int = ThermalSpecification.currentContractVersion
    ) {
        self.contractVersion = contractVersion
        self.ambientCelsius = ambientCelsius
        self.defaultJunctionToAmbient = defaultJunctionToAmbient
        self.components = components
        self.heatsinks = heatsinks
    }
}

/// A thermal analysis request. The electrical netlist and settings are the same
/// inputs the DC analyses use.
public struct ThermalRequest: Sendable {
    public var netlist: String
    public var settings: AnalysisSettings
    public var specification: ThermalSpecification
    public var libraries: [SpiceModelLibrary]
    /// Directory used to resolve relative `.include`/`.lib` paths.
    public var baseDirectory: URL?

    public init(
        netlist: String,
        settings: AnalysisSettings = .default,
        specification: ThermalSpecification,
        libraries: [SpiceModelLibrary] = [],
        baseDirectory: URL? = nil
    ) {
        self.netlist = netlist
        self.settings = settings
        self.specification = specification
        self.libraries = libraries
        self.baseDirectory = baseDirectory
    }
}

/// One component's solved thermal state.
public struct ThermalComponentResult: Codable, Equatable, Sendable {
    public let designator: String
    public let powerWatts: Double
    public let temperatureCelsius: Double
    public let temperatureRiseCelsius: Double
    /// Effective junction-to-ambient resistance (`rise / power`), or zero when
    /// the component dissipates no power.
    public let thermalResistance: Double
    public let heatsink: String?
    public let maxTemperatureCelsius: Double?
    public let exceedsLimit: Bool

    public init(
        designator: String,
        powerWatts: Double,
        temperatureCelsius: Double,
        temperatureRiseCelsius: Double,
        thermalResistance: Double,
        heatsink: String? = nil,
        maxTemperatureCelsius: Double? = nil,
        exceedsLimit: Bool = false
    ) {
        self.designator = designator
        self.powerWatts = powerWatts
        self.temperatureCelsius = temperatureCelsius
        self.temperatureRiseCelsius = temperatureRiseCelsius
        self.thermalResistance = thermalResistance
        self.heatsink = heatsink
        self.maxTemperatureCelsius = maxTemperatureCelsius
        self.exceedsLimit = exceedsLimit
    }
}

/// One shared heatsink's solved thermal state.
public struct ThermalHeatsinkResult: Codable, Equatable, Sendable {
    public let name: String
    public let thermalResistance: Double
    public let powerWatts: Double
    public let temperatureCelsius: Double
    public let temperatureRiseCelsius: Double

    public init(
        name: String,
        thermalResistance: Double,
        powerWatts: Double,
        temperatureCelsius: Double,
        temperatureRiseCelsius: Double
    ) {
        self.name = name
        self.thermalResistance = thermalResistance
        self.powerWatts = powerWatts
        self.temperatureCelsius = temperatureCelsius
        self.temperatureRiseCelsius = temperatureRiseCelsius
    }
}

/// The thermal result contract. All temperatures are absolute °C; rises are
/// relative to `ambientCelsius`.
public struct ThermalResult: Codable, Equatable, Sendable {
    public static let currentContractVersion = 1

    public let contractVersion: Int
    public let ambientCelsius: Double
    public let components: [ThermalComponentResult]
    public let heatsinks: [ThermalHeatsinkResult]
    public let totalPowerWatts: Double
    public let converged: Bool
    public let warnings: [String]

    public init(
        contractVersion: Int = ThermalResult.currentContractVersion,
        ambientCelsius: Double,
        components: [ThermalComponentResult],
        heatsinks: [ThermalHeatsinkResult],
        totalPowerWatts: Double,
        converged: Bool,
        warnings: [String]
    ) {
        self.contractVersion = contractVersion
        self.ambientCelsius = ambientCelsius
        self.components = components
        self.heatsinks = heatsinks
        self.totalPowerWatts = totalPowerWatts
        self.converged = converged
        self.warnings = warnings
    }
}

public enum ThermalAnalysis {
    public static func run(_ request: ThermalRequest) throws -> ThermalResult {
        let specification = request.specification
        guard !specification.components.isEmpty else {
            throw AnalysisError.noThermalComponents
        }
        guard specification.ambientCelsius.isFinite else {
            throw AnalysisError.invalidThermalSpecification("ambient temperature must be finite")
        }
        try validate(
            resistance: specification.defaultJunctionToAmbient,
            label: "default junction-to-ambient resistance"
        )

        // Resolve heatsinks first so component references can be validated.
        var heatsinksByKey: [String: ThermalHeatsink] = [:]
        for heatsink in specification.heatsinks {
            let key = heatsink.name.uppercased()
            guard heatsinksByKey[key] == nil else {
                throw AnalysisError.invalidThermalSpecification(
                    "heatsink \(heatsink.name) is defined more than once"
                )
            }
            try validate(resistance: heatsink.thermalResistance, label: "heatsink \(heatsink.name)")
            heatsinksByKey[key] = heatsink
        }

        var seenDesignators: Set<String> = []
        for component in specification.components {
            let key = component.designator.uppercased()
            guard seenDesignators.insert(key).inserted else {
                throw AnalysisError.invalidThermalSpecification(
                    "component \(component.designator) is listed more than once"
                )
            }
            try validate(resistance: component.junctionToAmbient, label: component.designator)
            try validate(resistance: component.junctionToCase, label: component.designator)
            if let power = component.powerWatts {
                guard power.isFinite, power >= 0 else {
                    throw AnalysisError.invalidThermalSpecification(
                        "\(component.designator) power must be a non-negative number"
                    )
                }
            }
            if let heatsink = component.heatsink {
                let heatsinkKey = heatsink.uppercased()
                guard heatsinksByKey[heatsinkKey] != nil else {
                    throw AnalysisError.invalidThermalSpecification(
                        "\(component.designator) references unknown heatsink \(heatsink)"
                    )
                }
                guard component.junctionToCase != nil else {
                    throw AnalysisError.invalidThermalSpecification(
                        "\(component.designator) mounts on a heatsink but has no junctionToCase resistance"
                    )
                }
            } else if component.junctionToCase != nil {
                throw AnalysisError.invalidThermalSpecification(
                    "\(component.designator) has a junctionToCase resistance but no heatsink"
                )
            }
        }

        // One nominal DC operating point supplies the power sources.
        let simulation = try SimulationEngine.solve(
            netlist: request.netlist,
            settings: request.settings.dcOnly(),
            libraries: request.libraries,
            baseDirectory: request.baseDirectory
        )
        guard let dc = simulation.dc, dc.converged else {
            throw AnalysisError.noDCOperatingPoint
        }

        var operatingPoints: [String: (voltage: Double, current: Double)] = [:]
        for component in dc.components {
            operatingPoints[component.name.uppercased()] = (component.voltage, component.current)
        }

        var powers: [String: Double] = [:]
        var warnings: [String] = []
        for component in specification.components {
            let key = component.designator.uppercased()
            let power: Double
            if let explicit = component.powerWatts {
                power = explicit
            } else if let operatingPoint = operatingPoints[key] {
                power = abs(operatingPoint.voltage * operatingPoint.current)
            } else {
                throw AnalysisError.unknownThermalComponent(component.designator)
            }
            guard power.isFinite else {
                throw AnalysisError.invalidThermalSpecification(
                    "\(component.designator) dissipates a non-finite power"
                )
            }
            powers[key] = power
        }

        // Build the thermal-resistance network. Node keys are stable strings so
        // matrix ordering never depends on dictionary iteration order.
        let junctionKeys = specification.components.map { "junction:\($0.designator.uppercased())" }
        var usedHeatsinkKeys: Set<String> = []
        for component in specification.components {
            if let heatsink = component.heatsink { usedHeatsinkKeys.insert(heatsink.uppercased()) }
        }
        var nodeKeys = Set(junctionKeys)
        for key in usedHeatsinkKeys { nodeKeys.insert("heatsink:\(key)") }
        let orderedNodes = nodeKeys.sorted()
        var nodeIndex: [String: Int] = [:]
        for (index, key) in orderedNodes.enumerated() { nodeIndex[key] = index }

        var matrix = SparseMatrix<Double>(rows: orderedNodes.count, columns: orderedNodes.count)
        var rhs = [Double](repeating: 0, count: orderedNodes.count)

        func addConnection(_ conductance: Double, from: String, to: String?) {
            guard let start = nodeIndex[from] else { return }
            matrix.add(conductance, row: start, column: start)
            if let to, let end = nodeIndex[to] {
                matrix.add(-conductance, row: start, column: end)
                matrix.add(-conductance, row: end, column: start)
                matrix.add(conductance, row: end, column: end)
            }
        }

        for component in specification.components {
            let designatorKey = component.designator.uppercased()
            let junction = "junction:\(designatorKey)"
            if let heatsink = component.heatsink {
                let resistance = component.junctionToCase ?? 0
                addConnection(1 / resistance, from: junction, to: "heatsink:\(heatsink.uppercased())")
            } else {
                guard let resistance = component.junctionToAmbient
                    ?? specification.defaultJunctionToAmbient
                else {
                    throw AnalysisError.missingThermalResistance(component.designator)
                }
                addConnection(1 / resistance, from: junction, to: nil)
            }
            rhs[nodeIndex[junction] ?? 0] += powers[designatorKey] ?? 0
        }

        for key in usedHeatsinkKeys.sorted() {
            guard let heatsink = heatsinksByKey[key] else { continue }
            addConnection(1 / heatsink.thermalResistance, from: "heatsink:\(key)", to: nil)
        }

        let rises: [Double]
        do {
            rises = try SparseLinearSolver.solve(matrix, rhs)
        } catch {
            throw AnalysisError.thermalSolveFailed(error.localizedDescription)
        }

        func rise(for key: String) -> Double {
            guard let index = nodeIndex[key] else { return 0 }
            return rises[index]
        }

        var componentResults: [ThermalComponentResult] = []
        for component in specification.components {
            let key = component.designator.uppercased()
            let power = powers[key] ?? 0
            let rise = rise(for: "junction:\(key)")
            let temperature = specification.ambientCelsius + rise
            let resistance = power > 0 ? rise / power : 0
            let limit = component.maxTemperatureCelsius
            componentResults.append(ThermalComponentResult(
                designator: component.designator,
                powerWatts: power,
                temperatureCelsius: temperature,
                temperatureRiseCelsius: rise,
                thermalResistance: resistance,
                heatsink: component.heatsink,
                maxTemperatureCelsius: limit,
                exceedsLimit: limit.map { temperature > $0 } ?? false
            ))
        }

        var heatsinkResults: [ThermalHeatsinkResult] = []
        for heatsink in specification.heatsinks {
            let key = heatsink.name.uppercased()
            guard usedHeatsinkKeys.contains(key) else {
                warnings.append("Heatsink \(heatsink.name) is not attached to any component.")
                continue
            }
            let attachedPower = specification.components.reduce(0.0) { total, component in
                component.heatsink?.uppercased() == key ? total + (powers[component.designator.uppercased()] ?? 0) : total
            }
            let rise = rise(for: "heatsink:\(key)")
            heatsinkResults.append(ThermalHeatsinkResult(
                name: heatsink.name,
                thermalResistance: heatsink.thermalResistance,
                powerWatts: attachedPower,
                temperatureCelsius: specification.ambientCelsius + rise,
                temperatureRiseCelsius: rise
            ))
        }

        let totalPower = specification.components.reduce(0.0) {
            $0 + (powers[$1.designator.uppercased()] ?? 0)
        }

        return ThermalResult(
            ambientCelsius: specification.ambientCelsius,
            components: componentResults,
            heatsinks: heatsinkResults,
            totalPowerWatts: totalPower,
            converged: true,
            warnings: warnings
        )
    }

    private static func validate(resistance: Double?, label: String) throws {
        guard let resistance else { return }
        guard resistance.isFinite, resistance > 0 else {
            throw AnalysisError.invalidThermalSpecification(
                "\(label) must be a positive, finite resistance"
            )
        }
    }
}
