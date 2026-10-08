import Foundation

/// User-chosen names for accounts, keyed by the stable `AccountRef.key`.
///
/// Needed because an account's machine-readable identity is often unhelpful: a
/// pre-Sept-2026 Codex account has no id at all and shows as `unidentified · pro`,
/// and even a real one is a UUID or an email you may not associate with "the work
/// one". The key survives logout/login, so a name set once sticks.
public final class NicknameStore: @unchecked Sendable {
    public let fileURL: URL
    private var names: [String: String] = [:]
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? SnapshotStore.defaultURL()
            .deletingLastPathComponent().appendingPathComponent("nicknames.json")
        reload()
    }

    public func reload() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        lock.lock(); names = decoded; lock.unlock()
    }

    public func name(for key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return names[key]
    }

    /// An empty or whitespace-only name clears it, so the field doubles as the
    /// way to undo a rename.
    public func set(_ name: String?, for key: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        if let trimmed, !trimmed.isEmpty { names[key] = trimmed } else { names.removeValue(forKey: key) }
        let snapshot = names
        lock.unlock()

        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
