import SwiftUI
import AppKit

@main
struct ActionsHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage("zoom") private var zoom: Double = 1.0
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("ActionsHub", id: "main") {
            RootView()
                .environment(\.zoom, zoom)
                .environment(model)
            .frame(minWidth: 720 * zoom, minHeight: 420 * zoom)
            .onAppear {
                model.start()
                ResizeBench.extraShots = { [model] dir in
                    // Alert editors for the group, a repo and a run, then the alert list. Nothing is saved.
                    var targets: [(String, AlertTarget)] = [("alerts-group", .group(model.currentGroupID))]
                    if let repo = model.pinned.first {
                        targets.append(("alerts-repo", .repo(repo)))
                        if let run = model.runs[repo]?.first { targets.append(("alerts-run", .run(repo: repo, run: run))) }
                    }
                    @MainActor func next(_ i: Int) async {
                        guard i < targets.count else {
                            openWindow(id: "alerts")
                            try? await Task.sleep(for: .seconds(1))
                            ResizeBench.capture("alert-list", in: dir)
                            exit(0)
                        }
                        model.alerts.editing = targets[i].1
                        try? await Task.sleep(for: .seconds(1))
                        ResizeBench.capture(targets[i].0, in: dir)
                        model.alerts.editing = nil
                        try? await Task.sleep(for: .seconds(0.7))
                        await next(i + 1)
                    }
                    Task { @MainActor in
                        // A failed run expanded, with its log.
                        if let (repo, run) = model.visibleRepos.lazy.compactMap({ r in model.attentionRuns(for: r).first { $0.state == .failure && ($0.duration ?? 0) > 30 }.map { (r, $0) } }).first {
                            if let window = NSApp.windows.first(where: { $0.title == "ActionsHub" }) {
                                window.setFrame(NSRect(x: window.frame.minX, y: window.frame.minY, width: 2400, height: 1400), display: true)
                            }
                            model.toggleExpanded(repo: repo, run: run.id)
                            try? await Task.sleep(for: .seconds(8))
                            ResizeBench.captureMain("failed-run-log", in: dir)
                            for job in model.jobs[run.id] ?? [] {
                                let log = model.jobLogs[job.id]
                                let excerpt = log?.excerpt
                                let errorText = excerpt.flatMap { e in e.errorLine.map { e.lines[$0] } } ?? "-"
                                FileHandle.standardError.write("LOG \(job.name) \(job.state): \(excerpt?.lines.count ?? -1)/\(excerpt?.totalLines ?? -1) lines, error: \(errorText), note: \(log?.note ?? "-"), annotations: \(log?.annotations.count ?? -1)\n".data(using: .utf8)!)
                            }
                            model.toggleExpanded(repo: repo, run: run.id)
                        }
                        // Trends for the busiest repo on screen.
                        if let repo = model.visibleRepos.max(by: { (model.runs[$0]?.count ?? 0) < (model.runs[$1]?.count ?? 0) }) {
                            model.trends = TrendsTarget(repo: repo)
                            try? await Task.sleep(for: .seconds(10))
                            ResizeBench.capture("trends", in: dir)
                            model.trends = nil
                            try? await Task.sleep(for: .seconds(0.7))
                        }
                        // The Run Workflow form (opened only; nothing is started).
                        if let repo = model.visibleRepos.first(where: { $0 == "sr3d/diagrammd" }) ?? model.visibleRepos.first {
                            model.dispatching = DispatchTarget(repo: repo)
                            try? await Task.sleep(for: .seconds(6))
                            ResizeBench.capture("run-workflow", in: dir)
                            model.dispatching = nil
                            try? await Task.sleep(for: .seconds(0.7))
                        }
                        await next(0)
                    }
                }
                ResizeBench.runIfRequested()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.refreshVisible()
            }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(after: .windowList) {
                Button("Alert List") { openWindow(id: "alerts") }
                    .keyboardShortcut("l", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Zoom In") { zoom = Zoom.step(zoom, up: true) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out") { zoom = Zoom.step(zoom, up: false) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { zoom = 1.0 }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                Menu("Pane Layout") {
                    // Encoded as rows*10 + cols.
                    ForEach([11, 12, 13, 21, 22, 23, 33], id: \.self) { rc in
                        Button("\(rc / 10) × \(rc % 10)") { model.setLayout(rows: rc / 10, cols: rc % 10) }
                    }
                }
                Divider()
                Toggle("Show Pull Requests", isOn: Binding(get: { model.showPRs }, set: { model.showPRs = $0 }))
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                Toggle("Show All Runs", isOn: Binding(get: { model.showAllRuns }, set: { model.showAllRuns = $0 }))
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                ForEach(Attention.allCases, id: \.self) { kind in
                    Toggle("Show \(kind.label)", isOn: Binding(
                        get: { model.attentionKinds.contains(kind) },
                        set: { _ in model.toggleAttention(kind) }))
                }
                Divider()
            }
            CommandMenu("Group") {
                ForEach(Array(model.groups.enumerated()), id: \.element.id) { i, group in
                    Toggle(group.name, isOn: Binding(get: { group.id == model.currentGroupID },
                                                     set: { _ in model.selectGroup(group.id) }))
                        .keyboardShortcut(i < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option]) : nil)
                }
                Divider()
                Button("Alerts for This Group…") { model.alerts.editing = .group(model.currentGroupID) }
                Divider()
                Button("New Group") { model.addGroup(named: "") }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
            CommandMenu("Go") {
                Button("Quick Open Repository…") { model.openSwitcher(adding: false) }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Add Repositories to Group…") { model.openSwitcher(adding: true) }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Refresh") {
                    if let s = model.selected { Task { await model.refreshRuns(s) } }
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("Alerts for This Repo…") {
                    if let s = model.selected { model.alerts.editing = .repo(s) }
                }
                .disabled(model.selected == nil)
                Button("Run Workflow…") {
                    if let s = model.selected { model.dispatching = DispatchTarget(repo: s) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selected == nil)
                Button("Trends…") {
                    if let s = model.selected { model.trends = TrendsTarget(repo: s) }
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(model.selected == nil)
                Button("Open Actions in Browser") {
                    if let s = model.selected { model.openInBrowser(model.url(for: s)) }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Button(model.selected.map { model.isPinned($0) ? "Remove from Group" : "Add to Group" } ?? "Add to Group") {
                    if let s = model.selected { model.togglePin(s) }
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(model.selected == nil)
                Divider()
                Button("Next Pane") { model.focusPane(offset: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Previous Pane") { model.focusPane(offset: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Divider()
                ForEach(Array(model.pinned.prefix(9).enumerated()), id: \.element) { i, name in
                    Button(name) { model.selectPinned(i) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
            }
        }

        // Every alert that fired, across all repos.
        Window("Alerts", id: "alerts") {
            AlertListView()
                .zFont(.body)
                .environment(\.zoom, zoom)
                .environment(model)
        }
        .defaultSize(width: 520, height: 600)

        // Keeps watching (and alerting) with the main window closed.
        MenuBarExtra {
            MenuBarPanel()
                .environment(\.zoom, zoom)
                .environment(model)
        } label: {
            MenuBarIcon()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        // ⌘, — GitHub accounts.
        Settings {
            AccountsSettingsView()
                .zFont(.body)
                .environment(\.zoom, zoom)
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM binary rather than a bundled .app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        // Dev aid: `swift run` then post this notification to dump the window to a PNG
        // without needing Screen Recording permission.
        DistributedNotificationCenter.default().addObserver(forName: .init("ActionsHubSnapshot"), object: nil, queue: .main) { note in
            // Object is "<pid>:<path>" so only the targeted process responds.
            guard let spec = note.object as? String,
                  let colon = spec.firstIndex(of: ":"),
                  Int32(spec[..<colon]) == ProcessInfo.processInfo.processIdentifier else { return }
            let path = String(spec[spec.index(after: colon)...])
            // Main window to <path>; popovers and other windows to <path>-1.png, -2.png…
            let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
                .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
            for (i, window) in windows.enumerated() {
                guard let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let out = i == 0 ? path : path.replacingOccurrences(of: ".png", with: "-\(i).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            }
        }
        #endif
    }

    // Keep running (and polling) when the window closes; clicking the Dock icon brings it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

enum Zoom {
    static let levels: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    static func step(_ current: Double, up: Bool) -> Double {
        if up { return levels.first { $0 > current + 0.001 } ?? levels.last! }
        return levels.last { $0 < current - 0.001 } ?? levels.first!
    }
}

/// Zoom is applied by re-laying out at real point sizes (fonts, icons, spacing and widths
/// all multiply by `zoom`) rather than `scaleEffect`, which magnifies a bitmap and blurs text.
private struct ZoomKey: EnvironmentKey { static let defaultValue: Double = 1 }

extension EnvironmentValues {
    var zoom: Double {
        get { self[ZoomKey.self] }
        set { self[ZoomKey.self] = newValue }
    }
}

/// macOS default point sizes for each text style, scaled by the current zoom.
private struct ZoomedFont: ViewModifier {
    @Environment(\.zoom) private var zoom
    let style: Font.TextStyle
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: Self.baseSize(style) * zoom, weight: weight, design: design))
    }

    static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote, .caption: 10
        case .caption2: 10
        @unknown default: 13
        }
    }
}

extension View {
    func zFont(_ style: Font.TextStyle, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ZoomedFont(style: style, weight: weight, design: design))
    }
}

@MainActor struct RootView: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    @AppStorage("prPaneWidth") private var prWidth: Double = 380
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            switch model.auth {
            case .checking:
                ProgressView("Looking for GitHub credentials…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsToken:
                TokenView()
            case .ready:
                HStack(spacing: 0) {
                    SidebarView()
                        .frame(width: 270 * z)
                    Divider()
                    DetailView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if model.showPRs {
                        ResizeHandle(width: $prWidth, range: 280...800)
                        PullRequestsView()
                            .frame(width: prWidth * z)
                    }
                }
            }
            if model.showSwitcher {
                QuickSwitcher()
            }
        }
        .zFont(.body)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.windowOpen = true
            model.openMainWindow = { openWindow(id: "main") }
            model.openAlertList = { openWindow(id: "alerts") }
        }
        .onDisappear { model.windowOpen = false }
        .sheet(item: Binding(get: { model.dispatching }, set: { model.dispatching = $0 })) { target in
            DispatchSheet(repo: target.repo)
                .zFont(.body)
                .environment(\.zoom, z)
                .environment(model)
        }
        .sheet(item: Binding(get: { model.trends }, set: { model.trends = $0 })) { target in
            TrendsSheet(repo: target.repo)
                .zFont(.body)
                .environment(\.zoom, z)
                .environment(model)
        }
        .sheet(item: Binding(get: { model.alerts.editing }, set: { model.alerts.editing = $0 })) { target in
            AlertEditor(target: target)
                .zFont(.body)
                .environment(\.zoom, z)
                .environment(model)
        }
    }
}

@MainActor struct TokenView: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * z) {
            Text("Connect to GitHub").zFont(.title2, weight: .bold)
            Text("No GitHub account found in the GitHub CLI, GH_TOKEN, or your Keychain. Paste a personal access token with the **repo** and **workflow** scopes — it's stored in your Keychain.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Or run `gh auth login` in Terminal, then relaunch. Add more accounts later in Settings (⌘,).")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("ghp_…", text: $token)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.saveToken(token) }
            if let error = model.tokenError {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Button("Create a token…") {
                    model.openInBrowser(URL(string: "https://github.com/settings/tokens/new?scopes=repo,workflow&description=ActionsHub")!)
                }
                Spacer()
                Button("Connect") { model.saveToken(token) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(token.isEmpty)
            }
        }
        .padding(28 * z)
        .frame(width: 460 * z)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
