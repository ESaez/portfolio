import Testing
@testable import MonitorCore

private func procArgs(argc: Int32, _ strings: [String]) -> [UInt8] {
    var bytes = withUnsafeBytes(of: argc.littleEndian) { Array($0) }
    for string in strings {
        bytes += Array(string.utf8)
        bytes.append(0)
    }
    return bytes
}

@Suite("Parsers")
struct ParsersTests {
    @Test func readsArgumentsAfterTheExecutablePath() {
        let bytes = procArgs(argc: 3, ["/opt/homebrew/bin/node", "", "", "node", "/app/node_modules/.bin/vite", "--port", "PATH=/usr/bin"])
        #expect(ProcArgsParser.arguments(from: bytes) == ["node", "/app/node_modules/.bin/vite", "--port"])
    }

    @Test func stopsAtTheEndOfATruncatedBuffer() {
        let bytes = procArgs(argc: 5, ["/usr/bin/python3", "python3", "script.py"])
        #expect(ProcArgsParser.arguments(from: bytes) == ["python3", "script.py"])
    }

    @Test func rejectsGarbage() {
        #expect(ProcArgsParser.arguments(from: [1, 2]) == nil)
        #expect(ProcArgsParser.arguments(from: procArgs(argc: 0, ["/bin/zsh"])) == nil)
        #expect(ProcArgsParser.arguments(from: procArgs(argc: -1, ["/bin/zsh"])) == nil)
    }

    @Test func buildsInterpreterHints() {
        #expect(InterpreterHint.hint(for: ["node", "/Users/me/app/node_modules/.bin/vite"]) == "vite")
        #expect(InterpreterHint.hint(for: ["/opt/homebrew/bin/node", "/opt/homebrew/bin/npm", "run", "dev"]) == "npm run dev")
        #expect(InterpreterHint.hint(for: ["python3", "-m", "http.server", "8000"]) == "http.server")
        #expect(InterpreterHint.hint(for: ["python3.12", "-u", "manage.py", "runserver"]) == "manage.py")
        #expect(InterpreterHint.hint(for: ["node", "--inspect=9229", "server.js"]) == "server.js")
        #expect(InterpreterHint.hint(for: ["node", "-r", "ts-node/register", "src/index.ts"]) == "index.ts")
        #expect(InterpreterHint.hint(for: ["java", "-jar", "/opt/app/server.jar"]) == "server.jar")
        #expect(InterpreterHint.hint(for: ["bun", "run", "dev"]) == "run dev")
    }

    @Test func givesNoHintWhenThereIsNothingUseful() {
        #expect(InterpreterHint.hint(for: ["python3", "-c", "print('secret')"]) == nil)
        #expect(InterpreterHint.hint(for: ["zsh", "script.sh"]) == nil)
        #expect(InterpreterHint.hint(for: ["node"]) == nil)
        #expect(InterpreterHint.hint(for: []) == nil)
    }

    @Test func clipsLongHints() {
        let hint = InterpreterHint.hint(for: ["node", String(repeating: "a", count: 80) + ".js"])
        #expect(hint?.count == 40)
        #expect(hint?.hasSuffix("…") == true)
    }

    @Test func parsesPSOutput() {
        let output = "  123  12.5  2048\n    1   0.0   100\ngarbage line\n   77  3,5  10\n  88  -1  5\n"
        let usage = PSOutputParser.parse(output)
        #expect(usage[123] == ApproxUsage(cpuPercent: 12.5, rssBytes: 2048 * 1024))
        #expect(usage[1] == ApproxUsage(cpuPercent: 0, rssBytes: 100 * 1024))
        #expect(usage[77] == ApproxUsage(cpuPercent: 3.5, rssBytes: 10 * 1024))
        #expect(usage[88] == nil)
        #expect(usage.count == 3)
    }

    @Test func readsThePIDOfAGPUClient() {
        #expect(GPUPropertyParser.pid(fromCreator: "pid 123, Safari") == 123)
        #expect(GPUPropertyParser.pid(fromCreator: "pid 0, kernel_task") == 0)
        #expect(GPUPropertyParser.pid(fromCreator: "Safari") == nil)
        #expect(GPUPropertyParser.pid(fromCreator: "pid , x") == nil)
        #expect(GPUPropertyParser.pid(fromCreator: "pid -5, x") == nil)
    }

    @Test func readsAppleSiliconGPUTime() {
        let usage: [[String: Any]] = [
            ["API": "Metal", "accumulatedGPUTime": 1_000],
            ["API": "Metal", "accumulatedGPUTime": 500],
        ]
        let properties: [String: Any] = ["IOUserClientCreator": "pid 42, Game", "AppUsage": usage]
        #expect(GPUPropertyParser.accumulatedGPUTime(from: properties) == 1_500)
    }

    @Test func prefersTheIntelKeyOnTheClient() {
        let properties: [String: Any] = ["accumulatedGPUTime": 42, "AppUsage": [["accumulatedGPUTime": 9_999]]]
        #expect(GPUPropertyParser.accumulatedGPUTime(from: properties) == 42)
    }

    @Test func ignoresMissingOrWrongGPUKeys() {
        #expect(GPUPropertyParser.accumulatedGPUTime(from: [:]) == nil)
        #expect(GPUPropertyParser.accumulatedGPUTime(from: ["AppUsage": "nope"]) == nil)
        #expect(GPUPropertyParser.accumulatedGPUTime(from: ["AppUsage": [["API": "Metal"]]]) == nil)
        #expect(GPUPropertyParser.accumulatedGPUTime(from: ["accumulatedGPUTime": -3]) == nil)
    }

    @Test func readsDeviceUtilization() {
        #expect(GPUPropertyParser.deviceUtilization(from: ["Device Utilization %": 37]) == 37)
        #expect(GPUPropertyParser.deviceUtilization(from: ["GPU Activity(%)": 120]) == 100)
        #expect(GPUPropertyParser.deviceUtilization(from: [:]) == nil)
    }
}

@Suite("Formatting")
struct FormatTests {
    @Test func percentages() {
        #expect(Format.percent(nil) == "—")
        #expect(Format.percent(12.34) == "12.3%")
        #expect(Format.percent(0) == "0.0%")
        #expect(Format.percent(99.97) == "100%")
        #expect(Format.percent(250) == "250%")
        #expect(Format.percent(12.34, approximate: true) == "≈ 12.3%")
    }

    @Test func bytes() {
        let gib: UInt64 = 1_073_741_824
        #expect(Format.bytes(nil) == "—")
        #expect(Format.bytes(512) == "512 bytes")
        #expect(Format.bytes(2_048) == "2 KB")
        #expect(Format.bytes(420 * 1_048_576) == "420 MB")
        #expect(Format.bytes(gib + gib * 9 / 10) == "1.9 GB")
        #expect(Format.bytes(150 * gib) == "150 GB")
        #expect(Format.bytes(2_048, approximate: true) == "≈ 2 KB")
    }

    @Test func memoryAndCounts() {
        let gib: UInt64 = 1_073_741_824
        #expect(Format.memoryUsage(used: 11 * gib + gib / 5, total: 16 * gib) == "11.2 / 16 GB")
        #expect(Format.processCount(1) == "1 process")
        #expect(Format.processCount(23) == "23 processes")
    }
}
