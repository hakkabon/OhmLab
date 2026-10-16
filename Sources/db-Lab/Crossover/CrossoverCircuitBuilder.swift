import Foundation

enum CrossoverCircuitBuildError: LocalizedError {
    case noFilterStages
    case invalidFrequencySweep
    case missingComponents(String)
    case missingDriver(String)
    case unsupportedCompensation(String)
    case unsupportedFilterType(String)
    case unsupportedComponentType(String)
    case unexpectedComponent(stage: String, index: Int, expected: String)
    case invalidValue(component: String)
    case invalidDriverImpedance(String)

    var errorDescription: String? {
        switch self {
        case .noFilterStages:
            return "Add at least one filter stage before generating a crossover circuit."
        case .invalidFrequencySweep:
            return "The frequency sweep must have positive finite limits, an increasing range, and positive points per decade."
        case .missingComponents(let stage):
            return "\(stage) has no synthesized component values. Synthesize the filter first."
        case .missingDriver(let name):
            return "No driver named \(name) is assigned to its filter stage."
        case .unsupportedCompensation(let networks):
            return "\(networks) compensation networks are not yet included in the generated circuit."
        case .unsupportedFilterType(let type):
            return "\(type) stages are not yet supported by the passive circuit generator."
        case .unsupportedComponentType(let component):
            return "\(component) cannot be represented as a crossover circuit component yet."
        case .unexpectedComponent(let stage, let index, let expected):
            return "\(stage) component \(index + 1) must be a \(expected) for this passive ladder."
        case .invalidValue(let component):
            return "\(component) has a non-positive or non-finite value."
        case .invalidDriverImpedance(let driver):
            return "\(driver) must have a positive, finite nominal impedance."
        }
    }
}

enum CrossoverCircuitBuilder {
    static func build(
        drivers: [DriverModel],
        filters: [FilterStageModel],
        compensations: [CompensationSpec] = [],
        fMin: Double = 20,
        fMax: Double = 20_000,
        pointsPerDecade: Int = 200
    ) throws -> String {
        guard !filters.isEmpty else {
            throw CrossoverCircuitBuildError.noFilterStages
        }
        guard fMin.isFinite, fMax.isFinite, fMin > 0, fMax > fMin, pointsPerDecade > 0 else {
            throw CrossoverCircuitBuildError.invalidFrequencySweep
        }
        guard compensations.isEmpty else {
            let names = compensations.map(\.kind.rawValue).joined(separator: ", ")
            throw CrossoverCircuitBuildError.unsupportedCompensation(names)
        }

        var lines = [
            "* Generated from db-Lab crossover domain model",
            "V1 IN 0 AC 1"
        ]
        for (stageOffset, stage) in filters.enumerated() {
            guard stage.filterType == .lowPass || stage.filterType == .highPass else {
                throw CrossoverCircuitBuildError.unsupportedFilterType(stage.filterType.rawValue)
            }
            guard !stage.components.isEmpty else {
                throw CrossoverCircuitBuildError.missingComponents(stage.driverName)
            }
            guard let driver = drivers.first(where: { $0.name == stage.driverName }) else {
                throw CrossoverCircuitBuildError.missingDriver(stage.driverName)
            }
            guard driver.nominalImpedance.isFinite, driver.nominalImpedance > 0 else {
                throw CrossoverCircuitBuildError.invalidDriverImpedance(driver.name)
            }

            let stageNumber = stageOffset + 1
            var currentNode = "IN"
            var seriesIndex = 0
            for (componentIndex, component) in stage.components.enumerated() {
                let isSeries = componentIndex.isMultiple(of: 2)
                let expectedKind: [ComponentKind]
                if stage.filterType == .lowPass {
                    expectedKind = isSeries ? [.inductor, .inductorSeries] : [.capacitor, .capacitorSeries]
                } else {
                    expectedKind = isSeries ? [.capacitor, .capacitorSeries] : [.inductor, .inductorSeries]
                }
                guard expectedKind.contains(component.kind) else {
                    throw CrossoverCircuitBuildError.unexpectedComponent(
                        stage: stage.driverName,
                        index: componentIndex,
                        expected: isSeries
                            ? (stage.filterType == .lowPass ? "series inductor" : "series capacitor")
                            : (stage.filterType == .lowPass ? "shunt capacitor" : "shunt inductor")
                    )
                }
                guard component.value.isFinite, component.value > 0 else {
                    throw CrossoverCircuitBuildError.invalidValue(component: component.name)
                }

                let reference = componentReference(
                    kind: component.kind,
                    stageNumber: stageNumber,
                    componentNumber: componentIndex + 1
                )
                if isSeries {
                    seriesIndex += 1
                    let nextNode = "F\(stageNumber)_N\(seriesIndex)"
                    try append(component, reference: reference, firstNode: currentNode, secondNode: nextNode, to: &lines)
                    currentNode = nextNode
                } else {
                    try append(component, reference: reference, firstNode: currentNode, secondNode: "0", to: &lines)
                }
            }
            lines.append("RLOAD_F\(stageNumber) \(currentNode) 0 \(spiceNumber(driver.nominalImpedance))")
        }
        lines.append(".AC DEC \(pointsPerDecade) \(spiceNumber(fMin)) \(spiceNumber(fMax))")
        lines.append(".end")
        return lines.joined(separator: "\n")
    }

    private static func componentReference(
        kind: ComponentKind,
        stageNumber: Int,
        componentNumber: Int
    ) -> String {
        let prefix: String
        switch kind {
        case .resistor, .resistorSeries: prefix = "R"
        case .capacitor, .capacitorSeries: prefix = "C"
        case .inductor, .inductorSeries: prefix = "L"
        }
        return "\(prefix)\(stageNumber)_\(componentNumber)"
    }

    private static func append(
        _ component: ComponentValue,
        reference: String,
        firstNode: String,
        secondNode: String,
        to lines: inout [String]
    ) throws {
        switch component.kind {
        case .resistor, .capacitor, .inductor:
            lines.append("\(reference) \(firstNode) \(secondNode) \(spiceNumber(component.value))")
        case .inductorSeries, .capacitorSeries, .resistorSeries:
            throw CrossoverCircuitBuildError.unsupportedComponentType(component.kind.rawValue)
        }
    }

    private static func spiceNumber(_ value: Double) -> String {
        String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
