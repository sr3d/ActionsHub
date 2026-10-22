import Foundation
import Observation
import AppKit
import UserNotifications

// MARK: - Rules

/// What an alert fires on.
enum AlertTrigger: String, Codable, CaseIterable, Identifiable {
    case fails, finishes, needsApproval, tooLong

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fails: "Fails"
        case .finishes: "Finishes (pass or fail)"
        case .needsApproval: "Needs approval"
        case .tooLong: "Takes too long"
        }
    }
}

/// The "takes too long" threshold: a fixed time, or a multiple of the workflow's usual time
/// (the median of its recent successful runs).
struct TooLong: Codable, Equatable {
    enum Mode: String, Codable { case minutes, timesUsual }
    var mode: Mode = .timesUsual
    var value: Double = 2

    var label: String {
        switch mode {
        case .minutes: "over \(Int(value)) min"
        case .timesUsual: "over \(value.formatted(.number.precision(.fractionLength(0...1))))× its usual time"
        }
    }
}

struct AlertRule: Codable, Equatable {
    var triggers: Set<AlertTrigger>
    var tooLong = TooLong()

    static let groupDefault = AlertRule(triggers: [.fails, .needsApproval])
    static let runDefault = AlertRule(triggers: [.fails])
    /// Steps can't be approved, and have no run history to compare against.
    static let stepDefault = AlertRule(triggers: [.fails], tooLong: TooLong(mode: .minutes, value: 10))

    var summary: String {
        let parts = AlertTrigger.allCases.filter(triggers.contains).map { $0 == .tooLong ? "takes too long (\(tooLong.label))" : $0.label.lowercased() }
        return parts.isEmpty ? "nothing" : parts.joined(separator: ", ")
    }
}

/// A repo's own setting. No entry means "as its group".
enum RepoAlert: Codable, Equatable {
    case off
    case on(AlertRule)
}

/// An alert on one run, whatever its repo or group says.
struct RunWatch: Codable, Equatable {
    var repo: String
    var runID: Int
    var rule: AlertRule
}

/// An alert on one step: of one run, or of every run of a workflow.
struct StepWatch: Codable, Equatable, Identifiable {
    var id = UUID()
    var repo: String
    var workflowFile: String
    var jobName: String
    var stepName: String
    /// nil: every run of `workflowFile`.
    var runID: Int?
    var rule: AlertRule
    /// When it was set: a step that finished after this alerts even on the first jobs fetch.
    var created: Date? = Date()
}

/// What the alert editor sheet is editing.
enum AlertTarget: Identifiable, Equatable {
    case group(UUID)
    case repo(String)
    case run(repo: String, run: WorkflowRun)
    case step(repo: String, run: WorkflowRun, job: Job)

    var id: String {
        switch self {
        case .group(let id): "group:\(id)"
        case .repo(let repo): "repo:\(repo)"
        case .run(let repo, let run): "run:\(repo):\(run.id)"
        case .step(let repo, let run, let job): "step:\(repo):\(run.id):\(job.id)"
        }
    }
}

// MARK: - Log

/// One alert that fired. Kept in the alert list (30 days, at most 1,000).
struct AlertEvent: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case failed, succeeded, finished, needsApproval, tooLong
    }

    var id = UUID()
    var date: Date
    var kind: Kind
    var repo: String
    var runID: Int
    var title: String
    /// "CI #30", or "CI #30 › build › Deploy" for a step.
    var source: String
    var detail: String
    var url: URL
    /// Same run, attempt and kind (and step) never alerts twice.
    var key: String

    var symbol: String {
        switch kind {
        case .failed: "xmark.circle.fill"
        case .succeeded: "checkmark.circle.fill"
        case .finished: "flag.checkered.circle.fill"
        case .needsApproval: "hand.raised.fill"
        case .tooLong: "hourglass.circle.fill"
        }
    }

    var state: RunState {
        switch kind {
        case .failed: .failure
        case .succeeded: .success
        case .finished: .neutral
        case .needsApproval: .waiting
        case .tooLong: .running
        }
    }

    var repoName: String { String(repo.split(separator: "/").last ?? Substring(repo)) }
}

// MARK: - Store

/// Every alert setting (group, repo, run, step) and the alert list. Settings live in
/// UserDefaults; the list is a JSON file read and written off the main thread.
@MainActor
@Observable
final class AlertStore {
    var groupRules: [UUID: AlertRule] = AlertStore.load("alertGroups", [String: AlertRule].self)
        .reduce(into: [:]) { out, pair in if let id = UUID(uuidString: pair.key) { out[id] = pair.value } } {
        didSet { save("alertGroups", Dictionary(uniqueKeysWithValues: groupRules.map { ($0.key.uuidString, $0.value) })); changed() }
    }
    var repoRules: [String: RepoAlert] = AlertStore.load("alertRepos", [String: RepoAlert].self) {
        didSet { save("alertRepos", repoRules); changed() }
    }
    var runWatches: [Int: RunWatch] = AlertStore.load("alertRuns", [Int: RunWatch].self) {
        didSet { save("alertRuns", runWatches); changed() }
    }
    var stepWatches: [StepWatch] = AlertStore.load("alertSteps", [StepWatch].self) {
        didSet { save("alertSteps", stepWatches); changed() }
    }

    /// Newest first.
    private(set) var log: [AlertEvent] = []
    @ObservationIgnored private var fired: Set<String> = []
    @ObservationIgnored private var loaded = false

    /// The sheet that edits one level's setting.
    var editing: AlertTarget?

    static let keepFor: TimeInterval = 30 * 24 * 3600
    static let keepAtMost = 1000

    private static func load<T: Decodable>(_ key: String, _ type: T.Type) -> T where T: ExpressibleByDictionaryLiteral {
        guard let data = UserDefaults.standard.data(forKey: key), let value = try? JSONDecoder().decode(T.self, from: data) else { return [:] }
        return value
    }

    private static func load<T: Decodable>(_ key: String, _ type: [T].Type) -> [T] {
        guard let data = UserDefaults.standard.data(forKey: key), let value = try? JSONDecoder().decode([T].self, from: data) else { return [] }
        return value
    }

    private func save<T: Encodable>(_ key: String, _ value: T) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Ask for notification permission the first time any alert is set up.
    private func changed() {
        if hasAnyRule { AlertNotifier.shared.requestAuthorization() }
    }

    var hasAnyRule: Bool { !groupRules.isEmpty || repoRules.values.contains { $0 != .off } || !runWatches.isEmpty || !stepWatches.isEmpty }

    // MARK: Log file

    private static var logURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ActionsHub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("alerts.json")
    }
    private static let queue = DispatchQueue(label: "ActionsHub.alerts", qos: .utility)

    func loadLog() async {
        guard !loaded else { return }
        loaded = true
        let url = Self.logURL
        let saved: [AlertEvent] = await withCheckedContinuation { done in
            Self.queue.async {
                let data = try? Data(contentsOf: url)
                done.resume(returning: data.flatMap { try? JSONDecoder().decode([AlertEvent].self, from: $0) } ?? [])
            }
        }
        // Anything fired before the file finished loading stays on top.
        log = Self.trimmed(log + saved)
        fired = Set(log.map(\.key))
        persist()
    }

    func hasFired(_ key: String) -> Bool { fired.contains(key) }

    func record(_ events: [AlertEvent]) {
        guard !events.isEmpty else { return }
        log = Self.trimmed(events.sorted { $0.date > $1.date } + log)
        // Only what's still in the log: older keys can't come back (their runs left the list).
        fired = Set(log.map(\.key))
        persist()
    }

    func clearLog() {
        log = []
        persist()
    }

    private func persist() {
        let snapshot = log, url = Self.logURL
        Self.queue.async { try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic) }
    }

    private static func trimmed(_ list: [AlertEvent]) -> [AlertEvent] {
        let cutoff = Date().addingTimeInterval(-keepFor)
        var seen = Set<UUID>()
        return Array(list.filter { $0.date > cutoff && seen.insert($0.id).inserted }.prefix(keepAtMost))
    }
}

// MARK: - Engine

extension AppModel {
    /// A repo's rule before any run or step alert: its own setting, else the union of its
    /// groups that have alerts on (a repo in several groups alerts if any of them is on).
    func repoAlertRule(_ repo: String) -> AlertRule? {
        switch alerts.repoRules[repo] {
        case .off: return nil
        case .on(let rule): return rule
        case nil: return groupAlertRule(repo)
        }
    }

    func groupAlertRule(_ repo: String) -> AlertRule? {
        var merged: AlertRule?
        for group in groups where group.repos.contains(repo) {
            guard let rule = alerts.groupRules[group.id] else { continue }
            if merged == nil { merged = rule } else { merged!.triggers.formUnion(rule.triggers) }
        }
        return merged
    }

    /// The most specific rule for a run: an alert on that run, else the repo's.
    func alertRule(repo: String, run: WorkflowRun) -> AlertRule? {
        alerts.runWatches[run.id]?.rule ?? repoAlertRule(repo)
    }

    /// Repos to keep polling for alerts, including ones in groups that aren't on screen.
    var alertRepos: Set<String> {
        var out = Set(alerts.runWatches.values.map(\.repo))
        out.formUnion(alerts.stepWatches.map(\.repo))
        for (repo, setting) in alerts.repoRules { if case .on = setting { out.insert(repo) } }
        for group in groups where alerts.groupRules[group.id] != nil {
            for repo in group.repos where alerts.repoRules[repo] != .off { out.insert(repo) }
        }
        return out
    }

    /// Runs whose jobs are fetched on each poll because a step alert watches them.
    func stepWatchedRuns() -> [(repo: String, run: Int)] {
        var out: [(String, Int)] = []
        var seen = Set<Int>()
        for watch in alerts.stepWatches {
            for run in runs[watch.repo] ?? [] where run.state.isMoving {
                let matches = watch.runID.map { $0 == run.id } ?? (run.workflowFile == watch.workflowFile)
                if matches, seen.insert(run.id).inserted { out.append((watch.repo, run.id)) }
            }
        }
        return out
    }

    /// Median time of the workflow's recent successful runs; nil with fewer than 3.
    /// Stored, rebuilt when the repo's runs change (`runsChanged`).
    func usualDuration(repo: String, workflowFile: String) -> TimeInterval? {
        usualDurations[repo]?[workflowFile]
    }

    static func usualDurations(_ list: [WorkflowRun]) -> [String: TimeInterval] {
        var times: [String: [TimeInterval]] = [:]
        for run in list where run.state == .success { if let d = run.duration { times[run.workflowFile, default: []].append(d) } }
        return times.compactMapValues { t in
            guard t.count >= 3 else { return nil }
            return t.sorted()[t.count / 2]
        }
    }

    private func limit(_ tooLong: TooLong, repo: String, workflowFile: String?) -> TimeInterval? {
        switch tooLong.mode {
        case .minutes: return tooLong.value * 60
        case .timesUsual:
            guard let workflowFile, let usual = usualDuration(repo: repo, workflowFile: workflowFile) else { return nil }
            return usual * tooLong.value
        }
    }

    /// Compares a repo's runs before and after a fetch and fires what changed (see `AlertDetector`).
    /// Returns the step-watched runs that just finished: their jobs need one last look, since
    /// the watched step most likely ended in the same poll (`finishRunAlerts` after that).
    func detectRunAlerts(repo: String, old: [WorkflowRun]?, new: [WorkflowRun]) -> [Int] {
        let events = AlertDetector.runEvents(
            repo: repo, old: old, new: new, own: ownActions,
            rule: { alertRule(repo: repo, run: $0) },
            limit: { tooLong, run in limit(tooLong, repo: repo, workflowFile: run.workflowFile) })
        fire(events)
        guard let old else { return [] }
        let wasActive = Set(old.filter(\.state.isActive).map(\.id))
        let watches = alerts.stepWatches.filter { $0.repo == repo }
        return new.filter { run in
            !run.state.isActive && wasActive.contains(run.id)
                && watches.contains { $0.runID.map { $0 == run.id } ?? ($0.workflowFile == run.workflowFile) }
        }.map(\.id)
    }

    /// Spends run and one-run step alerts whose run is over (or gone from the list), and
    /// forgets your own actions on finished runs, so a later re-run of one alerts again.
    func finishRunAlerts(repo: String, hadRuns: Bool, new: [WorkflowRun]) {
        let finished = Set(new.filter { !$0.state.isActive }.map(\.id))
        let listed = Set(new.map(\.id))
        func spent(_ id: Int) -> Bool { finished.contains(id) || (hadRuns && !listed.contains(id)) }
        if alerts.runWatches.contains(where: { $0.value.repo == repo && spent($0.key) }) {
            alerts.runWatches = alerts.runWatches.filter { $0.value.repo != repo || !spent($0.key) }
        }
        if alerts.stepWatches.contains(where: { $0.repo == repo && $0.runID.map(spent) == true }) {
            alerts.stepWatches.removeAll { $0.repo == repo && $0.runID.map(spent) == true }
        }
        if !ownActions.isDisjoint(with: finished) { ownActions.subtract(finished) }
    }

    /// Compares a watched run's jobs before and after a fetch, for step alerts.
    func detectStepAlerts(repo: String, runID: Int, old: [Job]?, new: [Job]) {
        guard let run = runs[repo]?.first(where: { $0.id == runID }) else { return }
        let watches = alerts.stepWatches.filter { $0.repo == repo && ($0.runID.map { $0 == runID } ?? ($0.workflowFile == run.workflowFile)) }
        guard !watches.isEmpty else { return }
        fire(AlertDetector.stepEvents(repo: repo, run: run, watches: watches, old: old, new: new, own: ownActions))
    }

    private func fire(_ events: [AlertEvent]) {
        var seen = Set<String>()
        let fresh = events.filter { !alerts.hasFired($0.key) && seen.insert($0.key).inserted }
        guard !fresh.isEmpty else { return }
        alerts.record(fresh)
        AlertNotifier.shared.enqueue(fresh)
    }

    /// Brings a run into view: its group, its pane, expanded.
    func reveal(repo: String, run: Int) {
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
        if !pinned.contains(repo), let group = groups.first(where: { $0.repos.contains(repo) }) {
            selectGroup(group.id)
        }
        if isSinglePane {
            show(repo, inPane: 0)
        } else if let i = panes.firstIndex(of: repo) {
            focusedPane = i
        } else if let url = runs[repo]?.first(where: { $0.id == run })?.htmlUrl {
            openInBrowser(url)
            return
        }
        showAllRuns = true
        if !expandedRuns.contains(run) { toggleExpanded(repo: repo, run: run) }
    }
}

// MARK: - Detection

/// Works out which alerts a fetch should fire. Pure: no stores, no I/O, so the dev
/// self-test (`ACTIONSHUB_ALERT_SELFTEST`) can drive it with made-up runs.
enum AlertDetector {
    /// The first fetch after launch (`old` nil) is only a baseline: existing failures don't
    /// alert. Runs in `own` (you cancelled or rejected them) never alert on finishing.
    static func runEvents(repo: String, old: [WorkflowRun]?, new: [WorkflowRun], own: Set<Int>,
                          rule: (WorkflowRun) -> AlertRule?, limit: (TooLong, WorkflowRun) -> TimeInterval?) -> [AlertEvent] {
        guard let old else { return [] }
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newestOld = old.map(\.createdAt).max() ?? .distantPast
        var events: [AlertEvent] = []
        for run in new {
            guard let rule = rule(run) else { continue }
            let prior = before[run.id]
            // A run we haven't seen counts only if it's actually new, not an old one that a
            // status query just brought into the list.
            if prior == nil && run.createdAt < newestOld.addingTimeInterval(-600) { continue }
            let attempt = run.runAttempt ?? 1
            let rerun = prior.map { ($0.runAttempt ?? 1) != attempt } ?? false
            let wasActive = prior.map { $0.state.isActive || rerun } ?? true

            if !run.state.isActive, wasActive, !own.contains(run.id) {
                if run.state == .failure, rule.triggers.contains(.fails) || rule.triggers.contains(.finishes) {
                    events.append(event(.failed, repo: repo, run: run, detail: "Failed"))
                } else if rule.triggers.contains(.finishes), run.state != .failure {
                    events.append(event(run.state == .success ? .succeeded : .finished, repo: repo, run: run, detail: run.state.label))
                }
            }
            if run.state == .waiting, prior?.state != .waiting || rerun, rule.triggers.contains(.needsApproval) {
                events.append(event(.needsApproval, repo: repo, run: run, detail: "Needs approval"))
            }
            if rule.triggers.contains(.tooLong), run.state.isMoving, let elapsed = run.duration,
               let max = limit(rule.tooLong, run), elapsed > max {
                events.append(event(.tooLong, repo: repo, run: run, detail: "Running for \(Format.duration(elapsed)), \(rule.tooLong.label)"))
            }
        }
        return events
    }

    static func stepEvents(repo: String, run: WorkflowRun, watches: [StepWatch], old: [Job]?, new: [Job], own: Set<Int>) -> [AlertEvent] {
        var events: [AlertEvent] = []
        for watch in watches {
            guard let job = new.first(where: { $0.name == watch.jobName }),
                  let step = job.steps?.first(where: { $0.name == watch.stepName }) else { continue }
            let prior = old?.first(where: { $0.name == watch.jobName })?.steps?.first(where: { $0.name == watch.stepName })
            let path = "\(run.workflowName) #\(run.runNumber) › \(job.name) › \(step.name)"
            // No earlier jobs: a baseline, like the first fetch of runs, except a step that
            // finished after the alert was set (a run that ended between two polls).
            let finishedSinceWatch = watch.created.flatMap { created in step.completedAt.map { $0 > created } } ?? false
            let wasActive = old == nil ? finishedSinceWatch : (prior?.state.isActive ?? true)
            if !step.state.isActive, step.state != .unknown, wasActive, !own.contains(run.id) {
                if step.state == .failure, watch.rule.triggers.contains(.fails) || watch.rule.triggers.contains(.finishes) {
                    events.append(event(.failed, repo: repo, run: run, detail: "Step failed", source: path, step: step.name))
                } else if watch.rule.triggers.contains(.finishes), step.state != .skipped {
                    events.append(event(step.state == .success ? .succeeded : .finished, repo: repo, run: run,
                                        detail: "Step \(step.state.label.lowercased())", source: path, step: step.name))
                }
            }
            if watch.rule.triggers.contains(.tooLong), step.state == .running, let elapsed = step.duration,
               watch.rule.tooLong.mode == .minutes, elapsed > watch.rule.tooLong.value * 60 {
                events.append(event(.tooLong, repo: repo, run: run,
                                    detail: "Step running for \(Format.duration(elapsed)), \(watch.rule.tooLong.label)", source: path, step: step.name))
            }
        }
        return events
    }

    static func event(_ kind: AlertEvent.Kind, repo: String, run: WorkflowRun, detail: String,
                      source: String? = nil, step: String? = nil) -> AlertEvent {
        AlertEvent(date: Date(), kind: kind, repo: repo, runID: run.id, title: run.title,
                   source: source ?? "\(run.workflowName) #\(run.runNumber)", detail: detail, url: run.htmlUrl,
                   key: "\(run.id)-\(run.runAttempt ?? 1)-\(kind.rawValue)\(step.map { "-" + $0 } ?? "")")
    }
}

// MARK: - Notifications

/// Posts alerts as macOS notifications. A burst is grouped: several alerts for one repo
/// become one notification, and more than three repos at once become a single summary.
@MainActor
final class AlertNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AlertNotifier()

    /// Set by the app: what the notification buttons do.
    var onOpen: ((String, Int) -> Void)?
    var onRerun: ((String, Int) -> Void)?
    var onApprove: ((String, Int) -> Void)?
    var onOpenList: (() -> Void)?

    private var queued: [AlertEvent] = []
    private var flushTask: Task<Void, Never>?
    private var authorized: Bool?

    /// `UNUserNotificationCenter` traps without a bundle (a bare `swift run` binary).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func setUp() {
        guard let center else { return }
        center.delegate = self
        let rerun = UNNotificationAction(identifier: "rerun", title: "Re-run Failed Jobs")
        let approve = UNNotificationAction(identifier: "approve", title: "Approve")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "failed", actions: [rerun], intentIdentifiers: []),
            UNNotificationCategory(identifier: "needsApproval", actions: [approve], intentIdentifiers: []),
            UNNotificationCategory(identifier: "other", actions: [], intentIdentifiers: []),
        ])
    }

    func requestAuthorization() {
        guard authorized == nil, let center else { return }
        authorized = false
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
    }

    /// Queued until `flush()`, which the poll loop calls once a tick, so a burst across
    /// several repos becomes one round of notifications. A fallback flush covers alerts
    /// fired outside the loop.
    func enqueue(_ events: [AlertEvent]) {
        queued += events
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        flushTask?.cancel()
        flushTask = nil
        let events = queued
        queued = []
        guard let center, !events.isEmpty else { return }
        let byRepo = Dictionary(grouping: events, by: \.repo)
        if byRepo.count > 3 {
            post(center, id: "summary-\(UUID())", title: "\(events.count) alerts in \(byRepo.count) repos",
                 body: byRepo.keys.sorted().map { String($0.split(separator: "/").last ?? "") }.joined(separator: ", "),
                 category: "other", info: ["list": true])
            return
        }
        for (repo, list) in byRepo {
            let name = list[0].repoName
            if list.count == 1, let e = list.first {
                post(center, id: e.id.uuidString, title: "\(name) · \(e.source) · \(e.detail)", body: e.title,
                     category: e.kind == .failed ? "failed" : e.kind == .needsApproval ? "needsApproval" : "other",
                     info: ["repo": repo, "run": e.runID])
            } else {
                let failed = list.filter { $0.kind == .failed }.count
                post(center, id: "group-\(UUID())",
                     title: failed == list.count ? "\(failed) runs failed in \(name)" : "\(list.count) alerts in \(name)",
                     body: list.map { "\($0.source): \($0.detail)" }.joined(separator: "\n"),
                     category: "other", info: ["repo": repo, "run": list[0].runID])
            }
        }
    }

    private func post(_ center: UNUserNotificationCenter, id: String, title: String, body: String, category: String, info: [String: Any]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = info
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if info["list"] != nil {
            await MainActor.run { onOpenList?() }
            return
        }
        guard let repo = info["repo"] as? String, let run = info["run"] as? Int else { return }
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case "rerun": onRerun?(repo, run)
            case "approve": onApprove?(repo, run)
            default: onOpen?(repo, run)
            }
        }
    }
}
