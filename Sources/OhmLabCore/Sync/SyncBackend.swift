// SyncBackend.swift
// The provider-agnostic seam for project sync.
//
// A `SyncBackend` exposes a flat, relative-path view of one side of a sync: the
// local working copy (an ordinary folder) and the remote (another folder, an
// iCloud ubiquity container, …). `ProjectSync` reasons only about snapshots of
// these two views, so the same engine drives iCloud, a shared folder, Dropbox,
// or a git working tree without special cases.

import Foundation
import CryptoKit

public enum SyncBackendError: LocalizedError, Equatable {
    case unavailable(String)
    case notADirectory(String)
    case ioFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let name):
            return "The \(name) sync location is not available."
        case .notADirectory(let name):
            return "\(name) is not a folder."
        case .ioFailed(let operation, let path):
            return "Sync could not \(operation) \(path)."
        }
    }
}

/// A cheap content fingerprint of one file. `hash` is authoritative for
/// change detection; `size` and `modified` are informational.
public struct FileStamp: Codable, Equatable, Sendable {
    public var size: Int
    public var modified: Date
    public var hash: String

    public init(size: Int, modified: Date, hash: String) {
        self.size = size
        self.modified = modified
        self.hash = hash
    }

    /// A stamp from raw bytes.
    public init(data: Data, modified: Date) {
        self.size = data.count
        self.modified = modified
        self.hash = FileStamp.digest(data)
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// One side of a sync: files addressed by a path relative to `rootURL`.
public protocol SyncBackend: Sendable {
    /// Human-readable provider name (used in errors and reports).
    var name: String { get }
    /// The absolute folder this backend is rooted at.
    var rootURL: URL { get }
    /// Every syncable regular file (relative path → stamp). Bookkeeping and
    /// hidden files are excluded.
    func snapshot() throws -> [String: FileStamp]
    func read(relativePath: String) throws -> Data
    func write(_ data: Data, to relativePath: String) throws
    func remove(relativePath: String) throws
}

public enum SyncFileScan {
    /// Recursively enumerates regular files under `root`, returning relative
    /// paths and content stamps. Hidden files (leading dot) are skipped so the
    /// sync's own state file never gets mirrored.
    public static func stamps(in root: URL) throws -> [String: FileStamp] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return [:]
        }
        guard isDirectory.boolValue else { throw SyncBackendError.notADirectory(root.lastPathComponent) }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var result: [String: FileStamp] = [:]
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            let name = url.lastPathComponent
            if name.hasPrefix(".") { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            let relative = relativePath(of: url, under: root)
            result[relative] = FileStamp(data: data, modified: values?.contentModificationDate ?? Date())
        }
        return result
    }

    public static func relativePath(of url: URL, under root: URL) -> String {
        let base = root.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        if full.hasPrefix(base + "/") {
            return String(full.dropFirst(base.count + 1))
        }
        return url.lastPathComponent
    }
}
