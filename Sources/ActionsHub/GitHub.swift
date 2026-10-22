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
    let defaultBranch: String?
    /// What the fetching account may do here; used to pick between accounts that both see a repo.
    let permissions: Permissions?

    struct Permissions: Codable, Hashable {
        let admin: Bool?
        let push: Bool?
        let pull: Bool?
    }

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
    /// Held because it comes from an outside contributor's fork, not by an environment's
    /// reviewers: approved with `approveRun`, not through pending deployments.
    var needsForkApproval: Bool { status == "action_required" || conclusion == "action_required" }

    var duration: TimeInterval? {
        guard state != .waiting, state != .queued, let start = runStartedAt else { return nil }
        let end = state.isActive ? Date() : updatedAt
        return max(0, end.timeIntervalSince(start))
    }
}

/// An environment a run is waiting on (`GET …/runs/{id}/pending_deployments`).
struct PendingDeployment: Decodable, Hashable {
    struct Environment: Decodable, Hashable {
        let id: Int
        let name: String?
    }
    let environment: Environment
    /// Whether this token's user is one of the environment's required reviewers.
    let currentUserCanApprove: Bool
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
    let startedAt: Date?
    let completedAt: Date?

    var state: RunState { RunState(status: status, conclusion: conclusion) }

    var duration: TimeInterval? {
        guard let start = startedAt else { return nil }
        return max(0, (completedAt ?? Date()).timeIntervalSince(start))
    }
}

/// A check-run annotation: an error or warning tied to a file and line.
struct CheckAnnotation: Decodable, Hashable {
    let path: String
    let startLine: Int?
    let annotationLevel: String?
    let title: String?
    let message: String

    var isFailure: Bool { annotationLevel == "failure" }
    /// "src/app.ts:42"; the job itself when GitHub has no file (".github").
    var location: String? {
        guard path != ".github", !path.isEmpty else { return nil }
        guard let line = startLine, line > 0 else { return path }
        return "\(path):\(line)"
    }
}

/// The part of a job's log worth reading in the app: around the first error, or the end.
struct LogExcerpt: Hashable {
    var lines: [String]
    /// Index in `lines` of the first error line.
    var errorLine: Int?
    var totalLines: Int
    /// The log was too big and only its end was read (`maxBytes`).
    var truncated = false

    static let before = 120, after = 30, tail = 200
    /// Most of a log read into memory; a bigger one is read from its end.
    static let maxBytes = 16 << 20

    /// Reads a downloaded log file, at most its last `maxBytes`.
    static func make(file: URL) throws -> LogExcerpt {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try handle.seek(toOffset: start)
        var text = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        // Starting mid-file: drop the partial first line.
        if start > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        var excerpt = make(from: text)
        excerpt.truncated = start > 0
        return excerpt
    }

    /// Strips timestamps and color codes, then keeps the lines around the first `##[error]`
    /// (or the last lines, if there's none). Runs off the main thread: logs can be megabytes.
    static func make(from text: String) -> LogExcerpt {
        var all = text.split(separator: "\n", omittingEmptySubsequences: false)
        if all.last?.isEmpty == true { all.removeLast() }
        let firstError = all.firstIndex { $0.contains("##[error]") }
        let range: Range<Int>
        if let firstError {
            range = max(0, firstError - before)..<min(all.count, firstError + after)
        } else {
            range = max(0, all.count - tail)..<all.count
        }
        let lines = all[range].map { clean($0) }
        return LogExcerpt(lines: lines, errorLine: firstError.map { $0 - range.lowerBound }, totalLines: all.count)
    }

    /// "2024-05-01T10:00:00.1234567Z ##[error]boom" → "error: boom"; drops ANSI escapes.
    private static func clean(_ line: Substring) -> String {
        var s = line
        if s.count > 29, s[s.startIndex].isNumber, let space = s.firstIndex(of: " "), s[s.index(before: space)] == "Z" {
            s = s[s.index(after: space)...]
        }
        var out = String(s).replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        for (marker, label) in [("##[error]", "error: "), ("##[warning]", "warning: "), ("##[group]", "▸ "), ("##[endgroup]", ""), ("##[debug]", "debug: ")] {
            if out.hasPrefix(marker) { out = label + out.dropFirst(marker.count) }
        }
        return out
    }
}

/// Stops at a redirect instead of following it, so the token isn't sent to the log store.
private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
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
    /// Login of the account that fetched this PR — "you" for review requests and authorship.
    var viewer = ""
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

/// An account's REST API budget, from the last response's headers.
struct RateLimit: Equatable {
    let remaining: Int
    /// Requests per hour (5,000 for a user token).
    let limit: Int?
    /// When the hour's budget starts over.
    let reset: Date?

    var percent: Int? { limit.flatMap { $0 > 0 ? Int((Double(remaining) / Double($0) * 100).rounded()) : nil } }

    /// "4492/5000 per hour"
    var label: String { limit.map { "\(remaining)/\($0) per hour" } ?? "\(remaining) left" }

    /// "4,492 of 5,000 API requests left this hour (90%), resets at 9:14"
    var detail: String {
        var text = limit.map { "\(remaining.formatted()) of \($0.formatted()) API requests left this hour" } ?? "\(remaining.formatted()) API requests left this hour"
        if let percent { text += " (\(percent)%)" }
        if let reset { text += ", resets at \(reset.formatted(date: .omitted, time: .shortened))" }
        return text
    }
}

struct GitHubError: LocalizedError {
    let message: String
    /// HTTP status, when the error came from an API response.
    var status: Int? = nil
    /// A 403/429 from the rate limit, not from the token lacking access.
    var rateLimited = false
    var errorDescription: String? { message }
    /// The token itself was rejected (revoked / expired), as opposed to "no access to this repo".
    var isAuthFailure: Bool { status == 401 }
    /// This account can't see the repo; another account might.
    var isNoAccess: Bool { (status == 404 || status == 403) && !rateLimited }
}

actor GitHubClient {
    private let token: String
    private let base = URL(string: "https://api.github.com")!
    /// Conditional-request cache: a 304 costs nothing against the rate limit.
    private var cache: [URL: (etag: String, data: Data)] = [:]
    private(set) var rateLimit: RateLimit?

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
        // Only the REST ("core") budget: search and others have their own, much smaller ones.
        if (http.value(forHTTPHeaderField: "x-ratelimit-resource") ?? "core") == "core",
           let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap(Int.init) {
            rateLimit = RateLimit(remaining: remaining,
                                  limit: http.value(forHTTPHeaderField: "x-ratelimit-limit").flatMap(Int.init),
                                  reset: http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:)))
        }
        switch http.statusCode {
        case 304:
            if let cached = cache[url] { return (cached.data, http) }
            throw GitHubError(message: "Cache miss on 304")
        case 200..<300:
            if let etag = http.value(forHTTPHeaderField: "ETag") { cache[url] = (etag, data) }
            return (data, http)
        default:
            throw Self.error(from: data, response: http)
        }
    }

    private static func error(from data: Data, response: URLResponse?) -> GitHubError {
        struct Body: Decodable { let message: String? }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let msg = (try? JSONDecoder().decode(Body.self, from: data))?.message ?? "HTTP \(status)"
        let rateLimited = status == 429 || (status == 403 && (http?.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
            || msg.localizedCaseInsensitiveContains("rate limit")))
        return GitHubError(message: "\(msg) (\(status))", status: status, rateLimited: rateLimited)
    }

    func get<T: Decodable>(_ type: T.Type, _ path: String) async throws -> T {
        let (data, _) = try await fetch(url(path))
        return try Self.decoder.decode(T.self, from: data)
    }

    func post(_ path: String, body: [String: Any]? = nil) async throws {
        var req = request(url(path), method: "POST")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.error(from: data, response: response) }
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

    /// The login this token belongs to.
    func viewer() async throws -> String {
        try await get(Owner.self, "/user").login
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

    func workflows(_ fullName: String) async throws -> [Workflow] {
        try await get(WorkflowsPage.self, "/repos/\(fullName)/actions/workflows?per_page=100").workflows
    }

    /// A text file's contents at `ref` (for a workflow's inputs).
    func fileText(_ fullName: String, path: String, ref: String) async throws -> String {
        struct Contents: Decodable { let content: String? }
        let encodedPath = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        let encodedRef = ref.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ref
        let file = try await get(Contents.self, "/repos/\(fullName)/contents/\(encodedPath)?ref=\(encodedRef)")
        guard let base64 = file.content, let data = Data(base64Encoded: base64.replacingOccurrences(of: "\n", with: "")) else {
            throw GitHubError(message: "Couldn't read \(path)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Starts a workflow by hand (`workflow_dispatch`).
    func dispatch(_ fullName: String, workflow: Int, ref: String, inputs: [String: String]) async throws {
        try await post("/repos/\(fullName)/actions/workflows/\(workflow)/dispatches", body: ["ref": ref, "inputs": inputs])
    }

    /// The last 100 finished runs, for trends. Fetched only when trends are opened.
    func runHistory(_ fullName: String) async throws -> [WorkflowRun] {
        try await get(RunsPage.self, "/repos/\(fullName)/actions/runs?per_page=100&status=completed").workflowRuns
    }

    /// Jobs of an earlier attempt of a run (the one before a green re-run, for flaky jobs).
    func attemptJobs(_ fullName: String, run: Int, attempt: Int) async throws -> [Job] {
        try await get(JobsPage.self, "/repos/\(fullName)/actions/runs/\(run)/attempts/\(attempt)/jobs?per_page=100").jobs
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
        guard (200..<300).contains(status) else { throw Self.error(from: data, response: response) }
        let body = try Self.decoder.decode(GraphQLBody.self, from: data)
        if let message = body.errors?.first?.message { throw GitHubError(message: message) }
        let results = body.data ?? [:]

        var snapshot = PullRequestSnapshot(viewer: results["viewer"]?.login ?? "", prs: [], direct: [], anyRequest: [], truncated: false)
        var seen = Set<URL>()
        for i in chunks.indices {
            let page = results["s\(i)"]
            if (page?.issueCount ?? 0) > (page?.nodes?.count ?? 0) { snapshot.truncated = true }
            for node in page?.nodes ?? [] {
                guard var pr = node.pullRequest, seen.insert(pr.url).inserted else { continue }
                pr.viewer = snapshot.viewer
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

    private static let noRedirect = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)

    /// A job's log, trimmed to the part worth reading. GitHub answers with a redirect to a
    /// signed URL that rejects our token, so the redirect is followed without it.
    func jobLog(_ fullName: String, job: Int) async throws -> LogExcerpt {
        let endpoint = url("/repos/\(fullName)/actions/jobs/\(job)/logs")
        let (data, response) = try await Self.noRedirect.data(for: request(endpoint))
        guard let http = response as? HTTPURLResponse else { throw GitHubError(message: "No response") }
        if (300..<400).contains(http.statusCode) {
            guard let location = http.value(forHTTPHeaderField: "Location"), let signed = URL(string: location, relativeTo: endpoint)?.absoluteURL else {
                throw GitHubError(message: "Log redirect without a location")
            }
            // To a file, not memory: a log can be hundreds of MB.
            let (file, logResponse) = try await URLSession.shared.download(from: signed)
            defer { try? FileManager.default.removeItem(at: file) }
            guard (logResponse as? HTTPURLResponse)?.statusCode == 200 else {
                let status = (logResponse as? HTTPURLResponse)?.statusCode ?? 0
                throw GitHubError(message: "Couldn't download the log (\(status))", status: status)
            }
            return try LogExcerpt.make(file: file)
        } else if !(200..<300).contains(http.statusCode) {
            throw Self.error(from: data, response: response)
        }
        return LogExcerpt.make(from: String(decoding: data, as: UTF8.self))
    }

    /// Errors and warnings with file and line. An Actions job's id is also its check run's id.
    func annotations(_ fullName: String, job: Int) async throws -> [CheckAnnotation] {
        try await get([CheckAnnotation].self, "/repos/\(fullName)/check-runs/\(job)/annotations?per_page=50")
    }

    /// Environments a run is parked on. Unchanged lists come back 304 via ETag.
    func pendingDeployments(_ fullName: String, run: Int) async throws -> [PendingDeployment] {
        try await get([PendingDeployment].self, "/repos/\(fullName)/actions/runs/\(run)/pending_deployments")
    }

    /// Approves or rejects a run's deployments to the given environments.
    func reviewDeployments(_ fullName: String, run: Int, environments: [Int], approve: Bool) async throws {
        try await post("/repos/\(fullName)/actions/runs/\(run)/pending_deployments",
                       body: ["environment_ids": environments, "state": approve ? "approved" : "rejected",
                              "comment": approve ? "Approved from ActionsHub" : "Rejected from ActionsHub"])
    }

    /// Lets a run from an outside contributor's fork go ahead (it's held before any job starts).
    func approveRun(_ fullName: String, run: Int) async throws {
        try await post("/repos/\(fullName)/actions/runs/\(run)/approve")
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
