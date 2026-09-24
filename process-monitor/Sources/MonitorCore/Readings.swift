import Foundation

/// One GPU user client: a Metal device or command queue opened by a process.
public struct GPUClientSample: Sendable, Equatable {
    /// IORegistry entry ID, stable for the client's lifetime.
    public var registryID: UInt64
    public var pid: Int32
    /// GPU time used by the client so far, in nanoseconds.
    public var accumulatedNs: UInt64

    public init(registryID: UInt64, pid: Int32, accumulatedNs: UInt64) {
        self.registryID = registryID
        self.pid = pid
        self.accumulatedNs = accumulatedNs
    }
}

public struct GPUReading: Sendable, Equatable {
    public var clients: [GPUClientSample]
    /// Whole-GPU utilization in percent, when the driver reports it.
    public var deviceUtilization: Double?

    public init(clients: [GPUClientSample] = [], deviceUtilization: Double? = nil) {
        self.clients = clients
        self.deviceUtilization = deviceUtilization
    }
}

/// Cumulative CPU ticks for the whole machine.
public struct CPUTicks: Sendable, Equatable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

public enum MemoryPressure: Sendable, Equatable {
    case normal, warning, critical, unknown

    /// Maps `kern.memorystatus_vm_pressure_level` (1, 2 or 4).
    public init(level: Int) {
        switch level {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: self = .unknown
        }
    }
}

public struct MemoryReading: Sendable, Equatable {
    public var totalBytes: UInt64
    /// Activity Monitor's "Memory Used": app memory + wired + compressed.
    public var usedBytes: UInt64
    public var pressure: MemoryPressure

    public init(totalBytes: UInt64, usedBytes: UInt64, pressure: MemoryPressure) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.pressure = pressure
    }
}

public struct SystemReading: Sendable, Equatable {
    public var cpu: CPUTicks?
    public var memory: MemoryReading?
    public var logicalCPUs: Int

    public init(cpu: CPUTicks? = nil, memory: MemoryReading? = nil, logicalCPUs: Int = 1) {
        self.cpu = cpu
        self.memory = memory
        self.logicalCPUs = logicalCPUs
    }
}

/// Approximate usage of a process the app can't measure directly (another user's).
public struct ApproxUsage: Sendable, Equatable {
    public var cpuPercent: Double
    public var rssBytes: UInt64

    public init(cpuPercent: Double, rssBytes: UInt64) {
        self.cpuPercent = cpuPercent
        self.rssBytes = rssBytes
    }
}

/// Machine-wide numbers for the summary strip.
public struct Totals: Sendable, Equatable {
    /// Share of all cores in use, 0–100.
    public var cpuPercent: Double?
    public var memory: MemoryReading?
    /// GPU device utilization, 0–100.
    public var gpuPercent: Double?
    public var logicalCPUs: Int

    public init(cpuPercent: Double? = nil, memory: MemoryReading? = nil, gpuPercent: Double? = nil, logicalCPUs: Int = 1) {
        self.cpuPercent = cpuPercent
        self.memory = memory
        self.gpuPercent = gpuPercent
        self.logicalCPUs = logicalCPUs
    }
}

/// One process in a snapshot, with its rates and safety verdict.
public struct ProcessStats: Sendable, Identifiable, Equatable {
    public var raw: RawProcess
    /// Display name, e.g. "Safari" or "node (vite)".
    public var name: String
    /// CPU % where 100 means one full core.
    public var cpuPercent: Double?
    public var memoryBytes: UInt64?
    public var gpuPercent: Double?
    public var hasGPUClient: Bool
    /// CPU and memory came from `ps` and are approximate.
    public var isApproximate: Bool
    public var safety: Safety

    public init(
        raw: RawProcess,
        name: String,
        cpuPercent: Double? = nil,
        memoryBytes: UInt64? = nil,
        gpuPercent: Double? = nil,
        hasGPUClient: Bool = false,
        isApproximate: Bool = false,
        safety: Safety
    ) {
        self.raw = raw
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.gpuPercent = gpuPercent
        self.hasGPUClient = hasGPUClient
        self.isApproximate = isApproximate
        self.safety = safety
    }

    public var id: ProcessKey { raw.key }
}

/// A row in the list: an app with all its helper processes, or a single process.
public enum GroupID: Hashable, Sendable {
    /// Normalized path of the app bundle, plus the owner's user ID.
    case app(bundlePath: String, uid: UInt32)
    case process(ProcessKey)
}

public struct ProcessGroup: Sendable, Identifiable, Equatable {
    public var id: GroupID
    public var name: String
    /// App bundle in its original spelling (for the icon and Show in Finder).
    public var bundlePath: String?
    public var bundleID: String?
    public var uid: UInt32
    /// Members ordered by pid.
    public var members: [ProcessStats]
    /// The app's main processes: executables directly in `Contents/MacOS`.
    public var leaders: [ProcessKey]
    public var cpuPercent: Double?
    public var memoryBytes: UInt64?
    public var gpuPercent: Double?
    public var hasGPUClient: Bool
    public var isApproximate: Bool
    /// Whether the whole group can be quit.
    public var quitAbility: Safety

    public init(
        id: GroupID,
        name: String,
        bundlePath: String? = nil,
        bundleID: String? = nil,
        uid: UInt32,
        members: [ProcessStats],
        leaders: [ProcessKey] = [],
        cpuPercent: Double? = nil,
        memoryBytes: UInt64? = nil,
        gpuPercent: Double? = nil,
        hasGPUClient: Bool = false,
        isApproximate: Bool = false,
        quitAbility: Safety
    ) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
        self.bundleID = bundleID
        self.uid = uid
        self.members = members
        self.leaders = leaders
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.gpuPercent = gpuPercent
        self.hasGPUClient = hasGPUClient
        self.isApproximate = isApproximate
        self.quitAbility = quitAbility
    }

    /// True when the group or any of its members can be quit.
    public var hasKillableMember: Bool {
        quitAbility.isKillable || members.contains { $0.safety.isKillable }
    }
}

/// Everything one refresh produced.
public struct Snapshot: Sendable {
    public var takenAt: Date
    public var totals: Totals
    /// False for a totals-only refresh (the window is hidden).
    public var includesProcesses: Bool
    public var groups: [ProcessGroup]
    public var processCount: Int
    public var me: SelfIdentity

    public init(
        takenAt: Date,
        totals: Totals,
        includesProcesses: Bool,
        groups: [ProcessGroup],
        processCount: Int,
        me: SelfIdentity
    ) {
        self.takenAt = takenAt
        self.totals = totals
        self.includesProcesses = includesProcesses
        self.groups = groups
        self.processCount = processCount
        self.me = me
    }
}
