import Foundation

public struct SampleOptions: Sendable, Equatable {
    /// False for a cheap refresh of the machine totals only.
    public var includeProcesses: Bool
    /// Run `ps` for approximate numbers of other users' processes.
    public var includeFallback: Bool

    public init(includeProcesses: Bool = true, includeFallback: Bool = false) {
        self.includeProcesses = includeProcesses
        self.includeFallback = includeFallback
    }
}

/// Reads every source and turns the readings into a `Snapshot`.
///
/// The sampler keeps the previous counters so it can turn them into rates, which is
/// why it is an actor: one sample at a time.
public actor Sampler: ValidationContextProvider {
    private let me: SelfIdentity
    private let processes: any ProcessSource
    private let gpu: (any GPUUsageSource)?
    private let system: any SystemStatsSource
    private let apps: any RunningAppsSource
    private let fallback: (any UsageFallbackSource)?
    private let responsibility: (any ResponsibilitySource)?
    private let clock: any MonotonicClock
    private var deltas = DeltaTracker()
    private var totals = TotalsTracker()

    public init(
        me: SelfIdentity,
        processes: any ProcessSource,
        gpu: (any GPUUsageSource)?,
        system: any SystemStatsSource,
        apps: any RunningAppsSource,
        fallback: (any UsageFallbackSource)? = nil,
        responsibility: (any ResponsibilitySource)? = nil,
        clock: any MonotonicClock
    ) {
        self.me = me
        self.processes = processes
        self.gpu = gpu
        self.system = system
        self.apps = apps
        self.fallback = fallback
        self.responsibility = responsibility
        self.clock = clock
    }

    public func sample(_ options: SampleOptions = SampleOptions()) async -> Snapshot {
        let now = clock.nowNs()
        let systemReading = system.read()
        let gpuReading = gpu?.read()
        let machine = Totals(
            cpuPercent: totals.cpuPercent(systemReading.cpu),
            memory: systemReading.memory,
            gpuPercent: gpuReading?.deviceUtilization,
            logicalCPUs: systemReading.logicalCPUs)

        guard options.includeProcesses else {
            return Snapshot(takenAt: Date(), totals: machine, includesProcesses: false, groups: [], processCount: 0, me: me)
        }

        let raw = processes.allProcesses().filter { !$0.isExiting }
        let table = Self.table(raw)
        let appList = await apps.runningApps()
        let env = SafetyEnvironment.make(me: me, apps: appList, table: table)
        let liveApps = appList.filter { app in
            guard let process = table[app.pid] else { return false }
            return SafetyEnvironment.matches(app, process)
        }
        let appByPID = Dictionary(liveApps.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        let cpu = deltas.cpuPercents(raw, nowNs: now, maxPercent: 100 * Double(max(1, systemReading.logicalCPUs)))
        let gpuRates = deltas.gpuPercents(gpuReading?.clients ?? [], nowNs: now)
        let estimates = options.includeFallback ? (fallback?.read() ?? [:]) : [:]
        let translated = me.isTranslated

        let stats = raw.map { process -> ProcessStats in
            var cpuPercent: Double? = translated ? nil : cpu[process.key]
            var memory = process.footprintBytes
            var isApproximate = false
            if process.cpuTimeNs == nil, let estimate = estimates[process.pid] {
                cpuPercent = estimate.cpuPercent
                memory = estimate.rssBytes
                isApproximate = true
            }
            return ProcessStats(
                raw: process,
                name: Grouper.displayName(for: process, app: appByPID[process.pid]),
                cpuPercent: cpuPercent,
                memoryBytes: memory,
                gpuPercent: gpuRates.percents[process.pid],
                hasGPUClient: gpuRates.pidsWithClients.contains(process.pid),
                isApproximate: isApproximate,
                safety: SafetyPolicy.evaluate(process, table: table, env: env))
        }

        let groups = Grouper.group(stats, table: table, apps: liveApps, responsibility: responsibility)
        return Snapshot(
            takenAt: Date(), totals: machine, includesProcesses: true, groups: groups, processCount: raw.count, me: me)
    }

    public func validationContext() async -> ValidationContext {
        let table = Self.table(processes.allProcesses())
        let appList = await apps.runningApps()
        return ValidationContext(table: table, env: SafetyEnvironment.make(me: me, apps: appList, table: table))
    }

    static func table(_ processes: [RawProcess]) -> [Int32: RawProcess] {
        var table: [Int32: RawProcess] = [:]
        table.reserveCapacity(processes.count)
        for process in processes { table[process.pid] = process }
        return table
    }
}
