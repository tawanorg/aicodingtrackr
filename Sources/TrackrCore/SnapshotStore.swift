import Foundation

/// Append-only log of everything we have ever observed, keyed by account.
///
/// This exists because the source data is destructive-overwrite: `~/.claude.json`
/// and `~/.codex/auth.json` hold exactly one logged-in account and are *replaced*
/// on login, so an account's final reading is lost unless something captured it
/// while it was active. Append-only (rather than last-write-wins) keeps the
/// history auditable when a number looks wrong.
public final class SnapshotStore: @unchecked Sendable {
    public let fileURL: URL
    private let queue = DispatchQueue(label: "keeptrack.store")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("AICodingTrackr")

        // Carry over data written under the project's old name, so an upgrade does
        // not silently start from an empty history.
        let legacy = base.appendingPathComponent("KeepTrack")
        if !FileManager.default.fileExists(atPath: dir.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: dir)
        }
        return dir.appendingPathComponent("snapshots.jsonl")
    }

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try? FileManager.default.createDirectory(
            at: self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    public func all() -> [AccountSnapshot] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return [] }
            return data.split(separator: UInt8(ascii: "\n")).compactMap {
                try? decoder.decode(AccountSnapshot.self, from: Data($0))
            }
        }
    }

    /// Newest reading per account.
    public func latest() -> [String: AccountSnapshot] {
        all().reduce(into: [:]) { acc, snap in
            if let existing = acc[snap.ref.key], existing.observedAt >= snap.observedAt { return }
            acc[snap.ref.key] = snap
        }
    }

    /// Records a reading, skipping ones that say nothing new so the log tracks
    /// change rather than poll frequency.
    public func record(_ snapshot: AccountSnapshot) {
        let previous = latest()[snapshot.ref.key]
        if let previous, !Self.isMateriallyDifferent(previous, snapshot) { return }

        queue.sync {
            guard var line = try? encoder.encode(snapshot) else { return }
            line.append(UInt8(ascii: "\n"))
            if FileManager.default.fileExists(atPath: fileURL.path),
               let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: fileURL)
            }
        }
    }

    static func isMateriallyDifferent(_ a: AccountSnapshot, _ b: AccountSnapshot) -> Bool {
        if a.ref != b.ref || a.note != b.note { return true }
        if a.windows.count != b.windows.count { return true }
        for (x, y) in zip(a.windows.sorted { $0.kind < $1.kind },
                          b.windows.sorted { $0.kind < $1.kind }) {
            if x.kind != y.kind { return true }
            if abs(x.percentUsed - y.percentUsed) >= 0.5 { return true }
            if abs(x.resetsAt.timeIntervalSince(y.resetsAt)) >= 60 { return true }
        }
        return false
    }
}
