import AppKit
import MonitorCore
import SwiftUI

/// Short confirmations at the bottom of the window ("Quit “Chrome”.").
struct ToastStack: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        VStack(spacing: 6) {
            ForEach(store.toasts) { toast in
                Label(toast.text, systemImage: icon(for: toast.kind))
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 36)
        .animation(.spring(duration: 0.3), value: store.toasts)
        .allowsHitTesting(false)
    }

    private func icon(for kind: Toast.Kind) -> String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }
}

struct SettingsView: View {
    @AppStorage(AppSettings.Key.refreshInterval) private var refreshInterval = 2.0
    @AppStorage(AppSettings.Key.askBeforeQuitting) private var askBeforeQuitting = true
    @AppStorage(AppSettings.Key.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(AppSettings.Key.showCPUInMenuBar) private var showCPUInMenuBar = false

    var body: some View {
        Form {
            Picker("Refresh every", selection: $refreshInterval) {
                ForEach(AppSettings.intervals, id: \.self) { seconds in
                    Text(seconds == 1 ? "1 second" : "\(Int(seconds)) seconds").tag(seconds)
                }
            }
            Toggle("Ask before quitting", isOn: $askBeforeQuitting)
            Toggle("Show in the menu bar", isOn: $showMenuBarIcon)
            Toggle("Show CPU usage in the menu bar", isOn: $showCPUInMenuBar)
                .disabled(!showMenuBarIcon)
            Section {
                Text(
                    "Process Monitor never asks for administrator rights, so it can only quit your own apps and processes. macOS system processes are always locked."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Tells the store whether the window it sits in is actually visible, so refreshing
/// can slow down or pause when nobody is looking.
struct VisibilityReporter: NSViewRepresentable {
    @Environment(MonitorStore.self) private var store
    let surface: Surface

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        let store = store
        let surface = surface
        view.onChange = { visible in store.setVisible(visible, surface: surface) }
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {}
}

final class VisibilityView: NSView {
    var onChange: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var lastReported: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        guard let window else {
            report(false)
            return
        }
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification,
        ]
        for name in names {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    let closing = note.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated { self?.evaluate(closing: closing) }
                })
        }
        evaluate(closing: false)
    }

    private func evaluate(closing: Bool) {
        guard let window, !closing else {
            report(false)
            return
        }
        report(window.isVisible && window.occlusionState.contains(.visible) && !window.isMiniaturized)
    }

    private func report(_ visible: Bool) {
        guard visible != lastReported else { return }
        lastReported = visible
        onChange?(visible)
    }
}
