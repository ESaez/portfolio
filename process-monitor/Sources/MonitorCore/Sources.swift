/// Reads the process table.
public protocol ProcessSource: Sendable {
    /// Every process. CPU time, footprint, the platform flag and the interpreter hint are
    /// only filled in for the user's own processes.
    func allProcesses() -> [RawProcess]
    /// A fresh read of one process, or nil when no process has this pid.
    func process(pid: Int32) -> RawProcess?
}

/// Reads per-client GPU time and whole-GPU utilization.
public protocol GPUUsageSource: Sendable {
    func read() -> GPUReading
}

/// Reads machine-wide CPU ticks and memory.
public protocol SystemStatsSource: Sendable {
    func read() -> SystemReading
}

/// Approximate CPU and memory for processes the app can't measure directly.
public protocol UsageFallbackSource: Sendable {
    func read() -> [Int32: ApproxUsage]
}

/// Finds the app responsible for a helper process (an XPC service, for example).
public protocol ResponsibilitySource: Sendable {
    func responsiblePID(for pid: Int32) -> Int32?
}

/// Lists running apps (NSWorkspace).
public protocol RunningAppsSource: Sendable {
    func runningApps() async -> [AppInfo]
}

public enum QuitSignal: Sendable, Equatable {
    /// SIGTERM: please exit.
    case terminate
    /// SIGKILL: exit now.
    case kill
    /// SIGCONT: wake a stopped process so it can handle SIGTERM.
    case resume
}

public enum SignalResult: Sendable, Equatable {
    case sent
    /// ESRCH
    case noSuchProcess
    /// EPERM
    case notPermitted
    case failed(Int32)
}

/// Sends signals (kill(2)).
public protocol Signaler: Sendable {
    func send(_ signal: QuitSignal, to pid: Int32) -> SignalResult
}

/// Quits apps the way the Dock does (NSRunningApplication).
public protocol AppTerminator: Sendable {
    /// Asks the app with this pid to quit, or force quits it. Returns false when the pid
    /// isn't an app that can be asked, so the caller falls back to a signal.
    func quitApp(pid: Int32, force: Bool) async -> Bool
}

/// A monotonic clock that tests can replace.
public protocol MonotonicClock: Sendable {
    func nowNs() -> UInt64
    func sleep(ns: UInt64) async throws
}

/// A fresh process table and policy environment, read right before quitting something.
public struct ValidationContext: Sendable {
    public var table: [Int32: RawProcess]
    public var env: SafetyEnvironment

    public init(table: [Int32: RawProcess], env: SafetyEnvironment) {
        self.table = table
        self.env = env
    }
}

public protocol ValidationContextProvider: Sendable {
    func validationContext() async -> ValidationContext
}
