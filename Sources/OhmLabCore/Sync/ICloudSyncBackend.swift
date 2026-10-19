// ICloudSyncBackend.swift
// A sync backend rooted at the app's iCloud Drive ubiquity container.
//
// A Swift package cannot declare the iCloud entitlement, so this is best-effort:
// `make()` returns nil when the container is unreachable and the caller falls
// back to `LocalFolderBackend`. Every access goes through `NSFileCoordinator`
// (and requests cloud-only items be downloaded) so it cooperates with the
// system's iCloud daemon and other processes.

import Foundation

public struct ICloudSyncBackend: SyncBackend {
    public let name: String
    public let rootURL: URL

    public init(rootURL: URL, name: String = "iCloud Drive") {
        self.rootURL = rootURL
        self.name = name
    }

    /// A backend rooted at the ubiquity container's `Documents` folder, or nil
    /// when iCloud is unavailable (no entitlement / not signed in).
    public static func make() -> ICloudSyncBackend? {
        guard let documents = CloudDocumentStore.documentsDirectory else { return nil }
        return ICloudSyncBackend(rootURL: documents)
    }

    public func snapshot() throws -> [String: FileStamp] {
        requestDownloads()
        return try SyncFileScan.stamps(in: rootURL)
    }

    public func read(relativePath: String) throws -> Data {
        let url = rootURL.appendingPathComponent(relativePath)
        CloudDocumentStore.startDownloading(url)
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw SyncBackendError.ioFailed("read", relativePath) }
        return try result.get()
    }

    public func write(_ data: Data, to relativePath: String) throws {
        let url = rootURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do { try data.write(to: coordinatedURL, options: .atomic) } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    public func remove(relativePath: String) throws {
        let url = rootURL.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var coordinationError: NSError?
        var removeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { coordinatedURL in
            do { try FileManager.default.removeItem(at: coordinatedURL) } catch { removeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let removeError { throw removeError }
    }

    /// Asks iCloud to start downloading every item in the container that is not
    /// yet local. Best-effort.
    private func requestDownloads() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in urls { CloudDocumentStore.startDownloading(url) }
    }
}
