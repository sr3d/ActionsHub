import SwiftUI
import AppKit

/// Docked pane listing open PRs across the current group's repos, bucketed by what they
/// need from you. Clicking a PR opens it on GitHub.
@MainActor struct PullRequestsView: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    @State private var showOptions = false

    var body: some View {
        let sections = model.prSections()
        VStack(spacing: 0) {
            header(total: sections.reduce(0) { $0 + $1.1.count })
            Divider()
            if let err = model.prError {
                Text(err)
                    .zFont(.callout)
                    .foregroundStyle(.red)
                    .padding(12 * z)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1))
            }
            if model.prSnapshot == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sections.isEmpty {
                VStack(spacing: 8 * z) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 30 * z)).foregroundStyle(.green)
                    Text("No open pull requests").zFont(.title3)
                    if !model.prIncludeStale || !model.prIncludeDrafts {
                        Text("Drafts and PRs idle 30+ days are hidden").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PRSectionsList(sections: sections, showRepo: true)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    private func header(total: Int) -> some View {
        HStack(spacing: 10 * z) {
            VStack(alignment: .leading, spacing: 2 * z) {
                HStack(spacing: 6 * z) {
                    Image(systemName: "arrow.triangle.pull")
                    Text("Pull Requests").zFont(.title3, weight: .semibold)
                    Text("\(total)").foregroundStyle(.secondary)
                }
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    Text("\(model.currentGroup.name) · " + (model.prUpdated.map { "updated \(Format.ago($0))" } ?? "loading…"))
                        .zFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4 * z)
            Button { showOptions.toggle() } label: {
                Image(systemName: model.prIncludeDrafts || model.prIncludeStale
                      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .frame(width: 22 * z, height: 22 * z)
            }
            .buttonStyle(.borderless)
            .help("Filter pull requests")
            .popover(isPresented: $showOptions, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8 * z) {
                    Toggle("Show other people's drafts", isOn: Binding(get: { model.prIncludeDrafts }, set: { model.prIncludeDrafts = $0 }))
                    Toggle("Show PRs idle for 30+ days", isOn: Binding(get: { model.prIncludeStale }, set: { model.prIncludeStale = $0 }))
                }
                .zFont(.body)
                .padding(12 * z)
                .environment(\.zoom, z)
            }
            if model.prLoading {
                ProgressView().controlSize(.small).frame(width: 22 * z)
            } else {
                Button { Task { await model.refreshPRs() } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 22 * z, height: 22 * z)
                }
                .buttonStyle(.borderless)
                .help("Refresh pull requests")
            }
            Button { model.showPRs = false } label: {
                Image(systemName: "xmark").frame(width: 22 * z, height: 22 * z)
            }
            .buttonStyle(.borderless)
            .help("Hide pull requests (⇧⌘P)")
        }
        .padding(.horizontal, 14 * z)
        .padding(.vertical, 10 * z)
    }

}

/// Collapsible PR sections, shared by the docked pane and each repo's PR subpane.
@MainActor struct PRSectionsList: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    let sections: [(AppModel.PRSection, [PullRequest])]
    /// Off inside a repo's own subpane, where the repo tag would be redundant.
    let showRepo: Bool
    @State private var collapsed: Set<AppModel.PRSection> = [.other]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(sections, id: \.0) { section, prs in
                    Section {
                        if !collapsed.contains(section) {
                            ForEach(prs) { pr in
                                PRRow(pr: pr, showRepo: showRepo)
                                Divider().padding(.leading, 12 * z)
                            }
                        }
                    } header: {
                        sectionHeader(section, count: prs.count)
                    }
                }
                if showRepo, model.prSnapshot?.truncated == true {
                    Text("Some repos have more than 100 open PRs; only the most recently updated are shown.")
                        .zFont(.caption)
                        .foregroundStyle(.secondary)
                        .padding(12 * z)
                }
            }
        }
    }

    private func sectionHeader(_ section: AppModel.PRSection, count: Int) -> some View {
        HStack(spacing: 6 * z) {
            Image(systemName: "chevron.right")
                .zFont(.caption2, weight: .bold)
                .rotationEffect(.degrees(collapsed.contains(section) ? 0 : 90))
            Text(section.rawValue.uppercased()).zFont(.caption2, weight: .semibold)
            Text("\(count)")
                .zFont(.caption2, weight: .bold)
                .foregroundStyle(section == .yourReview ? .white : .secondary)
                .padding(.horizontal, 5 * z)
                .background(Capsule().fill(section == .yourReview ? Color.blue : Color.primary.opacity(0.08)))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12 * z)
        .padding(.vertical, 6 * z)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture {
            if collapsed.contains(section) { collapsed.remove(section) } else { collapsed.insert(section) }
        }
    }
}

@MainActor private struct PRRow: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    var showRepo = true
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8 * z) {
            // CI status of the head commit.
            Image(systemName: pr.ci?.symbol ?? "circle.dashed")
                .foregroundStyle(pr.ci?.color ?? .secondary)
                .padding(.top, 1 * z)
                .help(pr.ciState.map { "Checks: \($0.lowercased())" } ?? "No checks")
            VStack(alignment: .leading, spacing: 3 * z) {
                Text(pr.title).lineLimit(2)
                HStack(spacing: 5 * z) {
                    if showRepo { RepoTag(repo: pr.repo) }
                    Text("#\(pr.number)").fixedSize()
                    if let author = pr.author { Text("· \(author)") }
                    Text("· \(Format.ago(pr.updatedAt))").fixedSize()
                }
                .lineLimit(1)
                .zFont(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 4 * z) {
                    if pr.isDraft { Badge(text: "Draft", color: .gray) }
                    switch pr.reviewDecision {
                    case "APPROVED": Badge(text: "Approved", color: .green)
                    case "CHANGES_REQUESTED": Badge(text: "Changes requested", color: .red)
                    case "REVIEW_REQUIRED": Badge(text: "Review required", color: .orange)
                    default: EmptyView()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12 * z)
        .padding(.vertical, 8 * z)
        .background(hovering ? Color.primary.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.openInBrowser(pr.url) }
        .help("Open #\(pr.number) on GitHub")
        .contextMenu {
            Button("Open in Browser") { model.openInBrowser(pr.url) }
            Button("Open Files Changed") { model.openInBrowser(pr.url.appendingPathComponent("files")) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pr.url.absoluteString, forType: .string)
            }
            if model.panes.contains(pr.repo) {
                Divider()
                Button("Show \(pr.repoName) Actions") { model.activate(pr.repo) }
            }
        }
    }
}

/// Repo name, tinted with the repo's color when one is set.
@MainActor struct RepoTag: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    let repo: String

    var body: some View {
        let name = String(repo.split(separator: "/").last ?? Substring(repo))
        if let color = model.color(for: repo)?.color {
            Text(name)
                .fontWeight(.medium)
                .foregroundStyle(color)
                .padding(.horizontal, 5 * z)
                .background(Capsule().fill(color.opacity(0.15)))
        } else {
            Text(name).fontWeight(.medium)
        }
    }
}

@MainActor private struct Badge: View {
    @Environment(\.zoom) private var z
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .zFont(.caption2, weight: .semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 6 * z)
            .padding(.vertical, 1 * z)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

/// Drag handle between the pane grid and the PR pane. `width` is in unzoomed points.
@MainActor struct ResizeHandle: View {
    @Environment(\.zoom) private var z
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1)
            .overlay(Color.clear.frame(width: 8).contentShape(Rectangle()))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let base = start ?? width
                    start = base
                    width = min(max(base - value.translation.width / z, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in start = nil })
    }
}
