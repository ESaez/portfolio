import Testing
@testable import MonitorCore

private let chromeMain = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
private let chromeHelper =
    "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/140/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
private let chromeGPUHelper =
    "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/140/Helpers/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)"
private let safariPath = "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari"
private let webContent =
    "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"

private func table(_ stats: [ProcessStats]) -> [Int32: RawProcess] {
    Dictionary(uniqueKeysWithValues: stats.map { ($0.raw.pid, $0.raw) })
}

private func group(
    _ stats: [ProcessStats], apps: [AppInfo] = [], responsibility: (any ResponsibilitySource)? = nil
) -> [ProcessGroup] {
    Grouper.group(stats, table: table(stats), apps: apps, responsibility: responsibility)
}

@Suite("Grouping")
struct GrouperTests {
    @Test func chromeAndItsHelpersAreOneApp() {
        let stats = [
            Make.stats(Make.process(100, chromeMain), cpu: 10, memory: 100),
            Make.stats(Make.process(101, chromeHelper, ppid: 100), cpu: 30, memory: 300, gpu: 2),
            Make.stats(Make.process(102, chromeGPUHelper, ppid: 100), cpu: nil, memory: 50, gpu: 8),
        ]
        let apps = [AppInfo(pid: 100, bundleID: "com.google.Chrome", name: "Google Chrome", bundlePath: "/Applications/Google Chrome.app", policy: .regular)]
        let groups = group(stats, apps: apps)
        #expect(groups.count == 1)
        let chrome = groups[0]
        #expect(chrome.id == .app(bundlePath: "/applications/google chrome.app", uid: 501))
        #expect(chrome.name == "Google Chrome")
        #expect(chrome.bundleID == "com.google.Chrome")
        #expect(chrome.bundlePath == "/Applications/Google Chrome.app")
        #expect(chrome.members.map(\.raw.pid) == [100, 101, 102])
        #expect(chrome.leaders == [ProcessKey(pid: 100, startMicros: 100)])
        #expect(chrome.cpuPercent == 40)
        #expect(chrome.memoryBytes == 450)
        #expect(chrome.gpuPercent == 10)
        #expect(chrome.hasGPUClient)
        #expect(chrome.quitAbility == .killable)
    }

    @Test func nestedHelperAppsGoToTheOutermostApp() {
        let stats = [
            Make.stats(Make.process(200, "/Applications/Visual Studio Code.app/Contents/MacOS/Electron")),
            Make.stats(
                Make.process(
                    201, "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)")),
        ]
        let groups = group(stats)
        #expect(groups.count == 1)
        #expect(groups[0].name == "Visual Studio Code")
        #expect(groups[0].leaders.map(\.pid) == [200])
    }

    @Test func aRunningAppInsideAnotherAppGetsItsOwnRow() {
        let simulatorBundle = "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app"
        let stats = [
            Make.stats(Make.process(300, "/Applications/Xcode.app/Contents/MacOS/Xcode")),
            Make.stats(Make.process(301, simulatorBundle + "/Contents/MacOS/Simulator")),
        ]
        let apps = [
            AppInfo(pid: 300, name: "Xcode", bundlePath: "/Applications/Xcode.app", policy: .regular),
            AppInfo(pid: 301, name: "Simulator", bundlePath: simulatorBundle, policy: .regular),
        ]
        let groups = group(stats, apps: apps)
        #expect(groups.map(\.name) == ["Xcode", "Simulator"])
        #expect(groups[1].leaders.map(\.pid) == [301])
    }

    @Test func homebrewPythonIsNotAnApp() {
        let path = "/opt/homebrew/Cellar/python@3.12/3.12.4/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python"
        let groups = group([Make.stats(Make.process(400, path))])
        #expect(groups.count == 1)
        #expect(groups[0].id == .process(ProcessKey(pid: 400, startMicros: 400)))
    }

    @Test func webContentJoinsSafariButStaysProtected() {
        let stats = [
            Make.stats(Make.process(500, safariPath), cpu: 5),
            Make.stats(Make.process(501, webContent), safety: .protected(.systemProcess), cpu: 20),
        ]
        let apps = [AppInfo(pid: 500, name: "Safari", bundlePath: "/Applications/Safari.app", policy: .regular)]
        let groups = group(stats, apps: apps, responsibility: FakeResponsibility(owners: [501: 500]))
        #expect(groups.count == 1)
        #expect(groups[0].name == "Safari")
        #expect(groups[0].cpuPercent == 25)
        #expect(groups[0].quitAbility == .killable)
        #expect(groups[0].leaders.map(\.pid) == [500])
    }

    @Test func implausibleResponsibilityAnswersAreIgnored() {
        let safari = Make.stats(Make.process(500, safariPath))
        // Answers: itself, an error, and an owner that started after the helper.
        for owner: Int32 in [501, -1, 600] {
            let helper = Make.stats(Make.process(501, webContent), safety: .protected(.systemProcess))
            let late = Make.stats(Make.process(600, "/Applications/Late.app/Contents/MacOS/Late", start: 9_999))
            let groups = group([safari, helper, late], responsibility: FakeResponsibility(owners: [501: owner]))
            #expect(groups.contains { $0.id == .process(helper.id) }, "owner \(owner)")
        }
    }

    @Test func toolsLaunchedFromTerminalStayOnTheirOwn() {
        let terminal = Make.stats(Make.process(700, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"))
        let zsh = Make.stats(Make.process(702, "/bin/zsh", ppid: 700))
        let groups = group([terminal, zsh], responsibility: FakeResponsibility(owners: [702: 700]))
        #expect(groups.count == 2)
    }

    @Test func theSameAppOfTwoUsersIsTwoRows() {
        let mine = Make.stats(Make.process(800, chromeMain, uid: 501))
        let theirs = Make.stats(Make.process(801, chromeMain, uid: 502), safety: .protected(.otherUser))
        let groups = group([mine, theirs])
        #expect(groups.count == 2)
        #expect(groups.map(\.quitAbility) == [.killable, .protected(.otherUser)])
    }

    @Test func appWithoutItsMainProcessCanStillBeQuit() {
        let helper = Make.stats(Make.process(900, chromeHelper))
        let groups = group([helper, Make.stats(Make.process(901, chromeGPUHelper))])
        #expect(groups.count == 1)
        #expect(groups[0].leaders.isEmpty)
        #expect(groups[0].quitAbility == .killable)
        #expect(groups[0].name == "Google Chrome")
    }

    @Test func appWithAProtectedMainProcessIsProtected() {
        let main = Make.stats(Make.process(950, chromeMain, euid: 0), safety: .protected(.elevated))
        let helper = Make.stats(Make.process(951, chromeHelper))
        let groups = group([main, helper])
        #expect(groups[0].quitAbility == .protected(.elevated))
    }

    @Test func displayNamesUseTheAppNameAndHints() {
        let node = Make.process(1000, "/opt/homebrew/bin/node", hint: "vite")
        #expect(Grouper.displayName(for: node, app: nil) == "node (vite)")
        let app = AppInfo(pid: 1001, name: "Slack", policy: .regular)
        #expect(Grouper.displayName(for: Make.process(1001, "/Applications/Slack.app/Contents/MacOS/Slack"), app: app) == "Slack")
        #expect(Grouper.displayName(for: Make.process(1002, nil), app: nil) == "?")
    }
}
