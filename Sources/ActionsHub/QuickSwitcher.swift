import SwiftUI
import AppKit

/// ⌘K palette: fuzzy-find any repository, pinned ones first.
/// Typing an `owner/name` that isn't in your list offers to open it directly.
@MainActor struct QuickSwitcher: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var index = 0
    @State private var keyMonitor: Any?
    @FocusState private var focused: Bool

    private enum Item: Hashable {
        case repo(String)
        case external(String)

        var name: String {
            switch self { case .repo(let n), .external(let n): n }
        }
    }

    private var items: [Item] {
        let names = model.pinned + model.repos.map(\.fullName).filter { !model.isPinned($0) }
        var result: [Item]
        if query.isEmpty {
            result = names.prefix(50).map { .repo($0) }
        } else {
            result = names.enumerated()
                .compactMap { i, name in Fuzzy.score(query, name).map { (name, $0, i) } }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
                .prefix(50)
                .map { .repo($0.0) }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.split(separator: "/").count == 2,
           !names.contains(where: { $0.caseInsensitiveCompare(q) == .orderedSame }) {
            result.append(.external(q))
        }
        return result
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: 8 * z) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(model.switcherAddsToGroup ? "Add repository to \(model.currentGroup.name)…" : "Jump to repository…", text: $query)
                        .textFieldStyle(.plain)
                        .zFont(.title3)
                        .focused($focused)
                        .onSubmit { choose() }
                        .onChange(of: query) { index = 0 }
                }
                .padding(14 * z)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element) { i, item in
                                row(item, highlighted: i == index)
                                    .onTapGesture { index = i; choose() }
                                    .onHover { if $0 { index = i } }
                            }
                        }
                        .padding(6 * z)
                    }
                    .onChange(of: index) {
                        let list = items
                        if list.indices.contains(index) { proxy.scrollTo(list[index]) }
                    }
                }
                .frame(height: min(Double(max(items.count, 1)) * 33 * z + 12 * z, 360 * z))
                Divider()
                HStack(spacing: 14 * z) {
                    if model.switcherAddsToGroup {
                        Text("↩ add / remove")
                    } else {
                        Text("↩ open in pane")
                        Text("⌘↩ add / remove from group")
                    }
                    Spacer()
                    Text("esc close")
                }
                .zFont(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14 * z)
                .padding(.vertical, 8 * z)
            }
            .frame(width: 520 * z)
            .background(RoundedRectangle(cornerRadius: 12 * z).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12 * z).stroke(Color.primary.opacity(0.12)))
            .shadow(radius: 24 * z, y: 8 * z)
            .padding(.top, 70 * z)
        }
        .onAppear {
            focused = true
            installKeyMonitor()
        }
        .onDisappear(perform: removeKeyMonitor)
    }

    private func row(_ item: Item, highlighted: Bool) -> some View {
        HStack(spacing: 10 * z) {
            switch item {
            case .repo(let name):
                StatusDot(state: model.summary(for: name))
                Text(name).lineLimit(1)
                Spacer()
                if model.isPinned(name) {
                    Label("In group", systemImage: "checkmark.circle.fill")
                        .zFont(.caption)
                        .foregroundStyle(highlighted ? .white : .green)
                }
            case .external(let name):
                Image(systemName: "arrow.right.circle")
                Text("Open \(name)").lineLimit(1)
                Spacer()
            }
        }
        .foregroundStyle(highlighted ? .white : .primary)
        .padding(.horizontal, 10 * z)
        .padding(.vertical, 7 * z)
        .background(RoundedRectangle(cornerRadius: 6 * z).fill(highlighted ? Color.accentColor : .clear))
        .contentShape(Rectangle())
    }

    private func choose() {
        if model.switcherAddsToGroup { toggleMembership(); return }
        let list = items
        guard list.indices.contains(index) else { return }
        switch list[index] {
        case .repo(let name): model.selected = name
        case .external(let name): model.open(fullName: name)
        }
        close()
    }

    /// Adds or removes the highlighted repo from the current group, keeping the palette open.
    private func toggleMembership() {
        let list = items
        guard list.indices.contains(index) else { return }
        switch list[index] {
        case .repo(let name): model.togglePin(name)
        case .external(let name): model.addToGroup(fullName: name); query = ""
        }
    }

    private func close() { model.showSwitcher = false }

    /// Arrow keys and Escape are swallowed by the text field's editor, so catch them at the window level.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 125: index = min(index + 1, max(items.count - 1, 0)); return nil  // down
            case 126: index = max(index - 1, 0); return nil                         // up
            case 53: close(); return nil                                             // escape
            case 36 where event.modifierFlags.contains(.command): toggleMembership(); return nil  // ⌘↩
            default: return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

enum Fuzzy {
    /// Ranks how well `query` matches a repo. Matches against the repo name only, unless the
    /// query contains "/" (then against owner/name). Tiers: exact > prefix > word start >
    /// substring > all words present > loose subsequence. Returns nil for no match.
    static func score(_ query: String, _ fullName: String) -> Int? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        let target = q.contains("/")
            ? fullName.lowercased()
            : String(fullName.split(separator: "/").last ?? Substring(fullName)).lowercased()
        let lengthPenalty = min(target.count, 99)

        if target == q { return 10_000 }
        if target.hasPrefix(q) { return 8_000 - lengthPenalty }
        if let range = target.range(of: q) {
            let atWordStart = range.lowerBound == target.startIndex
                || "-_./ ".contains(target[target.index(before: range.lowerBound)])
            return (atWordStart ? 6_000 : 4_000) - lengthPenalty
        }
        let words = q.split(separator: " ")
        if words.count > 1, words.allSatisfy({ target.contains($0) }) { return 3_000 - lengthPenalty }
        // Short queries only match literally; loose matching on 1–3 letters is mostly noise.
        if q.count >= 4, let s = subsequence(q.filter { $0 != " " }, target) { return s - lengthPenalty }
        return nil
    }

    /// Loose match ("tmvpc" → terraform-modules-vpc). Rewards characters that start a word
    /// or continue a run; rejects matches too scattered to be intentional.
    private static func subsequence(_ q: String, _ target: String) -> Int? {
        let q = Array(q), t = Array(target)
        var score = 0, qi = 0, streak = 0, gaps = 0
        for (ti, c) in t.enumerated() where qi < q.count {
            if c == q[qi] {
                let wordStart = ti == 0 || "-_./ ".contains(t[ti - 1])
                streak = wordStart ? 1 : streak + 1
                score += wordStart ? 30 : 10 * streak
                qi += 1
            } else if qi > 0 {
                if streak > 0 { gaps += 1 }
                streak = 0
            }
        }
        guard qi == q.count, gaps <= max(2, q.count / 2) else { return nil }
        return 1_000 + score
    }
}
