import SwiftUI
import TrackrCore

struct MenuView: View {
    @ObservedObject var model: BarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let report = model.report, !report.accounts.isEmpty {
                ForEach(report.accounts, id: \.ref.key) { account in
                    AccountCard(account: account) { newName in
                        model.rename(account, to: newName)
                    }
                }
            } else {
                Text("No accounts observed yet.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Use each account once while KeepTrack is running — it captures the reading before login overwrites it.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }

            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("AI Coding Trackr").font(.headline)
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            }
        }
    }

    private static let repo = URL(string: "https://github.com/tawanorg/aicodingtrackr")!
    private static let author = URL(string: "https://github.com/tawanorg")!

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Refresh") { Task { await model.refresh() } }
                .buttonStyle(.borderless)

            Spacer()

            Link(destination: Self.repo) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
            }
            .help("Source on GitHub")

            Link("@tawanorg", destination: Self.author)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .font(.caption)
        .buttonStyle(.borderless)
    }
}

struct AccountCard: View {
    let account: ResolvedAccount
    let onRename: (String) -> Void

    @State private var draft: String = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(account.ref.provider.display).font(.callout).fontWeight(.semibold)

                // Named in place — no settings screen, no dialog. Submitting an
                // empty name clears it and restores the provider's own label.
                TextField(account.ref.display, text: $draft)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(draft.isEmpty ? .secondary : .primary)
                    .focused($editing)
                    .onSubmit { onRename(draft); editing = false }
                    .onAppear { draft = account.nickname ?? "" }
                    .onChange(of: account.nickname) { _, new in
                        if !editing { draft = new ?? "" }
                    }

                Spacer()
                Text(freshness).font(.caption2).foregroundStyle(.tertiary)
            }

            if let subtitle = account.subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }

            ForEach(Array(account.windows.enumerated()), id: \.offset) { _, window in
                WindowRow(window: window)
            }

            if let note = account.note {
                Text(note).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var freshness: String {
        switch account.source {
        case .live:   "live"
        case .disk:   "from disk"
        case .cached: "last seen \(Fmt.relative(Date(), from: account.observedAt)) ago"
        }
    }
}

struct WindowRow: View {
    let window: ResolvedWindow

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 96, alignment: .leading)
                .foregroundStyle(.secondary).lineLimit(1)

            ProgressView(value: window.percentUsed, total: 100)
                .tint(tint).frame(height: 4)

            Text(Fmt.percent(window)).font(.caption).monospacedDigit()
                .frame(width: 42, alignment: .trailing)

            Text(reset).font(.caption2).foregroundStyle(window.hasReset ? Color.green : Color.secondary)
                .frame(width: 58, alignment: .trailing)
        }
    }

    private var label: String {
        if let scope = window.window.scope, window.window.group == "weekly", scope.count < 12 {
            return "\(window.window.group) · \(scope)"
        }
        return window.window.group
    }

    /// Colour tracks what actually blocks you, so a nearly-spent window reads as a
    /// warning before you discover it mid-task.
    private var tint: Color {
        switch window.percentUsed {
        case ..<50:  .green
        case ..<80:  .yellow
        case ..<95:  .orange
        default:     .red
        }
    }

    private var reset: String {
        window.hasReset ? "ready ✓" : Fmt.relative(window.window.resetsAt)
    }
}
