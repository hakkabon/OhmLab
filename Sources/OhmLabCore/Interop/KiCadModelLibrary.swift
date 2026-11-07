// KiCadModelLibrary.swift
// Generates the SPICE model library referenced by written KiCad schematics.
//
// Every semiconductor symbol gets its own uniquely named `.model` card built
// from the OhmLab symbol's parameters. This keeps KiCad's own simulator and
// `kicad-cli sch export netlist` working without any external vendor files.

import Foundation

public struct KiCadModelLibraryResult: Sendable {
    /// Model name keyed by the symbol's OhmLab UUID.
    public var modelNameBySymbolID: [UUID: String]
    /// The complete `.lib` text.
    public var text: String

    public init(modelNameBySymbolID: [UUID: String], text: String) {
        self.modelNameBySymbolID = modelNameBySymbolID
        self.text = text
    }
}

public enum KiCadModelLibrary {
    public static let fileName = "ohmlab_models.lib"
    public static let relativePath = "models/ohmlab_models.lib"

    /// Builds model cards for every semiconductor in the hierarchy. The
    /// traversal order is the snapshot's sheet order, then reference order, so
    /// the output is deterministic.
    public static func make(for snapshot: SchematicSnapshot) -> KiCadModelLibraryResult {
        var namesByID: [UUID: String] = [:]
        var usedNames: Set<String> = []
        var cards: [String] = []

        let symbols = allSymbols(in: snapshot)
        for symbol in symbols {
            guard symbol.sheetRef == nil,
                  let descriptor = ComponentRegistry.shared.descriptor(for: symbol.descriptorId),
                  isSemiconductor(descriptor.symbol) else { continue }
            let base = modelNameBase(for: symbol, descriptor: descriptor)
            let name = uniqueName(base: base, used: &usedNames)
            namesByID[symbol.id] = name
            cards.append(modelCard(for: symbol, descriptor: descriptor, name: name))
        }

        var lines: [String] = ["* OhmLab generated simulation models"]
        lines.append(contentsOf: cards.sorted())
        return KiCadModelLibraryResult(
            modelNameBySymbolID: namesByID,
            text: lines.joined(separator: "\n") + "\n"
        )
    }

    static func allSymbols(in snapshot: SchematicSnapshot) -> [SymbolInstance] {
        var result = snapshot.symbols.sorted(by: symbolOrder)
        for sheet in snapshot.sheets {
            result.append(contentsOf: sheet.symbols.sorted(by: symbolOrder))
        }
        return result
    }

    static func symbolOrder(_ first: SymbolInstance, _ second: SymbolInstance) -> Bool {
        if first.refDes == second.refDes {
            return first.id.uuidString < second.id.uuidString
        }
        return first.refDes < second.refDes
    }

    static func isSemiconductor(_ symbol: ComponentSymbol) -> Bool {
        switch symbol {
        case .diode, .npnTransistor, .pnpTransistor,
             .nmosTransistor, .pmosTransistor,
             .njfTransistor, .pjfTransistor:
            return true
        default:
            return false
        }
    }

    static func modelNameBase(for symbol: SymbolInstance, descriptor: ComponentDescriptor) -> String {
        let prefix: String
        switch descriptor.symbol {
        case .diode: prefix = "DMOD"
        case .npnTransistor, .pnpTransistor: prefix = "QMOD"
        case .nmosTransistor, .pmosTransistor: prefix = "MMOD"
        case .njfTransistor, .pjfTransistor: prefix = "JMOD"
        default: prefix = "XMOD"
        }
        var reference = symbol.refDes.uppercased().map { character -> Character in
            character.isLetter || character.isNumber || character == "_" ? character : "_"
        }
        if reference.isEmpty { reference = Array("X") }
        return "\(prefix)_\(String(reference))"
    }

    static func uniqueName(base: String, used: inout Set<String>) -> String {
        var candidate = base
        var suffix = 2
        while !used.insert(candidate).inserted {
            candidate = "\(base)_\(suffix)"
            suffix += 1
        }
        return candidate
    }

    static func modelCard(
        for symbol: SymbolInstance,
        descriptor: ComponentDescriptor,
        name: String
    ) -> String {
        func value(_ key: String, default fallback: Double) -> Double {
            symbol.parameters[key] ?? descriptor.defaultParameterValues[key] ?? fallback
        }

        switch descriptor.symbol {
        case .diode:
            var card = ".model \(name) D(IS=\(KiCadRoundTrip.spiceNumber(value("saturationCurrent", default: 1e-14)))"
            card += " N=\(KiCadRoundTrip.spiceNumber(value("emissionCoefficient", default: 1)))"
            let resistance = value("seriesResistance", default: 0)
            if resistance > 0 {
                card += " RS=\(KiCadRoundTrip.spiceNumber(resistance))"
            }
            return card + ")"
        case .npnTransistor, .pnpTransistor:
            let type = descriptor.symbol == .pnpTransistor ? "PNP" : "NPN"
            return ".model \(name) \(type)(IS=\(KiCadRoundTrip.spiceNumber(value("saturationCurrent", default: 1e-15)))"
                + " BF=\(KiCadRoundTrip.spiceNumber(value("forwardBeta", default: 100)))"
                + " BR=\(KiCadRoundTrip.spiceNumber(value("reverseBeta", default: 1)))" + ")"
        case .nmosTransistor, .pmosTransistor:
            let type = descriptor.symbol == .pmosTransistor ? "PMOS" : "NMOS"
            return ".model \(name) \(type)(VTO=\(KiCadRoundTrip.spiceNumber(value("thresholdVoltage", default: 1)))"
                + " KP=\(KiCadRoundTrip.spiceNumber(value("transconductanceParameter", default: 2e-5)))"
                + " LAMBDA=\(KiCadRoundTrip.spiceNumber(value("channelLengthModulation", default: 0)))"
                + " GAMMA=\(KiCadRoundTrip.spiceNumber(value("bodyEffect", default: 0)))"
                + " PHI=\(KiCadRoundTrip.spiceNumber(value("surfacePotential", default: 0.6)))" + ")"
        case .njfTransistor, .pjfTransistor:
            let type = descriptor.symbol == .pjfTransistor ? "PJF" : "NJF"
            return ".model \(name) \(type)(VTO=\(KiCadRoundTrip.spiceNumber(value("thresholdVoltage", default: -2)))"
                + " BETA=\(KiCadRoundTrip.spiceNumber(value("transconductanceParameter", default: 1e-4)))"
                + " LAMBDA=\(KiCadRoundTrip.spiceNumber(value("channelLengthModulation", default: 0)))"
                + " IS=\(KiCadRoundTrip.spiceNumber(value("gateSaturationCurrent", default: 1e-14)))" + ")"
        default:
            return ""
        }
    }
}
