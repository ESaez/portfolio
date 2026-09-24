import Darwin
import Foundation
import Testing
@testable import MonitorCore
@testable import MonitorDarwin

/// Records every signal before passing it to the real kill(2).
final class SpySignaler: Signaler, @unchecked Sendable {
    private let real = POSIXSignaler()
    private let log = Locked<[Int32]>([])

    var signaledPIDs: [Int32] { log.withValue { $0 } }

    func send(_ signal: QuitSignal, to pid: Int32) -> SignalResult {
        log.withValue { $0.append(pid) }
        return real.send(signal, to: pid)
    }
}

struct NoAppKit: AppTerminator {
    func quitApp(pid: Int32, force: Bool) async -> Bool { false }
}

/// The live process table with a fixed policy environment.
struct LiveContext: ValidationContextProvider {
    let source: KinfoProcessSource
    let env: SafetyEnvironment

    func validationContext() async -> ValidationContext {
        var table: [Int32: RawProcess] = [:]
        for process in source.allProcesses() { table[process.pid] = process }
        return ValidationContext(table: table, env: env)
    }
}

/// Copies /bin/sleep into a temporary folder and starts it, so the test has a process
/// of its own with a unique path.
final class Sleeper {
    let directory: URL
    let process = Process()

    init(seconds: Int = 300) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent("pm-sleeper")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: binary)
        process.executableURL = binary
        process.arguments = [String(seconds)]
        try process.run()
    }

    var pid: Int32 { process.processIdentifier }

    deinit {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: directory)
    }
}

private func coordinator(source: KinfoProcessSource, signaler: any Signaler, env: SafetyEnvironment) -> QuitCoordinator {
    QuitCoordinator(
        context: LiveContext(source: source, env: env), processes: source, signaler: signaler, apps: NoAppKit(),
        clock: MachTime())
}

/// The test runner stands in for Terminal: a regular app that started the child.
private func environmentTreatingTheTestRunnerAsAnApp() -> SafetyEnvironment {
    SafetyEnvironment(me: SelfIdentity(uid: getuid(), euid: geteuid(), pid: Int32.max), regularAppPIDs: [getpid()])
}

private func nowMicros() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000_000) }

@Suite("macOS integration", .serialized)
struct DarwinIntegrationTests {
    @Test func currentUIDMatchesGetuid() {
        #expect(MonitorDarwin.currentUID() == getuid())
        let me = MonitorDarwin.selfIdentity()
        #expect(me.pid == getpid())
        #expect(!me.isTranslated)
    }

    @Test func listsOurOwnProcessWithCounters() throws {
        let processes = KinfoProcessSource().allProcesses()
        #expect(processes.count > 20)
        let me = try #require(processes.first { $0.pid == getpid() })
        #expect(me.ruid == getuid())
        #expect(me.path != nil)
        #expect((me.cpuTimeNs ?? 0) > 0)
        #expect((me.footprintBytes ?? 0) > 1_000_000)
    }

    @Test func seesLaunchdButNotItsCounters() throws {
        let launchd = try #require(KinfoProcessSource().process(pid: 1))
        #expect(launchd.euid == 0)
        #expect(launchd.cpuTimeNs == nil)
        #expect(launchd.footprintBytes == nil)
    }

    @Test func machTimeConvertsTicks() {
        let time = MachTime()
        #expect(time.nanoseconds(fromTicks: time.denom) == time.numer)
        let before = time.nowNs()
        #expect(time.nowNs() >= before)
    }

    @Test func readsTheArgumentsOfItsOwnChild() throws {
        let sleeper = try Sleeper(seconds: 123)
        let arguments = try #require(KinfoProcessSource.arguments(pid: sleeper.pid))
        #expect(arguments.last == "123")
    }

    @Test func quitsItsOwnChild() async throws {
        let sleeper = try Sleeper()
        let source = KinfoProcessSource()
        let listed = try #require(source.process(pid: sleeper.pid))
        #expect(listed.path?.hasSuffix("/pm-sleeper") == true)
        #expect(listed.ruid == getuid())
        #expect(listed.ppid == getpid())

        let path = try #require(listed.path)
        let quit = coordinator(source: source, signaler: POSIXSignaler(), env: environmentTreatingTheTestRunnerAsAnApp())
        let request = QuitRequest(
            target: .process(listed.key), displayName: "sleeper", force: false,
            expectedPaths: [listed.key: path], uid: getuid(), requestedAtMicros: nowMicros())
        #expect(await quit.perform(request) == .exited)
        sleeper.process.waitUntilExit()
        #expect(sleeper.process.terminationReason == .uncaughtSignal)
        #expect(await quit.perform(request) == .alreadyGone)
    }

    @Test func refusesAWrongStartTime() async throws {
        let sleeper = try Sleeper()
        let source = KinfoProcessSource()
        let listed = try #require(source.process(pid: sleeper.pid))
        let spy = SpySignaler()
        let quit = coordinator(source: source, signaler: spy, env: environmentTreatingTheTestRunnerAsAnApp())
        let path = try #require(listed.path)
        let stale = ProcessKey(pid: listed.pid, startMicros: listed.key.startMicros - 5_000_000)
        let request = QuitRequest(
            target: .process(stale), displayName: "sleeper", force: true,
            expectedPaths: [stale: path], uid: getuid(), requestedAtMicros: nowMicros())
        #expect(await quit.perform(request) == .alreadyGone)
        #expect(spy.signaledPIDs.isEmpty)
        #expect(sleeper.process.isRunning)
    }

    @Test func neverSignalsLaunchdOrRootProcesses() async throws {
        let source = KinfoProcessSource()
        let launchd = try #require(source.process(pid: 1))
        let rootProcess = try #require(source.allProcesses().first { $0.euid == 0 && $0.pid > 1 && $0.path != nil })
        let spy = SpySignaler()
        let env = SafetyEnvironment(me: MonitorDarwin.selfIdentity())
        let quit = coordinator(source: source, signaler: spy, env: env)
        for target in [launchd, rootProcess] {
            for force in [false, true] {
                let request = QuitRequest(
                    target: .process(target.key), displayName: target.comm, force: force,
                    expectedPaths: [target.key: target.path ?? "/"], uid: 0, requestedAtMicros: nowMicros())
                let outcome = await quit.perform(request)
                #expect(outcome != .exited, "\(target.comm)")
                if case .refused = outcome {} else { Issue.record("\(target.comm) was not refused: \(outcome)") }
            }
        }
        #expect(spy.signaledPIDs.isEmpty)
    }

    @Test func signalerRefusesDangerousPIDs() {
        let signaler = POSIXSignaler()
        #expect(signaler.send(.kill, to: 0) == .notPermitted)
        #expect(signaler.send(.kill, to: -1) == .notPermitted)
        #expect(signaler.send(.terminate, to: 1) == .notPermitted)
        #expect(signaler.send(.kill, to: getpid()) == .notPermitted)
    }

    @Test func measuresTheCPUOfABusyProcess() async throws {
        let busy = Process()
        busy.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        busy.standardOutput = FileHandle.nullDevice
        try busy.run()
        defer { busy.terminate() }

        let source = KinfoProcessSource()
        let clock = MachTime()
        var tracker = DeltaTracker()
        _ = tracker.cpuPercents(source.allProcesses(), nowNs: clock.nowNs(), maxPercent: 10_000)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let rates = tracker.cpuPercents(source.allProcesses(), nowNs: clock.nowNs(), maxPercent: 10_000)
        let key = try #require(source.process(pid: busy.processIdentifier)?.key)
        let rate = try #require(rates[key])
        #expect(rate > 40 && rate < 130, "yes used \(rate)%")
    }

    @Test func readsMachineTotals() throws {
        let reading = HostStatsSource().read()
        #expect(reading.logicalCPUs >= 1)
        #expect(reading.cpu != nil)
        let memory = try #require(reading.memory)
        #expect(memory.totalBytes > 1 << 30)
        #expect(memory.usedBytes > 0 && memory.usedBytes <= memory.totalBytes)
        #expect(memory.pressure != .unknown)
    }

    @Test func psSeesOtherUsersProcesses() {
        let usage = PSFallbackSource().read()
        #expect(usage[1] != nil)
        #expect(usage.count > 20)
    }

    @Test func gpuReadingIsWellFormed() {
        // CI machines are virtual and may have no GPU clients at all.
        let reading = IOKitGPUSource().read()
        for client in reading.clients { #expect(client.pid >= 0) }
        if let utilization = reading.deviceUtilization { #expect(utilization >= 0 && utilization <= 100) }
        print("GPU clients: \(reading.clients.count), utilization: \(String(describing: reading.deviceUtilization))")
    }

    @Test func responsibilityLookupAnswersForOurselves() {
        let lookup = ResponsibilitySPI()
        print("responsibility SPI available: \(lookup.isAvailable)")
        if lookup.isAvailable { #expect(lookup.responsiblePID(for: getpid()) != nil) }
        #expect(lookup.responsiblePID(for: -1) == nil)
    }

    @Test func codeSigningCheckAnswersForAChild() throws {
        let sleeper = try Sleeper()
        let key = try #require(KinfoProcessSource().process(pid: sleeper.pid)?.key)
        let isPlatform = CodeSigningInspector().isPlatform(key: key, path: "/bin/sleep")
        print("copied /bin/sleep platform-signed: \(String(describing: isPlatform))")
        #expect(isPlatform != nil)
    }

    @Test func userNamesResolve() {
        #expect(UserNames.name(for: 0) == "root")
        #expect(UserNames.name(for: getuid()) != nil)
    }
}
