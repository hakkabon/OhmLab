// LocalFolderBackend.swift
// The default sync backend: an ordinary folder on disk.
//
// Used for the local working copy and, with a different root, as a stand-in for
// any remote that is mounted as a folder (a shared drive, a Dropbox/Drive
// directory, a git working tree). It is also the backend the tests exercise, so
// the sync engine's behaviour is verified without any network or entitlement.

import Foundation

public struct LocalFolderBackend: SyncBackend {
    public let name: String
    public let rootURL: URL

    public init(rootURL: URL, name: String? = nil) {
        self.rootURL = rootURL
        self.name = name ?? rootURL.lastPathComponent
    }

    public func snapshot() throws -> [String: FileStamp] {
        try SyncFileScan.stamps(in: rootURL)
    }

    public func read(relativePath: String) throws -> Data {
        let url: URL
        do {
            url = try ProjectPath.resolve(relativePath, under: rootURL)
        } catch {
            throw SyncBackendError.ioFailed("read unsafe path", relativePath)
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw SyncBackendError.ioFailed("read", relativePath)
        }
    }

    public func write(_ data: Data, to relativePath: String) throws {
        let url: URL
        do {
            url = try ProjectPath.resolve(relativePath, under: rootURL)
        } catch {
            throw SyncBackendError.ioFailed("write unsafe path", relativePath)
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            throw SyncBackendError.ioFailed("write", relativePath)
        }
    }

    public func remove(relativePath: String) throws {
        let url: URL
        do {
            url = try ProjectPath.resolve(relativePath, under: rootURL)
        } catch {
            throw SyncBackendError.ioFailed("remove unsafe path", relativePath)
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            throw SyncBackendError.ioFailed("remove", relativePath)
        }
    }
}
