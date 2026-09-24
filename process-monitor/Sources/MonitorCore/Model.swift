import Foundation

/// Identifies one run of a process.
///
/// A pid alone is not enough because pids are reused (they wrap at 99,999), but a pid
/// together with the process start time is unique. The key survives `exec`, which keeps
/// both, so anything that acts on a process must also re-check its path.
public struct ProcessKey: Hashable, Sendable, CustomStringConvertible {
    public let pid: Int32
    /// Start time in microseconds since 1970 (`p_starttime`).
    public let startMicros: Int64

    public init(pid: Int32, startMicros: Int64) {
        self.pid = pid
        self.startMicros = startMicros
    }

    public var description: String { "\(pid)@\(startMicros)" }
}

/// Everything the process source read about one process in one sample.
public struct RawProcess: Sendable, Equatable {
    public var key: ProcessKey
    public var ppid: Int32
    public var euid: UInt32
    public var ruid: UInt32
    public var svuid: UInt32
    /// Short kernel name (`p_comm`, at most 16 characters).
    public var comm: String
    /// Executable path, or nil when macOS didn't return one.
    public var path: String?
    /// The process is exiting or is a zombie.
    public var isExiting: Bool
    /// The process is stopped (for example with Ctrl-Z).
    public var isStopped: Bool
    /// Total CPU time in nanoseconds. Only readable for the user's own processes.
    public var cpuTimeNs: UInt64?
    /// Physical footprint in bytes (Activity Monitor's "Memory"). Own processes only.
    public var footprintBytes: UInt64?
    /// Whether the code signature marks this as part of macOS; nil when not checked.
    public var isPlatformSigned: Bool?
    /// Short hint such as "vite" for `node …/vite`. Own processes only.
    public var interpreterHint: String?

    public init(
        key: ProcessKey,
        ppid: Int32,
        euid: UInt32,
        ruid: UInt32,
        svuid: UInt32,
        comm: String,
        path: String?,
        isExiting: Bool = false,
        isStopped: Bool = false,
        cpuTimeNs: UInt64? = nil,
        footprintBytes: UInt64? = nil,
        isPlatformSigned: Bool? = nil,
        interpreterHint: String? = nil
    ) {
        self.key = key
        self.ppid = ppid
        self.euid = euid
        self.ruid = ruid
        self.svuid = svuid
        self.comm = comm
        self.path = path
        self.isExiting = isExiting
        self.isStopped = isStopped
        self.cpuTimeNs = cpuTimeNs
        self.footprintBytes = footprintBytes
        self.isPlatformSigned = isPlatformSigned
        self.interpreterHint = interpreterHint
    }

    public var pid: Int32 { key.pid }
}

/// A running app as NSWorkspace reports it.
public struct AppInfo: Sendable, Equatable {
    public enum Policy: Sendable, Equatable {
        /// Has a Dock icon and a user interface.
        case regular
        /// Menu bar utilities and UI agents: no Dock icon, but may show windows.
        case accessory
        /// Background only.
        case prohibited
    }

    public var pid: Int32
    public var bundleID: String?
    public var name: String?
    public var bundlePath: String?
    public var launchDate: Date?
    public var policy: Policy

    public init(
        pid: Int32,
        bundleID: String? = nil,
        name: String? = nil,
        bundlePath: String? = nil,
        launchDate: Date? = nil,
        policy: Policy
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.bundlePath = bundlePath
        self.launchDate = launchDate
        self.policy = policy
    }
}

/// Who Process Monitor itself is running as.
public struct SelfIdentity: Sendable, Equatable {
    /// Real user ID.
    public var uid: UInt32
    /// Effective user ID.
    public var euid: UInt32
    public var pid: Int32
    /// Running under Rosetta, where CPU times can't be converted reliably.
    public var isTranslated: Bool

    public init(uid: UInt32, euid: UInt32, pid: Int32, isTranslated: Bool = false) {
        self.uid = uid
        self.euid = euid
        self.pid = pid
        self.isTranslated = isTranslated
    }
}

/// Why a process can't be quit from the app.
public enum ProtectionReason: String, Sendable, Equatable, CaseIterable {
    case runningAsRoot
    case kernel
    case launchd
    case thisApp
    case notRunning
    case otherUser
    case elevated
    case unknownPath
    case coreService
    case systemProcess

    /// Short label shown next to the lock.
    public var label: String {
        switch self {
        case .runningAsRoot: "Quitting disabled"
        case .kernel, .launchd, .coreService, .systemProcess: "macOS system"
        case .thisApp: "This app"
        case .notRunning: "Exiting"
        case .otherUser: "Other user"
        case .elevated: "Admin rights"
        case .unknownPath: "Unknown program"
        }
    }

    /// Longer explanation shown as a tooltip.
    public var explanation: String {
        switch self {
        case .runningAsRoot:
            "Process Monitor is running with administrator rights, so quitting is turned off to keep your Mac safe."
        case .kernel:
            "The macOS kernel."
        case .launchd:
            "launchd starts and manages every other process on your Mac."
        case .thisApp:
            "This is Process Monitor itself. Use Quit in its menu instead."
        case .notRunning:
            "This process is already exiting."
        case .otherUser:
            "Owned by macOS or another user, so it can't be quit from here."
        case .elevated:
            "Running with administrator rights, so it can't be quit from here."
        case .unknownPath:
            "macOS didn't say which program this is, so it is left alone."
        case .coreService:
            "A core part of macOS, such as the Dock, Finder or the login window."
        case .systemProcess:
            "Part of macOS and started by the system, so it is left alone."
        }
    }
}

/// The safety policy's verdict for one process.
public enum Safety: Sendable, Equatable {
    case killable
    case protected(ProtectionReason)

    public var isKillable: Bool {
        if case .killable = self { return true }
        return false
    }

    public var protectionReason: ProtectionReason? {
        if case .protected(let reason) = self { return reason }
        return nil
    }
}
