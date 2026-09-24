import Testing
@testable import MonitorCore

private let second: UInt64 = 1_000_000_000

private func cpuProcess(_ pid: Int32, start: Int64 = 1, cpu: UInt64) -> RawProcess {
    Make.process(pid, "/opt/homebrew/bin/node", start: start, cpuNs: cpu)
}

@Suite("CPU and GPU rates")
struct DeltaTrackerTests {
    @Test func firstSampleHasNoValue() {
        var tracker = DeltaTracker()
        let rates = tracker.cpuPercents([cpuProcess(10, cpu: 5 * second)], nowNs: 0, maxPercent: 800)
        #expect(rates.isEmpty)
    }

    @Test func oneSecondOfCPUInTwoSecondsIsFiftyPercent() {
        var tracker = DeltaTracker()
        _ = tracker.cpuPercents([cpuProcess(10, cpu: 0)], nowNs: 0, maxPercent: 800)
        let rates = tracker.cpuPercents([cpuProcess(10, cpu: second)], nowNs: 2 * second, maxPercent: 800)
        #expect(rates[ProcessKey(pid: 10, startMicros: 1)] == 50)
    }

    @Test func multiCoreUseGoesAboveOneHundredButIsClamped() {
        var tracker = DeltaTracker()
        _ = tracker.cpuPercents([cpuProcess(10, cpu: 0)], nowNs: 0, maxPercent: 800)
        let rates = tracker.cpuPercents([cpuProcess(10, cpu: 8 * second)], nowNs: 2 * second, maxPercent: 800)
        #expect(rates[ProcessKey(pid: 10, startMicros: 1)] == 400)

        var small = DeltaTracker()
        _ = small.cpuPercents([cpuProcess(10, cpu: 0)], nowNs: 0, maxPercent: 200)
        let clamped = small.cpuPercents([cpuProcess(10, cpu: 8 * second)], nowNs: 2 * second, maxPercent: 200)
        #expect(clamped[ProcessKey(pid: 10, startMicros: 1)] == 200)
    }

    @Test func reusedPIDStartsFresh() {
        var tracker = DeltaTracker()
        _ = tracker.cpuPercents([cpuProcess(10, start: 1, cpu: 50 * second)], nowNs: 0, maxPercent: 800)
        let rates = tracker.cpuPercents([cpuProcess(10, start: 2, cpu: second)], nowNs: 2 * second, maxPercent: 800)
        #expect(rates.isEmpty)
    }

    @Test func counterGoingBackwardsReadsZero() {
        var tracker = DeltaTracker()
        _ = tracker.cpuPercents([cpuProcess(10, cpu: 10 * second)], nowNs: 0, maxPercent: 800)
        let rates = tracker.cpuPercents([cpuProcess(10, cpu: second)], nowNs: 2 * second, maxPercent: 800)
        #expect(rates[ProcessKey(pid: 10, startMicros: 1)] == 0)
    }

    @Test func samplesTooCloseTogetherReuseThePreviousRate() {
        var tracker = DeltaTracker()
        _ = tracker.cpuPercents([cpuProcess(10, cpu: 0)], nowNs: 0, maxPercent: 800)
        _ = tracker.cpuPercents([cpuProcess(10, cpu: second)], nowNs: 2 * second, maxPercent: 800)
        let rates = tracker.cpuPercents([cpuProcess(10, cpu: second + 1)], nowNs: 2 * second + 1_000, maxPercent: 800)
        #expect(rates[ProcessKey(pid: 10, startMicros: 1)] == 50)
    }

    @Test func aLongPauseStartsOver() {
        var tracker = DeltaTracker()
        _ = tracker.cpuPercents([cpuProcess(10, cpu: 0)], nowNs: 0, maxPercent: 800)
        let rates = tracker.cpuPercents([cpuProcess(10, cpu: 30 * second)], nowNs: 60 * second, maxPercent: 800)
        #expect(rates.isEmpty)
    }

    @Test func processesWithoutCountersAreSkipped() {
        var tracker = DeltaTracker()
        let other = Make.process(20, "/usr/sbin/daemon", uid: 0)
        _ = tracker.cpuPercents([other], nowNs: 0, maxPercent: 800)
        #expect(tracker.cpuPercents([other], nowNs: 2 * second, maxPercent: 800).isEmpty)
    }

    @Test func gpuClientsOfOneProcessAreSummed() {
        var tracker = DeltaTracker()
        _ = tracker.gpuPercents(
            [GPUClientSample(registryID: 1, pid: 5, accumulatedNs: 0), GPUClientSample(registryID: 2, pid: 5, accumulatedNs: 0)],
            nowNs: 0)
        let result = tracker.gpuPercents(
            [
                GPUClientSample(registryID: 1, pid: 5, accumulatedNs: second / 2),
                GPUClientSample(registryID: 2, pid: 5, accumulatedNs: second / 4),
            ],
            nowNs: second)
        #expect(result.percents[5] == 75)
        #expect(result.pidsWithClients == [5])
    }

    @Test func newGPUClientOnlySetsABaseline() {
        var tracker = DeltaTracker()
        let result = tracker.gpuPercents([GPUClientSample(registryID: 1, pid: 5, accumulatedNs: 9 * second)], nowNs: 0)
        #expect(result.percents[5] == nil)
        #expect(result.pidsWithClients.contains(5))
    }

    @Test func closedGPUClientNeverMakesTheRateNegative() {
        var tracker = DeltaTracker()
        _ = tracker.gpuPercents(
            [
                GPUClientSample(registryID: 1, pid: 5, accumulatedNs: 10 * second),
                GPUClientSample(registryID: 2, pid: 5, accumulatedNs: 0),
            ],
            nowNs: 0)
        let result = tracker.gpuPercents([GPUClientSample(registryID: 2, pid: 5, accumulatedNs: second / 10)], nowNs: second)
        #expect(result.percents[5] == 10)
    }

    @Test func machineCPUHandlesCounterWraparound() {
        var tracker = TotalsTracker()
        #expect(tracker.cpuPercent(CPUTicks(user: UInt32.max - 9, system: 0, idle: 0, nice: 0)) == nil)
        // 20 busy ticks (10 before the wrap, 10 after) and 20 idle ticks: 50%.
        #expect(tracker.cpuPercent(CPUTicks(user: 10, system: 0, idle: 20, nice: 0)) == 50)
    }

    @Test func ringBufferKeepsTheNewestElements() {
        var buffer = RingBuffer<Int>(capacity: 3)
        #expect(buffer.last == nil)
        for value in 1...5 { buffer.append(value) }
        #expect(buffer.elements == [3, 4, 5])
        #expect(buffer.last == 5)
        #expect(buffer.count == 3)
    }
}
