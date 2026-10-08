import Foundation

public enum Provider: String, Codable, Sendable, CaseIterable {
    case claude, codex
    public var display: String { self == .claude ? "Claude" : "Codex" }
}

/// Stable identity for one account. `id` is the provider's own account id, so it
/// survives logout/login; `label` is a human name captured opportunistically.
public struct AccountRef: Codable, Hashable, Sendable {
    public let provider: Provider
    public let id: String
    public var label: String?
    public var plan: String?

    public init(provider: Provider, id: String, label: String? = nil, plan: String? = nil) {
        self.provider = provider; self.id = id; self.label = label; self.plan = plan
    }

    public var display: String { label ?? String(id.prefix(8)) }
    public var key: String { "\(provider.rawValue):\(id)" }
}

/// One quota window (Claude 5-hour / 7-day, Codex weekly).
public struct QuotaWindow: Codable, Hashable, Sendable {
    public let kind: String        // "session", "weekly_all", "weekly", ...
    public let group: String       // "session" | "weekly"
    public let percentUsed: Double // as observed
    public let resetsAt: Date
    public var scope: String?

    public init(kind: String, group: String, percentUsed: Double, resetsAt: Date, scope: String? = nil) {
        self.kind = kind; self.group = group; self.percentUsed = percentUsed
        self.resetsAt = resetsAt; self.scope = scope
    }
}

/// How much we trust a reading.
public enum Certainty: String, Codable, Sendable {
    case exact      // read live, or provably reset because resetsAt has passed
    case atLeast    // stale snapshot mid-window: true usage is >= this
    case unknown
}

public enum SnapshotSource: String, Codable, Sendable {
    case live       // fetched just now over the network
    case disk       // parsed from the CLI's own on-disk telemetry
    case cached     // replayed from our own snapshot store
}

public struct AccountSnapshot: Codable, Sendable {
    public var ref: AccountRef
    public var windows: [QuotaWindow]
    public var source: SnapshotSource
    public var observedAt: Date
    public var note: String?

    public init(ref: AccountRef, windows: [QuotaWindow], source: SnapshotSource,
                observedAt: Date, note: String? = nil) {
        self.ref = ref; self.windows = windows; self.source = source
        self.observedAt = observedAt; self.note = note
    }
}

/// A window resolved against the clock. This is where the project earns its keep:
/// an absolute `resetsAt` in the past means the window provably rolled over, so a
/// week-old snapshot still yields an *exact* answer of 0% used.
public struct ResolvedWindow: Sendable {
    public let window: QuotaWindow
    public let percentUsed: Double
    public let certainty: Certainty
    public let hasReset: Bool

    public var headroom: Double { max(0, 100 - percentUsed) }

    /// A reading is exact when the window has provably reset, or when it was taken
    /// recently enough that usage cannot meaningfully have moved since. Otherwise
    /// usage can only have gone up, so the number is a floor, not a value.
    public init(window: QuotaWindow, observedAt: Date, now: Date,
                freshFor: TimeInterval = 900) {
        self.window = window
        if now >= window.resetsAt {
            self.percentUsed = 0
            self.certainty = .exact
            self.hasReset = true
        } else {
            self.percentUsed = window.percentUsed
            self.certainty = now.timeIntervalSince(observedAt) <= freshFor ? .exact : .atLeast
            self.hasReset = false
        }
    }
}

public struct ResolvedAccount: Sendable {
    public let ref: AccountRef
    public let windows: [ResolvedWindow]
    public let source: SnapshotSource
    public let observedAt: Date
    public let note: String?
    public let nickname: String?

    /// What to call this account on screen: the user's name wins, then whatever
    /// identity the provider gave us.
    public var displayName: String { nickname ?? ref.display }

    /// Shown beside a nickname. Deliberately the plan rather than the email: once
    /// you have named an account the address adds nothing, and not printing it
    /// keeps the window safe to screenshot or screen-share.
    public var subtitle: String? {
        guard nickname != nil else { return nil }
        return ref.plan
    }

    public init(snapshot: AccountSnapshot, now: Date, nickname: String? = nil) {
        self.nickname = nickname
        self.ref = snapshot.ref
        self.source = snapshot.source
        self.observedAt = snapshot.observedAt
        self.note = snapshot.note
        self.windows = snapshot.windows.map {
            ResolvedWindow(window: $0, observedAt: snapshot.observedAt, now: now)
        }
    }

    /// The window closest to blocking you — what actually gates the next request.
    public var binding: ResolvedWindow? {
        windows.max { $0.percentUsed < $1.percentUsed }
    }

    public var headroom: Double { binding?.headroom ?? 0 }

    /// True only when every window is known-exact. Drives the "≥" prefix in the UI.
    public var isExact: Bool { !windows.isEmpty && windows.allSatisfy { $0.certainty == .exact } }

    public var nextReset: Date? { windows.filter { !$0.hasReset }.map(\.window.resetsAt).min() }
}
