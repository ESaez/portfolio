import Foundation
@testable import MonitorCore

/// A value guarded by a lock, for fakes that are shared across tasks.
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

struct SentSignal: Equatable, Sendable {
    var signal: QuitSignal
    var pid: Int32
}

struct AppQuitCall: Equatable, Sendable {
    var pid: Int32
    var force: Bool
}

/// How a fake process reacts to being asked to quit.
enum Reaction: Sendable {
    case exits
    case ignores
    case becomesZombie
    /// The process is gone by the time the signal arrives (ESRCH).
    case vanishes
    /// The kernel refuses the signal (EPERM).
    case refuses
}

/// A scripted process table with a virtual clock. It implements every source the core
/// needs and records every signal and AppKit quit, so tests can check exactly what
/// would have been sent.
final class FakeWorld: ProcessSource, Signaler, AppTerminator, ValidationContextProvider, MonotonicClock,
    RunningAppsSource, @unchecked Sendable
{
    struct State {
        var table: [Int32: RawProcess] = [:]
        var apps: [AppInfo] = []
        var appPIDs: Set<Int32> = []
        var onTerminate: [Int32: Reaction] = [:]
        var onKill: [Int32: Reaction] = [:]
        var onAppQuit: [Int32: Reaction] = [:]
        var scheduledExits: [Int32: UInt64] = [:]
        var now: UInt64 = 1_000_000_000_000
        var signals: [SentSignal] = []
        var appQuits: [AppQuitCall] = []
    }

    let me: SelfIdentity
    private let state: Locked<State>

    init(me: SelfIdentity = SelfIdentity(uid: 501, euid: 501, pid: 4242), processes: [RawProcess], apps: [AppInfo] = []) {
        self.me = me
        var initial = State()
        for process in processes { initial.table[process.pid] = process }
        initial.apps = apps
        state = Locked(initial)
    }

    // MARK: Scripting

    func add(_ process: RawProcess) { state.withValue { $0.table[process.pid] = process } }
    func update(_ pid: Int32, _ change: @escaping (inout RawProcess) -> Void) {
        state.withValue { state in
            if var process = state.table[pid] {
                change(&process)
                state.table[pid] = process
            }
        }
    }
    func makeApp(_ pid: Int32) { state.withValue { _ = $0.appPIDs.insert(pid) } }
    func onTerminate(_ pid: Int32, _ reaction: Reaction) { state.withValue { $0.onTerminate[pid] = reaction } }
    func onKill(_ pid: Int32, _ reaction: Reaction) { state.withValue { $0.onKill[pid] = reaction } }
    func onAppQuit(_ pid: Int32, _ reaction: Reaction) { state.withValue { $0.onAppQuit[pid] = reaction } }
    func exit(_ pid: Int32, afterSeconds seconds: Double) {
        state.withValue { $0.scheduledExits[pid] = $0.now + UInt64(seconds * 1_000_000_000) }
    }
    func advance(seconds: Double) {
        state.withValue { state in
            state.now += UInt64(seconds * 1_000_000_000)
            Self.runScheduledExits(&state)
        }
    }

    var signals: [SentSignal] { state.withValue { $0.signals } }
    var appQuits: [AppQuitCall] { state.withValue { $0.appQuits } }
    func isRunning(_ pid: Int32) -> Bool { state.withValue { $0.table[pid].map { !$0.isExiting } ?? false } }

    // MARK: ProcessSource

    func allProcesses() -> [RawProcess] {
        state.withValue { $0.table.values.sorted { $0.pid < $1.pid } }
    }

    func process(pid: Int32) -> RawProcess? {
        state.withValue { $0.table[pid] }
    }

    // MARK: Signaler

    func send(_ signal: QuitSignal, to pid: Int32) -> SignalResult {
        state.withValue { state in
            state.signals.append(SentSignal(signal: signal, pid: pid))
            guard state.table[pid] != nil else { return .noSuchProcess }
            let reaction: Reaction
            switch signal {
            case .terminate: reaction = state.onTerminate[pid] ?? .exits
            case .kill: reaction = state.onKill[pid] ?? .exits
            case .resume: return .sent
            }
            return Self.apply(reaction, to: pid, in: &state)
        }
    }

    // MARK: AppTerminator

    func quitApp(pid: Int32, force: Bool) async -> Bool {
        state.withValue { state in
            guard state.appPIDs.contains(pid), state.table[pid] != nil else { return false }
            state.appQuits.append(AppQuitCall(pid: pid, force: force))
            let reaction = force ? (state.onKill[pid] ?? .exits) : (state.onAppQuit[pid] ?? .exits)
            _ = Self.apply(reaction, to: pid, in: &state)
            return true
        }
    }

    // MARK: ValidationContextProvider & RunningAppsSource

    func validationContext() async -> ValidationContext {
        state.withValue { state in
            ValidationContext(table: state.table, env: SafetyEnvironment.make(me: me, apps: state.apps, table: state.table))
        }
    }

    func runningApps() async -> [AppInfo] {
        state.withValue { $0.apps }
    }

    // MARK: MonotonicClock

    func nowNs() -> UInt64 { state.withValue { $0.now } }

    func sleep(ns: UInt64) async throws {
        advance(seconds: Double(ns) / 1_000_000_000)
    }

    // MARK: Internals

    private static func apply(_ reaction: Reaction, to pid: Int32, in state: inout State) -> SignalResult {
        switch reaction {
        case .exits:
            state.table[pid] = nil
            return .sent
        case .ignores:
            return .sent
        case .becomesZombie:
            state.table[pid]?.isExiting = true
            return .sent
        case .vanishes:
            state.table[pid] = nil
            return .noSuchProcess
        case .refuses:
            return .notPermitted
        }
    }

    private static func runScheduledExits(_ state: inout State) {
        for (pid, time) in state.scheduledExits where time <= state.now {
            state.table[pid] = nil
            state.scheduledExits[pid] = nil
        }
    }
}

final class FakeSystemStats: SystemStatsSource, @unchecked Sendable {
    let reading: Locked<SystemReading>
    init(_ reading: SystemReading) { self.reading = Locked(reading) }
    func read() -> SystemReading { reading.withValue { $0 } }
}

final class FakeGPU: GPUUsageSource, @unchecked Sendable {
    let reading: Locked<GPUReading>
    init(_ reading: GPUReading = GPUReading()) { self.reading = Locked(reading) }
    func read() -> GPUReading { reading.withValue { $0 } }
}

struct FakeFallback: UsageFallbackSource {
    var values: [Int32: ApproxUsage]
    func read() -> [Int32: ApproxUsage] { values }
}

struct FakeResponsibility: ResponsibilitySource {
    var owners: [Int32: Int32]
    func responsiblePID(for pid: Int32) -> Int32? { owners[pid] }
}

/// Shorthand for building processes and stats in tests.
enum Make {
    static func process(
        _ pid: Int32,
        _ path: String?,
        ppid: Int32 = 1,
        uid: UInt32 = 501,
        euid: UInt32? = nil,
        start: Int64? = nil,
        cpuNs: UInt64? = nil,
        footprint: UInt64? = nil,
        stopped: Bool = false,
        hint: String? = nil
    ) -> RawProcess {
        RawProcess(
            key: ProcessKey(pid: pid, startMicros: start ?? Int64(pid)),
            ppid: ppid,
            euid: euid ?? uid,
            ruid: uid,
            svuid: euid ?? uid,
            comm: path.map { String(PathClassifier.basename($0).prefix(16)) } ?? "?",
            path: path,
            isStopped: stopped,
            cpuTimeNs: cpuNs,
            footprintBytes: footprint,
            interpreterHint: hint)
    }

    static func stats(
        _ raw: RawProcess,
        name: String? = nil,
        safety: Safety = .killable,
        cpu: Double? = nil,
        memory: UInt64? = nil,
        gpu: Double? = nil,
        hasGPU: Bool = false
    ) -> ProcessStats {
        ProcessStats(
            raw: raw,
            name: name ?? raw.path.map(PathClassifier.basename) ?? raw.comm,
            cpuPercent: cpu,
            memoryBytes: memory,
            gpuPercent: gpu,
            hasGPUClient: hasGPU || gpu != nil,
            safety: safety)
    }

    static func snapshot(_ groups: [ProcessGroup], totalMemory: UInt64 = 16 * 1_073_741_824) -> Snapshot {
        Snapshot(
            takenAt: Date(timeIntervalSince1970: 0),
            totals: Totals(
                cpuPercent: 10, memory: MemoryReading(totalBytes: totalMemory, usedBytes: totalMemory / 2, pressure: .normal),
                gpuPercent: 5, logicalCPUs: 8),
            includesProcesses: true,
            groups: groups,
            processCount: groups.reduce(0) { $0 + $1.members.count },
            me: SelfIdentity(uid: 501, euid: 501, pid: 4242))
    }

    /// The parent chain every test world starts with: launchd, Terminal, login, zsh.
    static let session: [RawProcess] = [
        process(1, "/sbin/launchd", ppid: 0, uid: 0),
        process(700, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
        process(701, "/usr/bin/login", ppid: 700, uid: 0),
        process(702, "/bin/zsh", ppid: 701),
    ]

    static let terminalApp = AppInfo(
        pid: 700, bundleID: "com.apple.Terminal", name: "Terminal",
        bundlePath: "/System/Applications/Utilities/Terminal.app", policy: .regular)
}
