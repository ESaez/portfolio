import Foundation
import Testing
@testable import MonitorCore

private typealias F = PolicyFixture

/// 21 processes, each started by the one before; the first one is a child of Terminal.
/// The walk gives up before it gets back to Terminal.
private let deepChain: [RawProcess] = (0...20).map { index in
    let pid = 2000 + Int32(index)
    return F.process(pid, "/usr/libexec/step\(index)", ppid: index == 0 ? 700 : pid - 1)
}

private let protectedCases: [PolicyCase] = [
    PolicyCase(name: "kernel_task", process: F.kernel, expected: .protected(.kernel)),
    PolicyCase(name: "launchd", process: F.launchd, expected: .protected(.launchd)),
    PolicyCase(name: "Process Monitor itself", process: F.me, expected: .protected(.thisApp)),
    PolicyCase(
        name: "WindowServer (_windowserver)",
        process: F.process(400, "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", uid: 88),
        expected: .protected(.otherUser)),
    PolicyCase(
        name: "Chrome of another user",
        process: F.process(1000, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", uid: 502),
        expected: .protected(.otherUser)),
    PolicyCase(
        name: "sudo started from Terminal",
        process: F.process(1001, "/usr/bin/sudo", ppid: 702, euid: 0),
        expected: .protected(.elevated)),
    PolicyCase(name: "unreadable path", process: F.process(1002, nil), expected: .protected(.unknownPath)),
    PolicyCase(name: "relative path", process: F.process(1003, "sleep"), expected: .protected(.unknownPath)),
    PolicyCase(
        name: "path with ..",
        process: F.process(1004, "/Applications/../System/Library/tool"),
        expected: .protected(.unknownPath)),
    PolicyCase(name: "Finder, a regular app", process: F.finder, expected: .protected(.coreService)),
    PolicyCase(
        name: "Dock spelled with odd capitals",
        process: F.process(1005, "/SYSTEM/library/CoreServices/Dock.app/Contents/MacOS/Dock"),
        expected: .protected(.coreService)),
    PolicyCase(
        name: "Spotlight inside a cryptex",
        process: F.process(
            1006,
            "/System/Volumes/Preboot/Cryptexes/OS/System/Library/CoreServices/Spotlight.app/Contents/MacOS/Spotlight"),
        expected: .protected(.coreService)),
    PolicyCase(
        name: "user binary named like a critical one",
        process: F.process(1007, "/opt/homebrew/bin/lsd", ppid: 702),
        expected: .protected(.coreService)),
    PolicyCase(
        name: "Migration Assistant, matched by bundle ID",
        process: F.process(
            950, "/System/Applications/Utilities/Migration Assistant.app/Contents/MacOS/Migration Assistant"),
        expected: .protected(.coreService)),
    PolicyCase(
        name: "WebKit content process started by launchd",
        process: F.process(
            1008,
            "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
        ),
        expected: .protected(.systemProcess)),
    PolicyCase(
        name: "disowned /bin/sleep", process: F.process(1009, "/bin/sleep"), expected: .protected(.systemProcess)),
    PolicyCase(
        name: "zsh in an SSH session",
        process: F.process(1010, "/bin/zsh", ppid: 851),
        expected: .protected(.systemProcess)),
    PolicyCase(
        name: "sleep launched by Finder",
        process: F.process(1011, "/usr/bin/sleep", ppid: 300),
        expected: .protected(.systemProcess)),
    PolicyCase(
        name: "sh launched by Process Monitor",
        process: F.process(4300, "/bin/sh", ppid: F.myPID),
        expected: .protected(.systemProcess)),
    PolicyCase(
        name: "parents that form a cycle",
        process: F.process(1012, "/usr/libexec/a", ppid: 1013, start: 50),
        extraProcesses: [F.process(1013, "/usr/libexec/b", ppid: 1012, start: 50)],
        expected: .protected(.systemProcess)),
    PolicyCase(
        name: "chain deeper than the walk limit",
        process: deepChain[deepChain.count - 1],
        extraProcesses: deepChain,
        expected: .protected(.systemProcess)),
    PolicyCase(
        name: "parent newer than its child (reused pid)",
        process: F.process(1015, "/bin/sleep", ppid: 1014, start: 100),
        extraProcesses: [F.process(1014, "/opt/homebrew/bin/node", ppid: 702, start: 200)],
        expected: .protected(.systemProcess)),
    PolicyCase(
        name: "platform-signed binary outside the system folders",
        process: F.process(1016, "/Users/me/tmp/tool", platform: true),
        expected: .protected(.systemProcess)),
    PolicyCase(
        name: "tool in /private/var/db",
        process: F.process(1017, "/private/var/db/something/tool"),
        expected: .protected(.systemProcess)),
    PolicyCase(
        name: "exiting process",
        process: F.process(1018, "/Applications/Foo.app/Contents/MacOS/Foo", exiting: true),
        expected: .protected(.notRunning)),
    PolicyCase(
        name: "Process Monitor running as root",
        process: F.xcode,
        environment: SafetyEnvironment(me: SelfIdentity(uid: 0, euid: 0, pid: F.myPID)),
        expected: .protected(.runningAsRoot)),
    PolicyCase(
        name: "Process Monitor running setuid",
        process: F.xcode,
        environment: SafetyEnvironment(me: SelfIdentity(uid: F.uid, euid: 0, pid: F.myPID)),
        expected: .protected(.runningAsRoot)),
]

private let killableCases: [PolicyCase] = [
    PolicyCase(name: "Safari from its cryptex", process: F.safari, expected: .killable),
    PolicyCase(
        name: "Safari at /Applications, platform-signed",
        process: F.process(601, "/Applications/Safari.app/Contents/MacOS/Safari", platform: true),
        expected: .killable),
    PolicyCase(name: "Terminal", process: F.terminal, expected: .killable),
    PolicyCase(
        name: "System Settings",
        process: F.process(960, "/System/Applications/System Settings.app/Contents/MacOS/System Settings"),
        expected: .killable),
    PolicyCase(name: "zsh in Terminal, under a root login", process: F.zsh, expected: .killable),
    PolicyCase(name: "vim in Terminal", process: F.process(1100, "/usr/bin/vim", ppid: 702), expected: .killable),
    PolicyCase(name: "sleep in Terminal", process: F.process(1101, "/bin/sleep", ppid: 702), expected: .killable),
    PolicyCase(
        name: "zsh inside Homebrew tmux", process: F.process(1102, "/bin/zsh", ppid: 800), expected: .killable),
    PolicyCase(
        name: "python3 from the Command Line Tools",
        process: F.process(1103, "/Library/Developer/CommandLineTools/usr/bin/python3"),
        expected: .killable),
    PolicyCase(
        name: "Homebrew node started by launchd",
        process: F.process(1104, "/opt/homebrew/Cellar/node/22.0.0/bin/node"),
        expected: .killable),
    PolicyCase(name: "tool in /usr/local", process: F.process(1105, "/usr/local/bin/foo"), expected: .killable),
    PolicyCase(
        name: "Chrome renderer helper",
        process: F.process(
            1106,
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/140.0.0.0/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        ),
        expected: .killable),
    PolicyCase(
        name: "translocated app",
        process: F.process(
            1107, "/private/var/folders/xy/abc123/T/AppTranslocation/1A2B3C/d/Foo.app/Contents/MacOS/Foo"),
        expected: .killable),
    PolicyCase(
        name: "app running from a disk image",
        process: F.process(1108, "/Volumes/Foo/Foo.app/Contents/MacOS/Foo"),
        expected: .killable),
    PolicyCase(name: "Xcode", process: F.xcode, expected: .killable),
    PolicyCase(
        name: "app reached through the Data volume",
        process: F.process(1109, "/System/Volumes/Data/Applications/Foo.app/Contents/MacOS/Foo"),
        expected: .killable),
    PolicyCase(
        name: "Intel app running under Rosetta",
        process: F.process(1110, "/Applications/OldApp.app/Contents/MacOS/OldApp"),
        expected: .killable),
    PolicyCase(
        name: "go run binary",
        process: F.process(1111, "/private/var/folders/xy/abc123/T/go-build4242/b001/exe/main", ppid: 702),
        expected: .killable),
]

@Suite("Safety policy")
struct SafetyPolicyTests {
    @Test("Protected", arguments: protectedCases)
    func protectedProcess(_ policyCase: PolicyCase) {
        #expect(policyCase.evaluate() == policyCase.expected)
    }

    @Test("Killable", arguments: killableCases)
    func killableProcess(_ policyCase: PolicyCase) {
        #expect(policyCase.evaluate() == policyCase.expected)
    }

    @Test func walkWithinTheLimitReachesTerminal() {
        // Same shape as the deep chain, but short enough to reach Terminal.
        let chain = deepChain.prefix(5)
        let policyCase = PolicyCase(
            name: "short chain", process: chain[chain.endIndex - 1], extraProcesses: Array(chain), expected: .killable)
        #expect(policyCase.evaluate() == .killable)
    }

    @Test func everyReasonHasText() {
        for reason in ProtectionReason.allCases {
            #expect(!reason.label.isEmpty)
            #expect(!reason.explanation.isEmpty)
        }
    }
}

@Suite("Safety environment")
struct SafetyEnvironmentTests {
    let me = SelfIdentity(uid: 501, euid: 501, pid: 1)
    let started = Date(timeIntervalSince1970: 1_000)
    var table: [Int32: RawProcess] {
        [500: F.process(500, "/Applications/Foo.app/Contents/MacOS/Foo", start: 1_000_000_000)]
    }

    @Test func keepsAppsThatMatchTheLiveProcess() {
        let app = AppInfo(pid: 500, bundleID: "com.example.foo", launchDate: started.addingTimeInterval(1), policy: .regular)
        let environment = SafetyEnvironment.make(me: me, apps: [app], table: table)
        #expect(environment.regularAppPIDs == [500])
        #expect(environment.bundleIDByPID[500] == "com.example.foo")
    }

    @Test func ignoresStaleEntries() {
        let app = AppInfo(pid: 500, launchDate: started.addingTimeInterval(-3_600), policy: .regular)
        #expect(SafetyEnvironment.make(me: me, apps: [app], table: table).regularAppPIDs.isEmpty)
    }

    @Test func ignoresAppsWithoutAProcess() {
        let app = AppInfo(pid: 777, policy: .regular)
        #expect(SafetyEnvironment.make(me: me, apps: [app], table: table).regularAppPIDs.isEmpty)
    }

    @Test func accessoryAppsAreNotRegular() {
        let app = AppInfo(pid: 500, bundleID: "com.example.menu", policy: .accessory)
        let environment = SafetyEnvironment.make(me: me, apps: [app], table: table)
        #expect(environment.regularAppPIDs.isEmpty)
        #expect(environment.bundleIDByPID[500] == "com.example.menu")
    }
}

@Suite("Path classifier")
struct PathClassifierTests {
    @Test func normalizes() {
        #expect(PathClassifier.normalize("/System/Volumes/Data/Applications/Foo.app") == "/applications/foo.app")
        #expect(PathClassifier.normalize("//usr//bin/zsh") == "/usr/bin/zsh")
        #expect(PathClassifier.normalize("relative/path") == nil)
        #expect(PathClassifier.normalize("/a/./b") == nil)
        #expect(PathClassifier.normalize("/a/../b") == nil)
    }

    @Test func recognizesAppleSystemPaths() {
        let system = [
            "/system/library/foo", "/usr/bin/zsh", "/bin/sh", "/sbin/launchd", "/library/apple/usr/libexec/x",
            "/private/var/db/x", "/system/volumes/preboot/cryptexes/app/system/applications/safari.app",
        ]
        let notSystem = [
            "/usr/local/bin/foo", "/applications/foo.app", "/opt/homebrew/bin/node", "/users/me/bin/x",
            "/private/var/folders/ab/t/go-build/exe/main", "/library/developer/commandlinetools/usr/bin/git",
        ]
        for path in system { #expect(PathClassifier.isAppleSystemPath(path), "\(path)") }
        for path in notSystem { #expect(!PathClassifier.isAppleSystemPath(path), "\(path)") }
    }

    @Test func recognizesCoreServices() {
        #expect(PathClassifier.isCoreServices("/system/library/coreservices/dock.app/contents/macos/dock"))
        #expect(PathClassifier.isCoreServices("/library/apple/system/library/coreservices/xprotect.app/x"))
        #expect(!PathClassifier.isCoreServices("/users/me/system/library/coreservices/fake"))
        #expect(!PathClassifier.isCoreServices("/system/applications/mail.app/contents/macos/mail"))
    }

    @Test func findsAppBundles() {
        #expect(
            PathClassifier.appBundleCandidates(
                "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
            ) == ["/Applications/Google Chrome.app"])
        #expect(
            PathClassifier.appBundleCandidates(
                "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper")
                == [
                    "/Applications/Visual Studio Code.app",
                    "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app",
                ])
        #expect(
            PathClassifier.appBundleCandidates(
                "/opt/homebrew/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python"
            ).isEmpty)
        #expect(PathClassifier.appBundleCandidates("/opt/homebrew/bin/node").isEmpty)
    }

    @Test func recognizesXPCServices() {
        #expect(PathClassifier.isXPCService("/System/Library/Frameworks/WebKit.framework/XPCServices/a.xpc/Contents/MacOS/a"))
        #expect(!PathClassifier.isXPCService("/Applications/Foo.app/Contents/MacOS/Foo"))
    }
}
