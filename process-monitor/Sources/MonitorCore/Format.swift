import Foundation

/// Text formatting shared by the list, the summary strip and the menu.
public enum Format {
    public static let missing = "—"

    /// "12.3%", "250%", "—". Values from `ps` get a "≈" prefix.
    public static func percent(_ value: Double?, approximate: Bool = false) -> String {
        guard let value, value.isFinite else { return missing }
        let text = value >= 99.95 ? "\(Int(value.rounded()))%" : String(format: "%.1f%%", max(value, 0))
        return approximate ? "≈ " + text : text
    }

    /// "812 KB", "420 MB", "1.9 GB" (binary units, as Activity Monitor uses).
    public static func bytes(_ value: UInt64?, approximate: Bool = false) -> String {
        guard let value else { return missing }
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var amount = Double(value)
        var unit = 0
        while amount >= 1024, unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        let number: String
        if unit == 0 {
            number = "\(value)"
        } else if unit == 1 || amount >= 100 {
            number = String(format: "%.0f", amount)
        } else {
            number = String(format: "%.1f", amount)
        }
        let text = number + " " + units[unit]
        return approximate ? "≈ " + text : text
    }

    /// "11.2 / 16 GB"
    public static func memoryUsage(used: UInt64, total: UInt64) -> String {
        let gib = 1024.0 * 1024 * 1024
        return String(format: "%.1f / %.0f GB", Double(used) / gib, Double(total) / gib)
    }

    public static func processCount(_ count: Int) -> String {
        count == 1 ? "1 process" : "\(count) processes"
    }
}
