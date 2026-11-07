// KiCadSymbolLibrary.swift
// Generates the `OhmLab` KiCad symbol library and the embedded `lib_symbols`
// block used by every written schematic.
//
// The symbol geometry is derived from the same `ComponentDescriptor.pins`
// values that drive OhmLab's connectivity. A descriptor pin at grid offset
// `(dx, dy)` becomes a KiCad library pin at `(-dx * 1.27, -dy * 1.27)`, which
// the reader's inverse transform turns back into the original grid point for
// 0/90/180/270-degree placements.

import Foundation

public enum KiCadSymbolLibrary {
    public static let libraryName = "OhmLab"
    public static let fileName = "OhmLab.kicad_sym"

    /// The library id for a descriptor, e.g. `OhmLab:R`.
    public static func libId(for descriptor: ComponentDescriptor) -> String {
        "\(libraryName):\(symbolName(for: descriptor))"
    }

    /// The symbol name for a descriptor, e.g. `R`, `QNPN`, or `LSER`.
    public static func symbolName(for descriptor: ComponentDescriptor) -> String {
        switch descriptor.id {
        case "resistor": return "R"
        case "capacitor": return "C"
        case "inductor": return "L"
        case "inductor-series-resistance": return "LSER"
        case "voltage-source": return "VDC"
        case "current-source": return "IDC"
        case "diode": return "D"
        case "npn-transistor": return "QNPN"
        case "pnp-transistor": return "QPNP"
        case "nmos-transistor": return "NMOS"
        case "pmos-transistor": return "PMOS"
        case "njfet-transistor": return "NJFET"
        case "pjfet-transistor": return "PJFET"
        case "ground": return "0"
        default:
            return sanitizedSymbolName(descriptor.id)
        }
    }

    /// The descriptor id for a library id written by this library, when it is
    /// one of the built-ins. Custom descriptors fall back to the `OhmLab.*`
    /// property written on the placed symbol.
    public static func descriptorId(forLibId libId: String) -> String? {
        let name = libId.split(separator: ":").last.map(String.init) ?? libId
        switch name {
        case "R": return "resistor"
        case "C": return "capacitor"
        case "L": return "inductor"
        case "LSER": return "inductor-series-resistance"
        case "VDC": return "voltage-source"
        case "IDC": return "current-source"
        case "D": return "diode"
        case "QNPN": return "npn-transistor"
        case "QPNP": return "pnp-transistor"
        case "NMOS": return "nmos-transistor"
        case "PMOS": return "pmos-transistor"
        case "NJFET": return "njfet-transistor"
        case "PJFET": return "pjfet-transistor"
        case "0": return "ground"
        default: return nil
        }
    }

    /// The full `.kicad_sym` file. Symbols are sorted by name so the output is
    /// deterministic across runs.
    public static func libraryText() -> String {
        let descriptors = ComponentRegistry.shared.allDescriptors
            .filter { $0.symbol != .subcircuit }
            .sorted { symbolName(for: $0) < symbolName(for: $1) }

        var lines: [String] = [
            "(kicad_symbol_lib",
            "  (version 20250114)",
            "  (generator \"kicad_symbol_editor\")",
            "  (generator_version \"10.0\")"
        ]
        for descriptor in descriptors {
            lines.append(contentsOf: definition(for: descriptor, name: symbolName(for: descriptor)))
        }
        lines.append(")")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The `(lib_symbols …)` block for a set of library ids. Only symbols that
    /// are actually placed on the sheet are embedded, matching KiCad's own
    /// schematic files.
    static func embeddedSymbols(libIds: Set<String>) -> String {
        guard !libIds.isEmpty else { return "" }
        let descriptors = ComponentRegistry.shared.allDescriptors
            .filter { $0.symbol != .subcircuit }
        var byLibId: [String: ComponentDescriptor] = [:]
        for descriptor in descriptors {
            byLibId[libId(for: descriptor)] = descriptor
        }

        var lines: [String] = ["\t(lib_symbols"]
        for libId in libIds.sorted() {
            guard let descriptor = byLibId[libId] else { continue }
            lines.append(contentsOf: definition(for: descriptor, name: libId).map { "\t\t\($0)" })
        }
        lines.append("\t)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Definitions

    static func definition(for descriptor: ComponentDescriptor, name: String) -> [String] {
        let baseName = name.split(separator: ":").last.map(String.init) ?? name
        let pins = pinSpecs(for: descriptor)
        var lines: [String] = [
            "\t(symbol \(quoted(name))",
            "\t\t(pin_numbers (hide yes))",
            "\t\t(pin_names (offset 0.254)\(descriptor.symbol == .ground ? " (hide yes)" : ""))",
            "\t\t(exclude_from_sim no)",
            "\t\t(in_bom yes)",
            "\t\t(on_board yes)",
            "\t\t(in_pos_files yes)",
            "\t\t(duplicate_pin_numbers_are_jumpers no)"
        ]
        if descriptor.symbol == .ground {
            lines.insert("\t\t(power global)", at: 1)
        }

        lines.append(contentsOf: propertyLines(
            name: "Reference",
            value: descriptor.symbol == .ground ? "#GND" : descriptor.prefix,
            at: (2.54, 0, 0),
            hidden: descriptor.symbol == .ground
        ))
        lines.append(contentsOf: propertyLines(
            name: "Value",
            value: descriptor.symbol == .ground ? "0" : descriptor.displayName,
            at: (0, -2.54, 0),
            hidden: false
        ))
        lines.append(contentsOf: propertyLines(name: "Footprint", value: "", at: (0, 0, 0), hidden: true))
        lines.append(contentsOf: propertyLines(name: "Datasheet", value: "", at: (0, 0, 0), hidden: true))
        lines.append(contentsOf: propertyLines(
            name: "Description",
            value: descriptor.displayName,
            at: (0, 0, 0),
            hidden: true
        ))

        if let device = simDevice(for: descriptor) {
            lines.append(contentsOf: propertyLines(name: "Sim.Device", value: device, at: (0, 0, 0), hidden: true))
        }
        if let simPins = simPins(for: descriptor) {
            lines.append(contentsOf: propertyLines(name: "Sim.Pins", value: simPins, at: (0, 0, 0), hidden: true))
        }
        if descriptor.symbol == .voltageSource || descriptor.symbol == .currentSource {
            lines.append(contentsOf: propertyLines(name: "Sim.Type", value: "DC", at: (0, 0, 0), hidden: true))
        }
        lines.append(contentsOf: propertyLines(
            name: KiCadRoundTrip.descriptorProperty,
            value: descriptor.id,
            at: (0, 0, 0),
            hidden: true
        ))

        lines.append("\t\t(symbol \(quoted("\(baseName)_0_1"))")
        lines.append(contentsOf: graphics(for: descriptor).map { "\t\t\t\($0)" })
        lines.append("\t\t)")
        lines.append("\t\t(symbol \(quoted("\(baseName)_1_1"))")
        for pin in pins {
            lines.append(contentsOf: pinLines(pin).map { "\t\t\t\($0)" })
        }
        lines.append("\t\t)")
        lines.append("\t\t(embedded_fonts no)")
        lines.append("\t)")
        return lines
    }

    struct PinSpec {
        var number: String
        var name: String
        var x: Double
        var y: Double
        var angle: Int
        var type: String
        var length: Double
    }

    static func pinSpecs(for descriptor: ComponentDescriptor) -> [PinSpec] {
        // KiCad's diode convention is pin 1 = K (cathode) and pin 2 = A
        // (anode). Matching it exactly is what makes `kicad-cli sch export
        // netlist` emit the same anode/cathode order as OhmLab.
        if descriptor.symbol == .diode {
            return [
                PinSpec(number: "1", name: "K", x: -2.54, y: 0, angle: 0, type: "passive", length: 1.27),
                PinSpec(number: "2", name: "A", x: 2.54, y: 0, angle: 180, type: "passive", length: 1.27)
            ]
        }

        // KiCad's own voltage/current sources are vertical: pin 1 (+) is the
        // top pin and pin 2 (-) is the bottom pin. Keeping that orientation
        // makes `kicad-cli` emit the positive node first.
        if descriptor.symbol == .voltageSource || descriptor.symbol == .currentSource {
            return [
                PinSpec(number: "1", name: "+", x: 0, y: 5.08, angle: 270, type: "passive", length: 2.54),
                PinSpec(number: "2", name: "-", x: 0, y: -5.08, angle: 90, type: "passive", length: 2.54)
            ]
        }

        let roles = pinRoles(for: descriptor)
        return descriptor.pins.enumerated().map { index, pin in
            let dx = Int((pin.position.x / GridPoint.gridSize).rounded())
            let dy = Int((pin.position.y / GridPoint.gridSize).rounded())
            let x = Double(-dx) * 1.27
            let y = Double(-dy) * 1.27
            let role = index < roles.count ? roles[index] : pin.id
            return PinSpec(
                number: descriptor.symbol == .ground ? "1" : String(index + 1),
                name: descriptor.symbol == .ground ? "" : role,
                x: x,
                y: y,
                angle: pinAngle(x: x, y: y),
                type: descriptor.symbol == .ground ? "power_in" : "passive",
                length: descriptor.symbol == .ground ? 0 : 1.27
            )
        }
    }

    static func pinRoles(for descriptor: ComponentDescriptor) -> [String] {
        switch descriptor.symbol {
        case .voltageSource, .currentSource:
            return ["+", "-"]
        case .diode:
            return ["A", "K"]
        case .npnTransistor, .pnpTransistor:
            return ["C", "B", "E"]
        case .nmosTransistor, .pmosTransistor:
            return ["D", "G", "S", "B"]
        case .njfTransistor, .pjfTransistor:
            return ["D", "G", "S"]
        case .ground:
            return [""]
        default:
            return descriptor.pins.map { $0.name.isEmpty ? $0.id : $0.name }
        }
    }

    static func simDevice(for descriptor: ComponentDescriptor) -> String? {
        switch descriptor.symbol {
        case .resistor: return "R"
        case .capacitor: return "C"
        case .inductor, .inductorSeries: return "L"
        case .voltageSource: return "V"
        case .currentSource: return "I"
        case .diode: return "D"
        case .npnTransistor, .pnpTransistor: return "Q"
        case .nmosTransistor, .pmosTransistor: return "M"
        case .njfTransistor, .pjfTransistor: return "J"
        case .ground, .subcircuit: return nil
        }
    }

    static func simPins(for descriptor: ComponentDescriptor) -> String? {
        guard descriptor.symbol != .ground else { return nil }
        let pins = pinSpecs(for: descriptor)
        guard !pins.isEmpty else { return nil }
        return pins
            .map { "\($0.number)=\($0.name.isEmpty ? $0.number : $0.name)" }
            .joined(separator: " ")
    }

    // MARK: - Graphics

    static func graphics(for descriptor: ComponentDescriptor) -> [String] {
        switch descriptor.symbol {
        case .resistor:
            return [rectangle(-1.27, -1.27, 1.27, 1.27)]
        case .capacitor:
            return [
                polyline([(-1.905, 0.762), (1.905, 0.762)], width: 0.508),
                polyline([(-1.905, -0.762), (1.905, -0.762)], width: 0.508)
            ]
        case .inductor, .inductorSeries:
            return [
                polyline([(-1.905, 0), (-1.27, 1.27), (0, -1.27), (1.27, 1.27), (1.905, 0)], width: 0.254)
            ]
        case .voltageSource:
            return [
                circle(0, 0, 2.032),
                polyline([(-0.762, 0), (0.762, 0)], width: 0.254),
                polyline([(0, -0.762), (0, 0.762)], width: 0.254)
            ]
        case .currentSource:
            return [
                circle(0, 0, 2.032),
                polyline([(0, 1.27), (0, -1.27)], width: 0.254),
                polyline([(-0.508, 0.508), (0, 1.27), (0.508, 0.508)], width: 0.254)
            ]
        case .diode:
            return [
                polyline([(-1.27, 1.27), (-1.27, -1.27)], width: 0.254),
                polyline([(1.27, 1.27), (1.27, -1.27), (-1.27, 0), (1.27, 1.27)], width: 0.254)
            ]
        case .npnTransistor, .pnpTransistor, .nmosTransistor, .pmosTransistor,
             .njfTransistor, .pjfTransistor:
            return [
                circle(0, 0, 2.286),
                polyline([(-1.27, 0), (1.27, 0)], width: 0.254),
                polyline([(0, 0), (1.27, 1.27)], width: 0.254),
                polyline([(0, 0), (1.27, -1.27)], width: 0.254)
            ]
        case .ground:
            return [
                polyline([(-1.27, 0), (1.27, 0), (0, -1.27), (-1.27, 0)], width: 0)
            ]
        case .subcircuit:
            return [rectangle(-1.27, -1.27, 1.27, 1.27)]
        }
    }

    // MARK: - Formatting

    static func pinLines(_ pin: PinSpec) -> [String] {
        [
            "(pin \(pin.type) line",
            "\t(at \(KiCadRoundTrip.millimetres(pin.x)) \(KiCadRoundTrip.millimetres(pin.y)) \(pin.angle))",
            "\t(length \(KiCadRoundTrip.millimetres(pin.length)))",
            "\t(name \(quoted(pin.name))",
            "\t\t(effects (font (size 1.27 1.27)))",
            "\t)",
            "\t(number \(quoted(pin.number))",
            "\t\t(effects (font (size 1.27 1.27)))",
            "\t)",
            ")"
        ]
    }

    static func propertyLines(
        name: String,
        value: String,
        at position: (Double, Double, Double),
        hidden: Bool
    ) -> [String] {
        var lines: [String] = [
            "(property \(quoted(name)) \(quoted(value))",
            "\t(at \(KiCadRoundTrip.millimetres(position.0)) \(KiCadRoundTrip.millimetres(position.1)) \(Int(position.2)))",
            "\t(show_name no)",
            "\t(do_not_autoplace no)"
        ]
        if hidden { lines.append("\t(hide yes)") }
        lines.append("\t(effects (font (size 1.27 1.27)))")
        lines.append(")")
        return lines
    }

    static func rectangle(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> String {
        """
        (rectangle
        \t(start \(KiCadRoundTrip.millimetres(x1)) \(KiCadRoundTrip.millimetres(y1)))
        \t(end \(KiCadRoundTrip.millimetres(x2)) \(KiCadRoundTrip.millimetres(y2)))
        \t(stroke (width 0.254) (type default))
        \t(fill (type none))
        )
        """
    }

    static func circle(_ x: Double, _ y: Double, _ radius: Double) -> String {
        """
        (circle
        \t(center \(KiCadRoundTrip.millimetres(x)) \(KiCadRoundTrip.millimetres(y)))
        \t(radius \(KiCadRoundTrip.millimetres(radius)))
        \t(stroke (width 0.254) (type default))
        \t(fill (type none))
        )
        """
    }

    static func polyline(_ points: [(Double, Double)], width: Double) -> String {
        let xy = points
            .map { "(xy \(KiCadRoundTrip.millimetres($0.0)) \(KiCadRoundTrip.millimetres($0.1)))" }
            .joined(separator: " ")
        return """
        (polyline
        \t(pts \(xy))
        \t(stroke (width \(KiCadRoundTrip.millimetres(width))) (type default))
        \t(fill (type none))
        )
        """
    }

    static func quoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func pinAngle(x: Double, y: Double) -> Int {
        if abs(x) >= abs(y) {
            return x >= 0 ? 180 : 0
        }
        return y >= 0 ? 270 : 90
    }

    private static func sanitizedSymbolName(_ raw: String) -> String {
        var result = raw.map { character -> Character in
            character.isLetter || character.isNumber || character == "_" ? character : "_"
        }
        if result.isEmpty { result = Array("SYMBOL") }
        if let first = result.first, first.isNumber {
            result.insert("S", at: 0)
        }
        return String(result).uppercased()
    }
}
