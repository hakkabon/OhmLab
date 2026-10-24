// ZipArchive.swift
// A minimal ZIP reader/writer using the "stored" (uncompressed) method.
//
// Project bundles are exported as a single `.zip` for transport. No archive
// library is available in SwiftPM across all our targets, so this implements
// just enough of the ZIP container — stored entries only, no compression — to
// round-trip the archives we produce. It is deliberately not a general unzip:
// compressed (deflate) entries are rejected rather than silently mangled.

import Foundation

public enum ZipArchiveError: LocalizedError, Equatable {
    case malformed(String)
    case unsupportedCompression(UInt16)

    public var errorDescription: String? {
        switch self {
        case .malformed(let reason):
            return "The archive is not a readable ZIP file: \(reason)"
        case .unsupportedCompression(let method):
            return "The archive uses compression method \(method); only stored (uncompressed) entries are supported."
        }
    }
}

public enum ZipArchive {
    public struct Entry: Equatable {
        public var name: String
        public var data: Data

        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    /// Builds a ZIP archive from `entries`, stored uncompressed.
    public static func create(_ entries: [Entry]) -> Data {
        var output = Data()
        var central = Data()
        let stamp = dosDateTime(Date())

        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            let checksum = crc32(entry.data)
            let size = UInt32(truncatingIfNeeded: entry.data.count)
            let offset = UInt32(truncatingIfNeeded: output.count)

            output.appendLE(UInt32(0x04034b50))
            output.appendLE(UInt16(20))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(stamp.time)
            output.appendLE(stamp.date)
            output.appendLE(checksum)
            output.appendLE(size)
            output.appendLE(size)
            output.appendLE(UInt16(nameBytes.count))
            output.appendLE(UInt16(0))
            output.append(contentsOf: nameBytes)
            output.append(entry.data)

            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(stamp.time)
            central.appendLE(stamp.date)
            central.appendLE(checksum)
            central.appendLE(size)
            central.appendLE(size)
            central.appendLE(UInt16(nameBytes.count))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt32(0))
            central.appendLE(offset)
            central.append(contentsOf: nameBytes)
        }

        let centralOffset = UInt32(truncatingIfNeeded: output.count)
        output.append(central)
        let centralSize = UInt32(truncatingIfNeeded: central.count)

        output.appendLE(UInt32(0x06054b50))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(entries.count))
        output.appendLE(UInt16(entries.count))
        output.appendLE(centralSize)
        output.appendLE(centralOffset)
        output.appendLE(UInt16(0))
        return output
    }

    /// Reads every entry from a stored ZIP archive produced by `create`.
    public static func read(_ data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw ZipArchiveError.malformed("file is too small") }

        var end = -1
        var index = bytes.count - 22
        while index >= 0 {
            if readU32(bytes, index) == 0x06054b50 { end = index; break }
            index -= 1
        }
        guard end >= 0 else { throw ZipArchiveError.malformed("no end-of-central-directory record") }

        let total = Int(readU16(bytes, end + 10))
        let centralOffset = Int(readU32(bytes, end + 16))
        var entries: [Entry] = []
        var pointer = centralOffset

        for _ in 0..<total {
            guard readU32(bytes, pointer) == 0x02014b50 else {
                throw ZipArchiveError.malformed("bad central-directory entry")
            }
            let method = readU16(bytes, pointer + 10)
            let expectedChecksum = readU32(bytes, pointer + 16)
            let compressedSize = Int(readU32(bytes, pointer + 20))
            let nameLength = Int(readU16(bytes, pointer + 28))
            let extraLength = Int(readU16(bytes, pointer + 30))
            let commentLength = Int(readU16(bytes, pointer + 32))
            let localOffset = Int(readU32(bytes, pointer + 42))
            let nameStart = pointer + 46
            guard nameStart + nameLength <= bytes.count else {
                throw ZipArchiveError.malformed("entry name out of range")
            }
            let name = String(decoding: bytes[nameStart..<(nameStart + nameLength)], as: UTF8.self)

            guard readU32(bytes, localOffset) == 0x04034b50 else {
                throw ZipArchiveError.malformed("bad local header for \(name)")
            }
            let localNameLength = Int(readU16(bytes, localOffset + 26))
            let localExtraLength = Int(readU16(bytes, localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            guard dataStart + compressedSize <= bytes.count else {
                throw ZipArchiveError.malformed("entry data out of range for \(name)")
            }
            guard method == 0 else { throw ZipArchiveError.unsupportedCompression(method) }
            let entryData = Data(bytes[dataStart..<(dataStart + compressedSize)])
            guard crc32(entryData) == expectedChecksum else {
                throw ZipArchiveError.malformed("checksum mismatch for \(name)")
            }
            entries.append(Entry(name: name, data: entryData))

            pointer = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }
}

// MARK: - Little-endian helpers

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}

private func readU16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
    return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}

private func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
    return UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}

/// MS-DOS packed date/time for the ZIP headers.
private func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
    let calendar = Calendar(identifier: .gregorian)
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    let year = max(1980, parts.year ?? 1980)
    let month = parts.month ?? 1
    let day = parts.day ?? 1
    let hour = parts.hour ?? 0
    let minute = parts.minute ?? 0
    let second = parts.second ?? 0
    let dosTime = UInt16((hour << 11) | (minute << 5) | (second / 2))
    let dosDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
    return (dosTime, dosDate)
}

// MARK: - CRC-32

private let crc32Table: [UInt32] = {
    (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }
}()

private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFFFFFF
    for byte in data {
        crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFFFFFF
}
