import SwiftUI
import AppKit

/// Lays the current group's panes out as a rows × cols grid.
@MainActor struct DetailView: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model

    var body: some View {
        let (rows, cols) = model.layout
        PaneGrid(rows: rows, cols: cols) {
            ForEach(0..<rows * cols, id: \.self) { i in
                PaneView(index: i)
            }
        }
        .background(GridLines(rows: rows, cols: cols).fill(Color(nsColor: .separatorColor)))
    }
}

/// A run row's top line: fixed items at their natural size (measured once and cached),
/// the `Flexible` item (title and details) gets the width that's left, and the items after
/// it sit at the trailing edge. Top-aligned. An HStack with a Spacer re-negotiated every
/// child several times per frame while resizing.
struct RunRowLayout: Layout {
    var spacing: CGFloat
    /// Minimum room between the flexible item and the trailing items.
    var trailingGap: CGFloat

    struct Flexible: LayoutValueKey { static let defaultValue = false }

    struct Cache {
        var sizes: [CGSize?]   // nil for the flexible item
        var flexible: Int?
    }

    func makeCache(subviews: Subviews) -> Cache {
        let flexible = subviews.firstIndex { $0[Flexible.self] }
        return Cache(sizes: subviews.indices.map { $0 == flexible ? nil : subviews[$0].sizeThatFits(.unspecified) },
                     flexible: flexible)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    /// Width left for the flexible item.
    private func flexWidth(_ total: CGFloat, _ cache: Cache) -> CGFloat {
        let fixed = cache.sizes.compactMap { $0?.width }
        let gaps = spacing * CGFloat(max(fixed.count - 1, 0)) + (cache.flexible == nil ? 0 : spacing + trailingGap)
        return max(0, total - fixed.reduce(0, +) - gaps)
    }

    private func flexSize(_ width: CGFloat?, _ subviews: Subviews, _ cache: Cache) -> CGSize {
        guard let i = cache.flexible else { return .zero }
        return subviews[i].sizeThatFits(ProposedViewSize(width: width.map { flexWidth($0, cache) }, height: nil))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let flex = flexSize(proposal.width, subviews, cache)
        let height = max(flex.height, cache.sizes.compactMap { $0?.height }.max() ?? 0)
        if let width = proposal.width, width.isFinite { return CGSize(width: width, height: height) }
        let fixed = cache.sizes.compactMap { $0?.width }
        return CGSize(width: fixed.reduce(0, +) + flex.width + spacing * CGFloat(max(subviews.count - 1, 0)) + trailingGap,
                      height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let flexW = flexWidth(bounds.width, cache)
        // Leading items and the flexible one from the left; trailing items from the right.
        var x = bounds.minX
        let leading = cache.flexible.map { 0...$0 } ?? 0...(subviews.count - 1)
        for i in leading where subviews.indices.contains(i) {
            let size = cache.sizes[i] ?? CGSize(width: flexW, height: bounds.height)
            subviews[i].place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: size.width, height: cache.sizes[i]?.height))
            x += size.width + spacing
        }
        guard let flexible = cache.flexible, flexible + 1 < subviews.count else { return }
        var right = bounds.maxX
        for i in stride(from: subviews.count - 1, to: flexible, by: -1) {
            let size = cache.sizes[i] ?? .zero
            right -= size.width
            subviews[i].place(at: CGPoint(x: right, y: bounds.minY), proposal: ProposedViewSize(size))
            right -= spacing
        }
    }
}

/// One line of run details that drops whole details when it runs out of room, instead of
/// squashing them: tier 2 goes first, then tier 1; if even tier 0 doesn't fit, the
/// `Squeezable` item (the branch) is truncated. Natural widths are measured once and cached,
/// so a resize only adds up numbers. ViewThatFits with one variant per tier re-measured
/// every variant of every row on each frame, about 30 ms per frame with a 4x3 grid.
struct MetaLine: Layout {
    var spacing: CGFloat

    /// 0: always shown; higher tiers are dropped first.
    struct Tier: LayoutValueKey { static let defaultValue = 0 }
    /// Truncated to fit when even the tier-0 items don't.
    struct Squeezable: LayoutValueKey { static let defaultValue = false }

    struct Cache {
        var sizes: [CGSize]
        var tiers: [Int]
        var height: CGFloat
    }

    func makeCache(subviews: Subviews) -> Cache {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return Cache(sizes: sizes, tiers: subviews.map { $0[Tier.self] }, height: sizes.map(\.height).max() ?? 0)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    /// Which items to show, and whether the squeezable one must shrink to fit `width`.
    private func plan(_ width: CGFloat?, _ subviews: Subviews, _ cache: Cache) -> (shown: [Bool], squeeze: Bool) {
        let tiers = cache.tiers
        for maxTier in [2, 1, 0] {
            let shown = tiers.map { $0 <= maxTier }
            guard let width else { return (shown, false) }
            if naturalWidth(shown, cache) <= width { return (shown, false) }
        }
        return (tiers.map { $0 == 0 }, true)
    }

    private func naturalWidth(_ shown: [Bool], _ cache: Cache) -> CGFloat {
        let widths = zip(shown, cache.sizes).filter(\.0).map(\.1.width)
        return widths.reduce(0, +) + spacing * CGFloat(max(widths.count - 1, 0))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let (shown, squeeze) = plan(proposal.width, subviews, cache)
        // With nothing to truncate, the tier-0 items are as narrow as it gets.
        let canSqueeze = squeeze && subviews.contains { $0[Squeezable.self] }
        let width = canSqueeze ? (proposal.width ?? 0) : naturalWidth(shown, cache)
        return CGSize(width: width, height: cache.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let (shown, squeeze) = plan(bounds.width, subviews, cache)
        let overflow = squeeze ? naturalWidth(shown, cache) - bounds.width : 0
        var x = bounds.minX
        for (i, subview) in subviews.enumerated() {
            var size = cache.sizes[i]
            guard shown[i] else {
                // Dropped: parked outside the row, where the scroll view clips it away.
                subview.place(at: CGPoint(x: bounds.maxX + 10_000, y: bounds.minY), proposal: ProposedViewSize(size))
                continue
            }
            if overflow > 0, subview[Squeezable.self] { size.width = max(0, size.width - overflow) }
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
            x += size.width + spacing
        }
    }
}

/// Pane header: swatch, repo name over a details line, buttons on the right. The name gets
/// its full width first, then the buttons (MetaLine drops the least useful ones), and the
/// details line truncates into what's left. Stacks gave the details line equal say, so a
/// long details line truncated the name (#11).
struct PaneHeaderLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    // Subviews: swatch, name, details, buttons.
    private struct Plan { var swatch, name, details, buttons: CGSize }

    private func plan(_ width: CGFloat?, _ subviews: Subviews) -> Plan {
        let swatch = subviews[0].sizeThatFits(.unspecified)
        let name = subviews[1].sizeThatFits(.unspecified)
        let details = subviews[2].sizeThatFits(.unspecified)
        guard let width else {
            let buttons = subviews[3].sizeThatFits(.unspecified)
            return Plan(swatch: swatch, name: name, details: details, buttons: buttons)
        }
        let room = max(0, width - swatch.width - 2 * spacing)
        let buttons = subviews[3].sizeThatFits(ProposedViewSize(width: max(0, room - name.width), height: nil))
        let text = max(0, room - buttons.width)
        return Plan(swatch: swatch,
                    name: CGSize(width: min(name.width, text), height: name.height),
                    details: CGSize(width: min(details.width, text), height: details.height),
                    buttons: buttons)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let p = plan(proposal.width, subviews)
        let width = proposal.width ?? (p.swatch.width + max(p.name.width, p.details.width) + p.buttons.width + 2 * spacing)
        let height = max(p.swatch.height, p.name.height + lineSpacing + p.details.height, p.buttons.height)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let p = plan(bounds.width, subviews)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(p.swatch))
        let x = bounds.minX + p.swatch.width + spacing
        let top = bounds.midY - (p.name.height + lineSpacing + p.details.height) / 2
        subviews[1].place(at: CGPoint(x: x, y: top), proposal: ProposedViewSize(p.name))
        subviews[2].place(at: CGPoint(x: x, y: top + p.name.height + lineSpacing), proposal: ProposedViewSize(p.details))
        subviews[3].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(p.buttons))
    }
}

/// Equal grid that proposes each pane its exact cell size, once. Nested HStack/VStack with
/// flexible panes measured every pane several times per layout pass, which made resizing a
/// big grid drop well below 60 fps.
struct PaneGrid: Layout {
    let rows: Int
    let cols: Int
    /// Room between cells for the 1 pt divider lines.
    static let gap: CGFloat = 1

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cell = Self.cellSize(in: bounds.size, rows: rows, cols: cols)
        for (i, subview) in subviews.enumerated() {
            let (r, c) = (i / cols, i % cols)
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(c) * (cell.width + Self.gap),
                                      y: bounds.minY + CGFloat(r) * (cell.height + Self.gap)),
                          proposal: ProposedViewSize(cell))
        }
    }

    static func cellSize(in size: CGSize, rows: Int, cols: Int) -> CGSize {
        CGSize(width: max(0, (size.width - gap * CGFloat(cols - 1)) / CGFloat(cols)),
               height: max(0, (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)))
    }
}

/// The divider lines between `PaneGrid` cells, as one shape.
struct GridLines: Shape {
    let rows: Int
    let cols: Int

    func path(in rect: CGRect) -> Path {
        let cell = PaneGrid.cellSize(in: rect.size, rows: rows, cols: cols)
        let gap = PaneGrid.gap
        var path = Path()
        for c in 1..<max(cols, 1) {
            path.addRect(CGRect(x: rect.minX + CGFloat(c) * (cell.width + gap) - gap, y: rect.minY, width: gap, height: rect.height))
        }
        for r in 1..<max(rows, 1) {
            path.addRect(CGRect(x: rect.minX, y: rect.minY + CGFloat(r) * (cell.height + gap) - gap, width: rect.width, height: gap))
        }
        return path
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
        // Exactly the cell's size even when the content is wider (min 0), clipped to it, so a
        // narrow pane never paints over its neighbours.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
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
        PaneHeaderLayout(spacing: 12 * z, lineSpacing: 2 * z) {
            ColorSwatch(repo: repo)
            Text(repo.split(separator: "/").last.map(String.init) ?? repo)
                .zFont(.title3, weight: .semibold).lineLimit(1)
                .minimumScaleFactor(0.8)
                .help(repo)
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                Text("\(repo.split(separator: "/").first ?? "") · "
                     + (model.multiAccount ? (model.account(for: repo).map { "@\($0.login) · " } ?? "") : "")
                     + (model.lastUpdated[repo].map { "updated \(Format.ago($0))" } ?? "loading…"))
                    .zFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            MetaLine(spacing: 4 * z) {
                Button { showFilter.toggle() } label: {
                    HStack(spacing: 4 * z) {
                        Image(systemName: filter == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                        if let filter {
                            Text(filter).lineLimit(1).frame(maxWidth: 140 * z)
                        }
                    }
                    .frame(height: 22 * z)
                    .zFont(.callout)
                }
                .buttonStyle(.borderless)
                .help(filter.map { "Showing \($0) only" } ?? "Filter by workflow")
                // An active filter matters more than the buttons that have shortcuts.
                .layoutValue(key: MetaLine.Tier.self, value: filter == nil ? 2 : 1)
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
                    .layoutValue(key: MetaLine.Tier.self, value: 2)
                Group {
                    if model.runsLoading.contains(repo) {
                        ProgressView().controlSize(.small).frame(width: 22 * z)
                    } else {
                        HeaderButton(symbol: "arrow.clockwise", help: "Refresh (⌘R)") { Task { await model.refreshRuns(repo) } }
                    }
                }
                .layoutValue(key: MetaLine.Tier.self, value: 1)
                PRLinkButton(repo: repo)
                    .layoutValue(key: MetaLine.Tier.self, value: 1)
                HeaderButton(symbol: "safari", help: "Open in browser (⇧⌘O)") { model.openInBrowser(model.url(for: repo)) }
                if model.isSinglePane {
                    HeaderButton(symbol: "xmark", help: "Clear this pane") { model.clearPane(pane) }
                }
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

    /// Workflow, run number, branch and extras on one line. Narrow panes drop details instead
    /// of squashing them (see `MetaLine`).
    private var metaLine: some View {
        MetaLine(spacing: 6 * z) {
            Text(run.workflowLabel).layoutValue(key: MetaLine.Tier.self, value: 1)
            Text("#\(run.runNumber)")
            if let attempt = run.runAttempt, attempt > 1 {
                Text("attempt \(attempt)").layoutValue(key: MetaLine.Tier.self, value: 2)
            }
            if let branch = run.headBranch {
                Text(branch)
                    .zFont(.caption, design: .monospaced)
                    .truncationMode(.middle)
                    .padding(.horizontal, 5 * z)
                    .padding(.vertical, 1 * z)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    .layoutValue(key: MetaLine.Squeezable.self, value: true)
            }
            Text(run.event).layoutValue(key: MetaLine.Tier.self, value: 2)
            if let actor = run.actor {
                Text("· \(actor.login)").layoutValue(key: MetaLine.Tier.self, value: 2)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RunRowLayout(spacing: 10 * z, trailingGap: 8 * z) {
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
                    metaLine
                    .lineLimit(1)
                    .zFont(.caption)
                    .foregroundStyle(.secondary)
                }
                .layoutValue(key: RunRowLayout.Flexible.self, value: true)
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
        Group {
            if state == .running {
                // A plain partial ring reads as "spinning" far better than rotating a
                // symmetric symbol. Sized by an invisible symbol so it matches the font/zoom.
                Image(systemName: "circle")
                    .hidden()
                    .overlay {
                        SpinnerRing(color: state.color, lineWidth: 2 * z)
                            .padding(1.5 * z)
                    }
            } else {
                Image(systemName: state.symbol)
                    .foregroundStyle(state.color)
            }
        }
        .help(state.label)
    }
}

/// Partial ring rotated by Core Animation. The render server runs the rotation, so any
/// number of running icons cost the main thread nothing per frame. (A SwiftUI TimelineView
/// spinner re-rendered and re-laid-out the whole window at 30 fps per icon.) CA animations
/// also ignore Reduce Motion, so it keeps spinning.
struct SpinnerRing: NSViewRepresentable {
    let color: Color
    let lineWidth: CGFloat
    var period: Double = 1.2

    func makeNSView(context: Context) -> RingView { RingView() }

    func updateNSView(_ view: RingView, context: Context) {
        view.configure(color: NSColor(color), lineWidth: lineWidth, period: period)
    }

    final class RingView: NSView {
        private let ring = CAShapeLayer()
        private var color = NSColor.systemOrange
        private var period = 1.2
        private static let key = "spin"

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            ring.fillColor = nil
            ring.lineCap = .round
            ring.strokeEnd = 0.7
            layer?.addSublayer(ring)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        /// Clicks and hover go to the SwiftUI views around it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func configure(color: NSColor, lineWidth: CGFloat, period: Double) {
            self.color = color
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyColor()
            if ring.lineWidth != lineWidth { ring.lineWidth = lineWidth; needsLayout = true }
            CATransaction.commit()
            // Only restart the rotation when its speed changes, or it would jump on every update.
            if period != self.period {
                self.period = period
                ring.removeAnimation(forKey: Self.key)
            }
            startIfNeeded()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.frame = bounds
            let inset = ring.lineWidth / 2
            ring.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
            CATransaction.commit()
        }

        /// Core Animation drops a layer's animations when it leaves the window.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            startIfNeeded()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyColor()
            CATransaction.commit()
        }

        private func applyColor() {
            effectiveAppearance.performAsCurrentDrawingAppearance { ring.strokeColor = color.cgColor }
        }

        private func startIfNeeded() {
            guard window != nil, ring.animation(forKey: Self.key) == nil else { return }
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi   // clockwise: AppKit layers have y pointing up
            spin.duration = period
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            ring.add(spin, forKey: Self.key)
        }
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
