import Foundation
import Observation
import Security

// MARK: - Accounts

enum AccountSource: String, Codable {
    case env, pat, gh

    var label: String {
        switch self {
        case .env: "Environment variable"
        case .pat: "Personal access token"
        case .gh: "GitHub CLI"
        }
    }
}

enum AccountStatus: Equatable {
    case checking, ok, invalid(String)
}

/// One GitHub identity the app can act as, with its own client (token, ETag cache, rate limit).
struct Account: Identifiable {
    let login: String
    var source: AccountSource
    var status: AccountStatus = .checking
    var rateLimit: RateLimit?
    var ghActive = false
    let client: GitHubClient

    var id: String { login.lowercased() }
    var isUsable: Bool { if case .invalid = status { false } else { true } }
}

/// Discovers and holds every account: all `gh` logins, pasted tokens in the Keychain,
/// and GH_TOKEN / GITHUB_TOKEN. The same login from several sources becomes one account
/// (env beats a pasted token, which beats gh).
@MainActor
@Observable
final class AccountStore {
    private(set) var accounts: [Account] = []
    var legacyError: String?
    private(set) var discovering = false
    /// Token behind each account's client, so a rediscovery can tell whether it changed.
    @ObservationIgnored private var tokens: [String: String] = [:]

    /// User-chosen order (logins, lowercased); the first account is the default.
    private var order: [String] = UserDefaults.standard.stringArray(forKey: "accountOrder") ?? [] {
        didSet { UserDefaults.standard.set(order, forKey: "accountOrder") }
    }

    var usable: [Account] { accounts.filter(\.isUsable) }

    func account(_ login: String?) -> Account? {
        guard let login else { return nil }
        return accounts.first { $0.id == login.lowercased() }
    }

    /// Full rebuild from every source. Safe to call again ("Reload from gh").
    func discover() async {
        discovering = true
        defer { discovering = false }
        let found = await Task.detached(priority: .userInitiated) { await Self.gather() }.value
        legacyError = found.legacyError

        var byID: [String: Account] = [:]
        var newTokens: [String: String] = [:]
        let previous = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (login, token, source, active) in found.entries {
            let id = login.lowercased()
            let rank: [AccountSource: Int] = [.gh: 0, .pat: 1, .env: 2]
            if let existing = byID[id], rank[existing.source]! > rank[source]! { continue }
            var account: Account
            if let old = previous[id], tokens[id] == token {
                // Same token: keep the client (and its ETag cache), status and rate limit.
                account = old
                account.source = source
                if !account.isUsable { account.status = .checking }
            } else {
                account = Account(login: login, source: source, client: GitHubClient(token: token))
                // Logins from /user were already verified while gathering.
                if source != .gh { account.status = .ok }
            }
            account.ghActive = active || (byID[id]?.ghActive ?? false)
            byID[id] = account
            newTokens[id] = token
        }
        tokens = newTokens
        accounts = sorted(Array(byID.values))
        validate()
    }

    /// Default ordering: saved order first, then gh's active account, other gh accounts,
    /// pasted tokens, environment.
    private func sorted(_ list: [Account]) -> [Account] {
        func fallback(_ a: Account) -> Int {
            if a.source == .gh { return a.ghActive ? 0 : 1 }
            return a.source == .pat ? 2 : 3
        }
        return list.sorted { a, b in
            let ia = order.firstIndex(of: a.id) ?? Int.max, ib = order.firstIndex(of: b.id) ?? Int.max
            if ia != ib { return ia < ib }
            if fallback(a) != fallback(b) { return fallback(a) < fallback(b) }
            return a.id < b.id
        }
    }

    func makeDefault(_ login: String) {
        let id = login.lowercased()
        order = [id] + (order.isEmpty ? accounts.map(\.id) : order).filter { $0 != id }
        accounts = sorted(accounts)
    }

    /// Checks gh tokens in the background (pasted / env ones were checked when read).
    private func validate() {
        for account in accounts where account.status == .checking {
            Task {
                do {
                    _ = try await account.client.viewer()
                    update(account.id) { $0.status = .ok }
                } catch {
                    update(account.id) { $0.status = .invalid(error.localizedDescription) }
                }
                await noteRateLimit(account.login)
            }
        }
    }

    /// Verifies a pasted token, stores it in the Keychain under its login, and rebuilds.
    @discardableResult
    func addPAT(_ token: String) async throws -> String {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw GitHubError(message: "Paste a token first.") }
        let login = try await GitHubClient(token: token).viewer()
        Keychain.save(token, login: login)
        await discover()
        return login
    }

    func removePAT(login: String) async {
        Keychain.delete(login: login)
        await discover()
    }

    func noteRateLimit(_ login: String) async {
        guard let account = account(login) else { return }
        let limit = await account.client.rateLimit
        guard account.rateLimit != limit else { return }
        update(account.id) { $0.rateLimit = limit }
    }

    func markInvalid(_ login: String, _ message: String) {
        update(login.lowercased()) { $0.status = .invalid(message) }
    }

    private func update(_ id: String, _ change: (inout Account) -> Void) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        change(&accounts[i])
    }

    // MARK: Gathering (off the main thread: runs gh and hits /user)

    private struct Gathered: Sendable {
        var entries: [(login: String, token: String, source: AccountSource, active: Bool)] = []
        var legacyError: String?
    }

    private nonisolated static func gather() async -> Gathered {
        var out = Gathered()

        // 1. Every gh account, each token fetched by login.
        for (login, active) in GhCLI.accounts() {
            if let token = GhCLI.token(user: login) { out.entries.append((login, token, .gh, active)) }
        }

        // 2. Pasted tokens.
        for login in Keychain.patLogins() {
            if let token = Keychain.load(login: login) { out.entries.append((login, token, .pat, false)) }
        }

        // 3. Migrate the single token saved by earlier versions to a per-login item.
        if let legacy = Keychain.loadLegacy() {
            do {
                let login = try await GitHubClient(token: legacy).viewer()
                Keychain.save(legacy, login: login)
                if Keychain.load(login: login) == legacy { Keychain.deleteLegacy() }
                out.entries.append((login, legacy, .pat, false))
            } catch {
                out.legacyError = "A token saved by an earlier version couldn't be verified: \(error.localizedDescription)"
            }
        }

        // 4. Environment (only present when launched from a terminal).
        let env = ProcessInfo.processInfo.environment
        for key in ["GH_TOKEN", "GITHUB_TOKEN"] {
            guard let token = env[key], !token.isEmpty,
                  let login = try? await GitHubClient(token: token).viewer() else { continue }
            out.entries.append((login, token, .env, false))
        }
        return out
    }
}

// MARK: - GitHub CLI

enum GhCLI {
    /// GUI apps get a minimal PATH, so look in the usual install locations.
    static var binary: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Logged-in github.com accounts as (login, isActive).
    static func accounts() -> [(String, Bool)] {
        struct Status: Decodable {
            struct Entry: Decodable { let login: String; let active: Bool? }
            let hosts: [String: [Entry]]
        }
        if let data = run(["auth", "status", "--json", "hosts"]),
           let status = try? JSONDecoder().decode(Status.self, from: data),
           let entries = status.hosts["github.com"], !entries.isEmpty {
            return entries.map { ($0.login, $0.active ?? false) }
        }
        return parseHostsYml()
    }

    static func token(user: String) -> String? {
        guard let data = run(["auth", "token", "--user", user, "--hostname", "github.com"]) else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Runs gh without token env vars — otherwise gh returns that token and ignores `--user`.
    private static func run(_ args: [String]) -> Data? {
        guard let binary else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        for key in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"] { env[key] = nil }
        proc.environment = env
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return proc.terminationStatus == 0 ? data : nil
    }

    /// Fallback for older gh: read account names from hosts.yml (it holds no tokens).
    private static func parseHostsYml() -> [(String, Bool)] {
        let dir = ProcessInfo.processInfo.environment["GH_CONFIG_DIR"]
            ?? (NSHomeDirectory() + "/.config/gh")
        guard let text = try? String(contentsOfFile: dir + "/hosts.yml", encoding: .utf8) else { return [] }
        var inHost = false, inUsers = false
        var users: [String] = []
        var active: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if indent == 0 { inHost = trimmed == "github.com:"; inUsers = false; continue }
            guard inHost, !trimmed.isEmpty else { continue }
            if indent == 4 {
                inUsers = trimmed == "users:"
                if trimmed.hasPrefix("user:") { active = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces) }
            } else if inUsers, indent == 8, trimmed.hasSuffix(":") {
                users.append(String(trimmed.dropLast()))
            }
        }
        if users.isEmpty, let active { users = [active] }
        return users.map { ($0, $0 == active) }
    }
}

// MARK: - Keychain

/// Pasted tokens, one generic-password item per login ("pat:<login>") under service "ActionsHub".
enum Keychain {
    private static let service = "ActionsHub"
    private static let legacyAccount = "github-token"
    private static let prefix = "pat:"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ token: String, login: String) {
        let q = query(prefix + login)
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(login: String) -> String? { read(prefix + login) }
    static func delete(login: String) { SecItemDelete(query(prefix + login) as CFDictionary) }

    static func loadLegacy() -> String? { read(legacyAccount) }
    static func deleteLegacy() { SecItemDelete(query(legacyAccount) as CFDictionary) }

    /// Logins with a stored token. Reads attributes only, so it never prompts for access.
    static func patLogins() -> [String] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll]
        q[kSecReturnData as String] = false
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    private static func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
