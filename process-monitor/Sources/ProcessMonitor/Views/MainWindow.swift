import MonitorCore
import SwiftUI

struct MainWindow: View {
    static let id = "main"

    @Environment(MonitorStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            Banners()
            SummaryStrip()
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider()
            ProcessList()
            Divider()
            StatusBar()
        }
        .frame(minWidth: 620, minHeight: 440)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Resource", selection: $store.options.metric) {
                    ForEach(Metric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                .help("Choose what to sort by (⌘1, ⌘2, ⌘3)")
            }
            ToolbarItem(placement: .automatic) {
                Picker("Show", selection: $store.options.scope) {
                    ForEach(Scope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .pickerStyle(.menu)
                .help("My processes lists only what you can quit")
            }
        }
        .searchable(text: $store.options.search, placement: .toolbar, prompt: "Search apps, processes or PIDs")
        .overlay(alignment: .bottom) { ToastStack() }
        .alert(store.dialog?.title ?? "", isPresented: dialogIsPresented, presenting: store.dialog) { dialog in
            // Return confirms a normal quit, but never a force quit.
            Button(dialog.confirmTitle, role: dialog.request.force ? .destructive : nil) { store.confirmDialog() }
                .keyboardShortcut(dialog.request.force ? nil : .defaultAction)
            Button("Cancel", role: .cancel) { store.cancelDialog() }
        } message: { dialog in
            Text(dialog.message)
        }
        .background(VisibilityReporter(surface: .mainWindow))
    }

    private var dialogIsPresented: Binding<Bool> {
        Binding(
            get: { store.dialog != nil },
            set: { presented in
                if !presented { store.cancelDialog() }
            })
    }
}

/// Explains why quitting is off (root) or CPU is hidden (Rosetta).
private struct Banners: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        if store.quittingDisabled {
            banner(ProtectionReason.runningAsRoot.explanation, systemImage: "lock.shield")
        }
        if store.me.isTranslated {
            banner(
                "Process Monitor is running under Rosetta, so CPU numbers can't be measured. Open the Apple silicon version.",
                systemImage: "exclamationmark.triangle")
        }
    }

    private func banner(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.yellow.opacity(0.18))
    }
}

private struct StatusBar: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        HStack(spacing: 6) {
            if let snapshot = store.snapshot {
                let yours = snapshot.groups.filter(\.hasKillableMember).count
                Text("\(Format.processCount(snapshot.processCount)) running · \(yours) you can quit")
            } else {
                Text("Reading processes…")
            }
            Spacer()
            Image(systemName: "lock.fill")
                .imageScale(.small)
            Text("macOS processes are always protected")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}
