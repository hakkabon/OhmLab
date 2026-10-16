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
    @MainActor
    public static func analyze(_ document: SchematicDocument) -> [Diagnostic] {
        analyze(symbols: document.symbols, wires: document.wires, labels: document.netLabels)
    }

    public static func analyze(
        symbols: [SymbolInstance],
        wires: [WireSegment],
        labels: [NetLabel]
    ) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []

        let nonGroundSymbols = symbols.filter {
            ComponentRegistry.shared.descriptor(for: $0.descriptorId)?.symbol != .ground
        }

        if nonGroundSymbols.isEmpty {
            diagnostics.append(Diagnostic(severity: .info, message: "Place a component to start building the circuit."))
            return diagnostics
        }

        // Connectivity (Layer 2) is the basis for most warnings below.
        let nets = ConnectivityBuilder.build(symbols: symbols, wires: wires, labels: labels)

        // Ground reference.
        let groundNets = nets.filter(\.isGround)
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

        // Reference designators.
        for symbol in symbols {
            guard let descriptor = ComponentRegistry.shared.descriptor(for: symbol.descriptorId) else {
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
                case "resistance", "capacitance", "inductance":
                    if value <= 0 {
                        diagnostics.append(Diagnostic(
                            severity: .error,
                            message: "\(symbol.refDes) \(parameter.name.lowercased()) must be greater than zero.",
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
            guard ComponentRegistry.shared.descriptor(for: symbol.descriptorId)?.symbol != .ground else { continue }
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

        // Pin-level checks.
        for symbol in symbols {
            guard let descriptor = ComponentRegistry.shared.descriptor(for: symbol.descriptorId) else { continue }
            if descriptor.symbol == .ground { continue }

            var locatedNodes: [Int] = []
            for pin in descriptor.pins {
                let location = locationOf(pin: pin, on: symbol)
                let isOnWire = wires.contains { wire in
                    zip(wire.points, wire.points.dropFirst()).contains { ConnectivityBuilder.liesOnSegment(location, $0, $1) }
                }
                let net = nets.first { $0.connectedPins.contains(PinRef(symbolId: symbol.id, pinId: pin.id)) }
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

        // A source is needed to excite the circuit.
        let hasSource = symbols.contains {
            let symbol = ComponentRegistry.shared.descriptor(for: $0.descriptorId)?.symbol
            return symbol == .voltageSource || symbol == .currentSource
        }
        if !hasSource {
            diagnostics.append(Diagnostic(
                severity: .warning,
                message: "The circuit has no independent source, so analysis results will be all zero."
            ))
        }

        return diagnostics.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.message < rhs.message
        }
    }

    private static func locationOf(pin: PinDescriptor, on symbol: SymbolInstance) -> GridPoint {
        let offset = rotatedOffset(pin.position, rotation: symbol.rotation)
        return GridPoint(symbol.position.x + offset.x, symbol.position.y + offset.y)
    }

    private static func rotatedOffset(_ position: CGPoint, rotation: Int) -> (x: Int, y: Int) {
        let x = Int((position.x / GridPoint.gridSize).rounded())
        let y = Int((position.y / GridPoint.gridSize).rounded())
        switch ((rotation % 360) + 360) % 360 {
        case 90: return (-y, x)
        case 180: return (-x, -y)
        case 270: return (y, -x)
        default: return (x, y)
        }
    }
}
