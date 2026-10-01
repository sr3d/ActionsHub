import Foundation
import SwiftUI

// MARK: - Models

struct Owner: Codable, Hashable {
    let login: String
}

struct Repo: Codable, Identifiable, Hashable {
    let id: Int
    let fullName: String
    let name: String
    let owner: Owner
    let htmlUrl: URL
    let pushedAt: Date?
    let archived: Bool?

    var actionsURL: URL { htmlUrl.appendingPathComponent("actions") }
}

struct RunsPage: Decodable {
    let totalCount: Int
    let workflowRuns: [WorkflowRun]
}

struct WorkflowRun: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let displayTitle: String?
    let headBranch: String?
    let headSha: String
    let event: String
    let status: String?
    let conclusion: String?
    let runNumber: Int
    let runAttempt: Int?
    let htmlUrl: URL
    let createdAt: Date
    let updatedAt: Date
    let runStartedAt: Date?
    let actor: Owner?
    let path: String?

    var state: RunState { RunState(status: status, conclusion: conclusion) }
    var workflowName: String { name ?? "Workflow" }
    var title: String { displayTitle ?? workflowName }
    /// Secondary label: the workflow name, or its file when the name just duplicates the title.
    var workflowLabel: String {
        if workflowName != title { return workflowName }
        return path.map { ($0 as NSString).lastPathComponent } ?? workflowName
    }

    /// Workflow file name (e.g. "ci.yml"); stable even when run names embed ids.
    var workflowFile: String { path.map { ($0 as NSString).lastPathComponent } ?? workflowName }

    /// Elapsed time; nil for runs that haven't started (queued or parked on an approval gate),
    /// where it would just count how long they've been sitting there.
    var duration: TimeInterval? {
        guard state != .waiting, state != .queued, let start = runStartedAt else { return nil }
        let end = state.isActive ? Date() : updatedAt
        return max(0, end.timeIntervalSince(start))
    }
}

struct JobsPage: Decodable {
    let jobs: [Job]
}

struct Job: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let status: String?
    let conclusion: String?
    let startedAt: Date?
    let completedAt: Date?
    let htmlUrl: URL?
    let steps: [Step]?

    var state: RunState { RunState(status: status, conclusion: conclusion) }

    var duration: TimeInterval? {
        guard let start = startedAt else { return nil }
        return max(0, (completedAt ?? Date()).timeIntervalSince(start))
    }
}

struct Step: Decodable, Hashable {
    let name: String
    let status: String?
    let conclusion: String?
    let number: Int

    var state: RunState { RunState(status: status, conclusion: conclusion) }
}

/// Collapses GitHub's separate `status` / `conclusion` fields into one displayable state.
/// Unknown values map to `.unknown` rather than failing to decode.
enum RunState: Equatable {
    case waiting, queued, running, success, failure, cancelled, skipped, neutral, unknown

    init(status: String?, conclusion: String?) {
        switch status {
        case "waiting", "action_required": self = .waiting
        case "queued", "pending", "requested": self = .queued
        case "in_progress": self = .running
        case "completed":
            switch conclusion {
            case "success": self = .success
            case "action_required": self = .waiting
            case "failure", "timed_out", "startup_failure": self = .failure
            case "cancelled": self = .cancelled
            case "skipped": self = .skipped
            case "neutral", "stale": self = .neutral
            default: self = .unknown
            }
        default: self = .unknown
        }
    }

    /// Not finished yet (includes runs parked on an approval gate).
    var isActive: Bool { self == .queued || self == .running || self == .waiting }
    /// Actually executing or about to — worth polling quickly.
    var isMoving: Bool { self == .queued || self == .running }

    var color: Color {
        switch self {
        case .success: .green
        case .failure: .red
        case .running: .orange
        case .queued: .yellow
        case .waiting: .purple
        case .cancelled, .skipped, .neutral, .unknown: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .running: "circle.dotted.circle"
        case .queued: "clock.fill"
        case .waiting: "hand.raised.fill"
        case .cancelled: "slash.circle"
        case .skipped: "arrow.uturn.right.circle"
        case .neutral, .unknown: "circle"
        }
    }

    var label: String {
        switch self {
        case .waiting: "Needs approval"
        case .queued: "Queued"
        case .running: "In progress"
        case .success: "Success"
        case .failure: "Failed"
        case .cancelled: "Cancelled"
        case .skipped: "Skipped"
        case .neutral: "Neutral"
        case .unknown: "Unknown"
        }
    }
}

// MARK: - Pull requests

struct PullRequest: Identifiable, Hashable {
    let url: URL
    let number: Int
    let title: String
    let repo: String
    let author: String?
    let isDraft: Bool
    let updatedAt: Date
    let branch: String
    /// APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or nil when no review is required.
    let reviewDecision: String?
    /// Combined CI state of the head commit: SUCCESS, FAILURE, ERROR, PENDING, EXPECTED, or nil.
    let ciState: String?

    var id: URL { url }
    var repoName: String { String(repo.split(separator: "/").last ?? Substring(repo)) }

    var ci: RunState? {
        switch ciState {
        case "SUCCESS": .success
        case "FAILURE", "ERROR": .failure
        case "PENDING", "EXPECTED": .running
        default: nil
        }
    }
}

/// Open PRs across a set of repos, plus which of them ask for the viewer's review.
struct PullRequestSnapshot {
    var viewer: String
    var prs: [PullRequest]
    /// Review requested from the viewer personally.
    var direct: Set<URL>
    /// Review requested from the viewer or one of their teams.
    var anyRequest: Set<URL>
    /// Repo chunks where GitHub had more open PRs than one page returns.
    var truncated: Bool
}

// MARK: - Client

struct GitHubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

actor GitHubClient {
    private let token: String
    private let base = URL(string: "https://api.github.com")!
    /// Conditional-request cache: a 304 costs nothing against the rate limit.
    private var cache: [URL: (etag: String, data: Data)] = [:]
    private(set) var rateLimitRemaining: Int?

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(token: String) { self.token = token }

    private func request(_ url: URL, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        return req
    }

    private func url(_ path: String) -> URL {
        URL(string: path, relativeTo: base)!.absoluteURL
    }

    private func fetch(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var req = request(url)
        if let cached = cache[url] { req.setValue(cached.etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw GitHubError(message: "No response") }
        if let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining") {
            rateLimitRemaining = Int(remaining)
        }
        switch http.statusCode {
        case 304:
            if let cached = cache[url] { return (cached.data, http) }
            throw GitHubError(message: "Cache miss on 304")
        case 200..<300:
            if let etag = http.value(forHTTPHeaderField: "ETag") { cache[url] = (etag, data) }
            return (data, http)
        default:
            throw Self.error(from: data, status: http.statusCode)
        }
    }

    private static func error(from data: Data, status: Int) -> GitHubError {
        struct Body: Decodable { let message: String? }
        let msg = (try? JSONDecoder().decode(Body.self, from: data))?.message ?? "HTTP \(status)"
        return GitHubError(message: "\(msg) (\(status))")
    }

    func get<T: Decodable>(_ type: T.Type, _ path: String) async throws -> T {
        let (data, _) = try await fetch(url(path))
        return try Self.decoder.decode(T.self, from: data)
    }

    func post(_ path: String) async throws {
        let (data, response) = try await URLSession.shared.data(for: request(url(path), method: "POST"))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.error(from: data, status: status) }
    }

    /// Follows `Link: rel="next"` headers up to `maxPages`.
    func getAll<T: Decodable>(_ type: T.Type, _ path: String, maxPages: Int = 10) async throws -> [T] {
        var results: [T] = []
        var next: URL? = url(path)
        var pages = 0
        while let current = next, pages < maxPages {
            let (data, http) = try await fetch(current)
            results += try Self.decoder.decode([T].self, from: data)
            next = Self.nextLink(http.value(forHTTPHeaderField: "Link"))
            pages += 1
        }
        return results
    }

    private static func nextLink(_ header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";")
            guard pieces.count >= 2, pieces[1].contains("rel=\"next\"") else { continue }
            let raw = pieces[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            return URL(string: raw)
        }
        return nil
    }

    // MARK: Endpoints

    func repos() async throws -> [Repo] {
        try await getAll(Repo.self, "/user/repos?affiliation=owner,collaborator,organization_member&sort=pushed&per_page=100")
    }

    func repo(_ fullName: String) async throws -> Repo {
        try await get(Repo.self, "/repos/\(fullName)")
    }

    /// Recent runs plus every unfinished one. Runs parked on an approval gate can be weeks old,
    /// so they're fetched by status rather than hoping they're in the recent page.
    /// Unchanged pages come back 304 via ETag and don't cost rate limit.
    func runs(_ fullName: String) async throws -> [WorkflowRun] {
        let base = "/repos/\(fullName)/actions/runs?per_page="
        async let recent = get(RunsPage.self, base + "30").workflowRuns
        var all = try await recent
        for status in ["waiting", "action_required", "in_progress", "queued"] {
            all += try await get(RunsPage.self, base + "50&status=\(status)").workflowRuns
        }
        var seen = Set<Int>()
        return all.filter { seen.insert($0.id).inserted }.sorted { $0.createdAt > $1.createdAt }
    }

    func jobs(_ fullName: String, run: Int) async throws -> [Job] {
        try await get(JobsPage.self, "/repos/\(fullName)/actions/runs/\(run)/jobs?filter=latest&per_page=100").jobs
    }

    func rerun(_ fullName: String, run: Int, failedOnly: Bool) async throws {
        try await post("/repos/\(fullName)/actions/runs/\(run)/\(failedOnly ? "rerun-failed-jobs" : "rerun")")
    }

    /// One GraphQL round trip for all open PRs across `repos`, with review state and CI status
    /// (neither is available from the REST search API). Search queries are capped at 256
    /// characters, so repos are split into chunks, each queried under its own alias.
    func pullRequests(repos: [String]) async throws -> PullRequestSnapshot {
        let base = "is:pr is:open archived:false sort:updated-desc"
        var chunks: [[String]] = [[]]
        for repo in repos {
            let candidate = chunks[chunks.count - 1] + [repo]
            let query = ([base] + candidate.map { "repo:\($0)" } + ["user-review-requested:@me"]).joined(separator: " ")
            if query.count > 250, !chunks[chunks.count - 1].isEmpty { chunks.append([repo]) } else { chunks[chunks.count - 1] = candidate }
        }
        chunks.removeAll { $0.isEmpty }

        var declarations: [String] = []
        var fields = ["viewer { login }"]
        var variables: [String: String] = [:]
        for (i, chunk) in chunks.enumerated() {
            let q = ([base] + chunk.map { "repo:\($0)" }).joined(separator: " ")
            variables["q\(i)"] = q
            variables["d\(i)"] = q + " user-review-requested:@me"
            variables["r\(i)"] = q + " review-requested:@me"
            declarations += ["$q\(i): String!", "$d\(i): String!", "$r\(i): String!"]
            fields.append("s\(i): search(query: $q\(i), type: ISSUE, first: 100) { issueCount nodes { ...PR } }")
            fields.append("d\(i): search(query: $d\(i), type: ISSUE, first: 100) { nodes { ... on PullRequest { url } } }")
            fields.append("r\(i): search(query: $r\(i), type: ISSUE, first: 100) { nodes { ... on PullRequest { url } } }")
        }
        let query = """
        query(\(declarations.joined(separator: ", "))) {
          \(fields.joined(separator: "\n  "))
        }
        fragment PR on PullRequest {
          number title url isDraft updatedAt headRefName reviewDecision
          author { login }
          repository { nameWithOwner }
          commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
        }
        """

        var req = request(url("/graphql"), method: "POST")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.error(from: data, status: status) }
        let body = try Self.decoder.decode(GraphQLBody.self, from: data)
        if let message = body.errors?.first?.message { throw GitHubError(message: message) }
        let results = body.data ?? [:]

        var snapshot = PullRequestSnapshot(viewer: results["viewer"]?.login ?? "", prs: [], direct: [], anyRequest: [], truncated: false)
        var seen = Set<URL>()
        for i in chunks.indices {
            let page = results["s\(i)"]
            if (page?.issueCount ?? 0) > (page?.nodes?.count ?? 0) { snapshot.truncated = true }
            for node in page?.nodes ?? [] {
                guard let pr = node.pullRequest, seen.insert(pr.url).inserted else { continue }
                snapshot.prs.append(pr)
            }
            snapshot.direct.formUnion(results["d\(i)"]?.nodes?.compactMap(\.url) ?? [])
            snapshot.anyRequest.formUnion(results["r\(i)"]?.nodes?.compactMap(\.url) ?? [])
        }
        snapshot.prs.sort { $0.updatedAt > $1.updatedAt }
        return snapshot
    }

    func cancel(_ fullName: String, run: Int) async throws {
        try await post("/repos/\(fullName)/actions/runs/\(run)/cancel")
    }
}

// MARK: - GraphQL decoding

/// Every top-level alias decodes into this loose shape: `viewer` fills `login`,
/// searches fill `issueCount` / `nodes`.
private struct GraphQLBody: Decodable {
    struct Alias: Decodable {
        let login: String?
        let issueCount: Int?
        let nodes: [PRNode]?
    }
    struct Message: Decodable { let message: String }
    let data: [String: Alias]?
    let errors: [Message]?
}

/// Search results can include non-PR nodes (decoded as `{}`), so every field is optional.
private struct PRNode: Decodable {
    struct Login: Decodable { let login: String }
    struct Repository: Decodable { let nameWithOwner: String }
    struct Commits: Decodable {
        struct Node: Decodable {
            struct Commit: Decodable {
                struct Rollup: Decodable { let state: String? }
                let statusCheckRollup: Rollup?
            }
            let commit: Commit
        }
        let nodes: [Node]?
    }

    let number: Int?
    let title: String?
    let url: URL?
    let isDraft: Bool?
    let updatedAt: Date?
    let headRefName: String?
    let reviewDecision: String?
    let author: Login?
    let repository: Repository?
    let commits: Commits?

    var pullRequest: PullRequest? {
        guard let number, let title, let url, let repository, let updatedAt else { return nil }
        return PullRequest(url: url, number: number, title: title, repo: repository.nameWithOwner,
                           author: author?.login, isDraft: isDraft ?? false, updatedAt: updatedAt,
                           branch: headRefName ?? "", reviewDecision: reviewDecision,
                           ciState: commits?.nodes?.last?.commit.statusCheckRollup?.state)
    }
}

// MARK: - Token discovery

enum TokenSource {
    /// Tries the environment, then the `gh` CLI, then a token saved in the Keychain.
    static func discover() -> String? {
        let env = ProcessInfo.processInfo.environment
        for key in ["GH_TOKEN", "GITHUB_TOKEN"] {
            if let t = env[key], !t.isEmpty { return t }
        }
        if let t = ghToken() { return t }
        return Keychain.load()
    }

    private static func ghToken() -> String? {
        // GUI apps get a minimal PATH, so look in the usual install locations.
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let gh = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: gh)
        proc.arguments = ["auth", "token"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let token = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }
}

enum Keychain {
    private static let service = "ActionsHub"
    private static let account = "github-token"

    static func save(_ token: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
