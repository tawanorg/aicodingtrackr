import Foundation

/// Merges every readable source into one ranked view of your accounts.
public struct Tracker: Sendable {
    public let claude: ClaudeProvider
    public let codex: CodexProvider
    public let store: SnapshotStore
    public let nicknames: NicknameStore

    public init(claude: ClaudeProvider = .init(),
                codex: CodexProvider = .init(),
                store: SnapshotStore = .init(),
                nicknames: NicknameStore = .init()) {
        self.claude = claude; self.codex = codex; self.store = store
        self.nicknames = nicknames
    }

    public struct Report: Sendable {
        public var accounts: [ResolvedAccount]
        public var warnings: [String]
        public var generatedAt: Date
        /// Set when a provider asked us to slow down. The caller should not poll
        /// again before this many seconds have passed.
        public var backoffHint: TimeInterval?
    }

    public func refresh(now: Date = Date()) async -> Report {
        var observed: [String: AccountSnapshot] = [:]
        var warnings: [String] = []
        var backoff: TimeInterval?

        // Codex: on-disk, every account that has ever written an attributable rollout.
        for snapshot in codex.snapshots() {
            observed[snapshot.ref.key] = snapshot
            store.record(snapshot)
        }

        // Claude: live, but only for whichever account owns the Keychain token now.
        do {
            let snapshot = try await claude.fetchLive()
            observed[snapshot.ref.key] = snapshot
            store.record(snapshot)
        } catch {
            warnings.append("Claude live read failed: \(error.localizedDescription)")
            if let fetchError = error as? ClaudeProvider.FetchError,
               case .rateLimited = fetchError {
                // The endpoint has been seen returning `retry-after: 0` while still
                // throttling, so a non-positive hint must not reset our own backoff.
                backoff = fetchError.retryAfter.flatMap { $0 > 0 ? $0 : nil } ?? 600
            }
        }

        // Everything else falls back to its last known reading. These are still
        // useful: a window whose resetsAt has passed resolves to an exact 0%.
        var merged = observed
        for (key, cached) in store.latest() where merged[key] == nil {
            var replay = cached
            replay.source = .cached
            merged[key] = replay
        }

        if merged.isEmpty {
            warnings.append("No accounts seen yet. Use each account once while Trackr runs.")
        }

        let accounts = merged.values
            .map { ResolvedAccount(snapshot: $0, now: now, nickname: nicknames.name(for: $0.ref.key)) }
            // Most headroom first within a provider, so the usable accounts are
            // easiest to scan. Ordering only; the choice stays with the reader.
            .sorted {
                if $0.ref.provider != $1.ref.provider {
                    return $0.ref.provider.rawValue < $1.ref.provider.rawValue
                }
                return $0.headroom > $1.headroom
            }

        return Report(accounts: accounts, warnings: warnings, generatedAt: now,
                      backoffHint: backoff)
    }
}

extension Tracker {
    /// Rebuilds the view from stored snapshots alone — no network, no rollout scan.
    ///
    /// Every reset time is absolute, so counting down and flipping an expired
    /// window to "ready" is pure arithmetic against the clock. Only *new usage*
    /// needs a fetch, which is why the UI can tick every few seconds while the
    /// network is touched once in ten minutes.
    public func resolveCached(now: Date = Date()) -> Report {
        let accounts = store.latest().values
            .map { snapshot in
                ResolvedAccount(snapshot: snapshot, now: now,
                                nickname: nicknames.name(for: snapshot.ref.key))
            }
            .sorted {
                if $0.ref.provider != $1.ref.provider {
                    return $0.ref.provider.rawValue < $1.ref.provider.rawValue
                }
                return $0.headroom > $1.headroom
            }
        return Report(accounts: accounts, warnings: [], generatedAt: now, backoffHint: nil)
    }
}

// MARK: - Formatting shared by the CLI and the menu bar

public enum Fmt {
    public static func relative(_ date: Date, from now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    public static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: date)
    }

    public static func bar(_ percentUsed: Double, width: Int = 10) -> String {
        let filled = max(0, min(width, Int((percentUsed / 100 * Double(width)).rounded())))
        return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    }

    /// The "≥" is load-bearing: it marks a stale mid-window reading where real
    /// usage can only be higher than what we last saw.
    public static func percent(_ w: ResolvedWindow) -> String {
        w.certainty == .atLeast ? "≥\(Int(w.percentUsed))%" : "\(Int(w.percentUsed))%"
    }
}
