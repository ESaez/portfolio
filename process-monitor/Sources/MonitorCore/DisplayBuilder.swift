import Foundation

public enum Metric: String, Sendable, CaseIterable, Identifiable {
    case cpu, memory, gpu

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        }
    }
}

public enum Scope: String, Sendable, CaseIterable, Identifiable {
    /// Only apps and processes the user can quit.
    case mine
    /// Everything, with macOS processes locked.
    case all

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mine: "My processes"
        case .all: "All processes"
        }
    }
}

public struct ViewOptions: Sendable, Equatable {
    public var metric: Metric
    public var scope: Scope
    public var search: String
    public var expanded: Set<GroupID>

    public init(metric: Metric = .cpu, scope: Scope = .mine, search: String = "", expanded: Set<GroupID> = []) {
        self.metric = metric
        self.scope = scope
        self.search = search
        self.expanded = expanded
    }
}

public enum RowID: Hashable, Sendable {
    case group(GroupID)
    case member(ProcessKey)
}

public enum RowIcon: Hashable, Sendable {
    /// An app bundle's icon.
    case bundle(String)
    /// The icon macOS shows for an executable file.
    case executable(String)
    case generic
}

public enum QuitTarget: Hashable, Sendable {
    case process(ProcessKey)
    case group(GroupID)
}

/// What the right-hand side of a row offers.
public enum RowAction: Equatable, Sendable {
    case quit(QuitTarget)
    case locked(ProtectionReason)
    /// A protected helper of an app that can be quit as a whole.
    case partOf(app: String)
    /// The process ended while the list was frozen.
    case ended
}

public struct DisplayRow: Identifiable, Equatable, Sendable {
    public var id: RowID
    /// 0 for app and process rows, 1 for the members of an expanded app.
    public var depth: Int
    public var title: String
    public var subtitle: String
    /// nil when the row can't be expanded.
    public var isExpanded: Bool?
    public var value: Double?
    public var valueText: String
    /// Bar length, 0–1.
    public var barFraction: Double
    public var action: RowAction
    public var icon: RowIcon
    public var pid: Int32?
    public var path: String?

    public var quitTarget: QuitTarget? {
        if case .quit(let target) = action { return target }
        return nil
    }

    var sortKey: String {
        switch id {
        case .group(.app(let bundlePath, let uid)): "a\(bundlePath)|\(uid)"
        case .group(.process(let key)): "p\(key)"
        case .member(let key): "m\(key)"
        }
    }
}

/// Turns a snapshot into the rows the list shows: filtered by scope, tab and search,
/// sorted by the selected metric, with expanded apps followed by their members.
public enum DisplayBuilder {
    struct Entry: Sendable {
        var row: DisplayRow
        /// Member rows, only built for expanded groups.
        var members: [DisplayRow]
    }

    public static func rows(_ snapshot: Snapshot, options: ViewOptions, freezer: inout OrderFreezer) -> [DisplayRow] {
        let query = options.search.trimmingCharacters(in: .whitespacesAndNewlines)
        var entries: [Entry] = []

        for group in snapshot.groups {
            if options.scope == .mine && !group.hasKillableMember { continue }
            if options.metric == .gpu && !group.hasGPUClient { continue }
            var members = group.members
            var expanded = options.expanded.contains(group.id)
            if !query.isEmpty && !groupMatches(group, query) {
                members = group.members.filter { memberMatches($0, query) }
                if members.isEmpty { continue }
                expanded = expanded || group.members.count > 1
            }
            entries.append(entry(for: group, members: members, expanded: expanded, metric: options.metric))
        }

        entries.sort { rowOrdering($0.row, $1.row) }
        scaleBars(&entries, metric: options.metric, totals: snapshot.totals)
        entries = freezer.arrange(entries)
        return flatten(entries)
    }

    /// The top quittable apps and processes for the menu bar.
    public static func menuRows(_ snapshot: Snapshot, metric: Metric, limit: Int, freezer: inout OrderFreezer) -> [DisplayRow] {
        let all = rows(snapshot, options: ViewOptions(metric: metric, scope: .mine), freezer: &freezer)
        let quittable = all.filter { row in
            guard row.depth == 0 else { return false }
            switch row.action {
            case .quit, .ended: return true
            case .locked, .partOf: return false
            }
        }
        return Array(quittable.prefix(limit))
    }

    static func entry(for group: ProcessGroup, members: [ProcessStats], expanded: Bool, metric: Metric) -> Entry {
        let hasMany = group.members.count > 1
        let only = group.members.first
        let value = metricValue(group, metric)

        let action: RowAction
        switch group.quitAbility {
        case .killable:
            if case .process(let key) = group.id {
                action = .quit(.process(key))
            } else {
                action = .quit(.group(group.id))
            }
        case .protected(let reason):
            action = .locked(reason)
        }

        let icon: RowIcon
        if let bundle = group.bundlePath {
            icon = .bundle(bundle)
        } else if let path = only?.raw.path {
            icon = .executable(path)
        } else {
            icon = .generic
        }

        let row = DisplayRow(
            id: .group(group.id),
            depth: 0,
            title: group.name,
            subtitle: hasMany ? Format.processCount(group.members.count) : only.map { "PID \($0.raw.pid)" } ?? "",
            isExpanded: hasMany ? expanded : nil,
            value: value,
            valueText: text(value, metric: metric, approximate: group.isApproximate && metric != .gpu),
            barFraction: 0,
            action: action,
            icon: icon,
            pid: hasMany ? nil : only?.raw.pid,
            path: group.bundlePath ?? only?.raw.path)

        guard hasMany && expanded else { return Entry(row: row, members: []) }
        let memberRows = members.map { memberRow($0, in: group, metric: metric) }.sorted(by: rowOrdering)
        return Entry(row: row, members: memberRows)
    }

    static func memberRow(_ member: ProcessStats, in group: ProcessGroup, metric: Metric) -> DisplayRow {
        let value = metricValue(member, metric)
        let action: RowAction
        switch member.safety {
        case .killable:
            action = .quit(.process(member.id))
        case .protected(let reason):
            action = group.quitAbility.isKillable ? .partOf(app: group.name) : .locked(reason)
        }
        return DisplayRow(
            id: .member(member.id),
            depth: 1,
            title: member.name,
            subtitle: "PID \(member.raw.pid)",
            isExpanded: nil,
            value: value,
            valueText: text(value, metric: metric, approximate: member.isApproximate && metric != .gpu),
            barFraction: 0,
            action: action,
            icon: member.raw.path.map(RowIcon.executable) ?? .generic,
            pid: member.raw.pid,
            path: member.raw.path)
    }

    static func metricValue(_ group: ProcessGroup, _ metric: Metric) -> Double? {
        switch metric {
        case .cpu: group.cpuPercent
        case .memory: group.memoryBytes.map { Double($0) }
        case .gpu: group.gpuPercent
        }
    }

    static func metricValue(_ process: ProcessStats, _ metric: Metric) -> Double? {
        switch metric {
        case .cpu: process.cpuPercent
        case .memory: process.memoryBytes.map { Double($0) }
        case .gpu: process.gpuPercent
        }
    }

    static func text(_ value: Double?, metric: Metric, approximate: Bool) -> String {
        switch metric {
        case .cpu, .gpu:
            Format.percent(value, approximate: approximate)
        case .memory:
            Format.bytes(value.map { UInt64(max($0, 0)) }, approximate: approximate)
        }
    }

    /// Highest value first; rows without a value last; then by name.
    static func rowOrdering(_ lhs: DisplayRow, _ rhs: DisplayRow) -> Bool {
        switch (lhs.value, rhs.value) {
        case let (left?, right?) where left != right: return left > right
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        let leftTitle = lhs.title.lowercased()
        let rightTitle = rhs.title.lowercased()
        if leftTitle != rightTitle { return leftTitle < rightTitle }
        return lhs.sortKey < rhs.sortKey
    }

    /// Bars are relative to the biggest visible value, but never to less than a floor
    /// (one core for CPU, a full GPU, a tenth of RAM), so an idle Mac shows short bars.
    static func scaleBars(_ entries: inout [Entry], metric: Metric, totals: Totals) {
        let floor: Double
        switch metric {
        case .cpu, .gpu: floor = 100
        case .memory: floor = totals.memory.map { Double($0.totalBytes) * 0.1 } ?? 1_073_741_824
        }
        let top = entries.compactMap(\.row.value).max() ?? 0
        let scale = max(top, floor)
        func fraction(_ value: Double?) -> Double {
            guard let value, scale > 0 else { return 0 }
            return min(max(value / scale, 0), 1)
        }
        for index in entries.indices {
            entries[index].row.barFraction = fraction(entries[index].row.value)
            for memberIndex in entries[index].members.indices {
                entries[index].members[memberIndex].barFraction = fraction(entries[index].members[memberIndex].value)
            }
        }
    }

    static func flatten(_ entries: [Entry]) -> [DisplayRow] {
        var rows: [DisplayRow] = []
        rows.reserveCapacity(entries.count)
        for entry in entries {
            rows.append(entry.row)
            if entry.row.isExpanded == true { rows.append(contentsOf: entry.members) }
        }
        return rows
    }

    static func groupMatches(_ group: ProcessGroup, _ query: String) -> Bool {
        if contains(group.name, query) { return true }
        if let bundleID = group.bundleID, contains(bundleID, query) { return true }
        return false
    }

    static func memberMatches(_ member: ProcessStats, _ query: String) -> Bool {
        if contains(member.name, query) { return true }
        if query.allSatisfy({ $0.isASCII && $0.isNumber }) && String(member.raw.pid).hasPrefix(query) { return true }
        return false
    }

    static func contains(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// Keeps the list order still while the pointer is over it, so a row can't move out
/// from under a click. Values keep updating; rows that end stay as dimmed "ended" rows
/// and new rows are added at the bottom.
public struct OrderFreezer: Sendable {
    public private(set) var isFrozen = false
    private var groupOrder: [RowID] = []
    private var memberOrder: [RowID: [RowID]] = [:]
    private var lastRows: [RowID: DisplayRow] = [:]

    public init() {}

    /// Starts keeping `rows`, the rows on screen right now, in their current order.
    public mutating func freeze(current rows: [DisplayRow]) {
        guard !isFrozen else { return }
        isFrozen = true
        groupOrder = []
        memberOrder = [:]
        lastRows = [:]
        var currentGroup: RowID?
        for row in rows {
            lastRows[row.id] = row
            if row.depth == 0 {
                groupOrder.append(row.id)
                currentGroup = row.id
            } else if let group = currentGroup {
                memberOrder[group, default: []].append(row.id)
            }
        }
    }

    public mutating func unfreeze() {
        isFrozen = false
        groupOrder = []
        memberOrder = [:]
        lastRows = [:]
    }

    mutating func arrange(_ entries: [DisplayBuilder.Entry]) -> [DisplayBuilder.Entry] {
        guard isFrozen else { return entries }
        var byID: [RowID: DisplayBuilder.Entry] = [:]
        for entry in entries { byID[entry.row.id] = entry }

        var result: [DisplayBuilder.Entry] = []
        var placed = Set<RowID>()
        for id in groupOrder {
            placed.insert(id)
            if let entry = byID[id] {
                result.append(arrangeMembers(entry))
            } else if let last = lastRows[id] {
                result.append(DisplayBuilder.Entry(row: Self.ended(last), members: []))
            }
        }
        for entry in entries where !placed.contains(entry.row.id) {
            groupOrder.append(entry.row.id)
            result.append(arrangeMembers(entry))
        }

        for entry in result where entry.row.action != .ended {
            lastRows[entry.row.id] = entry.row
            for member in entry.members where member.action != .ended {
                lastRows[member.id] = member
            }
        }
        return result
    }

    private mutating func arrangeMembers(_ entry: DisplayBuilder.Entry) -> DisplayBuilder.Entry {
        guard entry.row.isExpanded == true else { return entry }
        let groupID = entry.row.id
        guard let order = memberOrder[groupID] else {
            // Expanded while frozen: keep the order it had when it opened.
            memberOrder[groupID] = entry.members.map(\.id)
            return entry
        }
        var byID: [RowID: DisplayRow] = [:]
        for member in entry.members { byID[member.id] = member }

        var members: [DisplayRow] = []
        var placed = Set<RowID>()
        var newOrder = order
        for id in order {
            placed.insert(id)
            if let member = byID[id] {
                members.append(member)
            } else if let last = lastRows[id] {
                members.append(Self.ended(last))
            }
        }
        for member in entry.members where !placed.contains(member.id) {
            members.append(member)
            newOrder.append(member.id)
        }
        memberOrder[groupID] = newOrder

        var arranged = entry
        arranged.members = members
        return arranged
    }

    static func ended(_ row: DisplayRow) -> DisplayRow {
        var row = row
        row.action = .ended
        row.value = nil
        row.valueText = ""
        row.barFraction = 0
        row.subtitle = "Ended"
        if row.isExpanded != nil { row.isExpanded = false }
        return row
    }
}

public struct SchedulePlan: Sendable, Equatable {
    public var interval: Double
    public var options: SampleOptions

    public init(interval: Double, options: SampleOptions) {
        self.interval = interval
        self.options = options
    }
}

/// Decides how often to refresh, and what, from what is on screen.
public enum SchedulePolicy {
    public static let hiddenInterval: Double = 10

    /// nil means pause.
    public static func plan(
        windowVisible: Bool, menuVisible: Bool, scope: Scope, interval: Double, cpuInMenuBar: Bool
    ) -> SchedulePlan? {
        if windowVisible {
            return SchedulePlan(interval: interval, options: SampleOptions(includeFallback: scope == .all))
        }
        if menuVisible {
            return SchedulePlan(interval: interval, options: SampleOptions())
        }
        if cpuInMenuBar {
            return SchedulePlan(interval: hiddenInterval, options: SampleOptions(includeProcesses: false))
        }
        return nil
    }
}
