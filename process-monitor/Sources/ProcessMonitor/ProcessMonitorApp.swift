import AppKit
import MonitorCore
import SwiftUI

@main
struct ProcessMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Process Monitor", id: "main") {
            Text("Process Monitor \(MonitorCore.version)")
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when running the bare executable (`swift run`): without a bundle the
        // app would otherwise get no Dock icon and keystrokes would go to Terminal.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}
