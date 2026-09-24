import AppKit
import MonitorCore
import UniformTypeIdentifiers

/// Running apps from NSWorkspace, read on the main thread.
struct WorkspaceApps: RunningAppsSource {
    func runningApps() async -> [AppInfo] {
        await MainActor.run {
            NSWorkspace.shared.runningApplications.map { app in
                AppInfo(
                    pid: app.processIdentifier,
                    bundleID: app.bundleIdentifier,
                    name: app.localizedName,
                    bundlePath: app.bundleURL?.path,
                    launchDate: app.launchDate,
                    policy: WorkspaceApps.policy(app.activationPolicy))
            }
        }
    }

    static func policy(_ policy: NSApplication.ActivationPolicy) -> AppInfo.Policy {
        switch policy {
        case .regular: return .regular
        case .accessory: return .accessory
        case .prohibited: return .prohibited
        @unknown default: return .prohibited
        }
    }
}

/// Quits apps the way the Dock does, so they can ask to save first.
struct AppKitTerminator: AppTerminator {
    func quitApp(pid: Int32, force: Bool) async -> Bool {
        await MainActor.run {
            guard let app = NSRunningApplication(processIdentifier: pid),
                !app.isTerminated,
                app.activationPolicy != .prohibited
            else { return false }
            return force ? app.forceTerminate() : app.terminate()
        }
    }
}

/// App and file icons, cached by path.
@MainActor
final class IconCache {
    static let shared = IconCache()
    private var icons: [String: NSImage] = [:]

    func icon(for reference: RowIcon) -> NSImage {
        let key: String
        switch reference {
        case .bundle(let path), .executable(let path): key = path
        case .generic: key = ""
        }
        if let icon = icons[key] { return icon }
        let icon: NSImage
        switch reference {
        case .bundle(let path), .executable(let path): icon = NSWorkspace.shared.icon(forFile: path)
        case .generic: icon = NSWorkspace.shared.icon(for: .unixExecutable)
        }
        if icons.count > 2_000 { icons.removeAll() }
        icons[key] = icon
        return icon
    }
}
