import Foundation
import TrackrCore

// A plain-text mirror of the menu bar, so the data layer can be verified
// without a UI in the loop.

// A side-effect-free flag: no network, no Keychain, no file scan. The Homebrew
// formula's test needs something safe to run in a sandbox.
if CommandLine.arguments.dropFirst().contains(where: { $0 == "--version" || $0 == "-v" }) {
    print("AI Coding Trackr \(trackrVersion)")
    exit(0)
}

let now = Date()
let report = await Tracker().refresh(now: now)

func render(_ account: ResolvedAccount) {
    // The subtitle already carries the plan once an account is named.
    let plan = account.subtitle == nil ? (account.ref.plan.map { " · \($0)" } ?? "") : ""
    let staleness: String
    switch account.source {
    case .live:   staleness = "live"
    case .disk:   staleness = "disk, \(Fmt.relative(now, from: account.observedAt)) ago"
    case .cached: staleness = "last seen \(Fmt.relative(now, from: account.observedAt)) ago"
    }

    let alias = account.subtitle.map { " (\($0))" } ?? ""
    print("\n\(account.ref.provider.display)  \(account.displayName)\(alias)\(plan)   [\(staleness)]")

    for window in account.windows.sorted(by: { $0.window.group < $1.window.group }) {
        let scope = window.window.scope.map { " (\($0))" } ?? ""
        let label = (window.window.group + scope).padding(toLength: 22, withPad: " ", startingAt: 0)
        let reset = window.hasReset
            ? "RESET — full quota"
            : "resets \(Fmt.clock(window.window.resetsAt)) (\(Fmt.relative(window.window.resetsAt, from: now)))"
        print("  \(label) \(Fmt.bar(window.percentUsed))  \(Fmt.percent(window).padding(toLength: 6, withPad: " ", startingAt: 0)) \(reset)")
    }

    if let note = account.note { print("  note: \(note)") }
}

print("AI Coding Trackr — \(Fmt.clock(now)) local")
report.accounts.forEach(render)

if !report.warnings.isEmpty {
    print("\nWarnings:")
    report.warnings.forEach { print("  ! \($0)") }
}
