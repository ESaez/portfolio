import Foundation

/// Classifies executable paths. Classification works on a normalized, lowercased
/// copy of the path; the original spelling is kept for display.
public enum PathClassifier {
    /// Locations that belong to macOS itself (normalized form).
    static let appleSystemPrefixes = [
        "/system/",
        "/usr/",
        "/bin/",
        "/sbin/",
        "/library/apple/",
        "/private/var/db/",
        "/private/var/run/com.apple.security.cryptexd/",
    ]

    /// Exceptions inside the Apple locations that belong to the user.
    static let userPrefixesInsideSystem = ["/usr/local/"]

    static let dataVolumePrefix = "/system/volumes/data/"
    static let coreServicesFolder = "/system/library/coreservices/"

    /// Returns a lowercased absolute path without the `/System/Volumes/Data` prefix and
    /// without empty components, or nil when the path is relative or contains `.`/`..`.
    ///
    /// APFS volumes are case-insensitive by default, so lowercasing keeps odd spellings
    /// such as `/SYSTEM/Library` from slipping past the checks.
    public static func normalize(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if components.contains(where: { $0 == "." || $0 == ".." }) { return nil }
        var normalized = ("/" + components.joined(separator: "/")).lowercased()
        if normalized.hasPrefix(dataVolumePrefix) {
            normalized = "/" + normalized.dropFirst(dataVolumePrefix.count)
        }
        return normalized
    }

    /// True for paths inside the parts of the disk that macOS owns.
    public static func isAppleSystemPath(_ normalized: String) -> Bool {
        if userPrefixesInsideSystem.contains(where: { normalized.hasPrefix($0) }) { return false }
        return appleSystemPrefixes.contains(where: { normalized.hasPrefix($0) })
    }

    /// True for anything in `/System/Library/CoreServices` (Finder, Dock, loginwindow,
    /// SystemUIServer, Control Center, …), including the copy inside a cryptex.
    public static func isCoreServices(_ normalized: String) -> Bool {
        isAppleSystemPath(normalized) && normalized.contains(coreServicesFolder)
    }

    /// The `.app` folders in `path` that come before the first `.framework` folder,
    /// outermost first, in their original spelling.
    ///
    /// Stopping at `.framework` keeps interpreters such as Homebrew's
    /// `Python.framework/…/Python.app` from being treated as an app.
    public static func appBundleCandidates(_ path: String) -> [String] {
        var candidates: [String] = []
        var current = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            current += "/" + component
            let lowered = component.lowercased()
            if lowered.hasSuffix(".framework") { break }
            if lowered.hasSuffix(".app") { candidates.append(current) }
        }
        return candidates
    }

    /// True for executables inside an XPC service bundle.
    public static func isXPCService(_ path: String) -> Bool {
        path.lowercased().contains(".xpc/")
    }

    /// The last path component.
    public static func basename(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map { String($0) } ?? path
    }
}
