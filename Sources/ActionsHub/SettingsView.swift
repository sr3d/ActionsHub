import SwiftUI

/// Settings (⌘,): every GitHub account the app can act as, and ways to add more.
@MainActor struct AccountsSettingsView: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var adding = false
    @State private var addError: String?
    @State private var chromeProfiles: [ChromeProfiles.Profile] = []

    private var store: AccountStore { model.accounts }

    /// Overrides pointing at accounts that no longer exist.
    private var orphaned: [String: String] {
        model.accountOverrides.filter { store.account($0.value) == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * z) {
            HStack {
                Text("GitHub Accounts").zFont(.title2, weight: .semibold)
                Spacer()
                Button {
                    Task {
                        await store.discover()
                        await model.accountsChanged()
                    }
                } label: {
                    Label("Reload from gh", systemImage: "arrow.clockwise")
                }
                .disabled(store.discovering)
            }

            VStack(spacing: 0) {
                ForEach(Array(store.accounts.enumerated()), id: \.element.id) { i, account in
                    if i > 0 { Divider() }
                    AccountRow(account: account, isDefault: i == 0, chromeProfiles: chromeProfiles)
                }
                if store.accounts.isEmpty {
                    Text(store.discovering ? "Looking for accounts…" : "No accounts yet.")
                        .foregroundStyle(.secondary)
                        .padding(12 * z)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8 * z).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8 * z).stroke(Color.primary.opacity(0.1)))

            if let legacy = store.legacyError {
                Label(legacy, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .zFont(.callout)
            }
            if !orphaned.isEmpty {
                HStack {
                    Label("\(orphaned.count) repo\(orphaned.count == 1 ? " is" : "s are") set to use an account that isn't available: "
                          + Set(orphaned.values).sorted().map { "@\($0)" }.joined(separator: ", "),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Use Automatic") {
                        for repo in orphaned.keys { model.setAccountOverride(nil, for: repo) }
                    }
                }
                .zFont(.callout)
            }

            VStack(alignment: .leading, spacing: 8 * z) {
                Text("Add an account").zFont(.headline, weight: .semibold)
                Text("**With the GitHub CLI:** run `gh auth login` in Terminal — it adds an account and keeps the existing ones — then click **Reload from gh**.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("**With a token:** paste a personal access token with the **repo** and **workflow** scopes. It's stored in your Keychain.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8 * z) {
                    SecureField("ghp_…", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(token.isEmpty || adding)
                    if adding { ProgressView().controlSize(.small) }
                }
                if let addError {
                    Text(addError).foregroundStyle(.red).zFont(.callout)
                }
                Button("Create a token on GitHub…") {
                    model.openInBrowser(URL(string: "https://github.com/settings/tokens/new?scopes=repo,workflow&description=ActionsHub")!)
                }
                .buttonStyle(.link)
            }
            .zFont(.callout)
        }
        .padding(20 * z)
        .frame(width: 560 * z)
        .task { chromeProfiles = await Task.detached { ChromeProfiles.load() }.value }
    }

    private func add() {
        guard !token.isEmpty else { return }
        adding = true
        Task {
            do {
                try await store.addPAT(token)
                token = ""
                addError = nil
                await model.accountsChanged()
            } catch {
                addError = error.localizedDescription
            }
            adding = false
        }
    }
}

@MainActor private struct AccountRow: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    let account: Account
    let isDefault: Bool
    let chromeProfiles: [ChromeProfiles.Profile]

    private var profile: Binding<String> {
        Binding(get: { model.browserProfiles[account.id] ?? "" },
                set: { model.browserProfiles[account.id] = $0.isEmpty ? nil : $0 })
    }

    private var pinnedRepos: Int { model.accountOverrides.values.filter { $0.lowercased() == account.id }.count }

    var body: some View {
        HStack(alignment: .top, spacing: 10 * z) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 26 * z))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3 * z) {
                HStack(spacing: 6 * z) {
                    Text(account.login).fontWeight(.semibold)
                    if isDefault {
                        Text("Default")
                            .zFont(.caption2, weight: .semibold)
                            .padding(.horizontal, 6 * z)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    }
                }
                HStack(spacing: 6 * z) {
                    statusDot
                    Text(statusText).foregroundStyle(.secondary)
                }
                .zFont(.caption)
                Text(removalHint)
                    .zFont(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if pinnedRepos > 0 {
                    Text("\(pinnedRepos) repo\(pinnedRepos == 1 ? "" : "s") set to always use this account")
                        .zFont(.caption)
                        .foregroundStyle(.secondary)
                }
                if !chromeProfiles.isEmpty {
                    Picker("Open links in", selection: profile) {
                        Text("Default browser").tag("")
                        ForEach(chromeProfiles) { Text("Chrome: \($0.label)").tag($0.id) }
                    }
                    .zFont(.caption)
                    .fixedSize()
                    .padding(.top, 2 * z)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6 * z) {
                if !isDefault {
                    Button("Make Default") { model.accounts.makeDefault(account.login); Task { await model.accountsChanged() } }
                }
                if account.source == .pat {
                    Button("Remove", role: .destructive) {
                        Task {
                            await model.accounts.removePAT(login: account.login)
                            await model.accountsChanged()
                        }
                    }
                }
            }
            .zFont(.callout)
        }
        .padding(12 * z)
    }

    @ViewBuilder private var statusDot: some View {
        switch account.status {
        case .checking: ProgressView().controlSize(.mini)
        case .ok: Circle().fill(Color.green).frame(width: 8 * z, height: 8 * z)
        case .invalid: Circle().fill(Color.red).frame(width: 8 * z, height: 8 * z)
        }
    }

    private var statusText: String {
        var parts = [account.source.label]
        switch account.status {
        case .checking: parts.append("checking…")
        case .ok: if let n = account.rateLimit { parts.append("\(n) API requests left this hour") }
        case .invalid(let message): parts.append(message)
        }
        return parts.joined(separator: " · ")
    }

    private var removalHint: String {
        switch account.source {
        case .gh: "Managed by the GitHub CLI — remove with `gh auth logout --user \(account.login)`."
        case .env: "From GH_TOKEN / GITHUB_TOKEN in the environment this app was launched from."
        case .pat: "Stored in your Keychain."
        }
    }
}

/// Small "@login" capsule, shown only when more than one account is set up.
@MainActor struct AccountTag: View {
    @Environment(\.zoom) private var z
    let login: String?

    var body: some View {
        if let login {
            Text("@\(login)")
                .zFont(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 5 * z)
                .padding(.vertical, 1 * z)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
    }
}
