import Darwin
import Foundation
import MonitorCore

/// Approximate CPU and memory for every process from `/bin/ps`, which can see other
/// users' processes. Only used, for display, while "All processes" is showing.
public final class PSFallbackSource: UsageFallbackSource, @unchecked Sendable {
    public init() {}

    public func read() -> [Int32: ApproxUsage] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,pcpu=,rss="]
        process.environment = ["LC_ALL": "C"]  // "12.5", never "12,5"
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return [:]
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [:] }
        return PSOutputParser.parse(String(decoding: data, as: UTF8.self))
    }
}

/// The private `responsibility_get_pid_responsible_for_pid`, which Activity Monitor uses
/// to show which app an XPC helper works for. It is looked up at run time and simply
/// unavailable if a future macOS removes it. It is only used for grouping rows.
public final class ResponsibilitySPI: ResponsibilitySource, @unchecked Sendable {
    private typealias Lookup = @convention(c) (pid_t) -> pid_t
    private let lookup: Lookup?

    public init() {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        if let symbol = dlsym(defaultHandle, "responsibility_get_pid_responsible_for_pid") {
            lookup = unsafeBitCast(symbol, to: Lookup.self)
        } else {
            lookup = nil
        }
    }

    public var isAvailable: Bool { lookup != nil }

    public func responsiblePID(for pid: Int32) -> Int32? {
        guard let lookup, pid > 0 else { return nil }
        let owner = lookup(pid)
        return owner > 0 ? owner : nil
    }
}

/// Sends signals with kill(2).
public struct POSIXSignaler: Signaler {
    public init() {}

    public func send(_ signal: QuitSignal, to pid: Int32) -> SignalResult {
        // kill(0, …) and kill(-1, …) would hit whole process groups or every process the
        // user owns, and pid 1 is launchd. Never go there, whatever the caller asks.
        guard pid > 1, pid != getpid() else { return .notPermitted }
        let number: Int32
        switch signal {
        case .terminate: number = SIGTERM
        case .kill: number = SIGKILL
        case .resume: number = SIGCONT
        }
        if kill(pid, number) == 0 { return .sent }
        let code = errno
        switch code {
        case ESRCH: return .noSuchProcess
        case EPERM: return .notPermitted
        default: return .failed(code)
        }
    }
}

/// User names for tooltips ("Owned by _windowserver").
public enum UserNames {
    private static let cache = Locked<[UInt32: String]>([:])

    public static func name(for uid: UInt32) -> String? {
        if let cached = cache.withValue({ $0[uid] }) { return cached }
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let capacity = 4096
        var buffer = [CChar](repeating: 0, count: capacity)
        guard getpwuid_r(uid, &entry, &buffer, capacity, &result) == 0, result != nil, let name = entry.pw_name else {
            return nil
        }
        let string = String(cString: name)
        cache.withValue { $0[uid] = string }
        return string
    }
}
