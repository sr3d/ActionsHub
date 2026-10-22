import AppKit

/// Chrome's profiles (from its "Local State" file), so each GitHub account's links can open in
/// the Chrome profile that's signed in to it.
enum ChromeProfiles {
    struct Profile: Identifiable, Hashable, Sendable {
        let id: String      // profile directory, e.g. "Profile 1"
        let name: String
        let email: String

        var label: String { email.isEmpty || email == name ? name : "\(name) (\(email))" }
    }

    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") }

    /// Reads the file, so call it off the main thread.
    nonisolated static func load() -> [Profile] {
        struct LocalState: Decodable {
            struct Profiles: Decodable { let info_cache: [String: Info] }
            struct Info: Decodable { let name: String?; let user_name: String? }
            let profile: Profiles
        }
        let path = NSHomeDirectory() + "/Library/Application Support/Google/Chrome/Local State"
        guard let data = FileManager.default.contents(atPath: path),
              let state = try? JSONDecoder().decode(LocalState.self, from: data) else { return [] }
        return state.profile.info_cache
            .map { Profile(id: $0.key, name: $0.value.name ?? $0.key, email: $0.value.user_name ?? "") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Opens `url` in the given profile. A second Chrome instance started with
    /// --profile-directory hands the URL to the running one and exits.
    static func open(_ url: URL, profile: String) -> Bool {
        // Chrome would create an empty profile for a directory that's gone.
        guard let app = appURL,
              FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/Application Support/Google/Chrome/" + profile)
        else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = ["--profile-directory=\(profile)", url.absoluteString]
        NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
            if error != nil { DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
        }
        return true
    }
}
