import Foundation

/// User preferences, stored in UserDefaults. (`@AppStorage` can't live inside an
/// `@Observable` class, so the store keeps this struct and saves it on every change.)
struct AppSettings: Equatable {
    var refreshInterval: Double = 2
    var askBeforeQuitting = true
    var showMenuBarIcon = true
    var showCPUInMenuBar = false

    enum Key {
        static let refreshInterval = "refreshInterval"
        static let askBeforeQuitting = "askBeforeQuitting"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let showCPUInMenuBar = "showCPUInMenuBar"
    }

    static let intervals: [Double] = [1, 2, 5]

    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        var settings = AppSettings()
        if let interval = defaults.object(forKey: Key.refreshInterval) as? Double, intervals.contains(interval) {
            settings.refreshInterval = interval
        }
        if let ask = defaults.object(forKey: Key.askBeforeQuitting) as? Bool { settings.askBeforeQuitting = ask }
        if let show = defaults.object(forKey: Key.showMenuBarIcon) as? Bool { settings.showMenuBarIcon = show }
        if let cpu = defaults.object(forKey: Key.showCPUInMenuBar) as? Bool { settings.showCPUInMenuBar = cpu }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(refreshInterval, forKey: Key.refreshInterval)
        defaults.set(askBeforeQuitting, forKey: Key.askBeforeQuitting)
        defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon)
        defaults.set(showCPUInMenuBar, forKey: Key.showCPUInMenuBar)
    }
}
