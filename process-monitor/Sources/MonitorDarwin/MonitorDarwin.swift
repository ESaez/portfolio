import Darwin
import Foundation
import MonitorCore

/// macOS implementations of the MonitorCore sources (sysctl, libproc, IOKit, Security).
public enum MonitorDarwin {
    /// The real user ID of this process.
    public static func currentUID() -> UInt32 { getuid() }

    /// Who Process Monitor is running as, and whether it runs under Rosetta.
    public static func selfIdentity() -> SelfIdentity {
        SelfIdentity(uid: getuid(), euid: geteuid(), pid: getpid(), isTranslated: isTranslated())
    }

    static func isTranslated() -> Bool {
        sysctlInt32("sysctl.proc_translated") == 1
    }

    static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

/// A value guarded by a lock.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// Converts Mach absolute-time ticks to nanoseconds, and is the app's monotonic clock.
public struct MachTime: MonotonicClock {
    public let numer: UInt64
    public let denom: UInt64

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        numer = UInt64(max(info.numer, 1))
        denom = UInt64(max(info.denom, 1))
    }

    /// Ticks are nanoseconds on Intel and 125/3 of them on Apple Silicon. The split
    /// keeps the multiplication from overflowing.
    public func nanoseconds(fromTicks ticks: UInt64) -> UInt64 {
        if numer == denom { return ticks }
        return (ticks / denom) &* numer &+ (ticks % denom) &* numer / denom
    }

    /// Time since boot, not counting sleep, like the CPU counters it is compared with.
    public func nowNs() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    public func sleep(ns: UInt64) async throws {
        try await Task.sleep(nanoseconds: ns)
    }
}
