import SwiftUI
import TrackrCore

@MainActor
final class BarModel: ObservableObject {
    @Published var report: Tracker.Report?
    @Published var isRefreshing = false
    @Published var lastError: String?

    private let tracker = Tracker()
    private var poller: Task<Void, Never>?

    /// Polling costs no agent quota — the usage endpoint is a metering read, not
    /// inference — but it rate-limits its own callers, and being throttled costs
    /// the live reading. Five minutes is well inside any window that matters: the
    /// shortest quota window is five hours.
    private let baseInterval: TimeInterval = 300
    private let maxInterval: TimeInterval = 1800
    private var backoff: TimeInterval = 0

    init() {
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let delay = await self.nextDelay()
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    deinit { poller?.cancel() }

    private func nextDelay() -> TimeInterval {
        max(baseInterval, backoff)
    }

    func rename(_ account: ResolvedAccount, to name: String) {
        tracker.nicknames.set(name, for: account.ref.key)
        Task { await refresh() }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let fresh = await tracker.refresh()
        report = fresh
        lastError = fresh.warnings.first

        // Honour a throttle, and double it while it keeps happening so a sustained
        // block does not turn into a tight retry loop.
        if let hint = fresh.backoffHint {
            backoff = min(maxInterval, max(hint, backoff == 0 ? hint : backoff * 2))
        } else {
            backoff = 0
        }
        isRefreshing = false
    }

    /// Glanceable strip: one token per account, a tick when its window has rolled
    /// over. This is the whole point of the app — "is codex2 usable yet?" answered
    /// without opening anything.
    var title: String {
        guard let accounts = report?.accounts, !accounts.isEmpty else { return "Trackr" }
        return accounts.map { account in
            let tag = account.ref.provider == .claude ? "CL" : "CX"
            guard let binding = account.binding else { return "\(tag) —" }
            if binding.hasReset { return "\(tag) ✓" }
            return "\(tag) \(Int(binding.percentUsed))%"
        }.joined(separator: "  ")
    }
}

@main
struct TrackrBarApp: App {
    @StateObject private var model = BarModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Text(model.title).monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}
