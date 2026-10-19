// ProjectSync.swift
// A small, deterministic two-way sync engine for project bundles.
//
// It compares two `SyncBackend` snapshots against the last-synced state
// (content hashes, not timestamps), then uploads, downloads, propagates
// deletions, or records a conflict. Conflicts keep the local version as
// canonical and preserve the losing version as a `(conflict …)` copy on both
// sides — never losing work, and never requiring a merge UI.

import Foundation

/// The last successfully synced fingerprint of each path. Stored in the local
/// working copy as a hidden dotfile so it is not itself synced.
public struct SyncState: Codable, Equatable, Sendable {
    public var entries: [String: FileStamp]
    public var lastSync: Date?

    public init(entries: [String: FileStamp] = [:], lastSync: Date? = nil) {
        self.entries = entries
        self.lastSync = lastSync
    }
}

public enum SyncStateStore {
    public static let fileName = ".ohmlab-sync.json"

    public static func url(in root: URL) -> URL {
        root.appendingPathComponent(fileName)
    }

    public static func load(from root: URL) -> SyncState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url(in: root)),
              let state = try? decoder.decode(SyncState.self, from: data) else {
            return SyncState()
        }
        return state
    }

    public static func save(_ state: SyncState, to root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: url(in: root), options: .atomic)
    }
}

public enum SyncAction: String, Equatable, Sendable {
    case upload
    case download
    case deleteLocal
    case deleteRemote
    case conflict
}

public struct SyncPlan: Equatable, Sendable {
    public var actions: [String: SyncAction]
    /// Files already identical on both sides (neither side changed).
    public var unchanged: Int

    public init(actions: [String: SyncAction] = [:], unchanged: Int = 0) {
        self.actions = actions
        self.unchanged = unchanged
    }

    public var isEmpty: Bool { actions.isEmpty }
}

public struct SyncReport: Equatable, Sendable {
    public var uploaded: [String] = []
    public var downloaded: [String] = []
    public var conflicts: [String] = []
    public var removedLocal: [String] = []
    public var removedRemote: [String] = []
    public var unchanged: Int = 0

    public init() {}

    public var isEmpty: Bool {
        uploaded.isEmpty && downloaded.isEmpty && conflicts.isEmpty
            && removedLocal.isEmpty && removedRemote.isEmpty
    }

    /// A one-line, human-readable summary for CLI output.
    public var summary: String {
        if isEmpty { return "Already up to date (\(unchanged) file(s))." }
        var parts: [String] = []
        if !uploaded.isEmpty { parts.append("\(uploaded.count) uploaded") }
        if !downloaded.isEmpty { parts.append("\(downloaded.count) downloaded") }
        if !removedRemote.isEmpty { parts.append("\(removedRemote.count) removed remote") }
        if !removedLocal.isEmpty { parts.append("\(removedLocal.count) removed local") }
        if !conflicts.isEmpty { parts.append("\(conflicts.count) conflict(s)") }
        return parts.joined(separator: ", ")
    }
}

public struct SyncOutcome: Equatable, Sendable {
    public var plan: SyncPlan
    public var report: SyncReport
    public var state: SyncState

    public init(plan: SyncPlan, report: SyncReport, state: SyncState) {
        self.plan = plan
        self.report = report
        self.state = state
    }
}

public enum ProjectSync {
    /// Computes what a sync would do, without touching either side.
    public static func plan(
        local: SyncBackend,
        remote: SyncBackend,
        state: SyncState
    ) throws -> SyncPlan {
        let localFiles = try local.snapshot()
        let remoteFiles = try remote.snapshot()
        var actions: [String: SyncAction] = [:]
        var unchanged = 0

        for path in Set(localFiles.keys).union(remoteFiles.keys) {
            let localStamp = localFiles[path]
            let remoteStamp = remoteFiles[path]
            let synced = state.entries[path]

            switch (localStamp, remoteStamp) {
            case let (.some(local), .some(remote)):
                let localChanged = local.hash != synced?.hash
                let remoteChanged = remote.hash != synced?.hash
                if !localChanged && !remoteChanged { unchanged += 1; continue }
                if local.hash == remote.hash { unchanged += 1; continue }
                if localChanged && !remoteChanged {
                    actions[path] = .upload
                } else if !localChanged && remoteChanged {
                    actions[path] = .download
                } else {
                    actions[path] = .conflict
                }
            case let (.some(local), .none):
                if synced != nil, local.hash == synced?.hash {
                    actions[path] = .deleteLocal      // remote deleted it; propagate
                } else {
                    actions[path] = .upload           // new or changed locally
                }
            case let (.none, .some(remote)):
                if synced != nil, remote.hash == synced?.hash {
                    actions[path] = .deleteRemote     // local deleted it; propagate
                } else {
                    actions[path] = .download         // new or changed remotely
                }
            case (.none, .none):
                continue
            }
        }
        return SyncPlan(actions: actions, unchanged: unchanged)
    }

    /// Applies a plan and returns the resulting report and new state.
    @discardableResult
    public static func sync(
        local: SyncBackend,
        remote: SyncBackend,
        state: SyncState,
        now: Date = Date()
    ) throws -> SyncOutcome {
        let planned = try plan(local: local, remote: remote, state: state)
        var report = SyncReport()
        report.unchanged = planned.unchanged

        for path in planned.actions.keys.sorted() {
            switch planned.actions[path] {
            case .upload:
                try remote.write(try local.read(relativePath: path), to: path)
                report.uploaded.append(path)
            case .download:
                try local.write(try remote.read(relativePath: path), to: path)
                report.downloaded.append(path)
            case .deleteRemote:
                try remote.remove(relativePath: path)
                report.removedRemote.append(path)
            case .deleteLocal:
                try local.remove(relativePath: path)
                report.removedLocal.append(path)
            case .conflict:
                let remoteData = try remote.read(relativePath: path)
                let localData = try local.read(relativePath: path)
                let copyPath = conflictPath(for: path, at: now)
                try local.write(remoteData, to: copyPath)     // preserve the remote version locally
                try remote.write(localData, to: path)         // local stays canonical
                try remote.write(remoteData, to: copyPath)    // and keep the copy on both sides
                report.conflicts.append(path)
            case .none:
                continue
            }
        }

        let newState = SyncState(entries: try local.snapshot(), lastSync: now)
        return SyncOutcome(plan: planned, report: report, state: newState)
    }

    /// The path of the conflict copy for `path` (same directory, timestamped).
    static func conflictPath(for path: String, at date: Date) -> String {
        let nsPath = path as NSString
        let directory = nsPath.deletingLastPathComponent
        let base = (nsPath.lastPathComponent as NSString)
        let stem = base.deletingPathExtension
        let ext = base.pathExtension
        let stamp = conflictFormatter.string(from: date)
        let name = ext.isEmpty
            ? "\(stem) (conflict \(stamp))"
            : "\(stem) (conflict \(stamp)).\(ext)"
        return (directory.isEmpty || directory == ".") ? name : "\(directory)/\(name)"
    }

    private static let conflictFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
