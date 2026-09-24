/// Turns cumulative CPU and GPU time counters into percentages.
///
/// Rates are computed from the change since the previous sample. The first sample of a
/// process (or GPU client) only records a baseline, so it has no value yet. Because CPU
/// baselines are keyed by `ProcessKey` (pid + start time), a reused pid starts fresh and
/// can never produce a negative rate.
public struct DeltaTracker: Sendable {
    struct Baseline: Sendable {
        var valueNs: UInt64
        var atNs: UInt64
    }

    struct ClientBaseline: Sendable {
        var pid: Int32
        var baseline: Baseline
    }

    /// Samples closer together than this reuse the previous rate.
    public var minimumIntervalNs: UInt64 = 100_000_000
    /// After a longer gap (the app was paused) the old baseline is discarded, so a
    /// rate never averages over minutes of pause.
    public var maximumIntervalNs: UInt64 = 30_000_000_000

    private var cpuBaselines: [ProcessKey: Baseline] = [:]
    private var lastCPU: [ProcessKey: Double] = [:]
    private var gpuBaselines: [UInt64: ClientBaseline] = [:]
    private var lastGPU: [Int32: Double] = [:]

    public init() {}

    /// CPU % per process, where 100 means one full core, clamped to `0...maxPercent`.
    public mutating func cpuPercents(_ processes: [RawProcess], nowNs: UInt64, maxPercent: Double) -> [ProcessKey: Double] {
        var result: [ProcessKey: Double] = [:]
        var baselines: [ProcessKey: Baseline] = [:]
        var last: [ProcessKey: Double] = [:]

        for process in processes {
            guard let cpuNs = process.cpuTimeNs else { continue }
            let key = process.key
            let current = Baseline(valueNs: cpuNs, atNs: nowNs)
            guard let previous = cpuBaselines[key], nowNs > previous.atNs else {
                baselines[key] = current
                continue
            }
            let elapsed = nowNs - previous.atNs
            if elapsed < minimumIntervalNs {
                baselines[key] = previous
                if let rate = lastCPU[key] {
                    result[key] = rate
                    last[key] = rate
                }
                continue
            }
            baselines[key] = current
            if elapsed > maximumIntervalNs { continue }
            let used = cpuNs >= previous.valueNs ? cpuNs - previous.valueNs : 0
            let rate = min(max(Double(used) / Double(elapsed) * 100, 0), maxPercent)
            result[key] = rate
            last[key] = rate
        }

        cpuBaselines = baselines
        lastCPU = last
        return result
    }

    /// GPU % per pid, summed over the pid's clients, plus every pid that has a client.
    ///
    /// Each client is tracked by its registry ID, so a client that closes can't make
    /// the pid's total drop and a new client only sets a baseline.
    public mutating func gpuPercents(_ clients: [GPUClientSample], nowNs: UInt64) -> (percents: [Int32: Double], pidsWithClients: Set<Int32>) {
        var rates: [Int32: Double] = [:]
        var measured = Set<Int32>()
        var pidsWithClients = Set<Int32>()
        var baselines: [UInt64: ClientBaseline] = [:]

        for client in clients {
            pidsWithClients.insert(client.pid)
            let current = ClientBaseline(pid: client.pid, baseline: Baseline(valueNs: client.accumulatedNs, atNs: nowNs))
            guard let previous = gpuBaselines[client.registryID], previous.pid == client.pid,
                nowNs > previous.baseline.atNs
            else {
                baselines[client.registryID] = current
                continue
            }
            let elapsed = nowNs - previous.baseline.atNs
            if elapsed < minimumIntervalNs {
                baselines[client.registryID] = previous
                continue
            }
            baselines[client.registryID] = current
            if elapsed > maximumIntervalNs { continue }
            let used = client.accumulatedNs >= previous.baseline.valueNs ? client.accumulatedNs - previous.baseline.valueNs : 0
            rates[client.pid, default: 0] += Double(used) / Double(elapsed) * 100
            measured.insert(client.pid)
        }

        var percents: [Int32: Double] = [:]
        for pid in pidsWithClients {
            if measured.contains(pid) {
                percents[pid] = rates[pid] ?? 0
            } else if let previous = lastGPU[pid] {
                percents[pid] = previous
            }
        }

        gpuBaselines = baselines
        lastGPU = percents
        return (percents, pidsWithClients)
    }
}

/// Turns cumulative machine-wide CPU ticks into a percentage of all cores.
public struct TotalsTracker: Sendable {
    private var lastTicks: CPUTicks?

    public init() {}

    public mutating func cpuPercent(_ ticks: CPUTicks?) -> Double? {
        guard let ticks else { return nil }
        defer { lastTicks = ticks }
        guard let last = lastTicks else { return nil }
        // The kernel's counters are 32-bit and wrap, so subtract with wrapping.
        let busy = UInt64(ticks.user &- last.user) + UInt64(ticks.system &- last.system) + UInt64(ticks.nice &- last.nice)
        let total = busy + UInt64(ticks.idle &- last.idle)
        guard total > 0 else { return nil }
        return Double(busy) / Double(total) * 100
    }
}

/// A fixed-size history, oldest element first.
public struct RingBuffer<Element: Sendable>: Sendable {
    public let capacity: Int
    private var storage: [Element] = []
    private var head = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    public var elements: [Element] {
        storage.count < capacity ? storage : Array(storage[head...]) + Array(storage[..<head])
    }

    public var count: Int { storage.count }

    public var last: Element? {
        guard !storage.isEmpty else { return nil }
        return storage.count < capacity ? storage.last : storage[(head + capacity - 1) % capacity]
    }
}
