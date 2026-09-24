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
