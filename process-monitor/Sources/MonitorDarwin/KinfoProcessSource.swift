import Darwin
import Foundation
import MonitorCore

/// Reads the process table with `sysctl(KERN_PROC_ALL)` and `proc_pidpath`, which work
/// for every process without special rights, plus `proc_pid_rusage` for CPU time and
/// memory, which macOS only allows for the user's own processes.
public final class KinfoProcessSource: ProcessSource, @unchecked Sendable {
    private struct CachedHint {
        var path: String?
        var hint: String?
    }

    private let uid: uid_t
    private let time: MachTime
    private let codeSigning: CodeSigningInspector?
    private let hints = Locked<[ProcessKey: CachedHint]>([:])

    public init(time: MachTime = MachTime(), codeSigning: CodeSigningInspector? = CodeSigningInspector()) {
        self.uid = getuid()
        self.time = time
        self.codeSigning = codeSigning
    }

    public func allProcesses() -> [RawProcess] {
        guard let list = Self.readProcessList() else { return [] }
        var processes: [RawProcess] = []
        processes.reserveCapacity(list.count)
        for info in list where Int32(info.kp_proc.p_stat) != SZOMB {
            processes.append(makeProcess(info))
        }
        let live = Set(processes.map(\.key))
        hints.withValue { cache in cache = cache.filter { live.contains($0.key) } }
        codeSigning?.prune(keeping: live)
        return processes
    }

    public func process(pid: Int32) -> RawProcess? {
        guard pid >= 0, let info = Self.readProcess(pid: pid) else { return nil }
        return makeProcess(info)
    }

    // MARK: - Building a RawProcess

    private func makeProcess(_ info: kinfo_proc) -> RawProcess {
        let pid = info.kp_proc.p_pid
        let started = info.kp_proc.p_un.__p_starttime
        let key = ProcessKey(pid: pid, startMicros: Int64(started.tv_sec) * 1_000_000 + Int64(started.tv_usec))
        let state = Int32(info.kp_proc.p_stat)
        let euid = info.kp_eproc.e_ucred.cr_uid
        let ruid = info.kp_eproc.e_pcred.p_ruid
        let svuid = info.kp_eproc.e_pcred.p_svuid
        let path = Self.executablePath(pid: pid)
        let isExiting = state == SZOMB || (info.kp_proc.p_flag & P_WEXIT) != 0

        var process = RawProcess(
            key: key,
            ppid: info.kp_eproc.e_ppid,
            euid: euid,
            ruid: ruid,
            svuid: svuid,
            comm: Self.string(fromCString: info.kp_proc.p_comm),
            path: path,
            isExiting: isExiting,
            isStopped: state == SSTOP)

        // Everything below needs the process to be the user's own.
        guard euid == uid, ruid == uid, svuid == uid, !isExiting else { return process }

        if let usage = Self.resourceUsage(pid: pid) {
            process.cpuTimeNs = time.nanoseconds(fromTicks: usage.ri_user_time &+ usage.ri_system_time)
            process.footprintBytes = usage.ri_phys_footprint
        }
        if let path, let normalized = PathClassifier.normalize(path), !PathClassifier.isAppleSystemPath(normalized) {
            process.isPlatformSigned = codeSigning?.isPlatform(key: key, path: path)
        }
        process.interpreterHint = interpreterHint(key: key, path: path)
        return process
    }

    private func interpreterHint(key: ProcessKey, path: String?) -> String? {
        guard let path, InterpreterHint.isInterpreter(PathClassifier.basename(path)) else { return nil }
        if let cached = hints.withValue({ $0[key] }), cached.path == path { return cached.hint }
        let hint = Self.arguments(pid: key.pid).flatMap(InterpreterHint.hint(for:))
        hints.withValue { $0[key] = CachedHint(path: path, hint: hint) }
        return hint
    }

    // MARK: - System calls

    /// All processes. The list can grow between asking for its size and reading it,
    /// so the buffer gets some headroom and the read is retried.
    static func readProcessList() -> [kinfo_proc]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
            size += size / 8
            var list = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 1)
            var bufferSize = list.count * stride
            let result = list.withUnsafeMutableBytes { buffer in
                sysctl(&mib, u_int(mib.count), buffer.baseAddress, &bufferSize, nil, 0)
            }
            if result == 0 { return Array(list.prefix(bufferSize / stride)) }
            if errno != ENOMEM { return nil }
        }
        return nil
    }

    static func readProcess(pid: Int32) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    static func executablePath(pid: Int32) -> String? {
        let capacity = 4 * Int(MAXPATHLEN)  // PROC_PIDPATHINFO_MAXSIZE
        var buffer = [UInt8](repeating: 0, count: capacity)
        let length = proc_pidpath(pid, &buffer, UInt32(capacity))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    static func resourceUsage(pid: Int32) -> rusage_info_v4? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        return result == 0 ? usage : nil
    }

    static let argumentsMax: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, u_int(mib.count), &value, &size, nil, 0) == 0, value > 0 else { return 262_144 }
        return Int(value)
    }()

    /// The process's arguments (own processes only).
    static func arguments(pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argumentsMax
        var buffer = [UInt8](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBytes { bytes in
            sysctl(&mib, u_int(mib.count), bytes.baseAddress, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }
        return ProcArgsParser.arguments(from: Array(buffer.prefix(size)))
    }

    /// Reads a fixed-size C string such as `p_comm`.
    static func string<Tuple>(fromCString tuple: Tuple) -> String {
        var copy = tuple
        return withUnsafeBytes(of: &copy) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
