import Foundation

/// Reads Codex quota straight off disk. Codex writes a full `rate_limits` snapshot
/// into every `token_count` event of its session rollouts, so no network call is
/// needed — and crucially, none is *possible*: Codex exposes no read-only usage
/// API, and rate limits only ride along on real inference responses. Firing one
/// to read the gauge would consume the quota we are trying to measure.
public final class CodexProvider: @unchecked Sendable {
    public let home: URL

    /// Rollout headers are immutable once written, so a scan only ever needs to
    /// parse a file's `session_meta` once. Without this, every poll re-reads tens
    /// of megabytes across hundreds of rollouts.
    /// Persisted, because a cold scan of several hundred rollouts costs seconds of
    /// I/O and this app starts at login. `""` stands in for "parsed, no account id",
    /// so unattributable files are not re-read on every launch either.
    private var headerCache: [String: String] = [:]
    private var cacheDirty = false
    private let cacheLock = NSLock()
    private let cacheURL: URL

    public init(home: URL? = nil, cacheURL: URL? = nil) {
        self.home = home ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
        self.cacheURL = cacheURL ?? SnapshotStore.defaultURL()
            .deletingLastPathComponent().appendingPathComponent("codex-headers.json")
        loadCache()
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        headerCache = decoded
    }

    private func saveCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard cacheDirty else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(headerCache) {
            try? data.write(to: cacheURL, options: .atomic)
            cacheDirty = false
        }
    }

    /// Rollout paths are unique and their headers never change, so a hit is final.
    private func cachedAccountId(for url: URL) -> String? {
        let key = url.lastPathComponent
        cacheLock.lock()
        if let hit = headerCache[key] { cacheLock.unlock(); return hit.isEmpty ? nil : hit }
        cacheLock.unlock()

        let accountId = sessionMeta(of: url)?["creator_account_id"] as? String
        cacheLock.lock()
        headerCache[key] = accountId ?? ""
        cacheDirty = true
        cacheLock.unlock()
        return accountId
    }

    // MARK: - Account identity (local, no network)

    /// The currently logged-in account, labelled from the id_token's claims.
    public func activeAccount() -> AccountRef? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accountId = tokens["account_id"] as? String
        else { return nil }

        var label: String?
        var plan: String?
        if let idToken = tokens["id_token"] as? String,
           let claims = Self.decodeJWTClaims(idToken) {
            label = claims["email"] as? String
            if let auth = claims["https://api.openai.com/auth"] as? [String: Any] {
                plan = auth["chatgpt_plan_type"] as? String
            }
        }
        return AccountRef(provider: .codex, id: accountId, label: label, plan: plan)
    }

    /// JWTs are signed, not encrypted; the payload decodes locally with no network
    /// and no secret. We never verify the signature because we are not trusting it
    /// for authorization — only reading the email and plan for display.
    static func decodeJWTClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Quota from rollouts

    /// Newest `rate_limits` per account, found by grouping rollouts on the
    /// `creator_account_id` recorded in each file's `session_meta` header.
    public func snapshots() -> [AccountSnapshot] {
        let active = activeAccount()
        var newestPerAccount: [String: (url: URL, mtime: Date)] = [:]

        let byNewest = rolloutFiles()
            .map { (url: $0, mtime: Self.mtime(of: $0)) }
            .sorted { $0.mtime > $1.mtime }

        for (url, _) in byNewest {
            guard let accountId = cachedAccountId(for: url)
            else { continue }   // pre-0.1x rollouts omit the field; unattributable
            let mtime = Self.mtime(of: url)
            if let existing = newestPerAccount[accountId], existing.mtime >= mtime { continue }
            newestPerAccount[accountId] = (url, mtime)
        }
        saveCache()

        var results: [AccountSnapshot] = newestPerAccount.compactMap { accountId, entry in
            guard let limits = lastRateLimits(in: entry.url) else { return nil }
            var ref = AccountRef(provider: .codex, id: accountId)
            if let active, active.id == accountId {
                ref.label = active.label; ref.plan = active.plan
            }
            if ref.plan == nil { ref.plan = limits.planType }
            return AccountSnapshot(
                ref: ref,
                windows: limits.windows,
                source: .disk,
                observedAt: entry.mtime,
                note: limits.creditsNote
            )
        }

        let claimed = Set(results.compactMap(\.ref.plan))
        results.append(contentsOf: inferredFromPlan(in: byNewest, excluding: claimed))
        return results
    }

    /// Codex only began writing `creator_account_id` in late 2026, so earlier
    /// rollouts cannot be keyed to an account. Their `plan_type` still
    /// distinguishes them, though: a `pro` rollout cannot have come from the
    /// `prolite` account we can identify. Surfacing those as inferred accounts is
    /// strictly better than pretending they do not exist — their windows are long
    /// expired, so they resolve to a provable "ready", which is the actionable bit.
    ///
    /// This is a heuristic and is labelled as one: two accounts on the same plan
    /// collapse into a single entry.
    func inferredFromPlan(in files: [(url: URL, mtime: Date)],
                          excluding claimed: Set<String>) -> [AccountSnapshot] {
        var newestPerPlan: [String: (limits: RateLimits, mtime: Date)] = [:]

        for (url, mtime) in files {
            if cachedAccountId(for: url) != nil { continue }   // already attributable
            guard let limits = lastRateLimits(in: url),
                  let plan = limits.planType,
                  !claimed.contains(plan)
            else { continue }
            if let existing = newestPerPlan[plan], existing.mtime >= mtime { continue }
            newestPerPlan[plan] = (limits, mtime)
            if newestPerPlan.count >= 6 { break }   // bound the scan on a cold cache
        }

        return newestPerPlan.map { plan, entry in
            AccountSnapshot(
                ref: AccountRef(provider: .codex, id: "plan:\(plan)",
                                label: "unidentified", plan: plan),
                windows: entry.limits.windows,
                source: .disk,
                observedAt: entry.mtime,
                note: "inferred from plan — log in to this account once to name it"
            )
        }
    }

    static func mtime(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    func rolloutFiles() -> [URL] {
        let root = home.appendingPathComponent("sessions")
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-") }
    }

    /// Only the first line is needed, so we avoid loading multi-megabyte rollouts.
    /// It is read in growing chunks until the newline actually appears: real
    /// `session_meta` headers run past 22 KB, and a fixed buffer silently
    /// truncates the JSON and drops the account.
    func sessionMeta(of url: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var buffer = Data()
        let maxHeader = 4 * 1024 * 1024
        while buffer.count < maxHeader {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty
            else { break }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                buffer = buffer[buffer.startIndex..<newline]
                break
            }
        }
        guard !buffer.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any],
              obj["type"] as? String == "session_meta"
        else { return nil }
        return obj["payload"] as? [String: Any]
    }

    struct RateLimits {
        var windows: [QuotaWindow]
        var planType: String?
        var creditsNote: String?
    }

    /// Rate limits are appended continuously, so the authoritative reading is the
    /// last one in the file. Read backwards from the end rather than parsing the
    /// whole rollout — these files reach tens of megabytes.
    func lastRateLimits(in url: URL) -> RateLimits? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }

        let window = 512 * 1024
        var offset = size
        var tail = Data()

        while offset > 0 {
            let step = UInt64(min(window, Int(offset)))
            offset -= step
            try? handle.seek(toOffset: offset)
            guard let chunk = try? handle.read(upToCount: Int(step)) else { break }
            tail = chunk + tail
            if let hit = Self.lastRateLimitsObject(in: tail) { return hit }
            if tail.count > 8 * 1024 * 1024 { break }   // give up rather than thrash
        }
        return nil
    }

    static func lastRateLimitsObject(in data: Data) -> RateLimits? {
        let lines = data.split(separator: UInt8(ascii: "\n"))
        for line in lines.reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any]
            else { continue }
            return parse(limits)
        }
        return nil
    }

    static func parse(_ limits: [String: Any]) -> RateLimits {
        var windows: [QuotaWindow] = []
        for key in ["primary", "secondary"] {
            guard let w = limits[key] as? [String: Any],
                  let percent = w["used_percent"] as? Double,
                  let resets = w["resets_at"] as? Double
            else { continue }
            let minutes = (w["window_minutes"] as? Int) ?? 0
            windows.append(QuotaWindow(
                kind: minutes >= 1440 ? "weekly" : "session",
                group: minutes >= 1440 ? "weekly" : "session",
                percentUsed: percent,
                resetsAt: Date(timeIntervalSince1970: resets),
                scope: minutes > 0 ? "\(minutes)m window" : nil
            ))
        }

        var note: String?
        if let credits = limits["credits"] as? [String: Any] {
            let unlimited = (credits["unlimited"] as? Bool) ?? false
            let has = (credits["has_credits"] as? Bool) ?? false
            if unlimited { note = "credits: unlimited" }
            else if !has { note = "no credits" }
            else if let balance = credits["balance"] as? String { note = "credits: \(balance)" }
        }

        return RateLimits(
            windows: windows,
            planType: limits["plan_type"] as? String,
            creditsNote: note
        )
    }
}
