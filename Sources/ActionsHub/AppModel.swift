import Foundation
import Observation
import AppKit
import SwiftUI

@MainActor
@Observable
final class AppModel {
    enum Auth: Equatable { case checking, needsToken, ready }

    var auth: Auth = .checking
    /// Seeded from the on-disk cache so the sidebar and ⌘K work instantly at launch.
    var repos: [Repo] = AppModel.loadCachedRepos()
    var reposLoading = false
    var reposError: String?

    // MARK: Groups (presets)

    /// Named sets of repos, each remembering its own split-pane layout. Persisted as JSON.
    var groups: [RepoGroup] = AppModel.loadGroups() {
        didSet { if let data = try? JSONEncoder().encode(groups) { UserDefaults.standard.set(data, forKey: "groups") } }
    }
    var currentGroupID: UUID = UUID(uuidString: UserDefaults.standard.string(forKey: "currentGroup") ?? "") ?? UUID() {
        didSet { UserDefaults.standard.set(currentGroupID.uuidString, forKey: "currentGroup") }
    }

    private var currentIndex: Int {
        groups.firstIndex { $0.id == currentGroupID } ?? 0
    }
    var currentGroup: RepoGroup { groups[currentIndex] }

    /// Repos in the current group, in display order.
    var pinned: [String] {
        get { currentGroup.repos }
        set { groups[currentIndex].repos = newValue }
    }

    /// Split panes of the current group, each monitoring one repo (or empty).
    /// What each pane shows. With one pane it's whatever you last picked (browse mode).
    /// With several, pane N always shows the group's Nth repo, so the panes follow the
    /// sidebar order and never change under you when you click around.
    var panes: [String?] {
        let cells = currentGroup.rows * currentGroup.cols
        if cells == 1 {
            let repo = currentGroup.panes.first ?? ""
            return [repo.isEmpty ? nil : repo]
        }
        return (0..<cells).map { pinned.indices.contains($0) ? pinned[$0] : nil }
    }
    var isSinglePane: Bool { currentGroup.rows * currentGroup.cols == 1 }
    var focusedPane = 0

    static let maxGrid = 4

    /// First launch after groups were introduced: fold the old pins/panes into one group.
    private static func loadGroups() -> [RepoGroup] {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "groups"),
           let saved = try? JSONDecoder().decode([RepoGroup].self, from: data), !saved.isEmpty {
            return saved
        }
        let panes = d.stringArray(forKey: "panes") ?? [d.string(forKey: "selected") ?? ""]
        return [RepoGroup(name: "My Repos", repos: d.stringArray(forKey: "pinned") ?? [], panes: panes, rows: 1, cols: panes.count)]
    }

    func selectGroup(_ id: UUID) {
        guard id != currentGroupID, groups.contains(where: { $0.id == id }) else { return }
        currentGroupID = id
        focusedPane = 0
        refreshVisible()
    }

    func selectGroup(at index: Int) {
        guard groups.indices.contains(index) else { return }
        selectGroup(groups[index].id)
    }

    func addGroup(named name: String) {
        let group = RepoGroup(name: name.isEmpty ? "Group \(groups.count + 1)" : name, repos: [], panes: [""], rows: 1, cols: 1)
        groups.append(group)
        selectGroup(group.id)
    }

    func renameGroup(_ id: UUID, to name: String) {
        guard let i = groups.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        groups[i].name = name
    }

    func deleteGroup(_ id: UUID) {
        guard groups.count > 1, let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups.remove(at: i)
        if id == currentGroupID { currentGroupID = groups[max(0, i - 1)].id; focusedPane = 0 }
    }

    // MARK: Pull requests

    var prSnapshot: PullRequestSnapshot?
    var prLoading = false
    var prError: String?
    var prUpdated: Date?
    var prIncludeDrafts: Bool = UserDefaults.standard.bool(forKey: "prIncludeDrafts") {
        didSet { UserDefaults.standard.set(prIncludeDrafts, forKey: "prIncludeDrafts") }
    }
    var prIncludeStale: Bool = UserDefaults.standard.bool(forKey: "prIncludeStale") {
        didSet { UserDefaults.standard.set(prIncludeStale, forKey: "prIncludeStale") }
    }
    static let staleAfter: TimeInterval = 30 * 24 * 3600

    var showPRs: Bool {
        get { currentGroup.showPRs }
        set {
            groups[currentIndex].showPRs = newValue
            if newValue { Task { await refreshPRs() } }
        }
    }

    /// Repos whose PRs we track: the group, plus anything on screen that isn't in it
    /// (e.g. a repo opened with ⌘K in single-pane mode).
    private var prRepos: [String] { pinned + visibleRepos.filter { !pinned.contains($0) } }

    func refreshPRs() async {
        let repos = prRepos
        guard let client, !prLoading, !repos.isEmpty else { return }
        prLoading = true
        defer { prLoading = false }
        do {
            prSnapshot = try await client.pullRequests(repos: repos)
            prError = nil
            prUpdated = Date()
        } catch {
            prError = error.localizedDescription
        }
    }

    enum PRSection: String, CaseIterable {
        case yourReview = "Review requested from you"
        case yours = "Your pull requests"
        case teamReview = "Review requested from your team"
        case other = "Other open"
    }

    /// Open PRs in the current group, bucketed. Drafts (except your own) and PRs idle for
    /// 30+ days are hidden unless their toggles are on — most repos carry a long stale tail.
    /// Pass `repo` for one repo's PRs (its pane's subpane); nil means the whole group.
    func prSections(repo: String? = nil) -> [(PRSection, [PullRequest])] {
        guard let snap = prSnapshot else { return [] }
        let groupRepos = repo.map { Set([$0]) } ?? Set(pinned)
        var buckets: [PRSection: [PullRequest]] = [:]
        for pr in snap.prs where groupRepos.contains(pr.repo) {
            let mine = pr.author == snap.viewer
            if !prIncludeStale, Date().timeIntervalSince(pr.updatedAt) > Self.staleAfter { continue }
            if !prIncludeDrafts, pr.isDraft, !mine { continue }
            let section: PRSection =
                mine ? .yours
                : snap.direct.contains(pr.url) ? .yourReview
                : snap.anyRequest.contains(pr.url) ? .teamReview
                : .other
            buckets[section, default: []].append(pr)
        }
        return PRSection.allCases.compactMap { section in buckets[section].map { (section, $0) } }
    }

    /// PRs asking for your review personally, per repo (sidebar badge).
    func reviewRequestCount(in repo: String) -> Int {
        prSections(repo: repo).first { $0.0 == .yourReview }?.1.count ?? 0
    }

    /// Repos whose pane shows its own PR subpane. Persisted.
    var prSubpaneRepos: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "prSubpaneRepos") ?? []) {
        didSet { UserDefaults.standard.set(Array(prSubpaneRepos), forKey: "prSubpaneRepos") }
    }

    func togglePRSubpane(_ repo: String) {
        if prSubpaneRepos.contains(repo) { prSubpaneRepos.remove(repo) } else {
            prSubpaneRepos.insert(repo)
            if prSnapshot == nil || !(prRepos.contains(repo)) { Task { await refreshPRs() } }
        }
    }

    /// Same count the repo's PR subpane shows (respects the draft / stale filters).
    func openPRCount(in repo: String) -> Int? {
        guard prSnapshot != nil else { return nil }
        return prSections(repo: repo).reduce(0) { $0 + $1.1.count }
    }

    // MARK: Repo colors

    /// Optional per-repo accent, so panes are easy to tell apart. Persisted; follows the repo
    /// across panes and groups.
    var repoColors: [String: String] = (UserDefaults.standard.dictionary(forKey: "repoColors") as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(repoColors, forKey: "repoColors") }
    }

    func color(for repo: String) -> RepoColor? { repoColors[repo].flatMap(RepoColor.init) }

    func setColor(_ color: RepoColor?, for repo: String) { repoColors[repo] = color?.rawValue }

    // MARK: Attention filter

    /// Which kinds of runs to show when not showing everything. Persisted.
    var attentionKinds: Set<Attention> = Set((UserDefaults.standard.stringArray(forKey: "attentionKinds") ?? Attention.allCases.map(\.rawValue)).compactMap(Attention.init)) {
        didSet { UserDefaults.standard.set(attentionKinds.map(\.rawValue), forKey: "attentionKinds") }
    }
    var showAllRuns: Bool = UserDefaults.standard.bool(forKey: "showAllRuns") {
        didSet { UserDefaults.standard.set(showAllRuns, forKey: "showAllRuns") }
    }

    func toggleAttention(_ kind: Attention) {
        if attentionKinds.contains(kind) { attentionKinds.remove(kind) } else { attentionKinds.insert(kind) }
        showAllRuns = false
    }

    /// Runs worth looking at. A failure only counts while it's still the latest run of that
    /// workflow on that branch — once a later run supersedes it, it's history, not a problem.
    func attentionRuns(for repo: String, kinds: Set<Attention>? = nil) -> [WorkflowRun] {
        let kinds = kinds ?? attentionKinds
        let list = runs[repo] ?? []
        var latestPerLine: [String: Int] = [:]
        for run in list where latestPerLine[run.lineKey] == nil { latestPerLine[run.lineKey] = run.id }  // list is newest first
        return list.filter { run in
            guard let kind = Attention(run.state) else { return false }
            guard kinds.contains(kind) else { return false }
            return kind != .failed || latestPerLine[run.lineKey] == run.id
        }
    }

    func attentionCount(_ kind: Attention, in repo: String) -> Int {
        attentionRuns(for: repo, kinds: [kind]).count
    }

    /// The repo in the focused pane. Setting it (sidebar, ⌘K, ⌘1–9) retargets that pane.
    var selected: String? {
        get { panes.indices.contains(focusedPane) ? panes[focusedPane] : nil }
        set {
            guard let newValue else { return }
            show(newValue, inPane: focusedPane)
        }
    }

    /// Sidebar click / ⌘1–9. One pane: show the repo there. Several: panes are sticky,
    /// so just focus the pane already showing it (repos past the grid aren't on screen).
    func activate(_ repo: String) {
        if isSinglePane {
            show(repo, inPane: 0)
        } else if let i = panes.firstIndex(of: repo) {
            focusedPane = i
        }
    }

    /// Repos currently on screen in any pane.
    var visibleRepos: [String] {
        var seen = Set<String>()
        return panes.compactMap { $0 }.filter { seen.insert($0).inserted }
    }

    var layout: (rows: Int, cols: Int) { (currentGroup.rows, currentGroup.cols) }

    /// Changes the grid. Several panes simply show the first rows × cols repos of the group;
    /// dropping back to one pane keeps whichever repo was focused.
    func setLayout(rows: Int, cols: Int) {
        let rows = min(max(rows, 1), Self.maxGrid), cols = min(max(cols, 1), Self.maxGrid)
        let focusedRepo = selected
        groups[currentIndex].rows = rows
        groups[currentIndex].cols = cols
        if rows * cols == 1 {
            groups[currentIndex].panes = [focusedRepo ?? pinned.first ?? ""]
            focusedPane = 0
        } else {
            focusedPane = focusedRepo.flatMap { panes.firstIndex(of: $0) } ?? 0
        }
    }

    /// Explicitly puts `repo` in pane `index` (⌘K, dragging onto a pane).
    /// With several panes it swaps places in the group's order with whatever that pane
    /// showed, so every other pane stays put. Adds the repo to the group if needed.
    func show(_ repo: String, inPane index: Int) {
        if isSinglePane {
            guard groups[currentIndex].panes.first != repo else { return }
            groups[currentIndex].panes = [repo]
            focusedPane = 0
        } else {
            var list = pinned
            if !list.contains(repo) { list.append(repo) }
            let from = list.firstIndex(of: repo)!
            if list.indices.contains(index) { list.swapAt(from, index) }
            pinned = list
            focusedPane = list.firstIndex(of: repo) ?? index
        }
        Task { await refreshRuns(repo) }
    }

    /// Single-pane only: empties the pane. (With several panes, remove the repo from the group.)
    func clearPane(_ index: Int) {
        guard isSinglePane else { return }
        groups[currentIndex].panes = [""]
    }

    func focusPane(offset: Int) {
        guard !panes.isEmpty else { return }
        focusedPane = (focusedPane + offset + panes.count) % panes.count
    }

    var runs: [String: [WorkflowRun]] = [:]
    var runsError: [String: String] = [:]
    var runsLoading: Set<String> = []
    var lastUpdated: [String: Date] = [:]
    var jobs: [Int: [Job]] = [:]
    var expandedRuns: Set<Int> = []
    var workflowFilter: [String: String] = [:]
    var actionError: String?
    var rateLimitRemaining: Int?
    var showSwitcher = false
    /// When true, the palette adds repos to the current group instead of opening them.
    var switcherAddsToGroup = false

    func openSwitcher(adding: Bool) {
        switcherAddsToGroup = adding
        showSwitcher = true
    }

    init() {
        if !groups.contains(where: { $0.id == currentGroupID }) { currentGroupID = groups[0].id }
    }

    private var client: GitHubClient?
    private var pollTask: Task<Void, Never>?

    // MARK: Lifecycle

    func start() {
        guard client == nil else { return }
        Task.detached(priority: .userInitiated) {
            let token = TokenSource.discover()
            await MainActor.run {
                if let token { self.connect(token) } else { self.auth = .needsToken }
            }
        }
    }

    func saveToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Keychain.save(trimmed)
        connect(trimmed)
    }

    private func connect(_ token: String) {
        client = GitHubClient(token: token)
        auth = .ready
        Task { await loadRepos() }
        for repo in visibleRepos { Task { await refreshRuns(repo) } }
        Task { await refreshPRs() }
        startPolling()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                tick += 1
                await self.poll(tick: tick)
            }
        }
    }

    /// Repos on screen: every 15s while something is running, otherwise every 60s.
    /// Other pinned repos: every 2 minutes, for their sidebar status dots.
    private func poll(tick: Int) async {
        let visible = visibleRepos
        for repo in visible {
            let active = runs[repo]?.contains { $0.state.isMoving } ?? false
            if active || tick % 4 == 0 { await refreshRuns(repo) }
            for id in expandedRuns where runs[repo]?.first(where: { $0.id == id })?.state.isMoving == true {
                await loadJobs(repo: repo, run: id)
            }
        }
        if tick % 8 == 0 {
            for name in pinned where !visible.contains(name) { await refreshRuns(name) }
            await refreshPRs()
        }
    }

    /// Called when the app becomes frontmost: bring everything visible up to date.
    func refreshVisible() {
        guard auth == .ready else { return }
        Task {
            let visible = visibleRepos
            for name in visible { await refreshRuns(name) }
            for name in pinned where !visible.contains(name) { await refreshRuns(name) }
            await refreshPRs()
        }
    }

    // MARK: Loading

    func loadRepos() async {
        guard let client else { return }
        reposLoading = true
        defer { reposLoading = false }
        do {
            repos = try await client.repos()
                .filter { $0.archived != true }
                .sorted { ($0.pushedAt ?? .distantPast) > ($1.pushedAt ?? .distantPast) }
            reposError = nil
            Self.cacheRepos(repos)
            for name in pinned { await refreshRuns(name) }
        } catch {
            reposError = error.localizedDescription
        }
        rateLimitRemaining = await client.rateLimitRemaining
    }

    func refreshRuns(_ fullName: String) async {
        guard let client, !runsLoading.contains(fullName) else { return }
        runsLoading.insert(fullName)
        defer { runsLoading.remove(fullName) }
        do {
            let fetched = try await client.runs(fullName)
            if runs[fullName] != fetched { runs[fullName] = fetched }
            runsError[fullName] = nil
            lastUpdated[fullName] = Date()
        } catch {
            runsError[fullName] = error.localizedDescription
        }
        rateLimitRemaining = await client.rateLimitRemaining
    }

    func loadJobs(repo: String, run: Int) async {
        guard let client else { return }
        do {
            let fetched = try await client.jobs(repo, run: run)
            if jobs[run] != fetched { jobs[run] = fetched }
        } catch {
            actionError = error.localizedDescription
        }
    }

    func toggleExpanded(repo: String, run: Int) {
        if expandedRuns.contains(run) {
            expandedRuns.remove(run)
        } else {
            expandedRuns.insert(run)
            Task { await loadJobs(repo: repo, run: run) }
        }
    }

    // MARK: Actions

    func rerun(repo: String, run: WorkflowRun, failedOnly: Bool) {
        perform(repo) { try await $0.rerun(repo, run: run.id, failedOnly: failedOnly) }
    }

    func cancel(repo: String, run: WorkflowRun) {
        perform(repo) { try await $0.cancel(repo, run: run.id) }
    }

    private func perform(_ repo: String, _ action: @escaping (GitHubClient) async throws -> Void) {
        guard let client else { return }
        Task {
            do {
                try await action(client)
                try? await Task.sleep(for: .seconds(2))
                await refreshRuns(repo)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// Opens a repo that isn't in the user's list (e.g. someone else's public repo).
    func open(fullName: String) {
        let name = fullName.trimmingCharacters(in: .whitespaces)
        if repos.contains(where: { $0.fullName.caseInsensitiveCompare(name) == .orderedSame }) {
            selected = repos.first { $0.fullName.caseInsensitiveCompare(name) == .orderedSame }?.fullName
            return
        }
        guard let client else { return }
        Task {
            do {
                let repo = try await client.repo(name)
                if !repos.contains(repo) { repos.append(repo) }
                selected = repo.fullName
            } catch {
                actionError = "\(name): \(error.localizedDescription)"
            }
        }
    }

    /// Adds a repo by name to the current group, looking it up first if it isn't in the user's list.
    func addToGroup(fullName: String) {
        let name = fullName.trimmingCharacters(in: .whitespaces)
        if let known = repos.first(where: { $0.fullName.caseInsensitiveCompare(name) == .orderedSame }) {
            if !isPinned(known.fullName) { togglePin(known.fullName) }
            return
        }
        guard let client else { return }
        Task {
            do {
                let repo = try await client.repo(name)
                if !repos.contains(repo) { repos.append(repo) }
                if !isPinned(repo.fullName) { togglePin(repo.fullName) }
            } catch {
                actionError = "\(name): \(error.localizedDescription)"
            }
        }
    }

    private static var repoCacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ActionsHub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("repos.json")
    }

    private static func loadCachedRepos() -> [Repo] {
        guard let data = try? Data(contentsOf: repoCacheURL) else { return [] }
        return (try? JSONDecoder().decode([Repo].self, from: data)) ?? []
    }

    private static func cacheRepos(_ repos: [Repo]) {
        try? JSONEncoder().encode(repos).write(to: repoCacheURL, options: .atomic)
    }

    // MARK: Pins

    func isPinned(_ name: String) -> Bool { pinned.contains(name) }

    func togglePin(_ name: String) {
        if let i = pinned.firstIndex(of: name) { pinned.remove(at: i) } else {
            pinned.append(name)
            Task { await refreshRuns(name); await refreshPRs() }
        }
    }

    func movePin(_ name: String, by offset: Int) {
        guard let i = pinned.firstIndex(of: name) else { return }
        let j = i + offset
        guard pinned.indices.contains(j) else { return }
        pinned.swapAt(i, j)
    }

    /// Drag-and-drop reorder: puts `name` where `target` currently sits.
    func movePin(_ name: String, to target: String) {
        guard name != target, let from = pinned.firstIndex(of: name), let to = pinned.firstIndex(of: target) else { return }
        var list = pinned
        list.remove(at: from)
        list.insert(name, at: to)
        pinned = list
    }

    func selectPinned(_ index: Int) {
        guard pinned.indices.contains(index) else { return }
        activate(pinned[index])
    }

    // MARK: Derived

    func repo(named name: String) -> Repo? { repos.first { $0.fullName == name } }

    func url(for name: String) -> URL {
        repo(named: name)?.actionsURL ?? URL(string: "https://github.com/\(name)/actions")!
    }

    /// Status dot: the most urgent thing going on — failed, awaiting approval, running —
    /// otherwise green if the latest run passed.
    func summary(for name: String) -> RunState? {
        guard let list = runs[name], let latest = list.first else { return nil }
        if attentionCount(.failed, in: name) > 0 { return .failure }
        if attentionCount(.approval, in: name) > 0 { return .waiting }
        if list.contains(where: { $0.state == .running }) { return .running }
        if list.contains(where: { $0.state == .queued }) { return .queued }
        return latest.state
    }

    func openInBrowser(_ url: URL) { NSWorkspace.shared.open(url) }
}

struct RepoGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var repos: [String]
    /// Pane grid in reading order (rows × cols); "" is an empty pane.
    var panes: [String]
    var rows: Int
    var cols: Int
    /// Whether the Pull Requests pane is open for this group.
    var showPRs = false

    init(name: String, repos: [String], panes: [String], rows: Int, cols: Int) {
        self.name = name
        self.repos = repos
        self.rows = max(rows, 1)
        self.cols = max(cols, 1)
        // Always exactly rows × cols cells.
        self.panes = Array((panes + Array(repeating: "", count: self.rows * self.cols)).prefix(self.rows * self.cols))
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let panes = try c.decode([String].self, forKey: .panes)
        self.init(name: try c.decode(String.self, forKey: .name),
                  repos: try c.decode([String].self, forKey: .repos),
                  panes: panes,
                  rows: try c.decodeIfPresent(Int.self, forKey: .rows) ?? 1,
                  cols: try c.decodeIfPresent(Int.self, forKey: .cols) ?? max(panes.count, 1))
        id = try c.decode(UUID.self, forKey: .id)
        showPRs = try c.decodeIfPresent(Bool.self, forKey: .showPRs) ?? false
    }
}

enum Attention: String, CaseIterable, Hashable {
    case approval, running, failed

    init?(_ state: RunState) {
        switch state {
        case .waiting: self = .approval
        case .running, .queued: self = .running
        case .failure: self = .failed
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .approval: "Approval"
        case .running: "Running"
        case .failed: "Failed"
        }
    }

    var state: RunState {
        switch self {
        case .approval: .waiting
        case .running: .running
        case .failed: .failure
        }
    }
}

extension WorkflowRun {
    /// Identifies a "line" of runs: the same workflow on the same branch.
    var lineKey: String { "\(path ?? workflowName)|\(headBranch ?? "")" }
}

enum RepoColor: String, CaseIterable {
    case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, brown, gray

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .gray: .gray
        }
    }

    var name: String { rawValue.capitalized }
}
