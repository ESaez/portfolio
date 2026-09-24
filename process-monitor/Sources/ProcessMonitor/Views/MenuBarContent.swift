import AppKit
import MonitorCore
import SwiftUI

/// The menu bar icon, optionally with live CPU use.
struct MenuBarLabel: View {
    let store: MonitorStore

    var body: some View {
        if store.settings.showCPUInMenuBar, let cpu = store.snapshot?.totals.cpuPercent {
            Text("CPU \(Int(cpu.rounded()))%")
                .monospacedDigit()
        } else {
            Image(systemName: "gauge.with.dots.needle.50percent")
        }
    }
}

/// The menu bar popover: totals, the top things you can quit, and shortcuts.
struct MenuBarContent: View {
    @Environment(MonitorStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                stat("CPU", Format.percent(store.snapshot?.totals.cpuPercent))
                stat("Memory", memoryText)
                stat("GPU", Format.percent(store.snapshot?.totals.gpuPercent))
            }

            Picker("Sort by", selection: $store.menuMetric) {
                ForEach(Metric.allCases) { metric in
                    Text(metric.title).tag(metric)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(spacing: 2) {
                if store.menuRows.isEmpty {
                    Text(store.snapshot == nil ? "Reading processes…" : "Nothing of yours is running")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ForEach(store.menuRows) { row in
                        MenuRow(row: row)
                    }
                }
            }
            .onHover { inside in store.setPointerInside(inside, surface: .menu) }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                MenuButton("Open Process Monitor") {
                    openWindow(id: MainWindow.id)
                    NSApp.activate()
                }
                MenuButton("Settings…") {
                    openSettings()
                    NSApp.activate()
                }
                MenuButton("Quit Process Monitor") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(12)
        .frame(width: 330)
        .background(VisibilityReporter(surface: .menu))
    }

    private var memoryText: String {
        guard let memory = store.snapshot?.totals.memory, memory.totalBytes > 0 else { return Format.missing }
        return Format.percent(Double(memory.usedBytes) / Double(memory.totalBytes) * 100)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row of the popover. With "Ask before quitting" on, the first click turns the
/// button into "Confirm" for a few seconds instead of opening a dialog.
private struct MenuRow: View {
    @Environment(MonitorStore.self) private var store
    let row: DisplayRow
    @State private var armed = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: IconCache.shared.icon(for: row.icon))
                .resizable()
                .frame(width: 18, height: 18)
            Text(row.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(row.valueText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            action
                .frame(width: 78, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .opacity(row.action == .ended ? 0.45 : 1)
    }

    @ViewBuilder private var action: some View {
        if let target = row.quitTarget {
            switch store.phase(of: target) {
            case .quitting?, .forceQuitting?:
                ProgressView().controlSize(.small)
            case .stillRunning?:
                twoStepButton(title: "Force", target: target, force: true)
            case nil:
                if store.settings.askBeforeQuitting {
                    twoStepButton(title: "Quit", target: target, force: false)
                } else {
                    Button("Quit") { store.requestQuit(target, force: false) }
                        .controlSize(.small)
                }
            }
        } else if row.action == .ended {
            Text("Ended").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func twoStepButton(title: String, target: QuitTarget, force: Bool) -> some View {
        Button(armed ? "Confirm" : title) {
            if armed {
                armed = false
                store.requestQuit(target, force: force, confirmed: true)
            } else {
                armed = true
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    armed = false
                }
            }
        }
        .controlSize(.small)
        .tint(armed || force ? Color.red : nil)
        .disabled(store.quittingDisabled)
    }
}

private struct MenuButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 2)
    }
}
