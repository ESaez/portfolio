import AppKit
import MonitorCore
import MonitorDarwin
import Observation

/// Where the list is shown.
enum Surface: Hashable {
    case mainWindow
    case menu
}

/// Progress of a quit the user started.
enum QuitPhase: Equatable {
    case quitting
    case forceQuitting
    /// A graceful quit timed out; the row offers Force Quit.
    case stillRunning
}

struct QuitDialog: Identifiable {
    let id = UUID()
    let request: QuitRequest
    let title: String
    let message: String
    let confirmTitle: String

    init(request: QuitRequest) {
        self.request = request
        let name = request.displayName
        let helpers = max(request.expectedPaths.count - max(request.leaders.count, 1), 0)
        var message =
            request.force
            ? "It will close immediately, and any unsaved changes will be lost."
            : "Unsaved changes may be lost if it doesn't ask to save them."
        if helpers > 0 {
            message = "This also closes \(helpers == 1 ? "1 helper process" : "\(helpers) helper processes"). " + message
        }
        self.title = request.force ? "Force quit “\(name)”?" : "Quit “\(name)”?"
        self.message = message
        self.confirmTitle = request.force ? "Force Quit" : "Quit"
    }
}

struct Toast: Identifiable, Equatable {
    enum Kind { case success, info, error }
    let id = UUID()
    let text: String
    let kind: Kind
}

/// Recent machine totals for the sparklines, as percentages.
struct TotalsHistory {
    var cpu = RingBuffer<Double>(capacity: 60)
    var memory = RingBuffer<Double>(capacity: 60)
    var gpu = RingBuffer<Double>(capacity: 60)

    mutating func append(_ totals: Totals) {
        if let value = totals.cpuPercent { cpu.append(value) }
        if let memory = totals.memory, memory.totalBytes > 0 {
            self.memory.append(Double(memory.usedBytes) / Double(memory.totalBytes) * 100)
        }
        if let value = totals.gpuPercent { gpu.append(value) }
    }
}

/// The app's state: the latest snapshot, what the user is looking at, and quits in
/// progress. It owns the refresh loop and adapts it to what is on screen.
@MainActor
@Observable
final class MonitorStore {
    private(set) var snapshot: Snapshot?
    private(set) var rows: [DisplayRow] = []
    private(set) var menuRows: [DisplayRow] = []
    private(set) var history = TotalsHistory()
    private(set) var phases: [QuitTarget: QuitPhase] = [:]
    private(set) var toasts: [Toast] = []
    var selection: RowID?

    // Properties with side effects keep their value in plain stored properties, which
    // Observation tracks, and react in their setters.
    private var storedDialog: QuitDialog?
    private var storedOptions = ViewOptions()
    private var storedMenuMetric: Metric = .cpu
    private var storedSettings: AppSettings

    var dialog: QuitDialog? {
        get { storedDialog }
        set {
            storedDialog = newValue
            dialogChanged()
        }
    }

    var options: ViewOptions {
        get { storedOptions }
        set {
            let old = storedOptions
            storedOptions = newValue
            optionsChanged(from: old)
        }
    }

    var menuMetric: Metric {
        get { storedMenuMetric }
        set {
            storedMenuMetric = newValue
            rebuild()
        }
    }

    /// Preferences live in UserDefaults (the Settings window edits them through
    /// `@AppStorage`); the store follows every change.
    var settings: AppSettings { storedSettings }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        var updated = storedSettings
        change(&updated)
        updated.save()
        settingsMayHaveChanged()
    }

    let me: SelfIdentity

    @ObservationIgnored private let sampler: Sampler
    @ObservationIgnored private let coordinator: QuitCoordinator
    @ObservationIgnored private var listFreezer = OrderFreezer()
    @ObservationIgnored private var menuFreezer = OrderFreezer()
    @ObservationIgnored private var respawns = RespawnWatcher()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var visibleSurfaces: Set<Surface> = []
    @ObservationIgnored private var pointerInside: Set<Surface> = []
    @ObservationIgnored private var thawTasks: [Surface: Task<Void, Never>] = [:]
    @ObservationIgnored private var needsWarmUp = true
    @ObservationIgnored private var started = false
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?

    static let shared = MonitorStore.live()

    init(me: SelfIdentity, sampler: Sampler, coordinator: QuitCoordinator, settings: AppSettings) {
        self.me = me
        self.sampler = sampler
        self.coordinator = coordinator
        self.storedSettings = settings
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsMayHaveChanged() }
        }
    }

    private func settingsMayHaveChanged() {
        let latest = AppSettings.load()
        guard latest != storedSettings else { return }
        storedSettings = latest
        reschedule()
    }

    static func live() -> MonitorStore {
        let me = MonitorDarwin.selfIdentity()
        let processes = KinfoProcessSource()
        let clock = MachTime()
        let sampler = Sampler(
            me: me,
            processes: processes,
            gpu: IOKitGPUSource(),
            system: HostStatsSource(),
            apps: WorkspaceApps(),
            fallback: PSFallbackSource(),
            responsibility: ResponsibilitySPI(),
            clock: clock)
        let coordinator = QuitCoordinator(
            context: sampler, processes: processes, signaler: POSIXSignaler(), apps: AppKitTerminator(), clock: clock)
        return MonitorStore(me: me, sampler: sampler, coordinator: coordinator, settings: .load())
    }

    var quittingDisabled: Bool { me.uid == 0 || me.euid != me.uid }

    // MARK: - Refreshing

    /// Starts refreshing. Safe to call more than once.
    func start() {
        guard !started else { return }
        started = true
        reschedule()
    }

    func refreshNow() {
        let options = currentPlan()?.options ?? SampleOptions(includeFallback: self.options.scope == .all)
        Task { await refresh(options) }
    }

    func setVisible(_ visible: Bool, surface: Surface) {
        let changed = visible ? visibleSurfaces.insert(surface).inserted : visibleSurfaces.remove(surface) != nil
        if changed { reschedule() }
    }

    private func currentPlan() -> SchedulePlan? {
        SchedulePolicy.plan(
            windowVisible: visibleSurfaces.contains(.mainWindow),
            menuVisible: visibleSurfaces.contains(.menu),
            scope: options.scope,
            interval: settings.refreshInterval,
            cpuInMenuBar: settings.showMenuBarIcon && settings.showCPUInMenuBar)
    }

    private func reschedule() {
        guard started else { return }
        loop?.cancel()
        loop = nil
        guard let plan = currentPlan() else {
            needsWarmUp = true
            return
        }
        loop = Task { [weak self] in
            await self?.run(plan)
        }
    }

    private func run(_ initial: SchedulePlan) async {
        var plan = initial
        if needsWarmUp {
            // Rates need two samples; take the second one quickly after a pause.
            needsWarmUp = false
            await refresh(plan.options)
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        }
        while !Task.isCancelled {
            await refresh(plan.options)
            do {
                try await Task.sleep(for: .seconds(plan.interval), tolerance: .seconds(plan.interval / 4))
            } catch {
                return
            }
            guard let next = currentPlan() else {
                needsWarmUp = true
                return
            }
            plan = next
        }
    }

    private func refresh(_ options: SampleOptions) async {
        let snapshot = await sampler.sample(options)
        apply(snapshot)
    }

    private func apply(_ new: Snapshot) {
        history.append(new.totals)
        guard new.includesProcesses else {
            snapshot?.totals = new.totals
            return
        }
        snapshot = new
        for name in respawns.check(new, nowMicros: Self.nowMicros()) {
            showToast("“\(name)” was restarted automatically by macOS.", kind: .info)
        }
        rebuild()
    }

    private func rebuild() {
        guard let snapshot else {
            rows = []
            menuRows = []
            return
        }
        rows = DisplayBuilder.rows(snapshot, options: options, freezer: &listFreezer)
        menuRows = DisplayBuilder.menuRows(snapshot, metric: menuMetric, limit: 5, freezer: &menuFreezer)
    }

    private func optionsChanged(from old: ViewOptions) {
        // A different tab, scope or search is a different list: never keep its old order.
        if old.metric != options.metric || old.scope != options.scope || old.search != options.search {
            listFreezer.unfreeze()
            rebuild()
            if pointerInside.contains(.mainWindow) { listFreezer.freeze(current: rows) }
        } else {
            rebuild()
        }
        if old.scope != options.scope { reschedule() }
    }

    // MARK: - Keeping rows still under the pointer

    func setPointerInside(_ inside: Bool, surface: Surface) {
        thawTasks[surface]?.cancel()
        thawTasks[surface] = nil
        if inside {
            pointerInside.insert(surface)
            freeze(surface)
        } else {
            pointerInside.remove(surface)
            thawTasks[surface] = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                self?.thaw(surface)
            }
        }
    }

    private func freeze(_ surface: Surface) {
        switch surface {
        case .mainWindow: listFreezer.freeze(current: rows)
        case .menu: menuFreezer.freeze(current: menuRows)
        }
    }

    private func thaw(_ surface: Surface) {
        guard !pointerInside.contains(surface) else { return }
        if surface == .mainWindow && dialog != nil { return }
        switch surface {
        case .mainWindow: listFreezer.unfreeze()
        case .menu: menuFreezer.unfreeze()
        }
        rebuild()
    }

    private func dialogChanged() {
        if dialog != nil {
            freeze(.mainWindow)
        } else {
            thaw(.mainWindow)
        }
    }

    func toggleExpanded(_ group: GroupID) {
        if options.expanded.contains(group) {
            options.expanded.remove(group)
        } else {
            options.expanded.insert(group)
        }
    }

    // MARK: - Quitting

    func phase(of target: QuitTarget) -> QuitPhase? { phases[target] }

    /// Starts quitting. Force quits always ask first, and normal quits do unless the user
    /// turned that off. `confirmed` means the user already confirmed (the menu bar's
    /// two-step button), so no dialog is needed.
    func requestQuit(_ target: QuitTarget, force: Bool, confirmed: Bool = false) {
        if let phase = phases[target], !(force && phase != .forceQuitting) { return }
        guard let snapshot else { return }
        guard !quittingDisabled,
            let request = QuitRequest.make(for: target, in: snapshot, force: force, nowMicros: Self.nowMicros())
        else {
            showToast("This can't be quit from Process Monitor.", kind: .error)
            return
        }
        if !confirmed && (force || settings.askBeforeQuitting) {
            dialog = QuitDialog(request: request)
        } else {
            perform(request)
        }
    }

    func confirmDialog(dontAskAgain: Bool = false) {
        guard let pending = dialog else { return }
        if dontAskAgain && !pending.request.force { updateSettings { $0.askBeforeQuitting = false } }
        dialog = nil
        perform(pending.request)
    }

    func cancelDialog() {
        dialog = nil
    }

    var selectedQuitTarget: QuitTarget? {
        guard let selection else { return nil }
        return rows.first { $0.id == selection }?.quitTarget
    }

    func quitSelected(force: Bool) {
        // ⌘⌫ is also "delete to the start of the line" while typing in the search field.
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor {
            editor.deleteToBeginningOfLine(nil)
            return
        }
        guard let target = selectedQuitTarget else {
            NSSound.beep()
            return
        }
        requestQuit(target, force: force)
    }

    private func perform(_ request: QuitRequest) {
        phases[request.target] = request.force ? .forceQuitting : .quitting
        let watchPaths = respawnCandidates(for: request)
        Task { [weak self, coordinator] in
            let outcome = await coordinator.perform(request)
            self?.finish(request, outcome: outcome, watchPaths: watchPaths)
        }
    }

    private func finish(_ request: QuitRequest, outcome: QuitOutcome, watchPaths: [String]) {
        if outcome == .stillRunning {
            phases[request.target] = .stillRunning
            showToast(outcome.message(for: request.displayName), kind: .info)
        } else {
            phases[request.target] = nil
            showToast(outcome.message(for: request.displayName), kind: outcome.isError ? .error : .success)
        }
        if outcome == .exited && !watchPaths.isEmpty {
            respawns.watch(name: request.displayName, paths: watchPaths, quitAtMicros: Self.nowMicros())
        }
        refreshNow()
    }

    /// Background processes started by launchd may be restarted by it (KeepAlive);
    /// watch those so the user learns why the row came back.
    private func respawnCandidates(for request: QuitRequest) -> [String] {
        guard case .process(let key) = request.target,
            let member = snapshot?.groups.lazy.flatMap(\.members).first(where: { $0.id == key }),
            member.raw.ppid == 1
        else { return [] }
        return Array(request.expectedPaths.values)
    }

    // MARK: - Toasts

    func showToast(_ text: String, kind: Toast.Kind) {
        let toast = Toast(text: text, kind: kind)
        toasts.append(toast)
        if toasts.count > 3 { toasts.removeFirst(toasts.count - 3) }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(kind == .error ? 7 : 4))
            self?.toasts.removeAll { $0.id == toast.id }
        }
    }

    static func nowMicros() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000_000)
    }
}
