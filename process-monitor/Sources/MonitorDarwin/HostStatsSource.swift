import Darwin
import MonitorCore

/// Machine-wide CPU ticks and memory from the Mach host interfaces.
public final class HostStatsSource: SystemStatsSource, @unchecked Sendable {
    private let host: host_t
    private let totalMemory: UInt64
    private let logicalCPUs: Int
    private let pageSize: UInt64

    public init() {
        host = mach_host_self()
        totalMemory = MonitorDarwin.sysctlUInt64("hw.memsize") ?? 0
        logicalCPUs = Int(MonitorDarwin.sysctlInt32("hw.logicalcpu") ?? 1)
        pageSize = UInt64(vm_kernel_page_size)
    }

    public func read() -> SystemReading {
        SystemReading(cpu: cpuTicks(), memory: memory(), logicalCPUs: max(logicalCPUs, 1))
    }

    func cpuTicks() -> CPUTicks? {
        var load = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { integers in
                host_statistics(host, HOST_CPU_LOAD_INFO, integers, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // Indexed by CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_IDLE, CPU_STATE_NICE.
        let ticks = load.cpu_ticks
        return CPUTicks(user: ticks.0, system: ticks.1, idle: ticks.2, nice: ticks.3)
    }

    /// Activity Monitor's "Memory Used": app memory (internal minus purgeable pages),
    /// wired memory and the compressor.
    func memory() -> MemoryReading? {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { integers in
                host_statistics64(host, HOST_VM_INFO64, integers, &count)
            }
        }
        guard result == KERN_SUCCESS, totalMemory > 0 else { return nil }

        let internal = UInt64(statistics.internal_page_count)
        let purgeable = UInt64(statistics.purgeable_count)
        let appPages = internal > purgeable ? internal - purgeable : 0
        let usedPages = appPages + UInt64(statistics.wire_count) + UInt64(statistics.compressor_page_count)
        let level = MonitorDarwin.sysctlInt32("kern.memorystatus_vm_pressure_level").map(Int.init) ?? 0
        return MemoryReading(
            totalBytes: totalMemory,
            usedBytes: min(usedPages * pageSize, totalMemory),
            pressure: MemoryPressure(level: level))
    }
}
