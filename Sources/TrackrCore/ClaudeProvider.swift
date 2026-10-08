import Foundation
import Security

/// Reads Claude Code quota from the same endpoint the CLI's own `/usage` command
/// uses, authenticating with the OAuth token Claude Code stores in the login
/// Keychain. This is an unofficial endpoint: it can change without notice, so
/// every failure degrades to the last stored snapshot rather than breaking the UI.
public struct ClaudeProvider: Sendable {
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let keychainService = "Claude Code-credentials"

    public let configPath: URL

    public init(configPath: URL? = nil) {
        self.configPath = configPath ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
    }

    // MARK: - Identity

    /// Identity comes from `~/.claude.json`, which needs no credentials at all.
    public func activeAccount() -> AccountRef? {
        guard let data = try? Data(contentsOf: configPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any],
              let uuid = account["accountUuid"] as? String
        else { return nil }
        return AccountRef(
            provider: .claude,
            id: uuid,
            label: account["emailAddress"] as? String,
            plan: (account["organizationType"] as? String)?
                .replacingOccurrences(of: "claude_", with: "")
        )
    }

    // MARK: - Credentials

    public struct Credentials: Sendable {
        public let accessToken: String
        public let expiresAt: Date?
        public var isExpired: Bool { expiresAt.map { $0 <= Date() } ?? false }
    }

    /// Reading another app's Keychain item prompts for consent the first time.
    /// That is a one-off macOS dialog, not a login.
    public func credentials() -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return nil }

        let expiry = (oauth["expiresAt"] as? Double).map {
            Date(timeIntervalSince1970: $0 / 1000)
        }
        return Credentials(accessToken: token, expiresAt: expiry)
    }

    // MARK: - Live fetch

    public enum FetchError: Error, LocalizedError {
        case noCredentials, tokenExpired, malformed
        case http(Int)
        /// The usage endpoint rate-limits its own callers, so polling it too often
        /// costs you the live reading. Carries the server's Retry-After when given.
        case rateLimited(retryAfter: TimeInterval?)

        public var errorDescription: String? {
            switch self {
            case .noCredentials: "no Claude credentials in Keychain — run `claude` and log in once"
            case .tokenExpired:  "access token expired — run any `claude` command to refresh it"
            case .http(let code): "usage endpoint returned HTTP \(code)"
            case .malformed:     "usage endpoint returned an unexpected shape"
            case .rateLimited(let after):
                if let after { "usage endpoint rate-limited; retrying in \(Int(after))s" }
                else { "usage endpoint rate-limited; backing off" }
            }
        }

        /// How long the caller should wait before trying again, if we can tell.
        public var retryAfter: TimeInterval? {
            if case .rateLimited(let after) = self { return after }
            return nil
        }
    }

    public func fetchLive() async throws -> AccountSnapshot {
        guard let creds = credentials() else { throw FetchError.noCredentials }
        // Refreshing is Claude Code's job; we only read. An expired token means the
        // CLI has not run recently, so we surface that instead of minting tokens.
        if creds.isExpired { throw FetchError.tokenExpired }

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.malformed }
        if http.statusCode == 429 {
            let header = http.value(forHTTPHeaderField: "Retry-After")
            throw FetchError.rateLimited(retryAfter: header.flatMap(TimeInterval.init))
        }
        guard http.statusCode == 200 else { throw FetchError.http(http.statusCode) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw FetchError.malformed }

        let ref = activeAccount() ?? AccountRef(provider: .claude, id: "unknown")
        return AccountSnapshot(
            ref: ref,
            windows: Self.parseWindows(root),
            source: .live,
            observedAt: Date(),
            note: Self.parseExtraUsage(root)
        )
    }

    /// The response ships a pre-normalised `limits[]` array; prefer it and fall
    /// back to the older top-level `five_hour` / `seven_day` objects.
    static func parseWindows(_ root: [String: Any]) -> [QuotaWindow] {
        if let limits = root["limits"] as? [[String: Any]], !limits.isEmpty {
            let parsed = limits.compactMap { entry -> QuotaWindow? in
                guard let kind = entry["kind"] as? String,
                      let percent = entry["percent"] as? Double,
                      let resets = entry["resets_at"] as? String,
                      let date = parseISO(resets)
                else { return nil }
                var scope: String?
                if let s = entry["scope"] as? [String: Any],
                   let model = s["model"] as? [String: Any] {
                    scope = model["display_name"] as? String
                }
                return QuotaWindow(
                    kind: kind,
                    group: (entry["group"] as? String) ?? kind,
                    percentUsed: percent,
                    resetsAt: date,
                    scope: scope
                )
            }
            if !parsed.isEmpty { return parsed }
        }

        return ["five_hour": "session", "seven_day": "weekly"].compactMap { key, group in
            guard let w = root[key] as? [String: Any],
                  let util = w["utilization"] as? Double,
                  let resets = w["resets_at"] as? String,
                  let date = parseISO(resets)
            else { return nil }
            return QuotaWindow(kind: key, group: group, percentUsed: util, resetsAt: date)
        }
    }

    static func parseExtraUsage(_ root: [String: Any]) -> String? {
        guard let extra = root["extra_usage"] as? [String: Any] else { return nil }
        let enabled = (extra["is_enabled"] as? Bool) ?? false
        guard !enabled else {
            let util = (extra["utilization"] as? Double) ?? 0
            return "extra usage on (\(Int(util))% of cap)"
        }
        if let reason = extra["disabled_reason"] as? String {
            return "extra usage off (\(reason.replacingOccurrences(of: "_", with: " ")))"
        }
        return "extra usage off"
    }

    static func parseISO(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }
}
