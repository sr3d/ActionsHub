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
    var repos: [Repo] = AppModel.cached.repos
    var reposLoading = false
    private var reposGeneration = 0
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

    /// One snapshot per account (each covers the repos that resolve to it).
    var prByAccount: [String: PullRequestSnapshot] = [:] { didSet { rebuildPRSnapshot() } }

    /// All accounts' PRs merged. Each PR keeps the `viewer` of the account that fetched it.
    /// Stored, not computed: every sidebar row reads it on each render.
    private(set) var prSnapshot: PullRequestSnapshot?

    /// Call when the PRs or the repo → account mapping change.
    private func rebuildPRSnapshot() {
        guard !prByAccount.isEmpty else { prSnapshot = nil; return }
        var merged = PullRequestSnapshot(viewer: "", prs: [], direct: [], anyRequest: [], truncated: false)
        for (login, snap) in prByAccount {
            // Skip repos that have since moved to another account (stale snapshot).
            merged.prs += snap.prs.filter { account(for: $0.repo)?.id ?? login.lowercased() == login.lowercased() }
            merged.direct.formUnion(snap.direct)
            merged.anyRequest.formUnion(snap.anyRequest)
            merged.truncated = merged.truncated || snap.truncated
        }
        merged.prs.sort { $0.updatedAt > $1.updatedAt }
        prSnapshot = merged
    }
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

    /// One GraphQL query per account, over the repos that resolve to it, in parallel.
    func refreshPRs() async {
        let repos = prRepos
        guard !prLoading, !repos.isEmpty else { return }
        var byLogin: [String: (client: GitHubClient, repos: [String])] = [:]
        for repo in repos {
            guard let account = account(for: repo) else { continue }
            byLogin[account.login, default: (account.client, [])].repos.append(repo)
        }
        guard !byLogin.isEmpty else { return }
        prLoading = true
        defer { prLoading = false }

        // Plain tasks, not a task group (see loadRepos).
        let tasks = byLogin.map { login, work in
            (login, Task { try await work.client.pullRequests(repos: work.repos) })
        }
        var results: [String: Result<PullRequestSnapshot, Error>] = [:]
        for (login, task) in tasks { results[login] = await task.result }
        var errors: [String] = []
        for (login, result) in results.sorted(by: { $0.key < $1.key }) {
            switch result {
            case .success(let snap): prByAccount[login] = snap
            case .failure(let error):
                if (error as? GitHubError)?.isAuthFailure == true { accounts.markInvalid(login, error.localizedDescription) }
                errors.append(multiAccount ? "\(login): \(error.localizedDescription)" : error.localizedDescription)
            }
        }
        prByAccount = prByAccount.filter { byLogin[$0.key] != nil }
        prError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        if errors.count < results.count { prUpdated = Date() }
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
            let mine = pr.author == pr.viewer
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
    /// The trends sheet's repo.
    var trends: TrendsTarget?
    /// The Run Workflow sheet's repo.
    var dispatching: DispatchTarget?
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

    private var pollTask: Task<Void, Never>?

    // MARK: Alerts

    let alerts = AlertStore()
    /// Runs you cancelled or rejected here: they never alert you.
    var ownActions: Set<Int> = []
    /// Whether the main window is open. Closed: only repos with alerts are polled, at the idle rate.
    var windowOpen = true
    /// Reopens the main window (set by a view that can reach `openWindow`).
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored var openAlertList: (() -> Void)?
    /// Worst state across every group's repos, for the menu bar icon. Stored, updated after
    /// each fetch, so the icon never recomputes it.
    private(set) var overallState: RunState?

    /// Each repo's status dot, and each workflow's usual time (by repo, then workflow file).
    /// Stored: sidebar rows and running rows read them on every render.
    private(set) var summaries: [String: RunState] = [:]
    private(set) var usualDurations: [String: [String: TimeInterval]] = [:]

    /// Rebuilds what's derived from one repo's runs; call after `runs[repo]` changes.
    private func runsChanged(_ repo: String) {
        let s = computeSummary(repo)
        if summaries[repo] != s { summaries[repo] = s }
        let usual = runs[repo].map(Self.usualDurations)
        if usualDurations[repo] != usual { usualDurations[repo] = usual }
        // Jobs of runs that left every list (expanded once, or watched) aren't kept.
        if jobs.count > 100 {
            let live = Set(runs.values.flatMap { $0.map(\.id) })
            jobs = jobs.filter { live.contains($0.key) }
        }
        updateOverallState()
    }

    private func updateOverallState() {
        var worst: RunState?
        func rank(_ s: RunState?) -> Int {
            switch s {
            case .failure: 4
            case .waiting: 3
            case .running, .queued: 2
            case .success: 1
            default: 0
            }
        }
        var seen = Set<String>()
        for group in groups {
            for repo in group.repos where seen.insert(repo).inserted {
                let s = summaries[repo]
                if rank(s) > rank(worst) { worst = s }
            }
        }
        if worst != overallState { overallState = worst }
    }

    // MARK: Accounts

    let accounts = AccountStore()
    /// fullName → logins whose repo list includes it, best first (owner, push access, account order).
    var repoAccounts: [String: [String]] = AppModel.cached.accounts { didSet { rebuildPRSnapshot() } }
    /// Manual per-repo choice ("Use Account"). Persisted.
    var accountOverrides: [String: String] = (UserDefaults.standard.dictionary(forKey: "repoAccountOverrides") as? [String: String]) ?? [:] {
        didSet {
            UserDefaults.standard.set(accountOverrides, forKey: "repoAccountOverrides")
            rebuildPRSnapshot()
        }
    }
    /// Account found to work for a repo by trying them (open by name, or after a 404). Persisted.
    var accountHints: [String: String] = (UserDefaults.standard.dictionary(forKey: "repoAccountHints") as? [String: String]) ?? [:] {
        didSet {
            UserDefaults.standard.set(accountHints, forKey: "repoAccountHints")
            rebuildPRSnapshot()
        }
    }
    /// Repos already probed across accounts this session, so a missing repo isn't retried forever.
    private var probed: Set<String> = []
    var tokenError: String?

    var multiAccount: Bool { accounts.accounts.count > 1 }

    /// The account used for everything about `repo`: a manual override when usable, else automatic.
    func account(for repo: String) -> Account? {
        if let login = accountOverrides[repo], let account = accounts.account(login), account.isUsable { return account }
        return autoAccount(for: repo)
    }

    /// Automatic choice: an account proven to work, then one that lists the repo, then the
    /// owner's account, then the default account.
    func autoAccount(for repo: String) -> Account? {
        let usable = accounts.usable
        func find(_ login: String?) -> Account? { login.flatMap { l in usable.first { $0.id == l.lowercased() } } }
        if let hinted = find(accountHints[repo]) { return hinted }
        for login in repoAccounts[repo] ?? [] { if let a = find(login) { return a } }
        if let owner = find(repo.split(separator: "/").first.map(String.init)) { return owner }
        return usable.first
    }

    /// Order to try accounts for a repo nobody has listed yet: the owner's account first.
    private func candidates(for repo: String) -> [Account] {
        let owner = repo.split(separator: "/").first.map { $0.lowercased() } ?? ""
        let usable = accounts.usable
        return usable.filter { $0.id == owner } + usable.filter { $0.id != owner }
    }

    func setAccountOverride(_ login: String?, for repo: String) {
        accountOverrides[repo] = login
        runs[repo] = nil
        runsChanged(repo)
        runsError[repo] = nil
        probed.remove(repo)
        Task {
            await refreshRuns(repo)
            await refreshPRs()
        }
    }

    // MARK: Lifecycle

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let notifier = AlertNotifier.shared
        notifier.setUp()
        notifier.onOpen = { [weak self] repo, run in self?.reveal(repo: repo, run: run) }
        notifier.onOpenList = { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.openAlertList?()
        }
        notifier.onRerun = { [weak self] repo, run in
            guard let self, let r = self.runs[repo]?.first(where: { $0.id == run }) else { return }
            self.rerun(repo: repo, run: r, failedOnly: true)
        }
        notifier.onApprove = { [weak self] repo, run in
            guard let self, let r = self.runs[repo]?.first(where: { $0.id == run }) else { return }
            Task {
                await self.loadPending(repo: repo, run: r)
                if self.canReview(r, repo: repo) { self.review(repo: repo, run: r, approve: true) } else { self.reveal(repo: repo, run: run) }
            }
        }
        if alerts.hasAnyRule { notifier.requestAuthorization() }
        Task {
            await alerts.loadLog()
            await accounts.discover()
            await accountsChanged()
        }
    }

    /// First-launch token screen.
    func saveToken(_ token: String) {
        Task {
            do {
                try await accounts.addPAT(token)
                tokenError = nil
                await accountsChanged()
            } catch {
                tokenError = error.localizedDescription
            }
        }
    }

    /// Call after accounts are added, removed or reloaded.
    func accountsChanged() async {
        if accounts.accounts.isEmpty {
            auth = .needsToken
            return
        }
        probed = []
        if auth != .ready {
            connect()
        } else {
            await loadRepos()
            refreshVisible()
        }
    }

    private func connect() {
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
    /// With the window closed nothing is drawn: only repos with alerts are polled, and at
    /// the idle rate (every 60s, or 2 minutes when nothing runs).
    private func poll(tick: Int) async {
        var covered = Set<String>()
        if windowOpen {
            let visible = visibleRepos
            for repo in visible {
                let active = runs[repo]?.contains { $0.state.isMoving } ?? false
                if active || tick % 4 == 0 { await refreshRuns(repo); covered.insert(repo) }
                for id in expandedRuns where runs[repo]?.first(where: { $0.id == id })?.state.isMoving == true {
                    await loadJobs(repo: repo, run: id)
                }
            }
            if tick % 8 == 0 {
                for name in pinned where !visible.contains(name) { await refreshRuns(name); covered.insert(name) }
                await refreshPRs()
            }
        }
        // Repos with alerts, wherever they are (another group, or the window closed).
        let fast = windowOpen ? 2 : 4
        for repo in alertRepos.sorted() where !covered.contains(repo) {
            // Moving, not waiting: a run parked on an approval for days needs no fast polling.
            let active = runs[repo]?.contains { $0.state.isMoving } ?? false
            if (active && tick % fast == 0) || tick % 8 == 0 { await refreshRuns(repo) }
        }
        // Step alerts need the watched runs' jobs: one request per poll for each.
        if windowOpen || tick % 4 == 0 {
            for (repo, run) in stepWatchedRuns() where !expandedRuns.contains(run) || !windowOpen {
                await loadJobs(repo: repo, run: run)
            }
        }
        // Everything this tick found, as one round of notifications.
        AlertNotifier.shared.flush()
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

    /// Every account's repos in parallel, merged by name. An account that fails keeps its
    /// cached repos so a flaky network or revoked token doesn't empty ⌘K.
    func loadRepos() async {
        let usable = accounts.usable
        guard !usable.isEmpty else { return }
        // A newer load (e.g. after Reload from gh) supersedes this one; drop our results.
        reposGeneration += 1
        let generation = reposGeneration
        reposLoading = true
        defer { if generation == reposGeneration { reposLoading = false } }

        // Plain tasks rather than a task group: in this main-actor method the group's
        // `for await` ended before its children finished, silently dropping every account's repos.
        let tasks = usable.map { account in
            let client = account.client
            return (account.login, Task { try await client.repos() })
        }
        var results: [String: Result<[Repo], Error>] = [:]
        for (login, task) in tasks { results[login] = await task.result }
        guard generation == reposGeneration else { return }

        var seen: [String: [String: Repo]] = [:]   // fullName → login → that account's view
        var errors: [String] = []
        for account in usable {
            switch results[account.login] {
            case .success(let list):
                for repo in list where repo.archived != true { seen[repo.fullName, default: [:]][account.login] = repo }
            case .failure(let error):
                if (error as? GitHubError)?.isAuthFailure == true { accounts.markInvalid(account.login, error.localizedDescription) }
                errors.append(multiAccount ? "\(account.login): \(error.localizedDescription)" : error.localizedDescription)
                for (name, logins) in repoAccounts where logins.contains(account.login) {
                    if let cached = repos.first(where: { $0.fullName == name }) { seen[name, default: [:]][account.login] = cached }
                }
            case nil:
                break
            }
            await accounts.noteRateLimit(account.login)
        }

        let order = usable.map(\.login)
        var lists: [String: [String]] = [:]
        var merged: [Repo] = []
        for (name, views) in seen {
            let owner = name.split(separator: "/").first.map { $0.lowercased() } ?? ""
            func rank(_ login: String) -> (Int, Int, Int) {
                (login.lowercased() == owner ? 0 : 1,
                 views[login]?.permissions?.push == true ? 0 : 1,
                 order.firstIndex(of: login) ?? Int.max)
            }
            let ranked = views.keys.sorted { rank($0) < rank($1) }
            lists[name] = ranked
            merged.append(views[ranked[0]]!)
        }
        // Keep repos opened by name that no account lists (e.g. other people's public repos).
        for repo in repos where seen[repo.fullName] == nil && accountHints[repo.fullName] != nil {
            merged.append(repo)
        }
        repos = merged.sorted { ($0.pushedAt ?? .distantPast) > ($1.pushedAt ?? .distantPast) }
        repoAccounts = lists
        reposError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        Self.saveCache(repos: repos, accounts: lists)
        for name in pinned { await refreshRuns(name) }
    }

    func refreshRuns(_ fullName: String) async {
        guard !runsLoading.contains(fullName) else { return }
        runsLoading.insert(fullName)
        defer { runsLoading.remove(fullName) }
        for _ in 0..<2 {
            guard let account = account(for: fullName) else { return }
            do {
                let fetched = try await account.client.runs(fullName)
                let old = runs[fullName]
                let lastLook = detectRunAlerts(repo: fullName, old: old, new: fetched)
                if old != fetched { runs[fullName] = fetched; runsChanged(fullName) }
                for run in lastLook { await loadJobs(repo: fullName, run: run) }
                finishRunAlerts(repo: fullName, hadRuns: old != nil, new: fetched)
                for run in fetched where run.state != .waiting && pending[run.id] != nil { pending[run.id] = nil }
                runsError[fullName] = nil
                lastUpdated[fullName] = Date()
                await accounts.noteRateLimit(account.login)
                return
            } catch {
                await accounts.noteRateLimit(account.login)
                if await recover(fullName, from: error, account: account) { continue }
                runsError[fullName] = multiAccount ? "\(error.localizedDescription) (as \(account.login))" : error.localizedDescription
                return
            }
        }
    }

    /// After a failed call: a rejected token marks its account invalid; "no access" tries the
    /// other accounts once. Returns true when a retry would use a different account.
    private func recover(_ repo: String, from error: Error, account: Account) async -> Bool {
        guard let err = error as? GitHubError else { return false }
        if err.isAuthFailure {
            accounts.markInvalid(account.login, err.message)
            return self.account(for: repo).map { $0.id != account.id } ?? false
        }
        guard err.isNoAccess, accountOverrides[repo] == nil, !probed.contains(repo) else { return false }
        // Only a definite "no access" from every other account stops future probes; a
        // rate limit or network error there may clear up, so try again next time.
        var definite = true
        for other in candidates(for: repo) where other.id != account.id {
            do {
                _ = try await other.client.repo(repo)
                accountHints[repo] = other.login
                return true
            } catch {
                if (error as? GitHubError)?.isNoAccess != true { definite = false }
            }
        }
        if definite { probed.insert(repo) }
        return false
    }

    func loadJobs(repo: String, run: Int) async {
        guard let account = account(for: repo) else { return }
        do {
            let fetched = try await account.client.jobs(repo, run: run)
            detectStepAlerts(repo: repo, runID: run, old: jobs[run], new: fetched)
            if jobs[run] != fetched { jobs[run] = fetched }
        } catch {
            actionError = error.localizedDescription
        }
        await accounts.noteRateLimit(account.login)
    }

    // MARK: Logs

    struct JobLog: Hashable {
        /// nil when there's no log to show; `note` says why.
        var excerpt: LogExcerpt?
        var note: String?
        var annotations: [CheckAnnotation]
    }

    /// Trimmed logs of failed jobs, by job id. At most `maxLogs`; the oldest goes first.
    private(set) var jobLogs: [Int: JobLog] = [:]
    private var jobLogOrder: [Int] = []
    private var jobLogLoading: Set<Int> = []
    static let maxLogs = 20

    /// Fetches a finished job's log and annotations once; they don't change after it ends.
    /// A job that never started (no steps) has no log, only annotations saying why.
    func loadLog(repo: String, job: Job) async {
        guard jobLogs[job.id] == nil, !jobLogLoading.contains(job.id), !job.state.isActive,
              let account = account(for: repo) else { return }
        jobLogLoading.insert(job.id)
        defer { jobLogLoading.remove(job.id) }
        let client = account.client
        let started = !(job.steps ?? []).isEmpty
        async let notes = client.annotations(repo, job: job.id)
        var log = JobLog(excerpt: nil, note: nil, annotations: [])
        if started {
            do { log.excerpt = try await client.jobLog(repo, job: job.id) }
            catch { log.note = (error as? GitHubError)?.status == 404 ? "GitHub has no log for this job." : "Couldn't load the log: \(error.localizedDescription)" }
        } else {
            log.note = "This job never started, so it has no log."
        }
        log.annotations = (try? await notes) ?? []
        jobLogs[job.id] = log
        jobLogOrder.removeAll { $0 == job.id }
        jobLogOrder.append(job.id)
        while jobLogOrder.count > Self.maxLogs { jobLogs[jobLogOrder.removeFirst()] = nil }
        await accounts.noteRateLimit(account.login)
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
        ownActions.insert(run.id)
        perform(repo) { try await $0.cancel(repo, run: run.id) }
    }

    // MARK: Approvals

    /// Environments each waiting run is parked on, by run id. Loaded when a waiting run is shown.
    var pending: [Int: [PendingDeployment]] = [:]
    /// Runs with an approve / reject on its way, so their buttons disable.
    var reviewing: Set<Int> = []

    /// Whether you can approve this waiting run: a reviewer for at least one of its
    /// environments, or (for a fork's run) anyone with write access, which GitHub checks.
    func canReview(_ run: WorkflowRun, repo: String) -> Bool {
        if run.needsForkApproval { return self.repo(named: repo)?.permissions?.push ?? true }
        return (pending[run.id] ?? []).contains(where: \.currentUserCanApprove)
    }

    func loadPending(repo: String, run: WorkflowRun) async {
        guard run.state == .waiting, !run.needsForkApproval, let account = account(for: repo) else { return }
        do {
            let list = try await account.client.pendingDeployments(repo, run: run.id)
            if pending[run.id] != list { pending[run.id] = list }
        } catch {
            pending[run.id] = []
        }
        await accounts.noteRateLimit(account.login)
    }

    /// Approves or rejects every environment on this run that you're a reviewer for.
    /// Runs from outside contributors' forks are approved as a whole instead.
    func review(repo: String, run: WorkflowRun, approve: Bool) {
        guard !reviewing.contains(run.id) else { return }
        let environments = (pending[run.id] ?? []).filter(\.currentUserCanApprove).map(\.environment.id)
        guard run.needsForkApproval ? approve : !environments.isEmpty else { return }
        reviewing.insert(run.id)
        if !approve { ownActions.insert(run.id) }
        perform(repo, done: { [weak self] in
            self?.reviewing.remove(run.id)
            self?.pending[run.id] = nil
        }) { client in
            if run.needsForkApproval {
                try await client.approveRun(repo, run: run.id)
            } else {
                try await client.reviewDeployments(repo, run: run.id, environments: environments, approve: approve)
            }
        }
    }

    private func perform(_ repo: String, done: (() -> Void)? = nil, _ action: @escaping (GitHubClient) async throws -> Void) {
        guard let account = account(for: repo) else { return }
        Task {
            defer { done?() }
            do {
                try await action(account.client)
                try? await Task.sleep(for: .seconds(2))
                await refreshRuns(repo)
            } catch {
                actionError = multiAccount ? "\(error.localizedDescription) (as \(account.login))" : error.localizedDescription
            }
        }
    }

    /// Finds a repo by name with whichever account can see it, remembering that account.
    private func lookup(_ name: String) async throws -> Repo {
        var lastError: Error = GitHubError(message: "No GitHub account available")
        for account in candidates(for: name) {
            do {
                let repo = try await account.client.repo(name)
                accountHints[repo.fullName] = account.login
                if !repos.contains(where: { $0.fullName == repo.fullName }) {
                    repos.append(repo)
                    Self.saveCache(repos: repos, accounts: repoAccounts)
                }
                return repo
            } catch {
                if (error as? GitHubError)?.isAuthFailure == true { accounts.markInvalid(account.login, error.localizedDescription) }
                lastError = error
            }
        }
        throw lastError
    }

    /// Opens a repo that isn't in the user's list (e.g. someone else's public repo).
    func open(fullName: String) {
        let name = fullName.trimmingCharacters(in: .whitespaces)
        if let known = repos.first(where: { $0.fullName.caseInsensitiveCompare(name) == .orderedSame }) {
            selected = known.fullName
            return
        }
        Task {
            do { selected = try await lookup(name).fullName }
            catch { actionError = "\(name): \(error.localizedDescription)" }
        }
    }

    /// Adds a repo by name to the current group, looking it up first if it isn't in the user's list.
    func addToGroup(fullName: String) {
        let name = fullName.trimmingCharacters(in: .whitespaces)
        if let known = repos.first(where: { $0.fullName.caseInsensitiveCompare(name) == .orderedSame }) {
            if !isPinned(known.fullName) { togglePin(known.fullName) }
            return
        }
        Task {
            do {
                let repo = try await lookup(name)
                if !isPinned(repo.fullName) { togglePin(repo.fullName) }
            } catch {
                actionError = "\(name): \(error.localizedDescription)"
            }
        }
    }

    // MARK: Repo cache

    /// v2 adds which accounts list each repo. v1 (`repos.json`, a bare array) is still read
    /// as a fallback and left in place.
    private struct RepoCache: Codable {
        var version = 2
        var repos: [Repo]
        var accounts: [String: [String]]
    }

    private static let cached: RepoCache = {
        if let data = try? Data(contentsOf: cacheDir.appendingPathComponent("repos-v2.json")),
           let cache = try? JSONDecoder().decode(RepoCache.self, from: data) {
            return cache
        }
        if let data = try? Data(contentsOf: cacheDir.appendingPathComponent("repos.json")),
           let repos = try? JSONDecoder().decode([Repo].self, from: data) {
            return RepoCache(repos: repos, accounts: [:])
        }
        return RepoCache(repos: [], accounts: [:])
    }()

    private static var cacheDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ActionsHub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Encodes and writes off the main thread. Writes run one at a time, in order, so an
    /// older list can never land after a newer one.
    private static func saveCache(repos: [Repo], accounts: [String: [String]]) {
        let cache = RepoCache(repos: repos, accounts: accounts)
        let url = cacheDir.appendingPathComponent("repos-v2.json")
        cacheQueue.async {
            try? JSONEncoder().encode(cache).write(to: url, options: .atomic)
        }
    }
    private static let cacheQueue = DispatchQueue(label: "ActionsHub.repoCache", qos: .utility)

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
    func summary(for name: String) -> RunState? { summaries[name] }

    private func computeSummary(_ name: String) -> RunState? {
        guard let list = runs[name], let latest = list.first else { return nil }
        if attentionCount(.failed, in: name) > 0 { return .failure }
        if attentionCount(.approval, in: name) > 0 { return .waiting }
        if list.contains(where: { $0.state == .running }) { return .running }
        if list.contains(where: { $0.state == .queued }) { return .queued }
        return latest.state
    }

    /// Chrome profile directory to open each account's links in (by lowercased login).
    var browserProfiles: [String: String] = (UserDefaults.standard.dictionary(forKey: "accountBrowserProfiles") as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(browserProfiles, forKey: "accountBrowserProfiles") }
    }

    /// Opens a github.com link in the Chrome profile set for the repo's account (the default
    /// account for links outside a repo), else in the default browser.
    func openInBrowser(_ url: URL) {
        var login = accounts.usable.first?.id
        let parts = url.pathComponents.filter { $0 != "/" }
        if url.host?.lowercased() == "github.com", parts.count >= 2,
           let account = account(for: parts[0] + "/" + parts[1]) {
            login = account.id
        }
        if let login, let profile = browserProfiles[login], ChromeProfiles.open(url, profile: profile) { return }
        NSWorkspace.shared.open(url)
    }

    /// Opens the Settings scene (works on macOS 14 without `openSettings`).
    static func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
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
