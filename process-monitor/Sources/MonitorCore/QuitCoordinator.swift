import Foundation

/// A quit the user asked for, with everything the row showed when they clicked.
public struct QuitRequest: Sendable, Equatable {
    public var target: QuitTarget
    public var displayName: String
    public var force: Bool
    /// Path of every killable process the request covers, as seen at click time.
    /// A process whose path changed since then (it ran `exec`) is left alone.
    public var expectedPaths: [ProcessKey: String]
    /// For apps: the main processes, which are asked to quit first.
    public var leaders: [ProcessKey]
    /// For apps: normalized bundle path, used to find helpers that outlive the app.
    public var bundlePath: String?
    public var uid: UInt32
    /// Helpers started after this moment are not part of the request.
    public var requestedAtMicros: Int64

    public init(
        target: QuitTarget,
        displayName: String,
        force: Bool,
        expectedPaths: [ProcessKey: String],
        leaders: [ProcessKey] = [],
        bundlePath: String? = nil,
        uid: UInt32,
        requestedAtMicros: Int64
    ) {
        self.target = target
        self.displayName = displayName
        self.force = force
        self.expectedPaths = expectedPaths
        self.leaders = leaders
        self.bundlePath = bundlePath
        self.uid = uid
        self.requestedAtMicros = requestedAtMicros
    }

    /// Builds the request for a row, or nil when the target isn't in the snapshot or
    /// has nothing that may be quit.
    public static func make(for target: QuitTarget, in snapshot: Snapshot, force: Bool, nowMicros: Int64) -> QuitRequest? {
        switch target {
        case .process(let key):
            for group in snapshot.groups {
                guard let member = group.members.first(where: { $0.id == key }) else { continue }
                guard member.safety.isKillable, let path = member.raw.path else { return nil }
                return QuitRequest(
                    target: target, displayName: member.name, force: force, expectedPaths: [key: path],
                    uid: member.raw.ruid, requestedAtMicros: nowMicros)
            }
            return nil

        case .group(let id):
            guard let group = snapshot.groups.first(where: { $0.id == id }), group.quitAbility.isKillable else { return nil }
            var paths: [ProcessKey: String] = [:]
            for member in group.members where member.safety.isKillable {
                if let path = member.raw.path { paths[member.id] = path }
            }
            guard !paths.isEmpty else { return nil }
            var bundlePath: String?
            if case .app(let normalizedBundle, _) = id { bundlePath = normalizedBundle }
            return QuitRequest(
                target: target, displayName: group.name, force: force, expectedPaths: paths,
                leaders: group.leaders.filter { paths[$0] != nil }, bundlePath: bundlePath, uid: group.uid,
                requestedAtMicros: nowMicros)
        }
    }
}

public enum QuitRefusal: Sendable, Equatable {
    /// The process now runs a different program, or is someone else's.
    case changed
    case protected(ProtectionReason)
}

public enum QuitFailure: Sendable, Equatable {
    case notPermitted
    case didNotExit
    case signalError(Int32)
}

public enum QuitOutcome: Sendable, Equatable {
    case exited
    case alreadyGone
    /// A graceful quit didn't finish in time; the app may be asking to save.
    case stillRunning
    /// The app quit but some helpers couldn't be closed.
    case partial(survivors: Int)
    case refused(QuitRefusal)
    case failed(QuitFailure)

    /// Toast text for the outcome.
    public func message(for name: String) -> String {
        switch self {
        case .exited:
            "Quit “\(name)”."
        case .alreadyGone:
            "“\(name)” had already quit."
        case .stillRunning:
            "“\(name)” is still running. It may be asking to save changes."
        case .partial(let survivors):
            "Quit “\(name)”, but \(survivors == 1 ? "1 helper process" : "\(survivors) helper processes") couldn't be closed."
        case .refused(.changed):
            "“\(name)” changed or ended, so nothing was quit."
        case .refused(.protected(let reason)):
            "“\(name)” is protected. \(reason.explanation)"
        case .failed(.notPermitted):
            "macOS didn't allow quitting “\(name)”."
        case .failed(.didNotExit):
            "“\(name)” didn't respond. It may be stuck waiting for a disk or the network."
        case .failed(.signalError(let code)):
            "Couldn't quit “\(name)” (error \(code))."
        }
    }

    public var isError: Bool {
        switch self {
        case .exited, .alreadyGone, .stillRunning: false
        case .partial, .refused, .failed: true
        }
    }
}

public struct QuitTiming: Sendable, Equatable {
    /// How long a graceful quit may take before the row offers Force Quit.
    public var graceful: Double = 5
    public var force: Double = 3
    /// How long helpers get to exit on their own after their app quit.
    public var helperGrace: Double = 2
    public var poll: Double = 0.25

    public init() {}
}

/// Carries out quits: re-checks every process on fresh data, asks it to quit, waits,
/// and cleans up helpers. It never signals anything the safety policy protects.
public struct QuitCoordinator: Sendable {
    private let context: any ValidationContextProvider
    private let processes: any ProcessSource
    private let signaler: any Signaler
    private let apps: any AppTerminator
    private let clock: any MonotonicClock
    private let timing: QuitTiming

    public init(
        context: any ValidationContextProvider,
        processes: any ProcessSource,
        signaler: any Signaler,
        apps: any AppTerminator,
        clock: any MonotonicClock,
        timing: QuitTiming = QuitTiming()
    ) {
        self.context = context
        self.processes = processes
        self.signaler = signaler
        self.apps = apps
        self.clock = clock
        self.timing = timing
    }

    public func perform(_ request: QuitRequest) async -> QuitOutcome {
        switch request.target {
        case .process(let key):
            return await quitProcess(key, request)
        case .group:
            return await quitGroup(request)
        }
    }

    // MARK: - One process

    private func quitProcess(_ key: ProcessKey, _ request: QuitRequest) async -> QuitOutcome {
        let fresh = await context.validationContext()
        let process: RawProcess
        switch validate(key, expectedPath: request.expectedPaths[key], in: fresh) {
        case .gone: return .alreadyGone
        case .changed: return .refused(.changed)
        case .protected(let reason): return .refused(.protected(reason))
        case .ok(let current): process = current
        }

        if let stop = await askToQuit(process, force: request.force) { return stop }
        let exited = await waitForExit([key], seconds: request.force ? timing.force : timing.graceful)
        if exited { return .exited }
        return request.force ? .failed(.didNotExit) : .stillRunning
    }

    // MARK: - A whole app

    private func quitGroup(_ request: QuitRequest) async -> QuitOutcome {
        let fresh = await context.validationContext()
        var leaders: [RawProcess] = []
        for key in request.leaders {
            switch validate(key, expectedPath: request.expectedPaths[key], in: fresh) {
            case .gone: continue
            case .changed: return .refused(.changed)
            case .protected(let reason): return .refused(.protected(reason))
            case .ok(let process): leaders.append(process)
            }
        }

        if request.force { return await forceQuitGroup(request, leaders: leaders) }

        if leaders.isEmpty {
            // No main process (only helpers are left): ask each one to exit.
            let members = await killableMembers(request)
            if members.isEmpty { return .alreadyGone }
            for key in members { _ = signaler.send(.terminate, to: key.pid) }
            return await waitForExit(members, seconds: timing.graceful) ? .exited : .stillRunning
        }

        for leader in leaders {
            if let stop = await askToQuit(leader, force: false), stop != .alreadyGone { return stop }
        }
        guard await waitForExit(leaders.map(\.key), seconds: timing.graceful) else { return .stillRunning }

        // Helpers normally exit with their app; give them a moment before cleaning up.
        let helpers = request.expectedPaths.keys.filter { !request.leaders.contains($0) }
        _ = await waitForExit(Array(helpers), seconds: timing.helperGrace)

        let leftovers = await killableMembers(request)
        if leftovers.isEmpty { return .exited }
        for key in leftovers { _ = signaler.send(.terminate, to: key.pid) }
        if await waitForExit(leftovers, seconds: timing.helperGrace) { return .exited }

        let stubborn = await killableMembers(request)
        for key in stubborn { _ = signaler.send(.kill, to: key.pid) }
        _ = await waitForExit(stubborn, seconds: 1)
        let survivors = stubborn.filter(isAlive).count
        return survivors == 0 ? .exited : .partial(survivors: survivors)
    }

    private func forceQuitGroup(_ request: QuitRequest, leaders: [RawProcess]) async -> QuitOutcome {
        for leader in leaders { _ = await askToQuit(leader, force: true) }
        let members = await killableMembers(request)
        for key in members { _ = signaler.send(.kill, to: key.pid) }

        var everyone = Set(members)
        for leader in leaders { everyone.insert(leader.key) }
        if everyone.isEmpty { return .alreadyGone }

        _ = await waitForExit(Array(everyone), seconds: timing.force)
        let survivors = everyone.filter(isAlive)
        if survivors.isEmpty { return .exited }
        if leaders.contains(where: { survivors.contains($0.key) }) { return .failed(.didNotExit) }
        return .partial(survivors: survivors.count)
    }

    /// Members of the app that are still running and may be signaled: the ones captured
    /// at click time plus any other process from the same bundle and user that started
    /// before the click. Each one is re-validated.
    private func killableMembers(_ request: QuitRequest) async -> [ProcessKey] {
        let fresh = await context.validationContext()
        var keys: [ProcessKey] = []
        var seen = Set<ProcessKey>()
        for (key, path) in request.expectedPaths {
            seen.insert(key)
            if case .ok = validate(key, expectedPath: path, in: fresh) { keys.append(key) }
        }
        if let bundle = request.bundlePath {
            for process in fresh.table.values where !seen.contains(process.key) {
                guard process.ruid == request.uid,
                    process.key.startMicros <= request.requestedAtMicros,
                    let path = process.path,
                    let normalized = PathClassifier.normalize(path),
                    normalized.hasPrefix(bundle + "/")
                else { continue }
                if case .ok = validate(process.key, expectedPath: path, in: fresh) { keys.append(process.key) }
            }
        }
        return keys.sorted { $0.pid < $1.pid }
    }

    // MARK: - Helpers

    enum Validation {
        case ok(RawProcess)
        case gone
        case changed
        case protected(ProtectionReason)
    }

    func validate(_ key: ProcessKey, expectedPath: String?, in fresh: ValidationContext) -> Validation {
        guard let current = fresh.table[key.pid], current.key == key, !current.isExiting else { return .gone }
        if let expectedPath {
            guard let path = current.path,
                let now = PathClassifier.normalize(path),
                now == PathClassifier.normalize(expectedPath)
            else { return .changed }
        }
        switch SafetyPolicy.evaluate(current, table: fresh.table, env: fresh.env) {
        case .killable: return .ok(current)
        case .protected(let reason): return .protected(reason)
        }
    }

    /// Asks an app to quit through AppKit, or sends a signal to anything else.
    /// Returns an outcome to stop with, or nil to go on waiting.
    private func askToQuit(_ process: RawProcess, force: Bool) async -> QuitOutcome? {
        if await apps.quitApp(pid: process.pid, force: force) { return nil }
        switch signaler.send(force ? .kill : .terminate, to: process.pid) {
        case .sent: break
        case .noSuchProcess: return .alreadyGone
        case .notPermitted: return .failed(.notPermitted)
        case .failed(let code): return .failed(.signalError(code))
        }
        if !force && process.isStopped {
            // A stopped process can't handle SIGTERM until it runs again.
            _ = signaler.send(.resume, to: process.pid)
        }
        return nil
    }

    func isAlive(_ key: ProcessKey) -> Bool {
        guard let process = processes.process(pid: key.pid) else { return false }
        return process.key == key && !process.isExiting
    }

    /// Polls until every process has exited, or the time is up.
    func waitForExit(_ keys: [ProcessKey], seconds: Double) async -> Bool {
        let deadline = clock.nowNs() &+ UInt64(max(seconds, 0) * 1_000_000_000)
        while true {
            if !keys.contains(where: isAlive) { return true }
            if clock.nowNs() >= deadline { return false }
            do {
                try await clock.sleep(ns: UInt64(timing.poll * 1_000_000_000))
            } catch {
                return !keys.contains(where: isAlive)
            }
        }
    }
}

/// Notices when something the user quit comes straight back, which happens with
/// background agents that macOS keeps alive.
public struct RespawnWatcher: Sendable {
    struct Watch: Sendable {
        var name: String
        var paths: Set<String>
        var quitAtMicros: Int64
        var untilMicros: Int64
    }

    private var watches: [Watch] = []

    public init() {}

    public mutating func watch(name: String, paths: [String], quitAtMicros: Int64, seconds: Double = 10) {
        let normalized = Set(paths.compactMap(PathClassifier.normalize))
        guard !normalized.isEmpty else { return }
        watches.append(
            Watch(name: name, paths: normalized, quitAtMicros: quitAtMicros, untilMicros: quitAtMicros + Int64(seconds * 1_000_000)))
    }

    /// Names of quit apps or processes that are running again.
    public mutating func check(_ snapshot: Snapshot, nowMicros: Int64) -> [String] {
        watches.removeAll { $0.untilMicros < nowMicros }
        guard !watches.isEmpty, snapshot.includesProcesses else { return [] }
        var respawned: [String] = []
        watches.removeAll { watch in
            let back = snapshot.groups.contains { group in
                group.members.contains { member in
                    guard member.raw.key.startMicros > watch.quitAtMicros,
                        let path = member.raw.path, let normalized = PathClassifier.normalize(path)
                    else { return false }
                    return watch.paths.contains(normalized)
                }
            }
            if back { respawned.append(watch.name) }
            return back
        }
        return respawned
    }
}
