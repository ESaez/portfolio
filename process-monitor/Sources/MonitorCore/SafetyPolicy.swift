import Foundation

/// Names and bundle IDs of macOS components that must never be quit, even though they
/// run as the logged-in user. Compared lowercased.
public enum CriticalLists {
    public static let names: Set<String> = [
        "loginwindow",  // quitting it logs you out immediately
        "dock",
        "finder",
        "systemuiserver",
        "controlcenter",
        "notificationcenter",
        "windowmanager",
        "spotlight",
        "windowserver",
        "cfprefsd",
        "distnoted",
        "usereventagent",
        "lsd",
        "pboard",
        "secd",
        "trustd",
        "usernoted",
        "talagent",
        "launchd",
        "kernel_task",
    ]

    public static let bundleIDs: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.dock",
        "com.apple.finder",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.windowmanager",
        "com.apple.spotlight",
        "com.apple.migrationassistant",
        "com.apple.installer",
    ]
}

/// What the safety policy needs to know besides the process itself.
public struct SafetyEnvironment: Sendable {
    public var me: SelfIdentity
    /// Pids of running Dock apps whose NSWorkspace entry matches the live process.
    public var regularAppPIDs: Set<Int32>
    /// Bundle IDs of running apps, by pid.
    public var bundleIDByPID: [Int32: String]
    public var criticalNames: Set<String> = CriticalLists.names
    public var criticalBundleIDs: Set<String> = CriticalLists.bundleIDs
    /// How far up the parent chain to look for something the user launched.
    public var maxAncestorDepth = 16

    public init(me: SelfIdentity, regularAppPIDs: Set<Int32> = [], bundleIDByPID: [Int32: String] = [:]) {
        self.me = me
        self.regularAppPIDs = regularAppPIDs
        self.bundleIDByPID = bundleIDByPID
    }

    /// NSWorkspace entries are ignored unless the app's launch date is within this many
    /// seconds of the process start, which guards against a stale entry whose pid has
    /// since been reused.
    public static let launchDateTolerance: TimeInterval = 10

    /// Builds the environment from NSWorkspace's app list, keeping only entries that
    /// still match a live process.
    public static func make(me: SelfIdentity, apps: [AppInfo], table: [Int32: RawProcess]) -> SafetyEnvironment {
        var regular = Set<Int32>()
        var bundleIDs: [Int32: String] = [:]
        for app in apps {
            guard let process = table[app.pid], matches(app, process) else { continue }
            if let bundleID = app.bundleID { bundleIDs[app.pid] = bundleID }
            if app.policy == .regular { regular.insert(app.pid) }
        }
        return SafetyEnvironment(me: me, regularAppPIDs: regular, bundleIDByPID: bundleIDs)
    }

    static func matches(_ app: AppInfo, _ process: RawProcess) -> Bool {
        guard let launchDate = app.launchDate else { return true }
        let start = Double(process.key.startMicros) / 1_000_000
        return abs(launchDate.timeIntervalSince1970 - start) <= launchDateTolerance
    }
}

/// Decides which processes the user may quit.
///
/// The rules deny by default and the first match wins:
///
/// - R0: Process Monitor itself runs as root or elevated → everything is protected.
/// - R1: pid 0 (`kernel_task`) and pid 1 (`launchd`) are protected.
/// - R2: Process Monitor itself is protected.
/// - R3: exiting processes are protected.
/// - R4: effective, real and saved user IDs must all be the user's.
/// - R5: the executable path must be readable.
/// - R6: `/System/Library/CoreServices` and the critical name/bundle ID lists are protected.
/// - R7: macOS code (a system path, or a platform code signature) is only killable when it
///   is a regular Dock app, or when something the user launched started it.
/// - R8: everything else the user owns is killable.
public enum SafetyPolicy {
    public static func evaluate(_ process: RawProcess, table: [Int32: RawProcess], env: SafetyEnvironment) -> Safety {
        if env.me.uid == 0 || env.me.euid != env.me.uid { return .protected(.runningAsRoot) }
        if process.pid == 0 { return .protected(.kernel) }
        if process.pid == 1 { return .protected(.launchd) }
        if process.pid == env.me.pid { return .protected(.thisApp) }
        if process.isExiting { return .protected(.notRunning) }
        if let reason = ownershipProblem(process, env: env) { return .protected(reason) }
        guard let rawPath = process.path, let path = PathClassifier.normalize(rawPath) else {
            return .protected(.unknownPath)
        }
        if isCritical(process, normalizedPath: path, env: env) { return .protected(.coreService) }
        if isAppleOSCode(process, normalizedPath: path) {
            if env.regularAppPIDs.contains(process.pid) { return .killable }
            if hasUserLaunchedAncestor(process, table: table, env: env) { return .killable }
            return .protected(.systemProcess)
        }
        return .killable
    }

    /// R4. The kernel lets a user signal a process whose real or saved user ID matches
    /// theirs, which would include a `sudo` they started, so all three IDs must match.
    static func ownershipProblem(_ process: RawProcess, env: SafetyEnvironment) -> ProtectionReason? {
        let uid = env.me.uid
        if process.euid == uid && process.ruid == uid && process.svuid == uid { return nil }
        return process.ruid == uid ? .elevated : .otherUser
    }

    /// R6.
    static func isCritical(_ process: RawProcess, normalizedPath: String, env: SafetyEnvironment) -> Bool {
        if PathClassifier.isCoreServices(normalizedPath) { return true }
        if env.criticalNames.contains(PathClassifier.basename(normalizedPath)) { return true }
        if env.criticalNames.contains(process.comm.lowercased()) { return true }
        if let bundleID = env.bundleIDByPID[process.pid], env.criticalBundleIDs.contains(bundleID.lowercased()) {
            return true
        }
        return false
    }

    /// R7: a system location, or a code signature that says "ships with macOS".
    static func isAppleOSCode(_ process: RawProcess, normalizedPath: String) -> Bool {
        PathClassifier.isAppleSystemPath(normalizedPath) || process.isPlatformSigned == true
    }

    /// Walks the parent chain looking for something the user launched: a regular app
    /// (Terminal, VS Code, …) or a program that isn't part of macOS (tmux, node, …).
    ///
    /// Ancestors owned by someone else (`login`, `sshd`) and Process Monitor itself are
    /// skipped. The walk gives up at launchd, at a missing parent, at a critical macOS
    /// component such as Finder, or at a parent that started after its child, which
    /// means the parent pid was reused.
    static func hasUserLaunchedAncestor(_ process: RawProcess, table: [Int32: RawProcess], env: SafetyEnvironment) -> Bool {
        var visited: Set<Int32> = [process.pid]
        var child = process
        for _ in 0..<env.maxAncestorDepth {
            let parentPID = child.ppid
            guard parentPID > 1, !visited.contains(parentPID), let parent = table[parentPID] else { return false }
            guard parent.key.startMicros <= child.key.startMicros else { return false }
            visited.insert(parentPID)
            child = parent

            if parent.pid == env.me.pid || parent.isExiting { continue }
            if ownershipProblem(parent, env: env) != nil { continue }
            guard let rawPath = parent.path, let path = PathClassifier.normalize(rawPath) else { continue }
            if isCritical(parent, normalizedPath: path, env: env) { return false }
            if env.regularAppPIDs.contains(parent.pid) { return true }
            if !isAppleOSCode(parent, normalizedPath: path) { return true }
        }
        return false
    }
}
