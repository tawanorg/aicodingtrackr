import Foundation

/// Reads GitHub Copilot quota via the `gh` CLI.
///
/// Copilot's quota lives behind an authenticated GitHub endpoint rather than on
/// disk — `~/.copilot` holds only config and logs. Rather than handle a GitHub
/// token ourselves, we shell out to `gh`, which the developer has almost always
/// already authenticated. If `gh` is missing or logged out, the provider simply
/// reports nothing instead of asking for a credential.
public struct CopilotProvider: Sendable {
    /// `/copilot_internal/user` is not a documented endpoint. It can change without
    /// notice, so every failure here is non-fatal.
    public static let endpoint = "/copilot_internal/user"

    public init() {}

    public enum FetchError: Error, LocalizedError {
        case ghNotFound, ghFailed(String), malformed

        public var errorDescription: String? {
            switch self {
            case .ghNotFound: "gh CLI not found — install it to track Copilot"
            case .ghFailed(let why): "gh could not read Copilot usage: \(why)"
            case .malformed: "Copilot endpoint returned an unexpected shape"
            }
        }
    }

    /// A GUI app inherits a minimal PATH, so the usual install locations are
    /// checked directly before falling back to a login shell lookup.
    static func locateGH() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/gh").path,
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public func fetch() async throws -> AccountSnapshot {
        guard let gh = Self.locateGH() else { throw FetchError.ghNotFound }

        let process = Process()
        process.executableURL = gh
        process.arguments = ["api", Self.endpoint]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let why = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(process.terminationStatus)"
            throw FetchError.ghFailed(String(why.prefix(120)))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw FetchError.malformed }

        let id = (root["id"] as? Int).map(String.init) ?? "copilot"
        let ref = AccountRef(
            provider: .copilot,
            id: id,
            label: root["login"] as? String,
            plan: root["copilot_plan"] as? String
        )
        return AccountSnapshot(
            ref: ref,
            windows: Self.parseWindows(root),
            source: .live,
            observedAt: Date(),
            note: nil
        )
    }

    static func parseWindows(_ root: [String: Any]) -> [QuotaWindow] {
        guard let resetString = root["quota_reset_date_utc"] as? String,
              let resetsAt = ClaudeProvider.parseISO(resetString),
              let snapshots = root["quota_snapshots"] as? [String: Any]
        else { return [] }

        return snapshots.compactMap { quotaId, raw -> QuotaWindow? in
            guard let quota = raw as? [String: Any] else { return nil }

            // An unlimited quota has nothing to show, and a zero entitlement is not
            // a spent allowance — it is an allowance the plan never included. Both
            // would otherwise render as an alarming full red bar.
            if (quota["unlimited"] as? Bool) == true { return nil }
            if let entitlement = quota["entitlement"] as? Double, entitlement <= 0 { return nil }

            guard let remaining = quota["percent_remaining"] as? Double else { return nil }
            return QuotaWindow(
                kind: quotaId,
                group: "monthly",
                percentUsed: max(0, min(100, 100 - remaining)),
                resetsAt: resetsAt,
                scope: quotaId.replacingOccurrences(of: "_", with: " ")
            )
        }
    }
}
