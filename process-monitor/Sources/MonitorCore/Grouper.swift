import Foundation

/// Groups processes into one row per app (with all its helpers) and one row per
/// standalone process.
public enum Grouper {
    public static func group(
        _ stats: [ProcessStats],
        table: [Int32: RawProcess],
        apps: [AppInfo],
        responsibility: (any ResponsibilitySource)?
    ) -> [ProcessGroup] {
        let regularBundles = Set(apps.filter { $0.policy == .regular }.compactMap { $0.bundlePath.flatMap(PathClassifier.normalize) })
        let appByPID = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        var order: [GroupID] = []
        var membersByGroup: [GroupID: [ProcessStats]] = [:]
        var bundleByGroup: [GroupID: String] = [:]

        for process in stats {
            let id: GroupID
            if let bundle = appBundle(for: process.raw, table: table, regularBundles: regularBundles, responsibility: responsibility) {
                id = .app(bundlePath: PathClassifier.normalize(bundle) ?? bundle.lowercased(), uid: process.raw.ruid)
                if bundleByGroup[id] == nil { bundleByGroup[id] = bundle }
            } else {
                id = .process(process.id)
            }
            if membersByGroup[id] == nil { order.append(id) }
            membersByGroup[id, default: []].append(process)
        }

        return order.map { id in
            makeGroup(id, members: membersByGroup[id] ?? [], bundle: bundleByGroup[id], appByPID: appByPID)
        }
    }

    /// The app bundle a process belongs to, in its original spelling.
    static func appBundle(
        for process: RawProcess,
        table: [Int32: RawProcess],
        regularBundles: Set<String>,
        responsibility: (any ResponsibilitySource)?
    ) -> String? {
        guard let path = process.path else { return nil }
        if let bundle = bundle(forPath: path, regularBundles: regularBundles) { return bundle }

        // XPC helpers (WebKit's web content and GPU processes, for example) live in
        // system frameworks, so their path says nothing about the app that uses them.
        // Ask macOS which process is responsible for them, but only trust the answer
        // when it is plausible: same user, and the owner started first.
        guard PathClassifier.isXPCService(path),
            let responsibility,
            let ownerPID = responsibility.responsiblePID(for: process.pid),
            ownerPID > 1, ownerPID != process.pid,
            let owner = table[ownerPID],
            owner.ruid == process.ruid,
            owner.key.startMicros <= process.key.startMicros,
            let ownerPath = owner.path
        else { return nil }
        return bundle(forPath: ownerPath, regularBundles: regularBundles)
    }

    /// The outermost `.app` in the path, unless a nested `.app` is itself a running Dock
    /// app (Simulator inside Xcode), in which case the innermost such app wins.
    static func bundle(forPath path: String, regularBundles: Set<String>) -> String? {
        let candidates = PathClassifier.appBundleCandidates(path)
        guard let outermost = candidates.first else { return nil }
        for candidate in candidates.dropFirst().reversed() {
            if let normalized = PathClassifier.normalize(candidate), regularBundles.contains(normalized) {
                return candidate
            }
        }
        return outermost
    }

    /// True for the app's main executable: directly inside `<bundle>/Contents/MacOS/`.
    static func isLeader(_ path: String?, bundle: String) -> Bool {
        guard let path, let normalizedPath = PathClassifier.normalize(path),
            let normalizedBundle = PathClassifier.normalize(bundle)
        else { return false }
        let prefix = normalizedBundle + "/contents/macos/"
        guard normalizedPath.hasPrefix(prefix) else { return false }
        return !normalizedPath.dropFirst(prefix.count).contains("/")
    }

    static func makeGroup(_ id: GroupID, members unsorted: [ProcessStats], bundle: String?, appByPID: [Int32: AppInfo]) -> ProcessGroup {
        let members = unsorted.sorted { $0.raw.pid < $1.raw.pid }
        let uid = members.first?.raw.ruid ?? 0

        guard case .app = id, let bundle else {
            let only = members[0]
            return ProcessGroup(
                id: id, name: only.name, uid: uid, members: members,
                cpuPercent: only.cpuPercent, memoryBytes: only.memoryBytes, gpuPercent: only.gpuPercent,
                hasGPUClient: only.hasGPUClient, isApproximate: only.isApproximate, quitAbility: only.safety)
        }

        let leaders = members.filter { isLeader($0.raw.path, bundle: bundle) }
        let leaderApp = leaders.lazy.compactMap { appByPID[$0.raw.pid] }.first
        let name = leaderApp?.name.flatMap { $0.isEmpty ? nil : $0 } ?? bundleDisplayName(bundle)

        let quitAbility: Safety
        if let blocked = leaders.first(where: { !$0.safety.isKillable }) {
            quitAbility = blocked.safety
        } else if !leaders.isEmpty || members.contains(where: { $0.safety.isKillable }) {
            quitAbility = .killable
        } else {
            quitAbility = members.first?.safety ?? .protected(.systemProcess)
        }

        return ProcessGroup(
            id: id,
            name: name,
            bundlePath: bundle,
            bundleID: leaderApp?.bundleID,
            uid: uid,
            members: members,
            leaders: leaders.map(\.id),
            cpuPercent: sum(members.map(\.cpuPercent)),
            memoryBytes: sum(members.map(\.memoryBytes)),
            gpuPercent: sum(members.map(\.gpuPercent)),
            hasGPUClient: members.contains { $0.hasGPUClient },
            isApproximate: members.contains { $0.isApproximate },
            quitAbility: quitAbility)
    }

    /// "Google Chrome" for ".../Google Chrome.app".
    static func bundleDisplayName(_ bundle: String) -> String {
        let base = PathClassifier.basename(bundle)
        return base.lowercased().hasSuffix(".app") ? String(base.dropLast(4)) : base
    }

    /// The name shown for one process: the app's name, else the executable's name,
    /// plus an interpreter hint ("node (vite)").
    public static func displayName(for process: RawProcess, app: AppInfo?) -> String {
        let base: String
        if let name = app?.name, !name.isEmpty {
            base = name
        } else if let path = process.path {
            base = PathClassifier.basename(path)
        } else {
            base = process.comm.isEmpty ? "PID \(process.pid)" : process.comm
        }
        guard let hint = process.interpreterHint else { return base }
        return "\(base) (\(hint))"
    }

    static func sum(_ values: [Double?]) -> Double? {
        let known = values.compactMap { $0 }
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    static func sum(_ values: [UInt64?]) -> UInt64? {
        let known = values.compactMap { $0 }
        return known.isEmpty ? nil : known.reduce(0, &+)
    }
}
