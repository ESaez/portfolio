import Testing
@testable import MonitorCore

private let nodePath = "/opt/homebrew/bin/node"
private let chatBundle = "/Applications/Chat.app"
private let chatMain = chatBundle + "/Contents/MacOS/Chat"
private let chatHelperA = chatBundle + "/Contents/Frameworks/Chat Helper.app/Contents/MacOS/Chat Helper"
private let chatHelperB = chatBundle + "/Contents/Frameworks/Chat Helper (GPU).app/Contents/MacOS/Chat Helper (GPU)"
private let chatPrivileged = chatBundle + "/Contents/Library/LaunchServices/com.chat.helper"

private func world(_ extra: [RawProcess], me: SelfIdentity = SelfIdentity(uid: 501, euid: 501, pid: 4242)) -> FakeWorld {
    FakeWorld(me: me, processes: Make.session + extra, apps: [Make.terminalApp])
}

private func coordinator(_ world: FakeWorld) -> QuitCoordinator {
    QuitCoordinator(context: world, processes: world, signaler: world, apps: world, clock: world)
}

private func processRequest(_ process: RawProcess, force: Bool = false, path: String? = nil) -> QuitRequest {
    QuitRequest(
        target: .process(process.key), displayName: "test", force: force,
        expectedPaths: [process.key: path ?? process.path ?? ""], uid: 501, requestedAtMicros: 5_000)
}

/// The Chat app: its main process, two helpers, and a privileged helper running as root.
private func chatWorld() -> (FakeWorld, QuitRequest) {
    let main = Make.process(2000, chatMain)
    let helperA = Make.process(2001, chatHelperA, ppid: 2000)
    let helperB = Make.process(2002, chatHelperB, ppid: 2000)
    let privileged = Make.process(2003, chatPrivileged, uid: 0)
    let fake = world([main, helperA, helperB, privileged])
    fake.makeApp(2000)
    let request = QuitRequest(
        target: .group(.app(bundlePath: "/applications/chat.app", uid: 501)), displayName: "Chat", force: false,
        expectedPaths: [main.key: chatMain, helperA.key: chatHelperA, helperB.key: chatHelperB],
        leaders: [main.key], bundlePath: "/applications/chat.app", uid: 501, requestedAtMicros: 5_000)
    return (fake, request)
}

@Suite("Quitting one process")
struct QuitProcessTests {
    @Test func sendsSIGTERMToAToolAndWaitsForIt() async {
        let node = Make.process(1000, nodePath, ppid: 702)
        let fake = world([node])
        #expect(await coordinator(fake).perform(processRequest(node)) == .exited)
        #expect(fake.signals == [SentSignal(signal: .terminate, pid: 1000)])
        #expect(!fake.isRunning(1000))
    }

    @Test func asksAppsToQuitThroughAppKit() async {
        let app = Make.process(1100, "/Applications/Notes Pro.app/Contents/MacOS/Notes Pro")
        let fake = world([app])
        fake.makeApp(1100)
        #expect(await coordinator(fake).perform(processRequest(app)) == .exited)
        #expect(fake.appQuits == [AppQuitCall(pid: 1100, force: false)])
        #expect(fake.signals.isEmpty)
    }

    @Test func reportsStillRunningThenForceQuits() async {
        let app = Make.process(1100, "/Applications/Notes Pro.app/Contents/MacOS/Notes Pro")
        let fake = world([app])
        fake.makeApp(1100)
        fake.onAppQuit(1100, .ignores)  // it's showing a "Save changes?" sheet
        let quit = coordinator(fake)
        #expect(await quit.perform(processRequest(app)) == .stillRunning)
        #expect(fake.isRunning(1100))
        #expect(await quit.perform(processRequest(app, force: true)) == .exited)
        #expect(fake.appQuits == [AppQuitCall(pid: 1100, force: false), AppQuitCall(pid: 1100, force: true)])
    }

    @Test func aZombieCountsAsExited() async {
        let node = Make.process(1000, nodePath, ppid: 702)
        let fake = world([node])
        fake.onTerminate(1000, .becomesZombie)
        #expect(await coordinator(fake).perform(processRequest(node)) == .exited)
    }

    @Test func aProcessThatVanishesHadAlreadyQuit() async {
        let node = Make.process(1000, nodePath, ppid: 702)
        let fake = world([node])
        fake.onTerminate(1000, .vanishes)
        #expect(await coordinator(fake).perform(processRequest(node)) == .alreadyGone)
    }

    @Test func reportsWhenMacOSRefuses() async {
        let node = Make.process(1000, nodePath, ppid: 702)
        let fake = world([node])
        fake.onTerminate(1000, .refuses)
        #expect(await coordinator(fake).perform(processRequest(node)) == .failed(.notPermitted))
    }

    @Test func aReusedPIDIsNeverSignaled() async {
        let node = Make.process(1000, nodePath, ppid: 702)
        let fake = world([Make.process(1000, nodePath, ppid: 702, start: 4_000)])
        #expect(await coordinator(fake).perform(processRequest(node)) == .alreadyGone)
        #expect(fake.signals.isEmpty)
    }

    @Test func aProcessThatRanExecIsNeverSignaled() async {
        let node = Make.process(1000, nodePath, ppid: 702)
        let fake = world([node])
        let request = processRequest(node, path: "/opt/homebrew/bin/python3")
        #expect(await coordinator(fake).perform(request) == .refused(.changed))
        #expect(fake.signals.isEmpty)
    }

    @Test func protectedProcessesAreRefusedWithoutSignals() async {
        let daemon = Make.process(1200, "/usr/libexec/somedaemon", uid: 0)
        let fake = world([daemon])
        let quit = coordinator(fake)
        let launchd = Make.session[0]
        #expect(await quit.perform(processRequest(launchd)) == .refused(.protected(.launchd)))
        #expect(await quit.perform(processRequest(daemon)) == .refused(.protected(.otherUser)))
        #expect(await quit.perform(processRequest(daemon, force: true)) == .refused(.protected(.otherUser)))
        #expect(fake.signals.isEmpty)
        #expect(fake.appQuits.isEmpty)
    }

    @Test func nothingIsQuitWhileRunningAsRoot() async {
        let node = Make.process(1000, nodePath, ppid: 702)
        let fake = world([node], me: SelfIdentity(uid: 0, euid: 0, pid: 4242))
        #expect(await coordinator(fake).perform(processRequest(node)) == .refused(.protected(.runningAsRoot)))
        #expect(fake.signals.isEmpty)
    }

    @Test func aStoppedProcessIsWokenSoItCanExit() async {
        let node = Make.process(1000, nodePath, ppid: 702, stopped: true)
        let fake = world([node])
        fake.onTerminate(1000, .ignores)
        #expect(await coordinator(fake).perform(processRequest(node)) == .stillRunning)
        #expect(fake.signals == [SentSignal(signal: .terminate, pid: 1000), SentSignal(signal: .resume, pid: 1000)])
    }

    @Test func aStuckProcessFailsToForceQuit() async {
        let node = Make.process(1000, nodePath, ppid: 702)
        let fake = world([node])
        fake.onKill(1000, .ignores)
        #expect(await coordinator(fake).perform(processRequest(node, force: true)) == .failed(.didNotExit))
    }
}

@Suite("Quitting an app")
struct QuitGroupTests {
    @Test func quitsTheAppThenCleansUpItsHelpers() async {
        let (fake, request) = chatWorld()
        fake.exit(2001, afterSeconds: 1)  // exits by itself soon after the app
        fake.onTerminate(2002, .ignores)  // needs SIGKILL
        // A new helper that starts after the click is not part of the request.
        fake.add(Make.process(2004, chatHelperA, start: 9_000))
        fake.onTerminate(2004, .ignores)

        #expect(await coordinator(fake).perform(request) == .exited)
        #expect(fake.appQuits == [AppQuitCall(pid: 2000, force: false)])
        #expect(fake.signals == [SentSignal(signal: .terminate, pid: 2002), SentSignal(signal: .kill, pid: 2002)])
        #expect(fake.isRunning(2003))  // the root helper was never touched
        #expect(fake.isRunning(2004))
    }

    @Test func reportsStillRunningWhenTheAppDoesNotQuit() async {
        let (fake, request) = chatWorld()
        fake.onAppQuit(2000, .ignores)
        #expect(await coordinator(fake).perform(request) == .stillRunning)
        #expect(fake.signals.isEmpty)
    }

    @Test func forceQuitKillsEveryKillableMember() async {
        let (fake, request) = chatWorld()
        fake.onAppQuit(2000, .ignores)
        var force = request
        force.force = true
        #expect(await coordinator(fake).perform(force) == .exited)
        #expect(fake.appQuits == [AppQuitCall(pid: 2000, force: true)])
        #expect(Set(fake.signals.map(\.pid)) == [2001, 2002])
        #expect(fake.signals.allSatisfy { $0.signal == .kill })
        #expect(fake.isRunning(2003))
    }

    @Test func helpersThatSurviveAreReported() async {
        let (fake, request) = chatWorld()
        fake.onTerminate(2001, .ignores)
        fake.onKill(2001, .ignores)
        fake.onTerminate(2002, .ignores)
        fake.onKill(2002, .ignores)
        #expect(await coordinator(fake).perform(request) == .partial(survivors: 2))
    }

    @Test func helpersWithoutTheirAppAreAskedToExit() async {
        let (fake, request) = chatWorld()
        fake.update(2000) { $0.isExiting = true }
        #expect(await coordinator(fake).perform(request) == .exited)
        #expect(Set(fake.signals.map(\.pid)) == [2001, 2002])
    }

    @Test func anAppWhoseMainProcessIsProtectedIsRefused() async {
        let (fake, request) = chatWorld()
        fake.update(2000) { $0.euid = 0; $0.svuid = 0 }
        #expect(await coordinator(fake).perform(request) == .refused(.protected(.elevated)))
        #expect(fake.signals.isEmpty)
        #expect(fake.appQuits.isEmpty)
    }
}

@Suite("Quit requests")
struct QuitRequestTests {
    private func snapshot() -> Snapshot {
        let main = Make.stats(Make.process(10, "/Applications/Alpha.app/Contents/MacOS/Alpha"))
        let helper = Make.stats(Make.process(11, "/Applications/Alpha.app/Contents/Frameworks/H.app/Contents/MacOS/H"))
        let locked = Make.stats(Make.process(12, "/Applications/Alpha.app/Contents/Library/tool", uid: 0), safety: .protected(.otherUser))
        let alpha = ProcessGroup(
            id: .app(bundlePath: "/applications/alpha.app", uid: 501), name: "Alpha", bundlePath: "/Applications/Alpha.app",
            uid: 501, members: [main, helper, locked], leaders: [main.id], quitAbility: .killable)
        let daemon = Make.stats(Make.process(20, "/usr/sbin/daemon", uid: 0), safety: .protected(.otherUser))
        let daemonGroup = ProcessGroup(
            id: .process(daemon.id), name: "daemon", uid: 0, members: [daemon], quitAbility: .protected(.otherUser))
        return Make.snapshot([alpha, daemonGroup])
    }

    @Test func appRequestsCoverOnlyKillableMembers() throws {
        let id = GroupID.app(bundlePath: "/applications/alpha.app", uid: 501)
        let request = try #require(QuitRequest.make(for: .group(id), in: snapshot(), force: false, nowMicros: 99))
        #expect(request.displayName == "Alpha")
        #expect(Set(request.expectedPaths.keys.map(\.pid)) == [10, 11])
        #expect(request.leaders.map(\.pid) == [10])
        #expect(request.bundlePath == "/applications/alpha.app")
        #expect(request.requestedAtMicros == 99)
    }

    @Test func processRequestsCaptureThePath() throws {
        let key = ProcessKey(pid: 11, startMicros: 11)
        let request = try #require(QuitRequest.make(for: .process(key), in: snapshot(), force: true, nowMicros: 1))
        #expect(request.expectedPaths == [key: "/Applications/Alpha.app/Contents/Frameworks/H.app/Contents/MacOS/H"])
        #expect(request.force)
    }

    @Test func protectedTargetsGetNoRequest() {
        let snap = snapshot()
        #expect(QuitRequest.make(for: .process(ProcessKey(pid: 12, startMicros: 12)), in: snap, force: false, nowMicros: 1) == nil)
        #expect(QuitRequest.make(for: .process(ProcessKey(pid: 20, startMicros: 20)), in: snap, force: false, nowMicros: 1) == nil)
        #expect(QuitRequest.make(for: .process(ProcessKey(pid: 99, startMicros: 99)), in: snap, force: false, nowMicros: 1) == nil)
    }

    @Test func outcomesHaveMessages() {
        #expect(QuitOutcome.exited.message(for: "Chat") == "Quit “Chat”.")
        #expect(QuitOutcome.partial(survivors: 1).message(for: "Chat").contains("1 helper process"))
        #expect(QuitOutcome.refused(.protected(.coreService)).isError)
        #expect(!QuitOutcome.stillRunning.isError)
    }
}

@Suite("Respawn watcher")
struct RespawnWatcherTests {
    private func snapshot(start: Int64) -> Snapshot {
        let agent = Make.stats(Make.process(30, "/Users/me/Library/Agent/agent", start: start))
        return Make.snapshot([ProcessGroup(id: .process(agent.id), name: "agent", uid: 501, members: [agent], quitAbility: .killable)])
    }

    @Test func noticesAProcessThatComesBack() {
        var watcher = RespawnWatcher()
        watcher.watch(name: "agent", paths: ["/Users/me/Library/Agent/agent"], quitAtMicros: 1_000)
        #expect(watcher.check(snapshot(start: 500), nowMicros: 2_000).isEmpty)  // the old one, still exiting
        #expect(watcher.check(snapshot(start: 1_500), nowMicros: 2_000) == ["agent"])
        #expect(watcher.check(snapshot(start: 1_500), nowMicros: 3_000).isEmpty)  // reported once
    }

    @Test func forgetsAfterTheWindow() {
        var watcher = RespawnWatcher()
        watcher.watch(name: "agent", paths: ["/Users/me/Library/Agent/agent"], quitAtMicros: 1_000, seconds: 10)
        #expect(watcher.check(snapshot(start: 20_000_000), nowMicros: 20_000_000).isEmpty)
    }
}
