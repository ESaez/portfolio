import Foundation
import Testing
@testable import MonitorCore

/// A small, realistic process tree shared by the safety policy tests.
///
/// Parents always get lower pids than their children, and the default start time is the
/// pid, so every parent starts before its children unless a test says otherwise.
enum PolicyFixture {
    static let uid: UInt32 = 501
    static let myPID: Int32 = 4242

    static func process(
        _ pid: Int32,
        _ path: String?,
        ppid: Int32 = 1,
        uid: UInt32 = PolicyFixture.uid,
        euid: UInt32? = nil,
        svuid: UInt32? = nil,
        start: Int64? = nil,
        comm: String? = nil,
        exiting: Bool = false,
        platform: Bool? = nil
    ) -> RawProcess {
        let name = comm ?? path.map { String(PathClassifier.basename($0).prefix(16)) } ?? "?"
        return RawProcess(
            key: ProcessKey(pid: pid, startMicros: start ?? Int64(pid)),
            ppid: ppid,
            euid: euid ?? uid,
            ruid: uid,
            svuid: svuid ?? euid ?? uid,
            comm: name,
            path: path,
            isExiting: exiting,
            isPlatformSigned: platform
        )
    }

    static let kernel = process(0, nil, ppid: 0, uid: 0, comm: "kernel_task")
    static let launchd = process(1, "/sbin/launchd", ppid: 0, uid: 0)
    static let finder = process(300, "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder")
    static let safari = process(
        600, "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari")
    static let terminal = process(700, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
    static let login = process(701, "/usr/bin/login", ppid: 700, uid: 0)
    static let zsh = process(702, "/bin/zsh", ppid: 701)
    static let tmux = process(800, "/opt/homebrew/bin/tmux")
    static let sshd = process(850, "/usr/sbin/sshd", uid: 0)
    static let sshdSession = process(851, "/usr/libexec/sshd-session", ppid: 850, uid: 0)
    static let xcode = process(900, "/Applications/Xcode.app/Contents/MacOS/Xcode")
    static let me = process(myPID, "/Applications/Process Monitor.app/Contents/MacOS/ProcessMonitor")

    static let baseTable: [RawProcess] = [
        kernel, launchd, finder, safari, terminal, login, zsh, tmux, sshd, sshdSession, xcode, me,
    ]

    static let environment = SafetyEnvironment(
        me: SelfIdentity(uid: uid, euid: uid, pid: myPID),
        regularAppPIDs: [300, 600, 601, 700, 900, 950, 960],
        bundleIDByPID: [
            300: "com.apple.finder",
            600: "com.apple.Safari",
            601: "com.apple.Safari",
            700: "com.apple.Terminal",
            900: "com.apple.dt.Xcode",
            950: "com.apple.MigrationAssistant",
            960: "com.apple.systempreferences",
        ]
    )
}

/// One row of the policy table.
struct PolicyCase: Sendable, CustomTestStringConvertible {
    let name: String
    let process: RawProcess
    var extraProcesses: [RawProcess] = []
    var environment: SafetyEnvironment = PolicyFixture.environment
    let expected: Safety

    var testDescription: String { name }

    func evaluate() -> Safety {
        var table: [Int32: RawProcess] = [:]
        for entry in PolicyFixture.baseTable + extraProcesses + [process] {
            table[entry.pid] = entry
        }
        return SafetyPolicy.evaluate(process, table: table, env: environment)
    }
}
