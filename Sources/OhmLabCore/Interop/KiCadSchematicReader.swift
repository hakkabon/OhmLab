// KiCadSchematicReader.swift
// Direct, native reading of KiCad `.kicad_sch` projects.
//
// This is the first half of KiCad Schematic Interop: OhmLab parses the
// schematic hierarchy itself instead of invoking `kicad-cli`. The reader
// preserves KiCad UUIDs, reference designators, values, hierarchy, and model
// library references, and derives electrical connectivity from KiCad's own
// wires, junctions, labels, and pin geometry.
//
// OhmLab's schematic model uses its own symbol geometry, so the reader keeps
// each component's KiCad position but attaches net labels directly to the
// corresponding OhmLab pins. That keeps the result editable and guarantees the
// projected netlist matches the connectivity KiCad reported.

import Foundation

public enum KiCadSchematicReaderError: LocalizedError, Equatable {
    case unreadableFile(String)
    case malformed(String)
    case notASchematic(String)
    case cyclicHierarchy(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let name):
            return "Could not read \(name)."
        case .malformed(let detail):
            return "The KiCad schematic is malformed: \(detail)"
        case .notASchematic(let name):
            return "\(name) is not a KiCad schematic."
        case .cyclicHierarchy(let name):
            return "The KiCad sheet hierarchy contains a cycle at \(name)."
        }
    }
}

public struct KiCadSchematicReadResult: Sendable {
    public var snapshot: SchematicSnapshot
    public var modelLibraries: [SpiceModelLibrary]
    public var warnings: [String]
    public var sourceFiles: [URL]
    public var rootSchematic: URL

    public init(
        snapshot: SchematicSnapshot,
        modelLibraries: [SpiceModelLibrary],
        warnings: [String],
        sourceFiles: [URL],
        rootSchematic: URL
    ) {
        self.snapshot = snapshot
        self.modelLibraries = modelLibraries
        self.warnings = warnings
        self.sourceFiles = sourceFiles
        self.rootSchematic = rootSchematic
    }
}

public enum KiCadSchematicReader {
    /// Reads a KiCad project (`.kicad_pro`), a root schematic, or any child
    /// schematic and returns the whole hierarchy.
    public static func readProject(at url: URL) throws -> KiCadSchematicReadResult {
        let root = KiCadProjectInterchange.rootSchematic(for: url) ?? url
        let reader = Reader(rootURL: root)
        return try reader.read()
    }

    /// Reads a single `.kicad_sch` file and any sheets it references.
    public static func readSchematic(at url: URL) throws -> KiCadSchematicReadResult {
        try readProject(at: url)
    }
}

// MARK: - Reader

private final class Reader {
    private let rootURL: URL
    private var warnings: [String] = []
    private var sourceFiles: [URL] = []
    private var childSheets: [Sheet] = []
    private var visited: Set<URL> = []
    private var librariesByPath: [String: SpiceModelLibrary] = [:]
    private var storedLibraries: [SpiceModelLibrary] = []
    private var definitions = LibraryDefinitions()
    private var nextSubcircuitIndex = 1
    private var nextGroundIndex = 1

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    func read() throws -> KiCadSchematicReadResult {
        let root = try buildSheet(
            at: rootURL,
            name: rootURL.deletingPathExtension().lastPathComponent,
            ports: []
        )
        let snapshot = SchematicSnapshot(
            symbols: root.symbols,
            wires: root.wires,
            netLabels: root.netLabels,
            sheets: childSheets
        )
        return KiCadSchematicReadResult(
            snapshot: snapshot,
            modelLibraries: storedLibraries,
            warnings: warnings,
            sourceFiles: sourceFiles,
            rootSchematic: rootURL
        )
    }

    // MARK: - Hierarchy

    private func buildSheet(at url: URL, name: String, ports: [SheetPort]) throws -> Sheet {
        let standardized = url.standardizedFileURL
        guard !visited.contains(standardized) else {
            warnings.append("Skipped cyclic sheet reference to \(url.lastPathComponent).")
            throw KiCadSchematicReaderError.cyclicHierarchy(url.lastPathComponent)
        }
        visited.insert(standardized)

        let file = try load(standardized)
        collectLibraries(from: file, relativeTo: standardized.deletingLastPathComponent())

        let sheetID = file.uuid ?? stableUUID(for: standardized.path)
        let content = try buildContent(
            file: file,
            fileURL: standardized,
            sheetName: name,
            sheetID: sheetID,
            ports: ports
        )

        visited.remove(standardized)
        return Sheet(
            id: sheetID,
            name: name,
            ports: ports,
            symbols: content.symbols,
            wires: [],
            netLabels: content.labels
        )
    }

    private func load(_ url: URL) throws -> KiCadSchematicFile {
        guard let data = try? Data(contentsOf: url) else {
            throw KiCadSchematicReaderError.unreadableFile(url.lastPathComponent)
        }
        let text = String(decoding: data, as: UTF8.self)
        do {
            let file = try KiCadSchematicFile.parse(text, fileName: url.lastPathComponent)
            sourceFiles.append(url)
            return file
        } catch let error as KiCadSchematicParseError {
            switch error {
            case .notASchematic(let name):
                throw KiCadSchematicReaderError.notASchematic(name)
            case .malformed(let detail):
                throw KiCadSchematicReaderError.malformed(detail)
            }
        } catch {
            throw KiCadSchematicReaderError.malformed(error.localizedDescription)
        }
    }

    // MARK: - Content

    private struct MappedSymbol {
        var kicad: KiCadPlacedSymbol
        var descriptor: ComponentDescriptor
        var parameters: [String: Double]
        /// Descriptor pin id -> KiCad pin number (nil for subcircuit instances).
        var pinNumbers: [String: String]
        /// KiCad pin number -> library pin definition, used for pin geometry.
        var libraryPins: [String: KiCadLibraryPin]
        var symbol: SymbolInstance
        var isGround: Bool
        var isSubcircuit: Bool
        var sheetPins: [KiCadSheetPin]
    }

    private struct Content {
        var symbols: [SymbolInstance] = []
        var labels: [NetLabel] = []
    }

    private func buildContent(
        file: KiCadSchematicFile,
        fileURL: URL,
        sheetName: String,
        sheetID: UUID,
        ports: [SheetPort]
    ) throws -> Content {
        var mapped: [MappedSymbol] = []
        var usedReferences: Set<String> = []

        // Placed components.
        for placed in file.symbols {
            if placed.dnp {
                warnings.append("Skipped \(placed.reference) because it is marked DNP.")
                continue
            }
            if placed.excludeFromSimulation {
                warnings.append("Skipped \(placed.reference) because it is excluded from simulation.")
                continue
            }
            guard let library = librarySymbol(for: placed.libId, in: file) else {
                warnings.append("Skipped \(displayName(for: placed)): its library symbol \(placed.libId) is not embedded in the schematic.")
                continue
            }
            guard let mapping = mapping(
                for: placed,
                library: library
            ) else {
                warnings.append("Skipped unsupported symbol \(displayName(for: placed)) (\(placed.libId)).")
                continue
            }

            let reference = uniqueReference(
                preferred: placed.properties[KiCadRoundTrip.referenceProperty]
                    ?? (mapping.isGround ? "GND" : placed.reference),
                descriptor: mapping.descriptor,
                used: &usedReferences,
                original: placed.reference
            )
            let symbol = SymbolInstance(
                id: placed.uuid ?? stableUUID(for: "\(fileURL.path)/\(placed.reference)"),
                descriptorId: mapping.descriptor.id,
                refDes: reference,
                position: placed.at.point.grid,
                rotation: normalizedRotation(placed.at.angle),
                parameters: mapping.parameters
            )
            mapped.append(MappedSymbol(
                kicad: placed,
                descriptor: mapping.descriptor,
                parameters: mapping.parameters,
                pinNumbers: mapping.pinNumbers,
                libraryPins: Dictionary(
                    uniqueKeysWithValues: library.pins(for: placed.unit).map { ($0.number, $0) }
                ),
                symbol: symbol,
                isGround: mapping.isGround,
                isSubcircuit: false,
                sheetPins: []
            ))
        }

        // Child sheets become subcircuit instances.
        for sheet in file.sheets {
            let childURL = resolve(sheet.file, relativeTo: fileURL.deletingLastPathComponent())
            guard FileManager.default.fileExists(atPath: childURL.path) else {
                warnings.append("Sheet \(sheet.name) references missing file \(sheet.file).")
                continue
            }
            let childPorts = sheet.pins.map {
                SheetPort(
                    id: stableUUID(for: "\(fileURL.path)/sheet/\(sheet.name)/port/\($0.name)"),
                    name: $0.name,
                    isInput: $0.shape.lowercased() != "output"
                )
            }
            let child: Sheet
            do {
                child = try buildSheet(at: childURL, name: sheet.name, ports: childPorts)
            } catch KiCadSchematicReaderError.cyclicHierarchy {
                continue
            }
            childSheets.append(child)

            let reference = sheet.properties[KiCadRoundTrip.referenceProperty]
                ?? "X\(nextSubcircuitIndex)"
            nextSubcircuitIndex += 1
            let position = sheet.properties[KiCadRoundTrip.positionProperty]
                .flatMap(KiCadRoundTrip.decode(position:))
                ?? sheet.at.point.grid
            let symbol = SymbolInstance(
                id: sheet.uuid ?? stableUUID(for: "\(fileURL.path)/sheet/\(sheet.name)"),
                descriptorId: SubcircuitInstance.descriptorId,
                refDes: reference,
                position: position,
                sheetRef: child.id
            )
            let descriptor = SubcircuitInstance.descriptor(for: symbol, sheet: child)
            mapped.append(MappedSymbol(
                kicad: KiCadPlacedSymbol(
                    libId: SubcircuitInstance.descriptorId,
                    at: sheet.at,
                    mirror: nil,
                    unit: 1,
                    uuid: sheet.uuid,
                    properties: [:],
                    pinUUIDs: [:],
                    reference: reference,
                    value: sheet.name,
                    dnp: false,
                    excludeFromSimulation: false
                ),
                descriptor: descriptor,
                parameters: [:],
                pinNumbers: [:],
                libraryPins: [:],
                symbol: symbol,
                isGround: false,
                isSubcircuit: true,
                sheetPins: sheet.pins
            ))
        }

        // Electrical connectivity from KiCad geometry.
        let solverPins = solverPins(for: mapped)
        let solverLabels = file.labels.map {
            SolverLabel(name: $0.name, point: $0.at.point.grid, kind: $0.kind)
        }
        let netNames = solveNets(
            pins: solverPins,
            labels: solverLabels,
            wires: file.wires,
            junctions: file.junctions,
            portNames: ports.map(\.name)
        )

        // Place symbols without letting two pins share a grid point, which
        // would short unrelated nets in OhmLab's vertex-based connectivity.
        let placed = place(mapped)

        var content = Content()
        content.symbols = placed.map(\.symbol)
        var seenLabels: Set<LabelKey> = []

        // Synthesised labels need deterministic identities so that reading the
        // same KiCad file twice (and therefore writing it twice) produces the
        // same bytes.
        func labelID(_ name: String, _ point: GridPoint) -> UUID {
            stableUUID(for: "\(fileURL.path)/\(sheetName)/label/\(name)/\(point.x)/\(point.y)")
        }

        for entry in placed {
            let netByPin = netNames[entry.symbol.id] ?? [:]
            for pin in entry.descriptor.pins {
                guard let net = netByPin[pin.id] else { continue }
                let location = PinGeometry.location(of: pin, on: entry.symbol)
                appendLabel(
                    NetLabel(id: labelID(net, location), name: net, position: location),
                    to: &content.labels,
                    seen: &seenLabels
                )
            }
        }

        // A ground symbol is required for OhmLab's root netlist builder and
        // makes `isGround` explicit. The fixture's KiCad ground symbols become
        // real OhmLab ground symbols above; this covers nets that only carry a
        // `0` label.
        let groundNets = Set(netNames.values.flatMap { $0.values }.filter { $0 == "0" })
        let representedGroundNets = Set(
            placed.filter(\.isGround).flatMap { entry in
                (netNames[entry.symbol.id] ?? [:]).values
            }
        )
        for _ in groundNets.subtracting(representedGroundNets) {
            let ground = SymbolInstance(
                id: stableUUID(for: "\(fileURL.path)/\(sheetName)/ground/\(nextGroundIndex)"),
                descriptorId: "ground",
                refDes: "GND\(nextGroundIndex)",
                position: GridPoint(2, 2 + nextGroundIndex * 2)
            )
            nextGroundIndex += 1
            content.symbols.append(ground)
            if let descriptor = ComponentRegistry.shared.descriptor(for: "ground"),
               let pin = descriptor.pins.first {
                let location = PinGeometry.location(of: pin, on: ground)
                appendLabel(
                    NetLabel(id: labelID("0", location), name: "0", position: location),
                    to: &content.labels,
                    seen: &seenLabels
                )
            }
        }

        // Ports that have no hierarchical label still need a node with the
        // port's name so the generated `.subckt` header and body agree.
        let labelNames = Set(content.labels.map { $0.name.uppercased() })
        for (index, port) in ports.enumerated() where !labelNames.contains(port.name.uppercased()) {
            warnings.append("Sheet \(sheetName) has no hierarchical label for port \(port.name).")
            let location = GridPoint(-4 - index, 2)
            appendLabel(
                NetLabel(id: labelID(port.name, location), name: port.name, position: location),
                to: &content.labels,
                seen: &seenLabels
            )
        }

        return content
    }

    // MARK: - Symbol mapping

    private struct SymbolMapping {
        var descriptor: ComponentDescriptor
        var parameters: [String: Double]
        var pinNumbers: [String: String]
        var isGround: Bool
    }

    private func librarySymbol(for libId: String, in file: KiCadSchematicFile) -> KiCadLibrarySymbol? {
        if let exact = file.librarySymbols[libId] { return exact }
        // Older KiCad files occasionally omit the library prefix.
        let suffix = libId.split(separator: ":").last.map(String.init) ?? libId
        return file.librarySymbols.first { key, _ in
            key.split(separator: ":").last.map(String.init) == suffix
        }?.value
    }

    private func mapping(for placed: KiCadPlacedSymbol, library: KiCadLibrarySymbol) -> SymbolMapping? {
        let referencePrefix = placed.reference.uppercased().first
        let lib = placed.libId.lowercased()
        let symbolName = (lib.split(separator: ":").last.map(String.init) ?? lib)
            .replacingOccurrences(of: "_small", with: "")
        let simPins = placed.properties["Sim.Pins"]

        func descriptor(_ id: String) -> ComponentDescriptor? {
            ComponentRegistry.shared.descriptor(for: id)
        }

        // Round-trip metadata written by OhmLab is authoritative: it preserves
        // the exact descriptor, parameters, and pin order even when KiCad's own
        // properties cannot express them (for example a MOSFET's full model).
        if let descriptorId = placed.properties[KiCadRoundTrip.descriptorProperty],
           let roundTripped = descriptor(descriptorId) {
            var parameters = roundTripped.defaultParameterValues
            if let encoded = placed.properties[KiCadRoundTrip.parametersProperty] {
                parameters.merge(KiCadRoundTrip.decode(parameters: encoded)) { _, new in new }
            }
            var pinNumbers: [String: String] = [:]
            let roles = KiCadSymbolLibrary.pinRoles(for: roundTripped)
            if !roles.isEmpty {
                pinNumbers = self.pinNumbers(
                    descriptor: roundTripped,
                    library: library,
                    symbol: placed,
                    simPins: simPins,
                    roles: roles
                )
            } else {
                for (index, pin) in roundTripped.pins.enumerated() {
                    pinNumbers[pin.id] = String(index + 1)
                }
            }
            return SymbolMapping(
                descriptor: roundTripped,
                parameters: parameters,
                pinNumbers: pinNumbers,
                isGround: roundTripped.symbol == .ground
            )
        }

        // Ground / power symbols.
        if library.isPower
            || lib.hasPrefix("power:")
            || lib == "simulation_spice:0"
            || referencePrefix == "#"
            || ["gnd", "earth", "gndref", "gndpwr", "gnda", "gndd"].contains(symbolName) {
            guard let ground = descriptor("ground") else { return nil }
            return SymbolMapping(
                descriptor: ground,
                parameters: [:],
                pinNumbers: pinNumbers(
                    descriptor: ground,
                    library: library,
                    symbol: placed,
                    simPins: simPins,
                    roles: []
                ),
                isGround: true
            )
        }

        // Two-terminal passives.
        if referencePrefix == "R" || symbolName.hasPrefix("r") {
            guard let descriptor = descriptor("resistor") else { return nil }
            var parameters = descriptor.defaultParameterValues
            parameters["resistance"] = number(from: placed.value) ?? parameters["resistance"]
            if number(from: placed.value) == nil {
                warnings.append("\(displayName(for: placed)): using the default resistance (value \(placed.value) was not numeric).")
            }
            return SymbolMapping(
                descriptor: descriptor,
                parameters: parameters,
                pinNumbers: pinNumbers(descriptor: descriptor, library: library, symbol: placed, simPins: simPins, roles: []),
                isGround: false
            )
        }
        if referencePrefix == "C" || symbolName.hasPrefix("c") {
            guard let descriptor = descriptor("capacitor") else { return nil }
            var parameters = descriptor.defaultParameterValues
            parameters["capacitance"] = number(from: placed.value) ?? parameters["capacitance"]
            if number(from: placed.value) == nil {
                warnings.append("\(displayName(for: placed)): using the default capacitance (value \(placed.value) was not numeric).")
            }
            return SymbolMapping(
                descriptor: descriptor,
                parameters: parameters,
                pinNumbers: pinNumbers(descriptor: descriptor, library: library, symbol: placed, simPins: simPins, roles: []),
                isGround: false
            )
        }
        if referencePrefix == "L" || symbolName.hasPrefix("l") {
            guard let descriptor = descriptor("inductor") else { return nil }
            var parameters = descriptor.defaultParameterValues
            parameters["inductance"] = number(from: placed.value) ?? parameters["inductance"]
            if number(from: placed.value) == nil {
                warnings.append("\(displayName(for: placed)): using the default inductance (value \(placed.value) was not numeric).")
            }
            return SymbolMapping(
                descriptor: descriptor,
                parameters: parameters,
                pinNumbers: pinNumbers(descriptor: descriptor, library: library, symbol: placed, simPins: simPins, roles: []),
                isGround: false
            )
        }

        // Independent sources.
        if referencePrefix == "V" || symbolName.hasPrefix("v") {
            guard let descriptor = descriptor("voltage-source") else { return nil }
            var parameters = descriptor.defaultParameterValues
            parameters.merge(sourceParameters(
                from: placed.value,
                simParams: placed.properties["Sim.Params"],
                symbolName: symbolName,
                dcKey: "dcVoltage"
            )) { _, new in new }
            return SymbolMapping(
                descriptor: descriptor,
                parameters: parameters,
                pinNumbers: pinNumbers(descriptor: descriptor, library: library, symbol: placed, simPins: simPins, roles: ["+", "-"]),
                isGround: false
            )
        }
        if referencePrefix == "I" || symbolName.hasPrefix("i") {
            guard let descriptor = descriptor("current-source") else { return nil }
            var parameters = descriptor.defaultParameterValues
            parameters.merge(sourceParameters(
                from: placed.value,
                simParams: placed.properties["Sim.Params"],
                symbolName: symbolName,
                dcKey: "dcCurrent"
            )) { _, new in new }
            return SymbolMapping(
                descriptor: descriptor,
                parameters: parameters,
                pinNumbers: pinNumbers(descriptor: descriptor, library: library, symbol: placed, simPins: simPins, roles: ["+", "-"]),
                isGround: false
            )
        }

        // Diodes.
        if referencePrefix == "D" || symbolName.hasPrefix("d") || symbolName.hasPrefix("led") {
            guard let descriptor = descriptor("diode") else { return nil }
            var parameters = descriptor.defaultParameterValues
            let modelName = (placed.properties["Sim.Name"] ?? placed.value).uppercased()
            if let model = definitions.diodeModels[modelName] {
                parameters["saturationCurrent"] = model.saturationCurrent
                parameters["emissionCoefficient"] = model.emissionCoefficient
                parameters["seriesResistance"] = model.seriesResistance
            } else if !modelName.isEmpty {
                warnings.append("\(displayName(for: placed)): diode model \(modelName) was not found; using editor defaults.")
            }
            return SymbolMapping(
                descriptor: descriptor,
                parameters: parameters,
                pinNumbers: pinNumbers(descriptor: descriptor, library: library, symbol: placed, simPins: simPins, roles: ["A", "K"]),
                isGround: false
            )
        }

        // Bipolar transistors.
        if referencePrefix == "Q" || lib.contains("transistor_bjt") {
            let modelName = (placed.properties["Sim.Name"] ?? placed.value).uppercased()
            let model = definitions.bjtModels[modelName]
            let isPNP = model?.polarity == .pnp || symbolName.contains("pnp")
            let descriptorId = isPNP ? "pnp-transistor" : "npn-transistor"
            guard let descriptor = descriptor(descriptorId) else { return nil }
            var parameters = descriptor.defaultParameterValues
            if let model {
                parameters["saturationCurrent"] = model.saturationCurrent
                parameters["forwardBeta"] = model.forwardBeta
                parameters["reverseBeta"] = model.reverseBeta
            } else if !modelName.isEmpty {
                warnings.append("\(displayName(for: placed)): BJT model \(modelName) was not found; using editor defaults.")
            }
            return SymbolMapping(
                descriptor: descriptor,
                parameters: parameters,
                pinNumbers: pinNumbers(descriptor: descriptor, library: library, symbol: placed, simPins: simPins, roles: ["C", "B", "E"]),
                isGround: false
            )
        }

        // MOSFETs.
        if referencePrefix == "M" || lib.contains("transistor_fet") {
            let modelName = (placed.properties["Sim.Name"] ?? placed.value).uppercased()
            let model = definitions.mosfetModels[modelName]
            let isPMOS = model?.polarity == .pmos || symbolName.contains("pmos")
            let descriptorId = isPMOS ? "pmos-transistor" : "nmos-transistor"
            guard let descriptor = descriptor(descriptorId) else { return nil }
            var parameters = descriptor.defaultParameterValues
            if let model {
                parameters["thresholdVoltage"] = model.thresholdVoltage
                parameters["transconductanceParameter"] = model.transconductanceParameter
                parameters["channelLengthModulation"] = model.channelLengthModulation
                parameters["bodyEffect"] = model.bodyEffect
                parameters["surfacePotential"] = model.surfacePotential
            } else if !modelName.isEmpty {
                warnings.append("\(displayName(for: placed)): MOSFET model \(modelName) was not found; using editor defaults.")
            }
            return SymbolMapping(
                descriptor: descriptor,
                parameters: parameters,
                pinNumbers: pinNumbers(descriptor: descriptor, library: library, symbol: placed, simPins: simPins, roles: ["D", "G", "S", "B"]),
                isGround: false
            )
        }

        // JFETs.
        if referencePrefix == "J" || lib.contains("transistor_jfet") {
            let modelName = (placed.properties["Sim.Name"] ?? placed.value).uppercased()
            let model = definitions.jfetModels[modelName]
            let isPJF = model?.polarity == .pjf || symbolName.contains("pjf")
            let descriptorId = isPJF ? "pjfet-transistor" : "njfet-transistor"
            guard let descriptor = descriptor(descriptorId) else { return nil }
            var parameters = descriptor.defaultParameterValues
            if let model {
                parameters["thresholdVoltage"] = model.thresholdVoltage
                parameters["transconductanceParameter"] = model.transconductanceParameter
                parameters["channelLengthModulation"] = model.channelLengthModulation
                parameters["gateSaturationCurrent"] = model.gateSaturationCurrent
            } else if !modelName.isEmpty {
                warnings.append("\(displayName(for: placed)): JFET model \(modelName) was not found; using editor defaults.")
            }
            return SymbolMapping(
                descriptor: descriptor,
                parameters: parameters,
                pinNumbers: pinNumbers(descriptor: descriptor, library: library, symbol: placed, simPins: simPins, roles: ["D", "G", "S"]),
                isGround: false
            )
        }

        return nil
    }

    /// Maps each descriptor pin to the KiCad pin number that carries it. The
    /// canonical roles (`A`/`K`, `C`/`B`/`E`, `+`/`-`, …) come from SPICE's
    /// device pin order; KiCad's `Sim.Pins` and library pin names provide the
    /// KiCad side of the mapping.
    private func pinNumbers(
        descriptor: ComponentDescriptor,
        library: KiCadLibrarySymbol,
        symbol: KiCadPlacedSymbol,
        simPins: String?,
        roles: [String]
    ) -> [String: String] {
        let pins = library.pins(for: symbol.unit)
        let sortedPins = pins.sorted { pinNumberOrder($0.number) < pinNumberOrder($1.number) }
        let roleByNumber = rolesByPinNumber(pins: pins, simPins: simPins)
        var result: [String: String] = [:]

        if roles.isEmpty {
            for (index, pin) in descriptor.pins.enumerated() {
                guard index < sortedPins.count else { break }
                result[pin.id] = sortedPins[index].number
            }
            return result
        }

        for (index, pin) in descriptor.pins.enumerated() {
            let role = index < roles.count ? roles[index] : ""
            if let number = roleByNumber.first(where: { normalizedRole($0.value) == normalizedRole(role) })?.key {
                result[pin.id] = number
            } else if index < sortedPins.count {
                result[pin.id] = sortedPins[index].number
            }
        }
        return result
    }

    private func rolesByPinNumber(pins: [KiCadLibraryPin], simPins: String?) -> [String: String] {
        var roles: [String: String] = [:]
        for pin in pins {
            if !pin.name.trimmingCharacters(in: .whitespaces).isEmpty {
                roles[pin.number] = pin.name
            }
        }
        if let simPins {
            for entry in simPins.split(whereSeparator: { $0.isWhitespace }) {
                let parts = entry.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                roles[String(parts[0])] = String(parts[1])
            }
        }
        return roles
    }

    private func normalizedRole(_ role: String) -> String {
        let trimmed = role.trimmingCharacters(in: .whitespaces).uppercased()
        switch trimmed {
        case "ANODE": return "A"
        case "CATHODE": return "K"
        case "COLLECTOR": return "C"
        case "BASE": return "B"
        case "EMITTER": return "E"
        case "DRAIN": return "D"
        case "GATE": return "G"
        case "SOURCE": return "S"
        case "BULK", "BODY": return "B"
        case "POSITIVE": return "+"
        case "NEGATIVE": return "-"
        default: return trimmed
        }
    }

    private func pinNumberOrder(_ number: String) -> Int {
        Int(number) ?? Int.max
    }

    private func number(from raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("{") else { return nil }
        return try? SpiceNetlistParser.parseNumber(trimmed, line: 0)
    }

    private func sourceParameters(
        from raw: String,
        simParams: String?,
        symbolName: String,
        dcKey: String
    ) -> [String: Double] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()
        var dc = number(from: trimmed) ?? 0
        var ac = 0.0
        if upper.hasPrefix("SIN(") || upper.hasPrefix("PULSE(") || upper.hasPrefix("PWL(") {
            let values = numbers(in: trimmed)
            dc = values.first ?? 0
            if upper.hasPrefix("SIN("), values.count > 1 { ac = values[1] }
            warnings.append("Source \(trimmed) uses a waveform; only its DC/AC values were imported.")
        } else if symbolName.contains("vac") || symbolName.contains("iac") {
            ac = dc
            dc = 0
        }
        var phase = 0.0
        if let simParams {
            for (key, value) in simParameterPairs(simParams) {
                switch key {
                case "dc": dc = value
                case "ac": ac = value
                case "phase": phase = value
                default: break
                }
            }
        }
        return [dcKey: dc, "acMagnitude": ac, "acPhaseDegrees": phase]
    }

    /// Parses KiCad's `Sim.Params` property. KiCad writes space-separated
    /// `key=value` pairs, but older files sometimes use `key value`.
    private func simParameterPairs(_ text: String) -> [(String, Double)] {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var result: [(String, Double)] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if let equals = token.firstIndex(of: "=") {
                let key = String(token[token.startIndex..<equals]).lowercased()
                let valueText = String(token[token.index(after: equals)...])
                if let value = number(from: valueText) {
                    result.append((key, value))
                }
            } else if index + 1 < tokens.count, let value = number(from: tokens[index + 1]) {
                result.append((token.lowercased(), value))
                index += 1
            }
            index += 1
        }
        return result
    }

    private func numbers(in text: String) -> [Double] {
        var values: [Double] = []
        var current = ""
        for character in text {
            if character.isNumber || character == "." || character == "+" || character == "-"
                || character == "e" || character == "E" {
                current.append(character)
            } else if !current.isEmpty {
                if let value = Double(current) { values.append(value) }
                current = ""
            }
        }
        if !current.isEmpty, let value = Double(current) { values.append(value) }
        return values
    }

    private func displayName(for symbol: KiCadPlacedSymbol) -> String {
        symbol.reference.isEmpty ? symbol.libId : symbol.reference
    }

    private func uniqueReference(
        preferred: String,
        descriptor: ComponentDescriptor,
        used: inout Set<String>,
        original: String
    ) -> String {
        let prefix = descriptor.prefix.first.map(String.init) ?? "X"
        var candidate = preferred.uppercased()
        let valid = candidate.first.map { $0 == prefix.first } == true
            && candidate.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        if !valid {
            candidate = "\(prefix)\(used.count + 1)"
            if !original.isEmpty {
                warnings.append("Renamed \(original) to \(candidate) for SPICE compatibility.")
            }
        }
        let base = candidate
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(base)_\(suffix)"
            suffix += 1
        }
        used.insert(candidate)
        return candidate
    }

    private func normalizedRotation(_ angle: Double) -> Int {
        let rounded = Int(angle.rounded())
        return ((rounded % 360) + 360) % 360
    }

    // MARK: - Model libraries

    private func collectLibraries(from file: KiCadSchematicFile, relativeTo directory: URL) {
        for symbol in file.symbols {
            guard let path = symbol.properties["Sim.Library"],
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let url = resolve(path, relativeTo: directory)
            let key = url.standardizedFileURL.path
            if librariesByPath[key] != nil { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                warnings.append("Could not read model library \(path).")
                continue
            }
            do {
                let library = try SpiceModelLibrary.parse(
                    text,
                    name: url.deletingPathExtension().lastPathComponent,
                    sourcePath: url.path
                )
                librariesByPath[key] = library
                storedLibraries.append(library)
                merge(library.definitions)
            } catch {
                warnings.append("Model library \(path) contains no usable definitions.")
            }
        }
    }

    private func merge(_ other: LibraryDefinitions) {
        definitions.diodeModels.merge(other.diodeModels) { _, new in new }
        definitions.bjtModels.merge(other.bjtModels) { _, new in new }
        definitions.mosfetModels.merge(other.mosfetModels) { _, new in new }
        definitions.jfetModels.merge(other.jfetModels) { _, new in new }
        definitions.subcircuits.merge(other.subcircuits) { _, new in new }
    }

    // MARK: - Connectivity

    private struct SolverPin: Hashable {
        var symbolID: UUID
        var pinID: String
        var point: GridPoint
        var isGround: Bool
        var suggestedName: String?
        var reference: String
    }

    private struct SolverLabel {
        var name: String
        var point: GridPoint
        var kind: KiCadLabelKind
    }

    private func solverPins(for mapped: [MappedSymbol]) -> [SolverPin] {
        var pins: [SolverPin] = []
        for entry in mapped {
            if entry.isSubcircuit {
                for sheetPin in entry.sheetPins {
                    pins.append(SolverPin(
                        symbolID: entry.symbol.id,
                        pinID: sheetPin.name,
                        point: sheetPin.at.point.grid,
                        isGround: false,
                        suggestedName: sheetPin.name,
                        reference: entry.symbol.refDes
                    ))
                }
                continue
            }
            for descriptorPin in entry.descriptor.pins {
                guard let number = entry.pinNumbers[descriptorPin.id],
                      let libraryPin = entry.libraryPins[number] else {
                    continue
                }
                let point = transform(libraryPin.at, for: entry.kicad).grid
                pins.append(SolverPin(
                    symbolID: entry.symbol.id,
                    pinID: descriptorPin.id,
                    point: point,
                    isGround: entry.isGround,
                    suggestedName: nil,
                    reference: entry.symbol.refDes
                ))
            }
        }
        return pins
    }

    private func solveNets(
        pins: [SolverPin],
        labels: [SolverLabel],
        wires: [KiCadWire],
        junctions: [KiCadPoint],
        portNames: [String]
    ) -> [UUID: [String: String]] {
        var unionFind = GridUnionFind()
        let segments: [(GridPoint, GridPoint)] = wires.flatMap { wire in
            let points = wire.points.map(\.grid)
            return zip(points, points.dropFirst()).map { ($0, $1) }
        }

        var allPoints = Set<GridPoint>()
        for segment in segments {
            allPoints.insert(segment.0)
            allPoints.insert(segment.1)
        }
        allPoints.formUnion(junctions.map(\.grid))
        allPoints.formUnion(pins.map(\.point))
        allPoints.formUnion(labels.map(\.point))

        for (start, end) in segments {
            unionFind.union(start, end)
        }
        for point in allPoints {
            for (start, end) in segments where ConnectivityBuilder.liesOnSegment(point, start, end) {
                unionFind.union(point, start)
            }
        }

        // Same-named labels are one net within a sheet, matching KiCad's local,
        // global, and hierarchical label semantics for the supported subset.
        var labelRoots: [String: GridPoint] = [:]
        for label in labels {
            let key = label.name.trimmingCharacters(in: .whitespaces).uppercased()
            guard !key.isEmpty else { continue }
            let root = unionFind.find(label.point)
            if let existing = labelRoots[key] {
                unionFind.union(existing, root)
            } else {
                labelRoots[key] = root
            }
        }

        var pinsByRoot: [GridPoint: [SolverPin]] = [:]
        for pin in pins {
            pinsByRoot[unionFind.find(pin.point), default: []].append(pin)
        }
        var labelsByRoot: [GridPoint: [SolverLabel]] = [:]
        for label in labels {
            labelsByRoot[unionFind.find(label.point), default: []].append(label)
        }

        let groundAliases: Set<String> = ["0", "GND", "GROUND", "AGND", "GNDA", "GNDD", "EARTH"]
        let declaredPorts = Dictionary(
            portNames.map { ($0.uppercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var usedNames: [String: GridPoint] = [:]
        var netNameByRoot: [GridPoint: String] = [:]
        var nextSynthetic = 1

        for (root, rootPins) in pinsByRoot {
            let rootLabels = labelsByRoot[root] ?? []
            let isGround = rootPins.contains(where: \.isGround)
                || rootLabels.contains { groundAliases.contains($0.name.uppercased()) }
            let name: String
            if isGround {
                name = "0"
            } else {
                name = chooseName(
                    labels: rootLabels,
                    pins: rootPins,
                    declaredPorts: declaredPorts,
                    used: &usedNames,
                    root: root,
                    nextSynthetic: &nextSynthetic
                )
            }
            netNameByRoot[root] = name
        }

        var result: [UUID: [String: String]] = [:]
        for pin in pins {
            let root = unionFind.find(pin.point)
            guard let name = netNameByRoot[root] else { continue }
            result[pin.symbolID, default: [:]][pin.pinID] = name
        }
        return result
    }

    private func chooseName(
        labels: [SolverLabel],
        pins: [SolverPin],
        declaredPorts: [String: String],
        used: inout [String: GridPoint],
        root: GridPoint,
        nextSynthetic: inout Int
    ) -> String {
        // A hierarchical label that matches a sheet port must keep the port's
        // spelling so the generated `.subckt` header and body agree.
        let sortedLabels = labels.sorted {
            priority($0.kind) == priority($1.kind)
                ? $0.name < $1.name
                : priority($0.kind) < priority($1.kind)
        }
        if let port = sortedLabels.first(where: { declaredPorts[$0.name.uppercased()] != nil }) {
            return unique(declaredPorts[port.name.uppercased()]!, root: root, used: &used)
        }
        if let label = sortedLabels.first {
            return unique(sanitize(label.name), root: root, used: &used)
        }
        if let suggested = pins.compactMap(\.suggestedName).sorted().first {
            return unique(sanitize(suggested), root: root, used: &used)
        }
        var name = "N\(nextSynthetic)"
        nextSynthetic += 1
        name = unique(name, root: root, used: &used)
        return name
    }

    private func priority(_ kind: KiCadLabelKind) -> Int {
        switch kind {
        case .hierarchical: return 0
        case .global: return 1
        case .local: return 2
        }
    }

    private func sanitize(_ raw: String) -> String {
        var result = ""
        for character in raw.trimmingCharacters(in: .whitespaces) {
            if character.isLetter || character.isNumber || character == "_" || character == "/"
                || character == "-" || character == "." || character == "+" {
                result.append(character)
            } else if character.isWhitespace {
                result.append("_")
            }
        }
        return result.isEmpty ? "N" : result
    }

    private func unique(_ name: String, root: GridPoint, used: inout [String: GridPoint]) -> String {
        let key = name.uppercased()
        if used[key] == nil {
            used[key] = root
            return name
        }
        if used[key] == root { return name }
        var suffix = 2
        while used["\(key)_\(suffix)"] != nil {
            suffix += 1
        }
        let candidate = "\(name)_\(suffix)"
        used[candidate.uppercased()] = root
        return candidate
    }

    // MARK: - Placement

    private func place(_ mapped: [MappedSymbol]) -> [MappedSymbol] {
        var placed: [MappedSymbol] = []
        var occupied: Set<GridPoint> = []
        let ordered = mapped.sorted {
            if $0.symbol.refDes == $1.symbol.refDes {
                return $0.symbol.id.uuidString < $1.symbol.id.uuidString
            }
            return $0.symbol.refDes < $1.symbol.refDes
        }

        for var entry in ordered {
            let candidates = positionCandidates(around: entry.symbol.position)
            var chosen: GridPoint?
            for candidate in candidates {
                var test = entry.symbol
                test.position = candidate
                let pins = pinLocations(of: test, descriptor: entry.descriptor)
                if pins.allSatisfy({ !occupied.contains($0) }) {
                    chosen = candidate
                    break
                }
            }
            if let chosen {
                entry.symbol.position = chosen
            } else {
                warnings.append("Could not find a collision-free position for \(entry.symbol.refDes); pins may overlap.")
            }
            for location in pinLocations(of: entry.symbol, descriptor: entry.descriptor) {
                occupied.insert(location)
            }
            placed.append(entry)
        }
        return placed
    }

    private func positionCandidates(around origin: GridPoint) -> [GridPoint] {
        var candidates: [GridPoint] = [origin]
        let steps = [4, 8, 12, 16, 24, 32, 48]
        for step in steps {
            candidates.append(GridPoint(origin.x + step, origin.y))
            candidates.append(GridPoint(origin.x - step, origin.y))
            candidates.append(GridPoint(origin.x, origin.y + step))
            candidates.append(GridPoint(origin.x, origin.y - step))
            candidates.append(GridPoint(origin.x + step, origin.y + step))
            candidates.append(GridPoint(origin.x - step, origin.y + step))
            candidates.append(GridPoint(origin.x + step, origin.y - step))
            candidates.append(GridPoint(origin.x - step, origin.y - step))
        }
        return candidates
    }

    private func pinLocations(of symbol: SymbolInstance, descriptor: ComponentDescriptor) -> [GridPoint] {
        descriptor.pins.map { PinGeometry.location(of: $0, on: symbol) }
    }

    // MARK: - Geometry transform

    /// KiCad symbol libraries use a y-up coordinate system; schematic sheets
    /// use y-down and are mirrored across both axes when a symbol is placed.
    /// Applying the rotation in library space and then flipping both axes
    /// reproduces KiCad's pin positions for 0/90/180/270-degree placements.
    func transform(_ pin: KiCadAt, for symbol: KiCadPlacedSymbol) -> KiCadPoint {
        var x = pin.x
        var y = pin.y
        if symbol.mirror?.lowercased() == "x" {
            y = -y
        } else if symbol.mirror?.lowercased() == "y" {
            x = -x
        }
        let radians = symbol.at.angle * Double.pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        let rotatedX = x * cosine - y * sine
        let rotatedY = x * sine + y * cosine
        return KiCadPoint(x: symbol.at.x - rotatedX, y: symbol.at.y - rotatedY)
    }

    // MARK: - Utilities

    private struct LabelKey: Hashable {
        var name: String
        var point: GridPoint
    }

    private func appendLabel(_ label: NetLabel, to labels: inout [NetLabel], seen: inout Set<LabelKey>) {
        let key = LabelKey(name: label.name, point: label.position)
        guard seen.insert(key).inserted else { return }
        labels.append(label)
    }

    private func resolve(_ path: String, relativeTo directory: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return directory.appendingPathComponent(expanded)
    }

    private func stableUUID(for value: String) -> UUID {
        let hex = StableSHA256.hexDigest(Data(value.utf8))
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            bytes.append(UInt8(hex[index..<end], radix: 16) ?? 0)
            index = end
        }
        while bytes.count < 16 { bytes.append(0) }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

// MARK: - Union-find

private struct GridUnionFind {
    private var parent: [GridPoint: GridPoint] = [:]
    private var rank: [GridPoint: Int] = [:]

    mutating func find(_ point: GridPoint) -> GridPoint {
        guard let parentPoint = parent[point] else {
            parent[point] = point
            rank[point] = 0
            return point
        }
        if parentPoint != point {
            let root = find(parentPoint)
            parent[point] = root
            return root
        }
        return point
    }

    mutating func union(_ first: GridPoint, _ second: GridPoint) {
        let firstRoot = find(first)
        let secondRoot = find(second)
        guard firstRoot != secondRoot else { return }
        let firstRank = rank[firstRoot, default: 0]
        let secondRank = rank[secondRoot, default: 0]
        if firstRank < secondRank {
            parent[firstRoot] = secondRoot
        } else if firstRank > secondRank {
            parent[secondRoot] = firstRoot
        } else {
            parent[secondRoot] = firstRoot
            rank[firstRoot] = firstRank + 1
        }
    }
}
