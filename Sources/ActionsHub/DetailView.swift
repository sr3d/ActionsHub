import SwiftUI

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

/// Placeholder for an unassigned pane: one click on a repo fills this pane.
@MainActor private struct EmptyPane: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    let index: Int

    var body: some View {
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
    }

    private var header: some View {
        HStack(spacing: 12 * z) {
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
                HStack(spacing: 4 * z) {
                    Image(systemName: "line.3.horizontal.decrease")
                    Text(filter ?? "All workflows").lineLimit(1)
                    Image(systemName: "chevron.down").zFont(.caption2)
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
            HeaderButton(symbol: "safari", help: "Open in browser (⇧⌘O)") { model.openInBrowser(model.url(for: repo)) }
            if model.panes.count > 1 {
                HeaderButton(symbol: "xmark", help: "Clear this pane") { model.clearPane(pane) }
            }
        }
        .padding(.horizontal, 16 * z)
        .padding(.vertical, 10 * z)
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
                    HStack(spacing: 6 * z) {
                        Text(run.workflowLabel).lineLimit(1)
                        Text("#\(run.runNumber)")
                        if let attempt = run.runAttempt, attempt > 1 { Text("attempt \(attempt)") }
                        if let branch = run.headBranch {
                            Text(branch)
                                .zFont(.caption, design: .monospaced)
                                .lineLimit(1)
                                .padding(.horizontal, 5 * z)
                                .padding(.vertical, 1 * z)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        }
                        Text(run.event)
                        if let actor = run.actor { Text("· \(actor.login)").lineLimit(1) }
                    }
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
