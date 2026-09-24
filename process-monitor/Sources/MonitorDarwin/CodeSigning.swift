import Foundation
import MonitorCore
import Security

/// Asks the Security framework whether a running process is part of macOS
/// (`kSecCodeStatusPlatform`: "ships with the operating system and is signed by Apple").
/// Answers are cached per process, because the check costs about a millisecond.
public final class CodeSigningInspector: @unchecked Sendable {
    private struct Entry {
        var path: String
        var isPlatform: Bool
    }

    /// `kSecCodeStatusPlatform` from SecCode.h.
    static let platformStatus: UInt32 = 0x0400_0000

    private let cache = Locked<[ProcessKey: Entry]>([:])

    public init() {}

    /// nil when macOS wouldn't say.
    public func isPlatform(key: ProcessKey, path: String) -> Bool? {
        if let cached = cache.withValue({ $0[key] }), cached.path == path { return cached.isPlatform }
        guard let isPlatform = Self.checkPlatform(pid: key.pid) else { return nil }
        cache.withValue { $0[key] = Entry(path: path, isPlatform: isPlatform) }
        return isPlatform
    }

    func prune(keeping keys: Set<ProcessKey>) {
        cache.withValue { cache in cache = cache.filter { keys.contains($0.key) } }
    }

    static func checkPlatform(pid: pid_t) -> Bool? {
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess, let code else {
            return nil
        }
        // SecCodeCopySigningInformation accepts a running (dynamic) code object where it
        // asks for a static one; the dynamic flag is what brings back the status bits.
        let staticCode = unsafeBitCast(code, to: SecStaticCode.self)
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSDynamicInformation | kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
            let dictionary = information as NSDictionary?,
            let status = dictionary[kSecCodeInfoStatus as String] as? NSNumber
        else { return nil }
        return status.uint32Value & platformStatus != 0
    }
}
