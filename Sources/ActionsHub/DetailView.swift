import SwiftUI
import AppKit

/// Lays the current group's panes out as a rows × cols grid.
@MainActor struct DetailView: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model

    var body: some View {
        let (rows, cols) = model.layout
        VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { r in
                if r > 0 { Divider() }
                HStack(spacing: 0) {
                    ForEach(0..<cols, id: \.self) { c in
                        if c > 0 { Divider() }
                        PaneView(index: r * cols + c)
                    }
                }
            }
        }
    }
}

@MainActor private struct PaneView: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    let index: Int
    @State private var dropTarget = false

    private var repo: String? { model.panes.indices.contains(index) ? model.panes[index] : nil }
    private var focused: Bool { model.focusedPane == index && model.panes.count > 1 }

    var body: some View {
        Group {
            if let repo {
                RunsView(repo: repo, pane: index)
                    .id(repo)
            } else {
                EmptyPane(index: index)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if focused {
                Rectangle().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2 * z).allowsHitTesting(false)
            }
        }
        .overlay {
            if dropTarget {
                Rectangle().fill(Color.accentColor.opacity(0.12))
                    .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 3 * z))
                    .allowsHitTesting(false)
            }
        }
        // Blank areas must be hit-testable, or clicking an empty pane can't focus it.
        .contentShape(Rectangle())
        // Focus follows any click in the pane without swallowing the click itself.
        .simultaneousGesture(TapGesture().onEnded { model.focusedPane = index })
        // Drag a repo from the sidebar onto a pane to show it there.
        .dropDestination(for: String.self) { items, _ in
            guard let repo = items.first else { return false }
            model.show(repo, inPane: index)
            return true
        } isTargeted: { dropTarget = $0 }
    }
}

/// Placeholder for an empty pane. With one pane: pick a repo to browse. With several,
/// panes follow the group's order, so an empty cell just means the group needs more repos.
@MainActor private struct EmptyPane: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    let index: Int

    var body: some View {
        if model.isSinglePane { picker } else { addPrompt }
    }

    private var addPrompt: some View {
        VStack(spacing: 10 * z) {
            Text("Pane \(index + 1)").zFont(.title3)
            Text("Panes show this group's repos in sidebar order.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Add a repository to the group… (⇧⌘K)") { model.openSwitcher(adding: true) }
                .buttonStyle(.link)
            Text("or drag one here from the sidebar")
                .zFont(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20 * z)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var picker: some View {
        VStack(spacing: 10 * z) {
            Text("Show a repository here").zFont(.title3)
            if model.pinned.isEmpty {
                Text("This group has no repositories yet.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 4 * z) {
                        ForEach(model.pinned, id: \.self) { repo in
                            RepoChoice(repo: repo) { model.show(repo, inPane: index) }
                        }
                    }
                    .padding(.horizontal, 4 * z)
                }
                .frame(maxWidth: 320 * z, maxHeight: 300 * z)
                .fixedSize(horizontal: false, vertical: true)
            }
            Button("Search all repositories… (⌘K)") {
                model.focusedPane = index
                model.openSwitcher(adding: false)
            }
            .buttonStyle(.link)
            Text("or drag one from the sidebar")
                .zFont(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20 * z)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor private struct RepoChoice: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    let repo: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8 * z) {
            StatusDot(state: model.summary(for: repo))
            Text(repo.split(separator: "/").last.map(String.init) ?? repo).lineLimit(1)
            Spacer(minLength: 0)
            if model.visibleRepos.contains(repo) {
                Text("shown").zFont(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10 * z)
        .padding(.vertical, 6 * z)
        .background(RoundedRectangle(cornerRadius: 6 * z).fill(hovering ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

@MainActor private struct RunsView: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    let repo: String
    let pane: Int
    @State private var showFilter = false
    /// Share of the pane height given to the PR subpane.
    @AppStorage("prSubpaneFraction") private var prFraction: Double = 0.4

    private var allRuns: [WorkflowRun] { model.runs[repo] ?? [] }
    private var workflowNames: [String] { Array(Set(allRuns.map(\.workflowFile))).sorted() }
    private var filter: String? { model.workflowFilter[repo] }
    private var visibleRuns: [WorkflowRun] {
        let base = model.showAllRuns ? allRuns : model.attentionRuns(for: repo)
        guard let filter else { return base }
        return base.filter { $0.workflowFile == filter }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let err = model.actionError {
                Banner(text: err, color: .red) { model.actionError = nil }
            }
            if let err = model.runsError[repo] {
                Banner(text: err, color: .red, onClose: nil)
            }
            if model.prSubpaneRepos.contains(repo) {
                // Runs on top, this repo's PRs below; drag the divider to resize.
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        runsArea
                            .frame(height: geo.size.height * (1 - prFraction))
                        RowResizeHandle(fraction: $prFraction, totalHeight: geo.size.height)
                        RepoPRSubpane(repo: repo)
                            .frame(maxHeight: .infinity)
                    }
                }
            } else {
                runsArea
            }
        }
    }

    @ViewBuilder private var runsArea: some View {
        if allRuns.isEmpty {
            Group {
                if model.runsLoading.contains(repo) || model.lastUpdated[repo] == nil {
                    ProgressView()
                } else {
                    Text("No workflow runs").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleRuns.isEmpty {
            VStack(spacing: 8 * z) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 34 * z)).foregroundStyle(.green)
                Text("Nothing needs attention").zFont(.title3)
                Text("\(allRuns.count) recent runs hidden").foregroundStyle(.secondary)
                Button("Show all runs") { model.showAllRuns = true }.buttonStyle(.link)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    LazyVStack(spacing: 0) {
                        ForEach(visibleRuns) { run in
                            RunRow(repo: repo, run: run)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12 * z) {
            ColorSwatch(repo: repo)
            VStack(alignment: .leading, spacing: 2 * z) {
                Text(repo.split(separator: "/").last.map(String.init) ?? repo)
                    .zFont(.title3, weight: .semibold).lineLimit(1)
                    .help(repo)
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    Text("\(repo.split(separator: "/").first ?? "") · " + (model.lastUpdated[repo].map { "updated \(Format.ago($0))" } ?? "loading…"))
                        .zFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button { showFilter.toggle() } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4 * z) {
                        Image(systemName: "line.3.horizontal.decrease")
                        Text(filter ?? "All workflows")
                        Image(systemName: "chevron.down").zFont(.caption2)
                    }
                    .fixedSize()
                    Image(systemName: filter == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                }
                .zFont(.callout)
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: 180 * z)
            .popover(isPresented: $showFilter, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach([nil] + workflowNames.map(Optional.some), id: \.self) { name in
                        FilterOption(title: name ?? "All workflows", checked: filter == name) {
                            model.workflowFilter[repo] = name
                            showFilter = false
                        }
                        if name == nil { Divider().padding(.vertical, 4 * z) }
                    }
                }
                .padding(6 * z)
                .zFont(.body)
                .environment(\.zoom, z)
            }
            HeaderButton(symbol: model.isPinned(repo) ? "pin.fill" : "pin", help: model.isPinned(repo) ? "Remove from group (⌘D)" : "Add to group (⌘D)") { model.togglePin(repo) }
            if model.runsLoading.contains(repo) {
                ProgressView().controlSize(.small).frame(width: 22 * z)
            } else {
                HeaderButton(symbol: "arrow.clockwise", help: "Refresh (⌘R)") { Task { await model.refreshRuns(repo) } }
            }
            PRLinkButton(repo: repo)
            HeaderButton(symbol: "safari", help: "Open in browser (⇧⌘O)") { model.openInBrowser(model.url(for: repo)) }
            if model.isSinglePane {
                HeaderButton(symbol: "xmark", help: "Clear this pane") { model.clearPane(pane) }
            }
        }
        .padding(.horizontal, 16 * z)
        .padding(.vertical, 10 * z)
        .background {
            // The repo's color tints the header and draws a bar across the top of the pane.
            if let color = model.color(for: repo)?.color {
                color.opacity(0.16)
                    .overlay(alignment: .top) { color.frame(height: 4 * z) }
            }
        }
    }
}

/// Open PRs for the repo; toggles the pane's PR subpane.
@MainActor private struct PRLinkButton: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    let repo: String

    var body: some View {
        let open = model.prSubpaneRepos.contains(repo)
        Button {
            model.togglePRSubpane(repo)
        } label: {
            HStack(spacing: 3 * z) {
                Image(systemName: "arrow.triangle.pull")
                if let n = model.openPRCount(in: repo), n > 0 {
                    Text("\(n)").monospacedDigit()
                }
                let reviews = model.reviewRequestCount(in: repo)
                if reviews > 0 {
                    Text("\(reviews)")
                        .zFont(.caption2, weight: .bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4 * z)
                        .background(Capsule().fill(Color.blue))
                }
            }
            .frame(height: 22 * z)
            .padding(.horizontal, 4 * z)
            .background(RoundedRectangle(cornerRadius: 5 * z).fill(open ? Color.accentColor.opacity(0.2) : .clear))
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .help((open ? "Hide" : "Show") + " pull requests" + (model.reviewRequestCount(in: repo) > 0 ? " — \(model.reviewRequestCount(in: repo)) waiting for your review" : ""))
    }
}

/// Color dot at the start of a pane header; click to pick the repo's color.
@MainActor struct ColorSwatch: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    let repo: String
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Group {
                if let color = model.color(for: repo)?.color {
                    Circle().fill(color)
                } else {
                    Circle().strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5 * z, dash: [3 * z, 2 * z]))
                }
            }
            .frame(width: 14 * z, height: 14 * z)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Pane color")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ColorPalette(selected: model.color(for: repo)) { choice in
                model.setColor(choice, for: repo)
                open = false
            }
            .environment(\.zoom, z)
        }
    }
}

@MainActor struct ColorPalette: View {
    @Environment(\.zoom) private var z
    let selected: RepoColor?
    let pick: (RepoColor?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * z) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26 * z), spacing: 6 * z), count: 6), spacing: 6 * z) {
                ForEach(RepoColor.allCases, id: \.self) { c in
                    Circle()
                        .fill(c.color)
                        .frame(width: 22 * z, height: 22 * z)
                        .overlay {
                            if c == selected {
                                Image(systemName: "checkmark").zFont(.caption, weight: .bold).foregroundStyle(.white)
                            }
                        }
                        .contentShape(Circle())
                        .onTapGesture { pick(c) }
                        .help(c.name)
                }
            }
            Button("No color") { pick(nil) }
                .buttonStyle(.link)
                .zFont(.callout)
        }
        .padding(12 * z)
    }
}

@MainActor private struct FilterOption: View {
    @Environment(\.zoom) private var z
    let title: String
    let checked: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6 * z) {
            Image(systemName: "checkmark").opacity(checked ? 1 : 0)
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8 * z)
        .padding(.vertical, 4 * z)
        .frame(minWidth: 200 * z, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5 * z).fill(hovering ? Color.accentColor.opacity(0.2) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

@MainActor private struct HeaderButton: View {
    @Environment(\.zoom) private var z
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22 * z, height: 22 * z)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

@MainActor private struct Banner: View {
    @Environment(\.zoom) private var z
    let text: String
    let color: Color
    let onClose: (() -> Void)?

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).lineLimit(2)
            Spacer()
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
        }
        .zFont(.callout)
        .foregroundStyle(color)
        .padding(.horizontal, 16 * z)
        .padding(.vertical, 8 * z)
        .background(color.opacity(0.1))
    }
}

@MainActor private struct RunRow: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    let repo: String
    let run: WorkflowRun
    @State private var hovering = false

    private var expanded: Bool { model.expandedRuns.contains(run.id) }

    private func metaLine(workflow: Bool, extras: Bool) -> some View {
        HStack(spacing: 6 * z) {
            if workflow { Text(run.workflowLabel) }
            Text("#\(run.runNumber)")
            if extras, let attempt = run.runAttempt, attempt > 1 { Text("attempt \(attempt)") }
            if let branch = run.headBranch {
                Text(branch)
                    .zFont(.caption, design: .monospaced)
                    .padding(.horizontal, 5 * z)
                    .padding(.vertical, 1 * z)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            }
            if extras {
                Text(run.event)
                if let actor = run.actor { Text("· \(actor.login)") }
            }
        }
        .fixedSize()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10 * z) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .zFont(.caption2, weight: .bold)
                    .foregroundStyle(.tertiary)
                    .frame(width: 10 * z)
                    .padding(.top, 5 * z)
                StateIcon(state: run.state)
                    .zFont(.title3)
                VStack(alignment: .leading, spacing: 3 * z) {
                    Text(run.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    // Narrow panes drop details instead of squashing them: the fullest
                    // variant that fits wins.
                    ViewThatFits(in: .horizontal) {
                        metaLine(workflow: true, extras: true)
                        metaLine(workflow: true, extras: false)
                        metaLine(workflow: false, extras: false)
                        // Last resort (always used if nothing above fits): trim the branch in the middle.
                        HStack(spacing: 6 * z) {
                            Text("#\(run.runNumber)").fixedSize()
                            if let branch = run.headBranch {
                                Text(branch)
                                    .zFont(.caption, design: .monospaced)
                                    .truncationMode(.middle)
                                    .padding(.horizontal, 5 * z)
                                    .padding(.vertical, 1 * z)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            }
                        }
                    }
                    .lineLimit(1)
                    .zFont(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8 * z)
                VStack(alignment: .trailing, spacing: 3 * z) {
                    Text(Format.ago(run.createdAt)).zFont(.caption)
                    if run.state == .waiting {
                        Text("awaiting review").zFont(.caption).foregroundStyle(.purple)
                    } else if run.state == .queued {
                        Text("queued").zFont(.caption).foregroundStyle(.secondary)
                    } else if let d = run.duration {
                        Label(Format.duration(d), systemImage: "stopwatch")
                            .zFont(.caption).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16 * z)
            .padding(.vertical, 9 * z)
            .background(hovering ? Color.primary.opacity(0.04) : .clear)
            .contentShape(Rectangle())
            .onTapGesture { model.toggleExpanded(repo: repo, run: run.id) }
            .onHover { hovering = $0 }
            .contextMenu { menu }

            if expanded {
                JobsList(jobs: model.jobs[run.id])
                    .padding(.leading, 52 * z)
                    .padding(.trailing, 16 * z)
                    .padding(.bottom, 10 * z)
            }
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Open in Browser") { model.openInBrowser(run.htmlUrl) }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(run.htmlUrl.absoluteString, forType: .string)
        }
        Divider()
        if run.state.isActive {
            Button("Cancel Run") { model.cancel(repo: repo, run: run) }
        } else {
            Button("Re-run All Jobs") { model.rerun(repo: repo, run: run, failedOnly: false) }
            if run.state == .failure {
                Button("Re-run Failed Jobs") { model.rerun(repo: repo, run: run, failedOnly: true) }
            }
        }
    }
}

@MainActor private struct JobsList: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    let jobs: [Job]?

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * z) {
            if let jobs {
                ForEach(jobs) { job in
                    VStack(alignment: .leading, spacing: 2 * z) {
                        HStack(spacing: 8 * z) {
                            StateIcon(state: job.state)
                            Text(job.name).lineLimit(1)
                            Spacer()
                            if let d = job.duration {
                                Text(Format.duration(d)).zFont(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            if let url = job.htmlUrl {
                                Button { model.openInBrowser(url) } label: {
                                    Image(systemName: "arrow.up.right.square")
                                }
                                .buttonStyle(.borderless)
                                .help("Open job log in browser")
                            }
                        }
                        // Surface the step that broke so you don't have to open the log.
                        ForEach(interestingSteps(job), id: \.number) { step in
                            HStack(spacing: 6 * z) {
                                StateIcon(state: step.state).zFont(.caption)
                                Text(step.name).zFont(.caption).lineLimit(1)
                            }
                            .padding(.leading, 24 * z)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3 * z)
                }
                if jobs.isEmpty {
                    Text("No jobs").zFont(.caption).foregroundStyle(.secondary)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(10 * z)
        .background(RoundedRectangle(cornerRadius: 8 * z).fill(Color.primary.opacity(0.035)))
    }

    private func interestingSteps(_ job: Job) -> [Step] {
        (job.steps ?? []).filter { $0.state == .failure || $0.state == .running }
    }
}

@MainActor struct StateIcon: View {
    @Environment(\.zoom) private var z
    let state: RunState

    var body: some View {
        Image(systemName: state.symbol)
            .foregroundStyle(state.color)
            .symbolEffect(.pulse, isActive: state == .running)
            .help(state.label)
    }
}

enum Format {
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func ago(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 10 { return "just now" }
        return relative.localizedString(for: date, relativeTo: Date())
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

/// A repo pane's own PR list: just this repo's PRs, bucketed like the docked panel.
@MainActor private struct RepoPRSubpane: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    let repo: String

    var body: some View {
        let sections = model.prSections(repo: repo)
        let total = sections.reduce(0) { $0 + $1.1.count }
        VStack(spacing: 0) {
            HStack(spacing: 8 * z) {
                Image(systemName: "arrow.triangle.pull")
                Text("Pull requests").fontWeight(.semibold)
                Text("\(total)").foregroundStyle(.secondary)
                Spacer()
                Button { model.openInBrowser(URL(string: "https://github.com/\(repo)/pulls")!) } label: {
                    Image(systemName: "safari")
                }
                .buttonStyle(.borderless)
                .help("Open pull requests on GitHub")
                Button { model.togglePRSubpane(repo) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Hide pull requests")
            }
            .zFont(.callout)
            .padding(.horizontal, 12 * z)
            .padding(.vertical, 6 * z)
            .background(model.color(for: repo)?.color.opacity(0.10) ?? Color.primary.opacity(0.04))
            Divider()
            if model.prSnapshot == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sections.isEmpty {
                Text(model.prIncludeStale && model.prIncludeDrafts ? "No open pull requests"
                     : "No open pull requests (drafts and PRs idle 30+ days hidden)")
                    .zFont(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(12 * z)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PRSectionsList(sections: sections, showRepo: false)
            }
        }
    }
}

/// Horizontal divider that resizes a vertical split by fraction of `totalHeight`.
@MainActor private struct RowResizeHandle: View {
    @Binding var fraction: Double
    let totalHeight: CGFloat
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.15))
            .frame(height: 1)
            .overlay(Color.clear.frame(height: 8).contentShape(Rectangle()))
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let base = start ?? fraction
                    start = base
                    guard totalHeight > 0 else { return }
                    fraction = min(max(base - value.translation.height / totalHeight, 0.15), 0.85)
                }
                .onEnded { _ in start = nil })
    }
}
