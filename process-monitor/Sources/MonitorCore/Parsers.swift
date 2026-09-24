import Foundation

/// Parses the `KERN_PROCARGS2` buffer: argc (Int32), the executable path, padding,
/// then argc NUL-terminated arguments (followed by the environment, which is ignored).
public enum ProcArgsParser {
    public static func arguments(from bytes: [UInt8]) -> [String]? {
        guard bytes.count >= 4 else { return nil }
        let argc = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        guard argc > 0, argc < 65_536 else { return nil }

        var index = 4
        while index < bytes.count, bytes[index] != 0 { index += 1 }  // executable path
        while index < bytes.count, bytes[index] == 0 { index += 1 }  // padding

        var arguments: [String] = []
        while arguments.count < argc, index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.isEmpty ? nil : arguments
    }
}

/// Builds a short hint such as "vite" or "npm run dev" for interpreter processes, so
/// several `node` rows can be told apart. Only basenames are used: full arguments can
/// contain tokens or passwords and are never shown.
public enum InterpreterHint {
    static let interpreters: Set<String> = ["node", "ruby", "java", "bun", "deno", "perl", "php"]
    static let runners: Set<String> = ["npm", "npx", "pnpm", "yarn", "bunx", "run", "x", "exec"]
    static let flagsWithValue: Set<String> = [
        "-r", "--require", "--loader", "--import", "--env-file", "-W", "-X", "-cp", "-classpath", "--class-path", "-I",
    ]
    static let maximumLength = 40

    public static func hint(for arguments: [String]) -> String? {
        guard let first = arguments.first else { return nil }
        let executable = PathClassifier.basename(first).lowercased()
        guard interpreters.contains(executable) || executable.hasPrefix("python") else { return nil }

        var words: [String] = []
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "-m" || argument == "-jar" {
                // python -m module, java -jar app.jar: the value is the hint.
                guard index < arguments.count else { return nil }
                return clip(PathClassifier.basename(arguments[index]))
            }
            if argument == "-e" || argument == "-c" { return nil }  // inline code: nothing useful to show
            if argument.hasPrefix("-") {
                if flagsWithValue.contains(argument) { index += 1 }
                continue
            }
            let word = PathClassifier.basename(argument)
            words.append(word)
            // "npm run dev", "bun run build": keep a couple of words after a runner.
            if !runners.contains(word.lowercased()) || words.count == 3 { break }
        }
        guard !words.isEmpty else { return nil }
        return clip(words.joined(separator: " "))
    }

    static func clip(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > maximumLength ? String(trimmed.prefix(maximumLength - 1)) + "…" : trimmed
    }
}

/// Parses `ps -axo pid=,pcpu=,rss=` output (RSS in KiB).
public enum PSOutputParser {
    public static func parse(_ output: String) -> [Int32: ApproxUsage] {
        var result: [Int32: ApproxUsage] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 3,
                let pid = Int32(fields[0]),
                let cpu = Double(fields[1].replacingOccurrences(of: ",", with: ".")),
                let rssKiB = UInt64(fields[2]),
                cpu >= 0
            else { continue }
            result[pid] = ApproxUsage(cpuPercent: cpu, rssBytes: rssKiB * 1024)
        }
        return result
    }
}

/// Parses the GPU driver's IORegistry properties. The keys are undocumented and have
/// changed between macOS versions, so everything here is defensive.
public enum GPUPropertyParser {
    /// "pid 123, Safari" → 123. The name part is cut to 16 characters by the kernel,
    /// so only the pid is used.
    public static func pid(fromCreator creator: String) -> Int32? {
        let trimmed = creator.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("pid ") else { return nil }
        let digits = trimmed.dropFirst(4).prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, let pid = Int32(digits), pid >= 0 else { return nil }
        return pid
    }

    /// GPU time of one user client in nanoseconds. Intel drivers put `accumulatedGPUTime`
    /// on the client itself; Apple Silicon has an `AppUsage` array with one entry per API.
    public static func accumulatedGPUTime(from properties: [String: Any]) -> UInt64? {
        if let direct = unsigned(properties["accumulatedGPUTime"]) { return direct }
        guard let usage = properties["AppUsage"] as? [Any] else { return nil }
        var total: UInt64 = 0
        var found = false
        for entry in usage {
            guard let dictionary = entry as? [String: Any], let value = unsigned(dictionary["accumulatedGPUTime"]) else {
                continue
            }
            total &+= value
            found = true
        }
        return found ? total : nil
    }

    /// Whole-GPU utilization in percent from the accelerator's `PerformanceStatistics`.
    public static func deviceUtilization(from statistics: [String: Any]) -> Double? {
        for key in ["Device Utilization %", "GPU Activity(%)"] {
            if let value = double(statistics[key]) { return min(max(value, 0), 100) }
        }
        return nil
    }

    static func unsigned(_ value: Any?) -> UInt64? {
        switch value {
        case let number as UInt64: return number
        case let number as Int: return number >= 0 ? UInt64(number) : nil
        case let number as Int64: return number >= 0 ? UInt64(number) : nil
        case let number as UInt32: return UInt64(number)
        case let number as Double: return number >= 0 && number.isFinite ? UInt64(number) : nil
        default: return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: return number.isFinite ? number : nil
        case let number as Int: return Double(number)
        case let number as Int64: return Double(number)
        case let number as UInt64: return Double(number)
        default: return nil
        }
    }
}
