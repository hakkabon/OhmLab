// KiCadRoundTrip.swift
// Shared metadata used by the KiCad writer and reader.
//
// KiCad's own properties (`Reference`, `Value`, `Sim.*`) are enough for KiCad
// to simulate an exported schematic. They are not, however, lossless for
// OhmLab: a resistor's value string loses nothing, but a source's AC phase and
// a MOSFET's full Level 1 parameter set do. The writer therefore adds a small
// set of `OhmLab.*` properties, and the reader prefers them when present.

import Foundation

enum KiCadRoundTrip {
    /// The OhmLab component descriptor id (`resistor`, `voltage-source`, …).
    static let descriptorProperty = "OhmLab.Descriptor"
    /// Exact numeric parameters as `key=value;key=value`.
    static let parametersProperty = "OhmLab.Parameters"
    /// The original OhmLab reference designator, including ground symbols.
    static let referenceProperty = "OhmLab.Reference"
    /// The original rotation for symbols whose KiCad representation has no
    /// angle of its own.
    static let rotationProperty = "OhmLab.Rotation"
    /// The original grid position for a subcircuit sheet instance, whose KiCad
    /// `at` is the sheet's top-left corner rather than the instance origin.
    static let positionProperty = "OhmLab.Position"
    /// The referenced child sheet's UUID for a subcircuit instance.
    static let sheetRefProperty = "OhmLab.SheetRef"
    /// A human-readable marker for the OhmLab version that wrote the file.
    static let writerProperty = "OhmLab.Writer"

    static let writerVersion = "OhmLab KiCad writer"

    /// Encodes parameters deterministically. `String(Double)` is the shortest
    /// representation that round-trips exactly, which matters for model
    /// parameters such as `1e-14`.
    static func encode(parameters: [String: Double]) -> String {
        parameters.keys.sorted().compactMap { key in
            guard let value = parameters[key] else { return nil }
            return "\(key)=\(String(value))"
        }.joined(separator: ";")
    }

    static func decode(parameters text: String) -> [String: Double] {
        var result: [String: Double] = [:]
        for entry in text.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let valueText = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, let value = Double(valueText) else { continue }
            result[key] = value
        }
        return result
    }

    /// KiCad writes UUIDs in lowercase; using the same form keeps diffs stable
    /// and matches the fixture corpus.
    static func uuidString(_ uuid: UUID) -> String {
        uuid.uuidString.lowercased()
    }

    /// A deterministic UUID (version 5 layout) derived from a stable key.
    static func stableUUID(_ key: String) -> UUID {
        let hex = StableSHA256.hexDigest(Data(key.utf8))
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

    /// Formats a double for a SPICE card. Mirrors `SpiceNetlistBuilder` so
    /// exported model cards are stable and locale-independent.
    static func spiceNumber(_ value: Double) -> String {
        String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// Formats a millimetre coordinate without scientific notation or a
    /// trailing `.0`, which KiCad accepts everywhere.
    static func millimetres(_ value: Double) -> String {
        var text = String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        if text == "-0" { text = "0" }
        return text
    }

    static func millimetres(grid: Int) -> String {
        millimetres(Double(grid) * 1.27)
    }

    static func encode(position: GridPoint) -> String {
        "\(position.x),\(position.y)"
    }

    static func decode(position text: String) -> GridPoint? {
        let parts = text.split(separator: ",")
        guard parts.count == 2,
              let x = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return GridPoint(x, y)
    }
}
