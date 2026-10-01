import SwiftUI

/// Shows only the current group's repos, plus the group switcher and the run filter.
@MainActor struct SidebarView: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6 * z) {
                GroupPicker()
                LayoutPicker()
                Button { model.showPRs.toggle() } label: {
                    Image(systemName: "arrow.triangle.pull")
                        .foregroundStyle(model.showPRs ? Color.white : Color.primary)
                        .frame(width: 30 * z, height: 30 * z)
                        .background(RoundedRectangle(cornerRadius: 7 * z)
                            .fill(model.showPRs ? Color.accentColor : Color.primary.opacity(0.06)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Pull requests (⇧⌘P)")
            }
            .padding(.horizontal, 10 * z)
            .padding(.top, 10 * z)

            FilterBar()
                .padding(.horizontal, 10 * z)
                .padding(.top, 10 * z)
                .padding(.bottom, 4 * z)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1 * z) {
                    let cells = model.panes.count
                    ForEach(Array(model.pinned.enumerated()), id: \.element) { i, name in
                        if !model.isSinglePane && i == cells {
                            OverflowDivider()
                        }
                        RepoRow(fullName: name, shortcut: i < 9 ? i + 1 : nil)
                            .opacity(!model.isSinglePane && i >= cells ? 0.55 : 1)
                    }
                    if model.pinned.isEmpty {
                        VStack(alignment: .leading, spacing: 6 * z) {
                            Text("No repositories in this group yet.")
                            Text("Add some with the button below, or press ⌘K and then ⌘↩ to add the highlighted repo.")
                                .zFont(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10 * z)
                    }
                }
                .padding(.horizontal, 6 * z)
                .padding(.vertical, 6 * z)
            }

            Divider()
            HStack(spacing: 10 * z) {
                Button { model.openSwitcher(adding: true) } label: {
                    Label("Add Repository", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add repositories to this group (⇧⌘K)")
                Spacer()
                if let remaining = model.rateLimitRemaining {
                    Text("API \(remaining)").zFont(.caption2).foregroundStyle(.secondary)
                        .help("GitHub API requests left this hour")
                }
            }
            .padding(.horizontal, 12 * z)
            .padding(.vertical, 7 * z)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
}

// MARK: - Group picker

@MainActor private struct GroupPicker: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6 * z) {
                Image(systemName: "square.stack.3d.up")
                Text(model.currentGroup.name).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 4 * z)
                Image(systemName: "chevron.up.chevron.down").zFont(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10 * z)
            .padding(.vertical, 7 * z)
            .background(RoundedRectangle(cornerRadius: 7 * z).fill(Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Switch group (⌥⌘1–9)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            GroupMenu(close: { open = false })
                .zFont(.body)
                .environment(\.zoom, z)
                .environment(model)
        }
    }
}

@MainActor private struct GroupMenu: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    let close: () -> Void
    @State private var editing: UUID?
    @State private var draft = ""
    @State private var newName = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2 * z) {
            ForEach(Array(model.groups.enumerated()), id: \.element.id) { i, group in
                if editing == group.id {
                    TextField("Group name", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .focused($fieldFocused)
                        .onSubmit { model.renameGroup(group.id, to: draft); editing = nil }
                        .onExitCommand { editing = nil }
                        .padding(.vertical, 2 * z)
                } else {
                    MenuRow(checked: group.id == model.currentGroupID) {
                        Text(group.name).lineLimit(1)
                        Spacer(minLength: 8 * z)
                        Text("\(group.repos.count)").foregroundStyle(.secondary)
                        if i < 9 {
                            Text("⌥⌘\(i + 1)").zFont(.caption, design: .monospaced).foregroundStyle(.secondary)
                        }
                    } action: {
                        model.selectGroup(group.id)
                        close()
                    }
                    .contextMenu {
                        Button("Rename…") { draft = group.name; editing = group.id; fieldFocused = true }
                        Button("Delete Group", role: .destructive) { model.deleteGroup(group.id) }
                            .disabled(model.groups.count < 2)
                    }
                }
            }
            Divider().padding(.vertical, 4 * z)
            HStack(spacing: 6 * z) {
                Image(systemName: "plus").foregroundStyle(.secondary)
                TextField("New group…", text: $newName)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        let name = newName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        model.addGroup(named: name)
                        newName = ""
                        close()
                    }
            }
            .padding(.horizontal, 8 * z)
            .padding(.vertical, 4 * z)
            Text("Right-click a group to rename or delete it.")
                .zFont(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8 * z)
                .padding(.top, 2 * z)
        }
        .padding(8 * z)
        .frame(width: 280 * z)
    }
}

@MainActor struct MenuRow<Label: View>: View {
    @Environment(\.zoom) private var z
    let checked: Bool
    @ViewBuilder let label: Label
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6 * z) {
            Image(systemName: "checkmark").opacity(checked ? 1 : 0)
            label
        }
        .padding(.horizontal, 8 * z)
        .padding(.vertical, 5 * z)
        .background(RoundedRectangle(cornerRadius: 5 * z).fill(hovering ? Color.accentColor.opacity(0.2) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

// MARK: - Run filter

/// "Needs attention" chips. Each toggles a kind; "All" shows every recent run.
@MainActor private struct FilterBar: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4 * z) {
            ForEach(Attention.allCases, id: \.self) { kind in
                Chip(label: kind.label,
                     symbol: kind.state.symbol,
                     tint: kind.state.color,
                     on: !model.showAllRuns && model.attentionKinds.contains(kind)) {
                    model.toggleAttention(kind)
                }
            }
            Chip(label: "All", symbol: nil, tint: .accentColor, on: model.showAllRuns) {
                model.showAllRuns.toggle()
            }
            .help("Show every recent run (⇧⌘A)")
        }
    }
}

@MainActor private struct Chip: View {
    @Environment(\.zoom) private var z
    let label: String
    let symbol: String?
    let tint: Color
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3 * z) {
                if let symbol { Image(systemName: symbol).foregroundStyle(on ? tint : .secondary) }
                Text(label)
            }
            .zFont(.caption, weight: on ? .semibold : .regular)
            .lineLimit(1)
            .padding(.horizontal, 7 * z)
            .padding(.vertical, 4 * z)
            .background(Capsule().fill(on ? tint.opacity(0.18) : Color.primary.opacity(0.05)))
            .overlay(Capsule().stroke(on ? tint.opacity(0.5) : .clear))
            .foregroundStyle(on ? .primary : .secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Repo row

@MainActor private struct RepoRow: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    let fullName: String
    let shortcut: Int?
    @State private var hovering = false
    @State private var dropTarget = false

    private var owner: String { String(fullName.split(separator: "/").first ?? "") }
    private var name: String { String(fullName.split(separator: "/").last ?? "") }
    private var isSelected: Bool { model.selected == fullName }
    /// Shown in some other split pane.
    private var isVisible: Bool { !isSelected && model.visibleRepos.contains(fullName) }

    var body: some View {
        HStack(spacing: 8 * z) {
            StatusDot(state: model.summary(for: fullName))
            VStack(alignment: .leading, spacing: 1 * z) {
                Text(name).lineLimit(1)
                    .foregroundStyle(!isSelected ? (model.color(for: fullName)?.color ?? .primary) : .white)
                Text(owner).zFont(.caption).foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary).lineLimit(1)
            }
            Spacer(minLength: 4 * z)
            HStack(spacing: 3 * z) {
                ForEach(Attention.allCases, id: \.self) { kind in
                    let n = model.attentionCount(kind, in: fullName)
                    if n > 0 {
                        CountBadge(count: n, color: kind.state.color, selected: isSelected)
                            .help("\(n) \(kind.label.lowercased())")
                    }
                }
                let reviews = model.reviewRequestCount(in: fullName)
                if reviews > 0 {
                    CountBadge(count: reviews, color: .blue, selected: isSelected)
                        .help("\(reviews) pull request\(reviews == 1 ? "" : "s") waiting for your review")
                }
            }
            if let shortcut {
                Text("⌘\(shortcut)").zFont(.caption2, design: .monospaced)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
        }
        .padding(.horizontal, 8 * z)
        .padding(.vertical, 5 * z)
        .overlay(alignment: .leading) {
            if let color = model.color(for: fullName)?.color {
                Capsule().fill(color).frame(width: 3 * z).padding(.vertical, 6 * z)
            }
        }
        .foregroundStyle(isSelected ? .white : .primary)
        .background(
            RoundedRectangle(cornerRadius: 6 * z)
                .fill(isSelected ? Color.accentColor
                      : isVisible ? Color.accentColor.opacity(0.15)
                      : hovering ? Color.primary.opacity(0.06) : .clear)
        )
        .overlay(alignment: .top) {
            if dropTarget {
                Rectangle().fill(Color.accentColor).frame(height: 2 * z).offset(y: -1 * z)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.activate(fullName) }
        .onHover { hovering = $0 }
        .draggable(fullName)
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first, model.isPinned(dragged) else { return false }
            withAnimation(.snappy) { model.movePin(dragged, to: fullName) }
            return true
        } isTargeted: { dropTarget = $0 }
        .contextMenu {
            Button("Move Up") { model.movePin(fullName, by: -1) }
            Button("Move Down") { model.movePin(fullName, by: 1) }
            Divider()
            Menu("Color") {
                ForEach(RepoColor.allCases, id: \.self) { c in
                    Toggle(c.name, isOn: Binding(get: { model.color(for: fullName) == c },
                                                 set: { _ in model.setColor(c, for: fullName) }))
                }
                Divider()
                Button("No Color") { model.setColor(nil, for: fullName) }
            }
            Divider()
            Button("Open Actions in Browser") { model.openInBrowser(model.url(for: fullName)) }
            Button("Open Pull Requests in Browser") { model.openInBrowser(URL(string: "https://github.com/\(fullName)/pulls")!) }
            Divider()
            Button("Remove from Group") { model.togglePin(fullName) }
        }
    }
}

/// Separates the repos shown in the pane grid from the ones that don't fit.
@MainActor private struct OverflowDivider: View {
    @Environment(\.zoom) private var z

    var body: some View {
        HStack(spacing: 6 * z) {
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
            Text("Not in layout").zFont(.caption2).foregroundStyle(.secondary).fixedSize()
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
        }
        .padding(.horizontal, 8 * z)
        .padding(.vertical, 6 * z)
        .help("The pane grid shows the group's first repos in order. Drag a repo above this line, or pick a bigger layout, to show it.")
    }
}

@MainActor private struct CountBadge: View {
    @Environment(\.zoom) private var z
    let count: Int
    let color: Color
    let selected: Bool

    var body: some View {
        Text("\(count)")
            .zFont(.caption2, weight: .bold)
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5 * z)
            .padding(.vertical, 1 * z)
            .background(Capsule().fill(color))
            .overlay(Capsule().stroke(selected ? Color.white.opacity(0.7) : .clear))
    }
}

@MainActor struct StatusDot: View {
    @Environment(\.zoom) private var z
    let state: RunState?

    var body: some View {
        Circle()
            .fill(state?.color ?? Color.secondary.opacity(0.3))
            .frame(width: 9 * z, height: 9 * z)
            .overlay {
                if state == .running {
                    Circle().stroke(Color.orange.opacity(0.5), lineWidth: 3 * z).scaleEffect(1.5)
                }
            }
            .help(state?.label ?? "No recent runs loaded")
    }
}
