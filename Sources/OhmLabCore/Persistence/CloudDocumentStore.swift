// CloudDocumentStore.swift
// Best-effort access to the app's iCloud Drive container.
//
// The DocumentGroup-based lifecycle handles open-in-place and autosave for the
// app's own storage. This helper adds an explicit path to the iCloud ubiquity
// container for "move a circuit to iCloud" / listing cloud documents. The
// ubiquity container requires an iCloud entitlement that a Swift package cannot
// declare, so every entry point degrades gracefully to `nil`/empty when the
// container is unavailable, and the app then falls back to local storage.

import Foundation

public enum CloudDocumentStore {
    /// The ubiquity container's root, or nil when iCloud is unavailable.
    public static var containerURL: URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: nil)
    }

    /// True when the iCloud container can be reached.
    public static var isAvailable: Bool { containerURL != nil }

    /// The `Documents` directory inside the iCloud container.
    public static var documentsDirectory: URL? {
        guard let containerURL else { return nil }
        let documents = containerURL.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        return documents
    }

    /// Circuit files currently in the iCloud container, sorted by name.
    public static func listDocuments() -> [URL] {
        guard let documents = documentsDirectory,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: documents,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == CircuitFileStore.fileExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Reads a circuit using coordinated access, requesting the ubiquitous item
    /// be downloaded first when needed.
    public static func read(at url: URL) throws -> CircuitFile {
        var coordinationError: NSError?
        var result: Result<CircuitFile, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try CircuitFileStore.read(from: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        return try result!.get()
    }

    /// Writes a circuit into the container at `url` using coordinated access.
    public static func write(_ file: CircuitFile, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do { try CircuitFileStore.write(file, to: coordinatedURL) } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    /// Copies a circuit into the iCloud container under `name` and returns the
    /// resulting URL, or nil when iCloud is unavailable.
    @discardableResult
    public static func upload(_ file: CircuitFile, named name: String) throws -> URL? {
        guard let documents = documentsDirectory else { return nil }
        let url = documents.appendingPathComponent(name).appendingPathExtension(CircuitFileStore.fileExtension)
        try write(file, to: url)
        return url
    }

    /// Requests download of an iCloud item that may not be local yet.
    public static func startDownloading(_ url: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
}
