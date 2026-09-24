import Testing
@testable import MonitorCore

private let second: UInt64 = 1_000_000_000
private let gib: UInt64 = 1_073_741_824
private let chromeMain = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
private let chromeHelper =
    "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"

private struct Setup {
    let world: FakeWorld
    let system: FakeSystemStats
    let gpu: FakeGPU
    let sampler: Sampler
}

private func makeSetup(me: SelfIdentity = SelfIdentity(uid: 501, euid: 501, pid: 4242), fallback: [Int32: ApproxUsage] = [:]) -> Setup {
    let processes = Make.session + [
        Make.process(100, chromeMain, cpuNs: 0, footprint: gib),
        Make.process(101, chromeHelper, ppid: 100, cpuNs: 0, footprint: gib / 2),
        Make.process(200, "/opt/homebrew/bin/node", ppid: 702, cpuNs: 0, footprint: 1_000, hint: "vite"),
        Make.process(300, "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", uid: 88),
    ]
    let apps = [
        Make.terminalApp,
        AppInfo(pid: 100, bundleID: "com.google.Chrome", name: "Google Chrome", bundlePath: "/Applications/Google Chrome.app", policy: .regular),
    ]
    let world = FakeWorld(me: me, processes: processes, apps: apps)
    let system = FakeSystemStats(
        SystemReading(
            cpu: CPUTicks(user: 0, system: 0, idle: 0, nice: 0),
            memory: MemoryReading(totalBytes: 16 * gib, usedBytes: 8 * gib, pressure: .normal),
            logicalCPUs: 8))
    let gpu = FakeGPU(GPUReading(clients: [GPUClientSample(registryID: 1, pid: 300, accumulatedNs: 0)], deviceUtilization: 12))
    let sampler = Sampler(
        me: me, processes: world, gpu: gpu, system: system, apps: world, fallback: FakeFallback(values: fallback), clock: world)
    return Setup(world: world, system: system, gpu: gpu, sampler: sampler)
}

/// Advances time by two seconds, during which Chrome used one second of CPU, its helper
/// half a second, node two seconds, and WindowServer half a second of GPU time.
private func runTwoSeconds(_ setup: Setup) {
    setup.world.advance(seconds: 2)
    setup.world.update(100) { $0.cpuTimeNs = second }
    setup.world.update(101) { $0.cpuTimeNs = second / 2 }
    setup.world.update(200) { $0.cpuTimeNs = 2 * second }
    setup.system.reading.withValue { $0.cpu = CPUTicks(user: 30, system: 10, idle: 60, nice: 0) }
    setup.gpu.reading.withValue { $0.clients = [GPUClientSample(registryID: 1, pid: 300, accumulatedNs: second / 2)] }
}

@Suite("Sampler")
struct SamplerTests {
    @Test func firstSampleHasNoRatesYet() async {
        let setup = makeSetup()
        let snapshot = await setup.sampler.sample()
        #expect(snapshot.includesProcesses)
        #expect(snapshot.totals.cpuPercent == nil)
        #expect(snapshot.totals.gpuPercent == 12)
        #expect(snapshot.totals.memory?.usedBytes == 8 * gib)
        let chrome = snapshot.groups.first { $0.name == "Google Chrome" }
        #expect(chrome?.cpuPercent == nil)
        #expect(chrome?.memoryBytes == gib + gib / 2)
    }

    @Test func secondSampleHasRatesGroupsAndVerdicts() async throws {
        let setup = makeSetup()
        _ = await setup.sampler.sample()
        runTwoSeconds(setup)
        let snapshot = await setup.sampler.sample()

        #expect(snapshot.totals.cpuPercent == 40)
        let chrome = try #require(snapshot.groups.first { $0.name == "Google Chrome" })
        #expect(chrome.members.count == 2)
        #expect(chrome.cpuPercent == 75)
        #expect(chrome.quitAbility == .killable)

        let node = try #require(snapshot.groups.first { $0.name == "node (vite)" })
        #expect(node.cpuPercent == 100)
        #expect(node.quitAbility == .killable)

        let windowServer = try #require(snapshot.groups.first { $0.name == "WindowServer" })
        #expect(windowServer.quitAbility == .protected(.otherUser))
        #expect(windowServer.cpuPercent == nil)
        #expect(windowServer.gpuPercent == 25)
        #expect(windowServer.hasGPUClient)

        let terminal = try #require(snapshot.groups.first { $0.name == "Terminal" })
        #expect(terminal.quitAbility == .killable)
        let zsh = try #require(snapshot.groups.first { $0.name == "zsh" })
        #expect(zsh.quitAbility == .killable)
    }

    @Test func otherUsersGetApproximateNumbersOnlyWhenAsked() async throws {
        let setup = makeSetup(fallback: [300: ApproxUsage(cpuPercent: 7.5, rssBytes: 600)])
        let plain = await setup.sampler.sample(SampleOptions(includeFallback: false))
        #expect(plain.groups.first { $0.name == "WindowServer" }?.cpuPercent == nil)

        let withFallback = await setup.sampler.sample(SampleOptions(includeFallback: true))
        let windowServer = try #require(withFallback.groups.first { $0.name == "WindowServer" })
        #expect(windowServer.cpuPercent == 7.5)
        #expect(windowServer.memoryBytes == 600)
        #expect(windowServer.isApproximate)
    }

    @Test func totalsOnlyRefreshSkipsProcesses() async {
        let setup = makeSetup()
        let snapshot = await setup.sampler.sample(SampleOptions(includeProcesses: false))
        #expect(!snapshot.includesProcesses)
        #expect(snapshot.groups.isEmpty)
        #expect(snapshot.totals.logicalCPUs == 8)
    }

    @Test func underRosettaCPUIsNotShown() async {
        let setup = makeSetup(me: SelfIdentity(uid: 501, euid: 501, pid: 4242, isTranslated: true))
        _ = await setup.sampler.sample()
        runTwoSeconds(setup)
        let snapshot = await setup.sampler.sample()
        #expect(snapshot.groups.first { $0.name == "node (vite)" }?.cpuPercent == nil)
    }

    @Test func validationContextSeesTheLiveTable() async {
        let setup = makeSetup()
        setup.world.add(Make.process(400, "/opt/homebrew/bin/ruby"))
        let context = await setup.sampler.validationContext()
        #expect(context.table[400] != nil)
        #expect(context.env.regularAppPIDs == [100, 700])
    }
}
