import Foundation
import IOKit
import MonitorCore

/// Reads GPU use from the IORegistry, which any user may read.
///
/// Every process that uses the GPU opens user clients under the GPU's `IOAccelerator`
/// service. Each client says which process created it (`IOUserClientCreator`,
/// "pid 123, Safari") and how much GPU time it has used (`accumulatedGPUTime`, directly
/// on Intel or inside `AppUsage` on Apple Silicon). The accelerator itself reports
/// whole-GPU utilization in `PerformanceStatistics`.
public final class IOKitGPUSource: GPUUsageSource, @unchecked Sendable {
    public init() {}

    public func read() -> GPUReading {
        var clients: [GPUClientSample] = []
        var utilization: Double?

        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS
        else { return GPUReading() }
        defer { IOObjectRelease(accelerators) }

        var accelerator = IOIteratorNext(accelerators)
        while accelerator != 0 {
            if utilization == nil, let statistics = Self.property("PerformanceStatistics", of: accelerator) as? [String: Any] {
                utilization = GPUPropertyParser.deviceUtilization(from: statistics)
            }
            clients += Self.clients(of: accelerator)
            IOObjectRelease(accelerator)
            accelerator = IOIteratorNext(accelerators)
        }
        return GPUReading(clients: clients, deviceUtilization: utilization)
    }

    static func clients(of accelerator: io_registry_entry_t) -> [GPUClientSample] {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(children) }

        var samples: [GPUClientSample] = []
        var child = IOIteratorNext(children)
        while child != 0 {
            if let properties = properties(of: child),
                let creator = properties["IOUserClientCreator"] as? String,
                let pid = GPUPropertyParser.pid(fromCreator: creator),
                let gpuTime = GPUPropertyParser.accumulatedGPUTime(from: properties)
            {
                var entryID: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(child, &entryID)
                samples.append(GPUClientSample(registryID: entryID, pid: pid, accumulatedNs: gpuTime))
            }
            IOObjectRelease(child)
            child = IOIteratorNext(children)
        }
        return samples
    }

    static func properties(of entry: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
            let dictionary = unmanaged?.takeRetainedValue()
        else { return nil }
        return (dictionary as NSDictionary) as? [String: Any]
    }

    static func property(_ key: String, of entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
