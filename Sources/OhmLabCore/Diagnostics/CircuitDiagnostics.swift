// CircuitDiagnostics.swift
// Static, non-destructive validation of a schematic.
//
// Diagnostics run on the document as it is edited and again before netlist
// generation, so invalid values, duplicate references, missing grounds, and
// floating pins are surfaced as guidance instead of as a solver failure.

import CoreGraphics
import Foundation

public struct Diagnostic: Identifiable, Equatable, Sendable {
    public enum Severity: Int, Comparable, Sendable {
        case info
        case warning
        case error

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let id: UUID
    public var severity: Severity
    public var message: String
    public var symbolID: UUID?
    public var wireID: UUID?
    public var labelID: UUID?

    public init(
        id: UUID = UUID(),
        severity: Severity,
        message: String,
        symbolID: UUID? = nil,
        wireID: UUID? = nil,
        labelID: UUID? = nil
    ) {
        self.id = id
        self.severity = severity
        self.message = message
        self.symbolID = symbolID
        self.wireID = wireID
        self.labelID = labelID
    }
}

public enum CircuitDiagnostics {
    /// Analyzes every sheet in the document, tagging diagnostics from child
    /// sheets with the sheet name. Checks that only make sense at the top level
    /// (ground reference, needing a source, grounded groups) are limited to the
    /// root sheet, since a subcircuit body legitimately has none of them.
    @MainActor
    public static func analyze(_ document: SchematicDocument) -> [Diagnostic] {
        let catalog = document.subcircuitCatalog
        var combined: [Diagnostic] = []

        for (index, sheet) in document.sheets.enumerated() {
            let isRoot = index == 0
            if sheet.symbols.isEmpty && sheet.wires.isEmpty && sheet.netLabels.isEmpty { continue }
            let nets = ConnectivityBuilder.build(
                symbols: sheet.symbols,
                wires: sheet.wires,
                labels: sheet.netLabels,
                catalog: catalog
            )
            var sheetDiagnostics = analyze(
                symbols: sheet.symbols,
                wires: sheet.wires,
                labels: sheet.netLabels,
                nets: nets,
                catalog: catalog,
                isRootSheet: isRoot
            )
            if !isRoot {
                sheetDiagnostics = sheetDiagnostics.map { diagnostic in
                    var tagged = diagnostic
                    tagged.message = "\(sheet.name): \(diagnostic.message)"
                    return tagged
                }
            }
            combined.append(contentsOf: sheetDiagnostics)
        }

        return combined.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.message < rhs.message
        }
    }

    public static func analyze(
        symbols: [SymbolInstance],
        wires: [WireSegment],
        labels: [NetLabel]
    ) -> [Diagnostic] {
        analyze(symbols: symbols, wires: wires, labels: labels, nets: nil, catalog: nil)
    }

    /// - Parameter nets: connectivity precomputed by the caller (the document
    ///   already derives and caches it); recomputed here when nil.
    /// - Parameter catalog: resolves subcircuit-instance pins from the sheet
    ///   hierarchy; when nil only flat components are understood.
    /// - Parameter isRootSheet: guards the checks that only apply to the top of
    ///   a hierarchy (ground, sources, grounded groups).
    public static func analyze(
        symbols: [SymbolInstance],
        wires: [WireSegment],
        labels: [NetLabel],
        nets precomputedNets: [Net]?,
        catalog: SubcircuitCatalog? = nil,
        isRootSheet: Bool = true
    ) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []

        func descriptor(for symbol: SymbolInstance) -> ComponentDescriptor? {
            catalog?.descriptor(for: symbol) ?? ComponentRegistry.shared.descriptor(for: symbol.descriptorId)
        }

        let nonGroundSymbols = symbols.filter {
            descriptor(for: $0)?.symbol != .ground
        }

        if nonGroundSymbols.isEmpty {
            if isRootSheet {
                diagnostics.append(Diagnostic(severity: .info, message: "Place a component to start building the circuit."))
            }
            return diagnostics
        }

        // Connectivity (Layer 2) is the basis for most warnings below.
        let nets = precomputedNets ?? ConnectivityBuilder.build(
            symbols: symbols,
            wires: wires,
            labels: labels,
            catalog: catalog
        )

        // Ground reference (top level only: a subcircuit body has none).
        let groundNets = nets.filter(\.isGround)
        if isRootSheet {
            if groundNets.isEmpty {
                diagnostics.append(Diagnostic(
                    severity: .error,
                    message: "No ground symbol. Add ground so the circuit has a node 0 reference."
                ))
            } else if groundNets.count > 1 {
                diagnostics.append(Diagnostic(
                    severity: .info,
                    message: "Multiple ground symbols are treated as the same node 0."
                ))
            }
        }

        // Reference designators.
        for symbol in symbols {
            guard let descriptor = descriptor(for: symbol) else {
                diagnostics.append(Diagnostic(
                    severity: .error,
                    message: "\(symbol.refDes.isEmpty ? "A component" : symbol.refDes) has no registered definition.",
                    symbolID: symbol.id
                ))
                continue
            }
            if descriptor.symbol == .ground { continue }

            let reference = symbol.refDes.trimmingCharacters(in: .whitespaces).uppercased()
            if reference.isEmpty {
                diagnostics.append(Diagnostic(
                    severity: .error,
                    message: "\(descriptor.displayName) has an empty reference designator.",
                    symbolID: symbol.id
                ))
            } else if reference.first != descriptor.prefix.first {
                diagnostics.append(Diagnostic(
                    severity: .error,
                    message: "Reference \(symbol.refDes) should start with \"\(descriptor.prefix)\" for a \(descriptor.displayName).",
                    symbolID: symbol.id
                ))
            }

            // Parameter validation.
            for parameter in descriptor.parameters {
                guard let value = symbol.parameters[parameter.id] else {
                    diagnostics.append(Diagnostic(
                        severity: .error,
                        message: "\(symbol.refDes) is missing its \(parameter.name.lowercased()) value.",
                        symbolID: symbol.id
                    ))
                    continue
                }
                guard value.isFinite else {
                    diagnostics.append(Diagnostic(
                        severity: .error,
                        message: "\(symbol.refDes) has a non-finite \(parameter.name.lowercased()).",
                        symbolID: symbol.id
                    ))
                    continue
                }
                switch parameter.id {
                case "seriesResistance":
                    if value < 0 {
                        diagnostics.append(Diagnostic(
                            severity: .error,
                            message: "\(symbol.refDes) series resistance must be zero or greater.",
                            symbolID: symbol.id
                        ))
                    }
                case "acMagnitude":
                    if value < 0 {
                        diagnostics.append(Diagnostic(
                            severity: .error,
                            message: "\(symbol.refDes) AC magnitude must be zero or greater.",
                            symbolID: symbol.id
                        ))
                    }
                case "channelLengthModulation", "bodyEffect":
                    if value < 0 {
                        diagnostics.append(Diagnostic(
                            severity: .error,
                            message: "\(symbol.refDes) \(parameter.name.lowercased()) must be zero or greater.",
                            symbolID: symbol.id
                        ))
                    }
                case "resistance", "capacitance", "inductance", "saturationCurrent", "emissionCoefficient", "reverseBeta", "transconductanceParameter", "surfacePotential", "gateSaturationCurrent":
                    if value <= 0 {
                        diagnostics.append(Diagnostic(
                            severity: .error,
                            message: "\(symbol.refDes) \(parameter.name.lowercased()) must be greater than zero.",
                            symbolID: symbol.id
                        ))
                    }
                case "forwardBeta":
                    if value <= 1 {
                        diagnostics.append(Diagnostic(
                            severity: .error,
                            message: "\(symbol.refDes) forward beta must be greater than one.",
                            symbolID: symbol.id
                        ))
                    }
                default:
                    break
                }
            }
        }

        // Duplicate references.
        var referenceCounts: [String: Int] = [:]
        for symbol in symbols {
            guard descriptor(for: symbol)?.symbol != .ground else { continue }
            let reference = symbol.refDes.trimmingCharacters(in: .whitespaces).uppercased()
            guard !reference.isEmpty else { continue }
            referenceCounts[reference, default: 0] += 1
        }
        let duplicateReferences = Set(referenceCounts.filter { $0.value > 1 }.keys)
        for symbol in symbols where duplicateReferences.contains(symbol.refDes.trimmingCharacters(in: .whitespaces).uppercased()) {
            diagnostics.append(Diagnostic(
                severity: .error,
                message: "Reference \(symbol.refDes) is used more than once.",
                symbolID: symbol.id
            ))
        }

        // Pin -> net lookup, reused by the pin checks and reachability below.
        var netIDByPin: [PinRef: Int] = [:]
        for net in nets {
            for pin in net.connectedPins {
                netIDByPin[pin] = net.id
            }
        }

        // Pin-level checks.
        for symbol in symbols {
            guard let descriptor = descriptor(for: symbol) else { continue }
            if descriptor.symbol == .ground { continue }

            var locatedNodes: [Int] = []
            for pin in descriptor.pins {
                let location = PinGeometry.location(of: pin, on: symbol)
                let isOnWire = wires.contains { wire in
                    zip(wire.points, wire.points.dropFirst()).contains { ConnectivityBuilder.liesOnSegment(location, $0, $1) }
                }
                let net = netIDByPin[PinRef(symbolId: symbol.id, pinId: pin.id)].flatMap { id in
                    nets.first { $0.id == id }
                }
                let pinCount = net?.connectedPins.count ?? 0

                if !isOnWire && pinCount <= 1 {
                    diagnostics.append(Diagnostic(
                        severity: .warning,
                        message: "\(symbol.refDes) pin \(pin.id) is not connected to anything.",
                        symbolID: symbol.id
                    ))
                }
                if let node = net?.id {
                    locatedNodes.append(node)
                }
            }

            if locatedNodes.count == 2, locatedNodes[0] == locatedNodes[1] {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "\(symbol.refDes) has both pins on the same net (short circuit).",
                    symbolID: symbol.id
                ))
            }
        }

        // Subcircuit instances: the referenced sheet must exist, and every port
        // should be bound to a same-named net label inside that sheet.
        if let catalog {
            for symbol in symbols where symbol.isSubcircuitInstance {
                guard let reference = symbol.sheetRef else { continue }
                guard let sheet = catalog.sheet(id: reference) else {
                    diagnostics.append(Diagnostic(
                        severity: .error,
                        message: "\(symbol.refDes) refers to a subcircuit sheet that no longer exists.",
                        symbolID: symbol.id
                    ))
                    continue
                }
                let labelNames = Set(sheet.netLabels.map { $0.name.uppercased() })
                for port in sheet.ports where !labelNames.contains(port.name.uppercased()) {
                    diagnostics.append(Diagnostic(
                        severity: .warning,
                        message: "Port \(port.name) of \(sheet.name) has no same-named net label, so it is not connected inside the sheet.",
                        symbolID: symbol.id
                    ))
                }
            }
        }

        // A source is needed to excite the circuit (top level only: a subcircuit
        // body may hold no independent source of its own).
        if isRootSheet {
            let hasSource = symbols.contains {
                let symbol = descriptor(for: $0)?.symbol
                return symbol == .voltageSource || symbol == .currentSource
            }
            if !hasSource {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "The circuit has no independent source, so analysis results will be all zero."
                ))
            }

            // Ungrounded subcircuits: nets joined by components but with no path
            // to ground make the nodal matrix singular. Group them and warn once
            // each. Skipped inside sheets, where a formal (external) ground is
            // supplied by the enclosing instance.
            if !groundNets.isEmpty {
                diagnostics.append(contentsOf: ungroundedSubcircuits(
                    symbols: symbols,
                    nets: nets,
                    netIDByPin: netIDByPin,
                    groundNetIDs: Set(groundNets.map(\.id)),
                    catalog: catalog
                ))
            }
        }

        diagnostics.append(contentsOf: busDiagnostics(labels: labels))

        return diagnostics.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.message < rhs.message
        }
    }

    /// Finds groups of nets that are connected by two-terminal components but
    /// have no path to ground, and reports one warning per floating group.
    /// Checks bus member labels against declarations.
    private static func busDiagnostics(labels: [NetLabel]) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        let declarations = labels.compactMap { label -> (NetLabel, BusName)? in
            guard let bus = label.busName, bus.isDeclaration else { return nil }
            return (label, bus)
        }
        let declaredBases = Set(declarations.map { $0.1.base.uppercased() })

        var rangeByBase: [String: ClosedRange<Int>] = [:]
        for (label, bus) in declarations {
            let key = bus.base.uppercased()
            if let existing = rangeByBase[key], existing != bus.range {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "Bus \(bus.base) is declared with conflicting ranges.",
                    labelID: label.id
                ))
            } else {
                rangeByBase[key] = bus.range
            }
        }

        for label in labels {
            guard let bus = label.busName, bus.isBitSelect, let bit = bus.bit else { continue }
            let key = bus.base.uppercased()
            if !declaredBases.contains(key) {
                diagnostics.append(Diagnostic(
                    severity: .info,
                    message: "Member \(label.name) has no matching bus declaration (e.g. \(bus.base)[n:0]).",
                    labelID: label.id
                ))
            } else if let range = rangeByBase[key], !range.contains(bit) {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "\(label.name) is outside the declared range of bus \(bus.base).",
                    labelID: label.id
                ))
            }
        }
        return diagnostics
    }

    private static func ungroundedSubcircuits(
        symbols: [SymbolInstance],
        nets: [Net],
        netIDByPin: [PinRef: Int],
        groundNetIDs: Set<Int>,
        catalog: SubcircuitCatalog?
    ) -> [Diagnostic] {
        var adjacency: [Int: Set<Int>] = [:]
        var refsByNet: [Int: [String]] = [:]

        for symbol in symbols {
            guard let descriptor = catalog?.descriptor(for: symbol)
                ?? ComponentRegistry.shared.descriptor(for: symbol.descriptorId),
                  descriptor.symbol != .ground else { continue }
            let nodeIDs = descriptor.pins.compactMap { netIDByPin[PinRef(symbolId: symbol.id, pinId: $0.id)] }
            for nodeID in nodeIDs {
                refsByNet[nodeID, default: []].append(symbol.refDes)
            }
            // Join every terminal to the first, so a multi-terminal device (such
            // as a transistor) connects all of the nets it touches.
            let terminals = Array(Set(nodeIDs))
            if terminals.count >= 2 {
                for nodeID in terminals.dropFirst() {
                    adjacency[terminals[0], default: []].insert(nodeID)
                    adjacency[nodeID, default: []].insert(terminals[0])
                }
            }
        }

        var reachable = groundNetIDs
        var queue = Array(groundNetIDs)
        while let current = queue.popLast() {
            for neighbor in adjacency[current] ?? [] where reachable.insert(neighbor).inserted {
                queue.append(neighbor)
            }
        }

        let isolated = Set(nets.map(\.id).filter {
            !reachable.contains($0) && !refsByNet[$0, default: []].isEmpty
        })
        guard !isolated.isEmpty else { return [] }

        let nameByID = Dictionary(uniqueKeysWithValues: nets.map { ($0.id, $0.name) })
        var visited: Set<Int> = []
        var diagnostics: [Diagnostic] = []
        for netID in isolated.sorted() where !visited.contains(netID) {
            var group: [Int] = []
            var stack = [netID]
            visited.insert(netID)
            while let current = stack.popLast() {
                group.append(current)
                for neighbor in adjacency[current] ?? [] where isolated.contains(neighbor) && visited.insert(neighbor).inserted {
                    stack.append(neighbor)
                }
            }
            let refs = Set(group.flatMap { refsByNet[$0, default: []] }).sorted()
            let names = group.sorted().map { nameByID[$0] ?? "N\($0)" }
            diagnostics.append(Diagnostic(
                severity: .warning,
                message: "\(refs.joined(separator: ", ")) is not connected to ground (nets \(names.joined(separator: ", ")))."
            ))
        }
        return diagnostics
    }
}
