import AppKit
import MonitorCore
import SwiftUI

struct ProcessList: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Group {
            if store.snapshot?.includesProcesses != true {
                ProgressView("Reading processes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.rows.isEmpty {
                EmptyListView()
            } else {
                List(store.rows, selection: $store.selection) { row in
                    ProcessRowView(row: row)
                        .contextMenu { RowMenu(row: row) }
                }
                .listStyle(.inset)
                .transaction { $0.animation = nil }
            }
        }
        .onHover { inside in store.setPointerInside(inside, surface: .mainWindow) }
    }
}

private struct EmptyListView: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        if !store.options.search.isEmpty {
            ContentUnavailableView.search(text: store.options.search)
        } else if store.options.metric == .gpu {
            ContentUnavailableView(
                "Nothing is using the GPU", systemImage: "cpu",
                description: Text("Apps that draw with the GPU show up here while they run."))
        } else {
            ContentUnavailableView(
                "Nothing to show", systemImage: "checkmark.circle",
                description: Text("Switch to All processes to see what macOS is running."))
        }
    }
}

struct ProcessRowView: View {
    @Environment(MonitorStore.self) private var store
    let row: DisplayRow

    var body: some View {
        HStack(spacing: 8) {
            disclosure
            Image(nsImage: IconCache.shared.icon(for: row.icon))
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help(row.path ?? row.title)
            Spacer(minLength: 12)
            UsageBar(fraction: row.barFraction)
                .frame(width: 110, height: 6)
            Text(row.valueText)
                .monospacedDigit()
                .frame(width: 78, alignment: .trailing)
            QuitCell(row: row)
                .frame(width: 124, alignment: .trailing)
        }
        .padding(.leading, row.depth == 1 ? 26 : 0)
        .padding(.vertical, 2)
        .opacity(row.action == .ended ? 0.45 : 1)
    }

    @ViewBuilder private var disclosure: some View {
        if let expanded = row.isExpanded, case .group(let group) = row.id {
            Button {
                store.toggleExpanded(group)
            } label: {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(expanded ? "Hide processes" : "Show processes")
        } else {
            Color.clear.frame(width: 14, height: 1)
        }
    }
}

/// A thin capsule showing the share of the bar scale.
struct UsageBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if fraction > 0 {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(geometry.size.width * fraction, 4))
                }
            }
        }
    }

    private var tint: Color {
        switch fraction {
        case 0.9...: .red
        case 0.6...: .orange
        default: .accentColor
        }
    }
}

/// The right-hand side of a row: Quit, progress, Force Quit, or why it's locked.
struct QuitCell: View {
    @Environment(MonitorStore.self) private var store
    let row: DisplayRow

    var body: some View {
        switch row.action {
        case .quit(let target):
            switch store.phase(of: target) {
            case .quitting?, .forceQuitting?:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Quitting…").foregroundStyle(.secondary)
                }
            case .stillRunning?:
                Button("Force Quit") { store.requestQuit(target, force: true) }
                    .controlSize(.small)
                    .tint(.red)
                    .help("It didn't quit. It may be asking to save changes.")
            case nil:
                Button("Quit") { store.requestQuit(target, force: false) }
                    .controlSize(.small)
                    .disabled(store.quittingDisabled)
            }
        case .locked(let reason):
            Label(reason.label, systemImage: "lock.fill")
                .labelStyle(LockLabelStyle())
                .help(reason.explanation)
        case .partOf(let app):
            Text("Part of \(app)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("Managed by macOS. Quit \(app) to close it.")
        case .ended:
            Text("Ended")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct LockLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title.font(.caption).lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }
}

/// Right-click menu for a row.
struct RowMenu: View {
    @Environment(MonitorStore.self) private var store
    let row: DisplayRow

    var body: some View {
        if let target = row.quitTarget {
            Button("Quit") { store.requestQuit(target, force: false) }
            Button("Force Quit…") { store.requestQuit(target, force: true) }
            Divider()
        }
        if let path = row.path {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        if let pid = row.pid {
            Button("Copy PID") { copy(String(pid)) }
        }
        if let path = row.path {
            Button("Copy Path") { copy(path) }
        }
        if case .locked(let reason) = row.action {
            Divider()
            Text(reason.explanation)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
