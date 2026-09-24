import AppKit
import MonitorCore
import SwiftUI

@main
struct ProcessMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = MonitorStore.shared
    @AppStorage(AppSettings.Key.showMenuBarIcon) private var showMenuBarIcon = true

    var body: some Scene {
        Window("Process Monitor", id: MainWindow.id) {
            MainWindow()
                .environment(store)
        }
        .defaultSize(width: 780, height: 620)
        .commands { ProcessCommands(store: store) }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarContent()
                .environment(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier == nil {
            // Running the bare executable (`swift run`): without this there is no Dock
            // icon and keystrokes keep going to Terminal.
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
        MonitorStore.shared.start()

        // Test hook used by CI to look at the real window: save an image of it.
        if let path = ProcessInfo.processInfo.environment["PROCESS_MONITOR_SNAPSHOT"] {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(7))
                Self.snapshotMainWindow(to: URL(fileURLWithPath: path))
            }
        }
    }

    /// Draws the main window (title bar and toolbar included) into a PNG. An app may
    /// always capture its own windows, so this needs no screen-recording permission.
    static func snapshotMainWindow(to url: URL) {
        let window =
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(MainWindow.id) == true && $0.isVisible }
            ?? NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) }
        guard let content = window?.contentView else { return }
        let view = content.superview ?? content
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Keep running in the menu bar after the window closes, unless the icon is off.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppSettings.load().showMenuBarIcon
    }
}

struct ProcessCommands: Commands {
    let store: MonitorStore

    var body: some Commands {
        CommandMenu("Process") {
            Button("Quit Process") { store.quitSelected(force: false) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(store.selectedQuitTarget == nil)
            Button("Force Quit Process…") { store.quitSelected(force: true) }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .disabled(store.selectedQuitTarget == nil)
            Divider()
            Button("Refresh Now") { store.refreshNow() }
                .keyboardShortcut("r", modifiers: .command)
        }
        CommandGroup(after: .toolbar) {
            Button("CPU") { store.options.metric = .cpu }
                .keyboardShortcut("1", modifiers: .command)
            Button("Memory") { store.options.metric = .memory }
                .keyboardShortcut("2", modifiers: .command)
            Button("GPU") { store.options.metric = .gpu }
                .keyboardShortcut("3", modifiers: .command)
            Divider()
        }
    }
}
