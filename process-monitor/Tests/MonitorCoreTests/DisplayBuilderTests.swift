import Testing
@testable import MonitorCore

private let gib: UInt64 = 1_073_741_824

/// Four rows: an app with two helpers, a node process, WindowServer (protected) and
/// Safari with a protected web content helper.
private func sampleSnapshot(nodeCPU: Double = 80) -> Snapshot {
    let alphaMain = Make.stats(Make.process(10, "/Applications/Alpha.app/Contents/MacOS/Alpha"), name: "Alpha", cpu: 30, memory: 2 * gib)
    let alphaHelper = Make.stats(
        Make.process(11, "/Applications/Alpha.app/Contents/Frameworks/Alpha Helper.app/Contents/MacOS/Alpha Helper"),
        name: "Alpha Helper", cpu: 20, memory: gib)
    let alpha = ProcessGroup(
        id: .app(bundlePath: "/applications/alpha.app", uid: 501), name: "Alpha", bundlePath: "/Applications/Alpha.app",
        bundleID: "com.example.alpha", uid: 501, members: [alphaMain, alphaHelper], leaders: [alphaMain.id],
        cpuPercent: 50, memoryBytes: 3 * gib, quitAbility: .killable)

    let node = Make.stats(Make.process(20, "/opt/homebrew/bin/node", hint: "vite"), name: "node (vite)", cpu: nodeCPU, memory: gib / 2, gpu: 10)
    let nodeGroup = ProcessGroup(
        id: .process(node.id), name: node.name, uid: 501, members: [node], cpuPercent: nodeCPU, memoryBytes: gib / 2,
        gpuPercent: 10, hasGPUClient: true, quitAbility: .killable)

    let windowServer = Make.stats(
        Make.process(30, "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", uid: 88),
        name: "WindowServer", safety: .protected(.otherUser), cpu: 20, gpu: 40)
    let windowServerGroup = ProcessGroup(
        id: .process(windowServer.id), name: "WindowServer", uid: 88, members: [windowServer], cpuPercent: 20,
        gpuPercent: 40, hasGPUClient: true, quitAbility: .protected(.otherUser))

    let safariMain = Make.stats(Make.process(40, "/Applications/Safari.app/Contents/MacOS/Safari"), name: "Safari", cpu: 1)
    let webContent = Make.stats(
        Make.process(41, "/System/Library/Frameworks/WebKit.framework/XPCServices/w.xpc/Contents/MacOS/w"),
        name: "Safari Web Content", safety: .protected(.systemProcess), cpu: 4)
    let safari = ProcessGroup(
        id: .app(bundlePath: "/applications/safari.app", uid: 501), name: "Safari", bundlePath: "/Applications/Safari.app",
        uid: 501, members: [safariMain, webContent], leaders: [safariMain.id], cpuPercent: 5, quitAbility: .killable)

    return Make.snapshot([alpha, nodeGroup, windowServerGroup, safari])
}

private func rows(_ snapshot: Snapshot, _ options: ViewOptions) -> [DisplayRow] {
    var freezer = OrderFreezer()
    return DisplayBuilder.rows(snapshot, options: options, freezer: &freezer)
}

@Suite("List building")
struct DisplayBuilderTests {
    @Test func myProcessesHidesWhatCantBeQuit() {
        let titles = rows(sampleSnapshot(), ViewOptions(metric: .cpu, scope: .mine)).map(\.title)
        #expect(titles == ["node (vite)", "Alpha", "Safari"])
    }

    @Test func allProcessesShowsLockedRows() {
        let list = rows(sampleSnapshot(), ViewOptions(metric: .cpu, scope: .all))
        #expect(list.map(\.title) == ["node (vite)", "Alpha", "WindowServer", "Safari"])
        #expect(list[2].action == .locked(.otherUser))
        #expect(list[0].action == .quit(.process(ProcessKey(pid: 20, startMicros: 20))))
        #expect(list[1].action == .quit(.group(.app(bundlePath: "/applications/alpha.app", uid: 501))))
        #expect(list[1].subtitle == "2 processes")
        #expect(list[0].subtitle == "PID 20")
    }

    @Test func gpuTabOnlyListsGPUUsers() {
        let list = rows(sampleSnapshot(), ViewOptions(metric: .gpu, scope: .all))
        #expect(list.map(\.title) == ["WindowServer", "node (vite)"])
        #expect(list[0].valueText == "40.0%")
    }

    @Test func memoryTabSortsByMemory() {
        let list = rows(sampleSnapshot(), ViewOptions(metric: .memory, scope: .mine))
        #expect(list.map(\.title) == ["Alpha", "node (vite)", "Safari"])
        #expect(list[0].valueText == "3.0 GB")
        #expect(list[2].valueText == "—")
    }

    @Test func barsNeverScaleBelowTheFloor() {
        let cpu = rows(sampleSnapshot(), ViewOptions(metric: .cpu, scope: .mine))
        #expect(cpu[0].barFraction == 0.8)  // 80% against a floor of 100%
        #expect(cpu[1].barFraction == 0.5)

        let busy = rows(sampleSnapshot(nodeCPU: 400), ViewOptions(metric: .cpu, scope: .mine))
        #expect(busy[0].barFraction == 1)
        #expect(busy[1].barFraction == 0.125)

        // Memory: 16 GB machine, so the floor is 1.6 GB and Alpha's 3 GB is the top.
        let memory = rows(sampleSnapshot(), ViewOptions(metric: .memory, scope: .mine))
        #expect(memory[0].barFraction == 1)
    }

    @Test func expandedAppsShowTheirMembers() {
        let alphaID = GroupID.app(bundlePath: "/applications/alpha.app", uid: 501)
        let safariID = GroupID.app(bundlePath: "/applications/safari.app", uid: 501)
        let list = rows(sampleSnapshot(), ViewOptions(metric: .cpu, scope: .mine, expanded: [alphaID, safariID]))
        #expect(list.map(\.title) == ["node (vite)", "Alpha", "Alpha", "Alpha Helper", "Safari", "Safari Web Content", "Safari"])
        #expect(list[1].isExpanded == true)
        #expect(list[2].depth == 1)
        #expect(list[5].action == .partOf(app: "Safari"))
        #expect(list[6].action == .quit(.process(ProcessKey(pid: 40, startMicros: 40))))
    }

    @Test func searchFindsAppsAndHints() {
        #expect(rows(sampleSnapshot(), ViewOptions(scope: .all, search: "vite")).map(\.title) == ["node (vite)"])
        #expect(rows(sampleSnapshot(), ViewOptions(scope: .all, search: "COM.EXAMPLE")).map(\.title) == ["Alpha"])
        #expect(rows(sampleSnapshot(), ViewOptions(scope: .all, search: "zzz")).isEmpty)
    }

    @Test func searchingForAHelperOpensItsApp() {
        let list = rows(sampleSnapshot(), ViewOptions(scope: .mine, search: "helper"))
        #expect(list.map(\.title) == ["Alpha", "Alpha Helper"])
        #expect(list[0].isExpanded == true)
    }

    @Test func searchMatchesPIDPrefixes() {
        let list = rows(sampleSnapshot(), ViewOptions(scope: .all, search: "3"))
        #expect(list.map(\.title) == ["WindowServer"])
    }

    @Test func menuShowsTheTopQuittableRows() {
        var freezer = OrderFreezer()
        let menu = DisplayBuilder.menuRows(sampleSnapshot(), metric: .cpu, limit: 2, freezer: &freezer)
        #expect(menu.map(\.title) == ["node (vite)", "Alpha"])
    }
}

@Suite("Frozen order")
struct OrderFreezerTests {
    @Test func orderHoldsWhileValuesChange() {
        var freezer = OrderFreezer()
        let options = ViewOptions(metric: .cpu, scope: .mine)
        let before = DisplayBuilder.rows(sampleSnapshot(nodeCPU: 80), options: options, freezer: &freezer)
        #expect(before.map(\.title) == ["node (vite)", "Alpha", "Safari"])

        freezer.freeze(current: before)
        let after = DisplayBuilder.rows(sampleSnapshot(nodeCPU: 1), options: options, freezer: &freezer)
        #expect(after.map(\.title) == ["node (vite)", "Alpha", "Safari"])
        #expect(after[0].valueText == "1.0%")

        freezer.unfreeze()
        let thawed = DisplayBuilder.rows(sampleSnapshot(nodeCPU: 1), options: options, freezer: &freezer)
        #expect(thawed.map(\.title) == ["Alpha", "Safari", "node (vite)"])
    }

    @Test func endedRowsStayAndNewRowsGoLast() {
        var freezer = OrderFreezer()
        let options = ViewOptions(metric: .cpu, scope: .mine)
        let snapshot = sampleSnapshot()
        freezer.freeze(current: DisplayBuilder.rows(snapshot, options: options, freezer: &freezer))

        var changed = snapshot
        changed.groups.removeAll { $0.name == "node (vite)" }
        let newcomer = Make.stats(Make.process(50, "/opt/homebrew/bin/ruby"), name: "ruby", cpu: 99)
        changed.groups.append(
            ProcessGroup(id: .process(newcomer.id), name: "ruby", uid: 501, members: [newcomer], cpuPercent: 99, quitAbility: .killable))

        let list = DisplayBuilder.rows(changed, options: options, freezer: &freezer)
        #expect(list.map(\.title) == ["node (vite)", "Alpha", "Safari", "ruby"])
        #expect(list[0].action == .ended)
        #expect(list[0].valueText == "")
        #expect(list[3].action == .quit(.process(newcomer.id)))
    }
}

@Suite("Refresh schedule")
struct SchedulePolicyTests {
    @Test func visibleWindowUsesTheChosenInterval() {
        let plan = SchedulePolicy.plan(windowVisible: true, menuVisible: false, scope: .all, interval: 2, cpuInMenuBar: false)
        #expect(plan == SchedulePlan(interval: 2, options: SampleOptions(includeProcesses: true, includeFallback: true)))
    }

    @Test func menuOnlyNeverRunsPS() {
        let plan = SchedulePolicy.plan(windowVisible: false, menuVisible: true, scope: .all, interval: 1, cpuInMenuBar: false)
        #expect(plan?.options.includeFallback == false)
        #expect(plan?.interval == 1)
    }

    @Test func hiddenAppPausesOrReadsTotalsOnly() {
        #expect(SchedulePolicy.plan(windowVisible: false, menuVisible: false, scope: .mine, interval: 2, cpuInMenuBar: false) == nil)
        let plan = SchedulePolicy.plan(windowVisible: false, menuVisible: false, scope: .mine, interval: 2, cpuInMenuBar: true)
        #expect(plan == SchedulePlan(interval: 10, options: SampleOptions(includeProcesses: false)))
    }
}
