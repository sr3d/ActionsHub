import SwiftUI
import AppKit

// MARK: - Editor

/// One sheet for every level: a group, a repo, a run, or a step of a run.
@MainActor struct AlertEditor: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: AlertTarget

    private enum RepoMode: Hashable { case asGroup, on, off }

    @State private var enabled = false
    @State private var repoMode = RepoMode.asGroup
    @State private var rule = AlertRule.runDefault
    @State private var stepName = ""
    @State private var everyRun = false
    @State private var loaded = false

    private var store: AlertStore { model.alerts }
    private var isStep: Bool { if case .step = target { true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * z) {
            Text(title).zFont(.title3, weight: .semibold)
            levelControls
            if isOn {
                triggerControls
            }
            if case .step(_, let run, _) = target {
                costNote(run)
                otherStepAlerts(run)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isOn && rule.triggers.isEmpty || isStep && stepName.isEmpty)
            }
        }
        .padding(20 * z)
        .frame(width: 440 * z)
        // Native controls don't follow the font zoom; a larger size keeps them in step.
        .controlSize(z >= 1.25 ? .large : .regular)
        .onAppear(perform: load)
    }

    private var title: String {
        switch target {
        case .group(let id): "Alerts for \(model.groups.first { $0.id == id }?.name ?? "group")"
        case .repo(let repo): "Alerts for \(repo.split(separator: "/").last.map(String.init) ?? repo)"
        case .run(_, let run): "Alert on \(run.workflowName) #\(run.runNumber)"
        case .step(_, let run, let job): "Alert on a step of \(run.workflowName) #\(run.runNumber) › \(job.name)"
        }
    }

    private var isOn: Bool {
        switch target {
        case .repo: repoMode == .on
        case .step: true
        default: enabled
        }
    }

    @ViewBuilder private var levelControls: some View {
        switch target {
        case .group:
            Toggle("Alert on runs in this group's repos", isOn: $enabled)
            Text("Repos set to their own alerts follow those instead.").zFont(.caption).foregroundStyle(.secondary)
        case .repo(let repo):
            Picker("Alerts", selection: $repoMode) {
                Text(model.groupAlertRule(repo) == nil ? "As its group (off)" : "As its group (on)").tag(RepoMode.asGroup)
                Text("On").tag(RepoMode.on)
                Text("Off").tag(RepoMode.off)
            }
            .pickerStyle(.radioGroup)
            if repoMode == .asGroup, let groupRule = model.groupAlertRule(repo) {
                Text("Its group alerts when a run \(groupRule.summary).").zFont(.caption).foregroundStyle(.secondary)
            }
        case .run:
            Toggle("Alert on this run", isOn: $enabled)
            Text("Overrides the repo and group settings for this run. Ends once the run is over.")
                .zFont(.caption).foregroundStyle(.secondary)
        case .step(_, _, let job):
            Picker("Step", selection: $stepName) {
                ForEach(job.steps ?? [], id: \.number) { Text($0.name).tag($0.name) }
            }
            Picker("Watch", selection: $everyRun) {
                Text("This run only").tag(false)
                Text("This step in every run of the workflow").tag(true)
            }
            .pickerStyle(.radioGroup)
        }
    }

    private var triggers: [AlertTrigger] {
        isStep ? [.fails, .finishes, .tooLong] : AlertTrigger.allCases
    }

    @ViewBuilder private var triggerControls: some View {
        VStack(alignment: .leading, spacing: 6 * z) {
            Text("Alert when it…").zFont(.headline, weight: .semibold)
            ForEach(triggers) { trigger in
                Toggle(trigger.label, isOn: Binding(
                    get: { rule.triggers.contains(trigger) },
                    set: { if $0 { rule.triggers.insert(trigger) } else { rule.triggers.remove(trigger) } }))
            }
            if rule.triggers.contains(.tooLong) {
                HStack(spacing: 8 * z) {
                    if !isStep {
                        Picker("", selection: $rule.tooLong.mode) {
                            Text("× its usual time").tag(TooLong.Mode.timesUsual)
                            Text("minutes").tag(TooLong.Mode.minutes)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    TextField("", value: $rule.tooLong.value, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60 * z)
                    Stepper("", value: $rule.tooLong.value, in: rule.tooLong.mode == .minutes ? 1...600 : 1.1...10,
                            step: rule.tooLong.mode == .minutes ? 1 : 0.5)
                        .labelsHidden()
                    Text(isStep || rule.tooLong.mode == .minutes ? "minutes" : "")
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 20 * z)
                Text(rule.tooLong.mode == .minutes || isStep
                     ? "Fires once if it's still going after that long."
                     : "Compared with the median of its recent successful runs; needs at least 3.")
                    .zFont(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 20 * z)
            }
        }
    }

    /// Step alerts cost API requests; say how many before you choose.
    private func costNote(_ run: WorkflowRun) -> some View {
        let text = everyRun
            ? "Costs up to 240 API requests an hour for each running \(run.workflowFile) run (60 with the window closed), of 5,000 per account."
            : "Costs up to 240 API requests an hour while this run is going (60 with the window closed), of 5,000 per account."
        return Label(text, systemImage: "gauge.with.dots.needle.33percent")
            .zFont(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func otherStepAlerts(_ run: WorkflowRun) -> some View {
        let others = store.stepWatches.filter { $0.repo == repoName && $0.workflowFile == run.workflowFile }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 4 * z) {
                Text("Step alerts on this workflow").zFont(.headline, weight: .semibold)
                ForEach(others) { watch in
                    HStack {
                        Image(systemName: "bell.fill").foregroundStyle(.orange)
                        Text("\(watch.jobName) › \(watch.stepName)").lineLimit(1)
                        Text(watch.runID == nil ? "every run" : "one run").foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove") { store.stepWatches.removeAll { $0.id == watch.id } }
                            .buttonStyle(.link)
                    }
                    .zFont(.callout)
                }
            }
        }
    }

    private var repoName: String {
        switch target {
        case .group: ""
        case .repo(let repo), .run(let repo, _), .step(let repo, _, _): repo
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch target {
        case .group(let id):
            enabled = store.groupRules[id] != nil
            rule = store.groupRules[id] ?? .groupDefault
        case .repo(let repo):
            switch store.repoRules[repo] {
            case .off: repoMode = .off; rule = .groupDefault
            case .on(let r): repoMode = .on; rule = r
            case nil: repoMode = .asGroup; rule = model.groupAlertRule(repo) ?? .groupDefault
            }
        case .run(_, let run):
            enabled = store.runWatches[run.id] != nil
            rule = store.runWatches[run.id]?.rule ?? .runDefault
        case .step(_, let run, let job):
            rule = .stepDefault
            let failing = job.steps?.first { $0.state == .failure || $0.state == .running }
            stepName = failing?.name ?? job.steps?.first?.name ?? ""
            let mine = store.stepWatches.filter { $0.jobName == job.name && ($0.runID == run.id || ($0.runID == nil && $0.workflowFile == run.workflowFile)) }
            if let existing = mine.first(where: { $0.runID == run.id }) ?? mine.first {
                stepName = existing.stepName
                rule = existing.rule
                everyRun = existing.runID == nil
            }
        }
    }

    private func save() {
        switch target {
        case .group(let id):
            store.groupRules[id] = enabled ? rule : nil
        case .repo(let repo):
            switch repoMode {
            case .asGroup: store.repoRules[repo] = nil
            case .on: store.repoRules[repo] = .on(rule)
            case .off: store.repoRules[repo] = .off
            }
        case .run(let repo, let run):
            store.runWatches[run.id] = enabled ? RunWatch(repo: repo, runID: run.id, rule: rule) : nil
        case .step(let repo, let run, let job):
            let runID: Int? = everyRun ? nil : run.id
            // One alert per step: switching between this run and every run replaces it.
            store.stepWatches.removeAll { $0.repo == repo && $0.jobName == job.name && $0.stepName == stepName
                && ($0.runID == run.id || ($0.runID == nil && $0.workflowFile == run.workflowFile)) }
            store.stepWatches.append(StepWatch(repo: repo, workflowFile: run.workflowFile, jobName: job.name,
                                               stepName: stepName, runID: runID, rule: rule))
        }
    }
}

// MARK: - Alert list

/// Every alert that fired, newest first, across all repos: a plain log.
@MainActor struct AlertListView: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Alerts").zFont(.title3, weight: .semibold)
                Text("\(model.alerts.log.count)").foregroundStyle(.secondary)
                Spacer()
                Text("Last 30 days").zFont(.caption).foregroundStyle(.secondary)
                Button("Clear") { model.alerts.clearLog() }
                    .disabled(model.alerts.log.isEmpty)
            }
            .padding(.horizontal, 16 * z)
            .padding(.vertical, 10 * z)
            Divider()
            if model.alerts.log.isEmpty {
                VStack(spacing: 8 * z) {
                    Image(systemName: "bell.slash").zFont(.title)
                    Text("No alerts yet").zFont(.title3)
                    Text(model.alerts.hasAnyRule
                         ? "Alerts that fire show up here."
                         : "Turn alerts on with Group › Alerts for This Group… or Go › Alerts for This Repo…, the bell in a pane's header, or the bell on a job.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24 * z)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.alerts.log) { event in
                            AlertRow(event: event)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 380 * z, minHeight: 300 * z)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor private struct AlertRow: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    let event: AlertEvent
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10 * z) {
            Image(systemName: event.symbol)
                .foregroundStyle(event.state.color)
                .zFont(.title3)
            VStack(alignment: .leading, spacing: 2 * z) {
                Text("\(event.repoName) · \(event.detail)").fontWeight(.medium).lineLimit(1)
                Text(event.title).lineLimit(1)
                Text(event.source).zFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8 * z)
            Text(Format.ago(event.date)).zFont(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16 * z)
        .padding(.vertical, 8 * z)
        .background(hovering ? Color.primary.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.reveal(repo: event.repo, run: event.runID) }
        .help("Show this run")
        .contextMenu {
            Button("Show Run") { model.reveal(repo: event.repo, run: event.runID) }
            Button("Open in Browser") { model.openInBrowser(event.url) }
        }
    }
}

// MARK: - Menu bar

/// The menu bar icon: the worst state across every group, in color.
@MainActor struct MenuBarIcon: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: Self.image(for: model.overallState))
            .onAppear {
                // The icon lives as long as the app, so it can reopen the main window.
                model.openMainWindow = { openWindow(id: "main") }
            model.openAlertList = { openWindow(id: "alerts") }
            }
    }

    private static var cache: [String: NSImage] = [:]

    static func image(for state: RunState?) -> NSImage {
        let key = state.map { "\($0)" } ?? "none"
        if let cached = cache[key] { return cached }
        let (symbol, color): (String, NSColor?) = switch state {
        case .failure: ("xmark.circle.fill", .systemRed)
        case .waiting: ("hand.raised.circle.fill", .systemPurple)
        case .running, .queued: ("circle.dotted.circle", .systemOrange)
        case .success: ("checkmark.circle.fill", .systemGreen)
        default: ("circle.dashed", nil)
        }
        var config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        if let color { config = config.applying(.init(paletteColors: [color])) }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ActionsHub")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = color == nil
        cache[key] = image
        return image
    }
}

/// What the menu bar icon opens: what needs attention across every group, and the way back in.
@MainActor struct MenuBarPanel: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    /// Built only while the panel is open.
    private var items: [(repo: String, run: WorkflowRun)] {
        var seen = Set<String>()
        var out: [(String, WorkflowRun)] = []
        for group in model.groups {
            for repo in group.repos where seen.insert(repo).inserted {
                for run in model.attentionRuns(for: repo, kinds: Set(Attention.allCases)) { out.append((repo, run)) }
            }
        }
        return out.sorted { rank($0.1.state) > rank($1.1.state) || rank($0.1.state) == rank($1.1.state) && $0.1.createdAt > $1.1.createdAt }
    }

    private func rank(_ s: RunState) -> Int { s == .failure ? 3 : s == .waiting ? 2 : 1 }

    var body: some View {
        let list = items
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(nsImage: MenuBarIcon.image(for: model.overallState))
                Text(list.isEmpty ? "Nothing needs attention" : "\(list.count) need\(list.count == 1 ? "s" : "") attention")
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(10 * z)
            Divider()
            if !list.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(list.prefix(12), id: \.run.id) { item in
                            PanelRow(repo: item.repo, run: item.run)
                        }
                    }
                }
                .frame(maxHeight: 360 * z)
                Divider()
            }
            VStack(alignment: .leading, spacing: 0) {
                PanelButton(title: "Open ActionsHub", symbol: "macwindow") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                PanelButton(title: "Alert List (\(model.alerts.log.count))", symbol: "bell") {
                    openWindow(id: "alerts")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Divider().padding(.vertical, 4 * z)
                PanelButton(title: "Quit ActionsHub", symbol: "power") { NSApp.terminate(nil) }
            }
            .padding(6 * z)
        }
        .frame(width: 340 * z)
        .zFont(.body)
    }
}

@MainActor private struct PanelRow: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    let repo: String
    let run: WorkflowRun
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8 * z) {
            StateIcon(state: run.state)
            VStack(alignment: .leading, spacing: 1 * z) {
                Text(run.title).lineLimit(1)
                Text("\(repo.split(separator: "/").last.map(String.init) ?? repo) · \(run.workflowName) #\(run.runNumber)")
                    .zFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4 * z)
            Text(Format.ago(run.createdAt)).zFont(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10 * z)
        .padding(.vertical, 6 * z)
        .background(hovering ? Color.accentColor.opacity(0.18) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.reveal(repo: repo, run: run.id) }
    }
}

@MainActor private struct PanelButton: View {
    @Environment(\.zoom) private var z
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8 * z) {
            Image(systemName: symbol).frame(width: 18 * z)
            Text(title)
            Spacer()
        }
        .padding(.horizontal, 8 * z)
        .padding(.vertical, 5 * z)
        .background(RoundedRectangle(cornerRadius: 5 * z).fill(hovering ? Color.accentColor.opacity(0.2) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}
