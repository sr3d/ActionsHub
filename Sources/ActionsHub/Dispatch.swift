import SwiftUI

// MARK: - Models

struct Workflow: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let path: String
    let state: String

    var file: String { (path as NSString).lastPathComponent }
}

struct WorkflowsPage: Decodable {
    let workflows: [Workflow]
}

/// One input of a `workflow_dispatch` trigger.
struct DispatchInput: Identifiable, Equatable {
    enum Kind: Equatable { case string, boolean, number, choice([String]), environment }

    let name: String
    var description = ""
    var required = false
    var defaultValue = ""
    var kind = Kind.string

    var id: String { name }
}

/// Reads just enough of a workflow file to start it by hand: whether `on:` includes
/// `workflow_dispatch`, and its inputs. Not a YAML parser; it handles the shapes GitHub's
/// docs use (block maps, `- item` lists, `[a, b]` lists, quoted scalars, comments).
enum DispatchParser {
    /// nil when the workflow can't be started by hand.
    static func inputs(in yaml: String) -> [DispatchInput]? {
        let lines = yaml.components(separatedBy: .newlines).map(stripComment).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let onIndex = lines.firstIndex(where: { indent($0) == 0 && ["on", "\"on\"", "'on'", "true"].contains(key($0)) }) else { return nil }
        let inline = value(lines[onIndex])
        if !inline.isEmpty {
            // on: workflow_dispatch / on: [push, workflow_dispatch]
            return list(inline).contains("workflow_dispatch") ? [] : nil
        }
        let onBlock = block(after: onIndex, in: lines)
        guard let first = onBlock.first else { return nil }
        let childIndent = indent(first)
        // on:\n  - push\n  - workflow_dispatch
        if first.trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
            return onBlock.contains { unquote($0.trimmingCharacters(in: .whitespaces).dropFirst(2).trimmingCharacters(in: .whitespaces)) == "workflow_dispatch" } ? [] : nil
        }
        guard let dispatch = onBlock.firstIndex(where: { indent($0) == childIndent && key($0) == "workflow_dispatch" }) else { return nil }
        let dispatchBlock = block(after: dispatch, in: onBlock)
        guard let inputsLine = dispatchBlock.firstIndex(where: { key($0) == "inputs" }) else { return [] }
        let inputsBlock = block(after: inputsLine, in: dispatchBlock)
        guard let firstInput = inputsBlock.first else { return [] }
        let inputIndent = indent(firstInput)

        var out: [DispatchInput] = []
        var names = Set<String>()
        for (i, line) in inputsBlock.enumerated() where indent(line) == inputIndent {
            // A name listed twice is invalid YAML for GitHub too; keep the first.
            guard names.insert(unquote(key(line))).inserted else { continue }
            var input = DispatchInput(name: unquote(key(line)))
            let props = block(after: i, in: inputsBlock)
            var j = 0
            while j < props.count {
                let prop = props[j]
                let v = unquote(value(prop))
                switch key(prop) {
                case "description": input.description = v
                case "required": input.required = v == "true"
                case "default": input.defaultValue = v
                case "type":
                    switch v {
                    case "boolean": input.kind = .boolean
                    case "number": input.kind = .number
                    case "environment": input.kind = .environment
                    case "choice": if case .choice = input.kind {} else { input.kind = .choice([]) }
                    default: break
                    }
                case "options":
                    var options = value(prop).isEmpty ? [] : list(value(prop))
                    if options.isEmpty {
                        let items = block(after: j, in: props)
                        options = items.map { unquote($0.trimmingCharacters(in: .whitespaces).dropFirst(2).trimmingCharacters(in: .whitespaces)) }
                        j += items.count
                    }
                    input.kind = .choice(options)
                default: break
                }
                j += 1
            }
            if input.kind == .boolean, input.defaultValue.isEmpty { input.defaultValue = "false" }
            if case .choice(let options) = input.kind, input.defaultValue.isEmpty { input.defaultValue = options.first ?? "" }
            out.append(input)
        }
        return out
    }

    private static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    /// Lines indented deeper than `lines[index]`, up to the next line that isn't.
    private static func block(after index: Int, in lines: [String]) -> [String] {
        let base = indent(lines[index])
        var out: [String] = []
        for line in lines[(index + 1)...] {
            if indent(line) <= base { break }
            out.append(line)
        }
        return out
    }

    private static func key(_ line: String) -> String {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let colon = t.firstIndex(of: ":") else { return t }
        return String(t[..<colon]).trimmingCharacters(in: .whitespaces)
    }

    private static func value(_ line: String) -> String {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let colon = t.firstIndex(of: ":") else { return "" }
        return String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    /// "[a, 'b']" → [a, b]; "a" → [a].
    private static func list(_ text: String) -> [String] {
        var t = text
        if t.hasPrefix("["), t.hasSuffix("]") { t = String(t.dropFirst().dropLast()) }
        return t.split(separator: ",").map { unquote(String($0).trimmingCharacters(in: .whitespaces)) }
    }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2, let f = s.first, let l = s.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    /// Drops a `# comment` that isn't inside quotes.
    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var prev: Character = " "
        for (i, c) in line.enumerated() {
            if let q = quote { if c == q { quote = nil } }
            else if c == "\"" || c == "'" { quote = c }
            else if c == "#", prev == " " { return String(line.prefix(i)) }
            prev = c
        }
        return line
    }
}

// MARK: - Sheet

struct DispatchTarget: Identifiable, Equatable {
    let repo: String
    var id: String { repo }
}

/// Starts a workflow that has a `workflow_dispatch` trigger, with a form built from its inputs.
@MainActor struct DispatchSheet: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let repo: String

    @State private var workflows: [Workflow]?
    @State private var selected: Workflow?
    @State private var inputs: [DispatchInput]?
    /// Each dispatchable workflow's inputs, read when the sheet opens.
    @State private var parsed: [Int: [DispatchInput]] = [:]
    @State private var skipped = 0
    @State private var values: [String: String] = [:]
    @State private var branch = ""
    @State private var error: String?
    @State private var starting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * z) {
            Text("Run Workflow · \(repo.split(separator: "/").last.map(String.init) ?? repo)").zFont(.title3, weight: .semibold)
            if let workflows, !workflows.isEmpty {
                Picker("Workflow", selection: $selected) {
                    ForEach(workflows) { wf in
                        Text("\(wf.name) (\(wf.file))").tag(Optional(wf))
                    }
                }
                if skipped > 0 {
                    Text("\(skipped) other workflow\(skipped == 1 ? "" : "s") can't be started by hand (no workflow_dispatch trigger).")
                        .zFont(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Branch or tag")
                    TextField("", text: $branch, prompt: Text("main"))
                        .textFieldStyle(.roundedBorder)
                }
                if let inputs {
                    if inputs.isEmpty {
                        Text("This workflow has no inputs.").zFont(.callout).foregroundStyle(.secondary)
                    }
                    let form = VStack(alignment: .leading, spacing: 10 * z) { ForEach(inputs) { field($0) } }
                    // Scroll only when there are many; a scroll view sized to fit clipped the first line.
                    if inputs.count > 6 {
                        ScrollView { form }.frame(height: 360 * z)
                    } else {
                        form
                    }
                } else if selected != nil, error == nil {
                    HStack(spacing: 6 * z) { ProgressView().controlSize(.small); Text("Reading the workflow…").foregroundStyle(.secondary) }
                }
            } else if workflows == nil, error == nil {
                HStack(spacing: 6 * z) { ProgressView().controlSize(.small); Text("Loading workflows…").foregroundStyle(.secondary) }
            }
            if let error { Text(error).foregroundStyle(.red).zFont(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Run Workflow") { Task { await start() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(inputs == nil || starting || branch.isEmpty || missingRequired)
            }
        }
        .padding(20 * z)
        .frame(width: 480 * z)
        .controlSize(z >= 1.25 ? .large : .regular)
        .task { await loadWorkflows() }
        .onChange(of: selected) { _, wf in loadInputs(wf) }
    }

    private var missingRequired: Bool {
        (inputs ?? []).contains { $0.required && $0.kind != .boolean && (values[$0.name] ?? "").isEmpty }
    }

    @ViewBuilder private func field(_ input: DispatchInput) -> some View {
        let binding = Binding(get: { values[input.name] ?? "" }, set: { values[input.name] = $0 })
        VStack(alignment: .leading, spacing: 3 * z) {
            switch input.kind {
            case .boolean:
                Toggle(input.name, isOn: Binding(get: { binding.wrappedValue == "true" }, set: { binding.wrappedValue = $0 ? "true" : "false" }))
            case .choice(let options):
                Picker(input.name + (input.required ? " *" : ""), selection: binding) {
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
            default:
                // macOS shows no title for a rounded text field, so the name goes above it.
                Text(input.name + (input.required ? " *" : "")).fontWeight(.medium)
                TextField("", text: binding, prompt: Text(input.kind == .number ? "number" : input.defaultValue))
                    .textFieldStyle(.roundedBorder)
            }
            if !input.description.isEmpty {
                Text(input.description).zFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func loadWorkflows() async {
        guard let account = model.account(for: repo) else { error = "No account can see this repo."; return }
        let client = account.client
        do {
            let all = try await client.workflows(repo).filter { $0.state == "active" }
            let ref = try await client.repo(repo).defaultBranch ?? "main"
            // Read every workflow file at once (one request each, only now) and keep the
            // ones with a workflow_dispatch trigger.
            let reads = all.map { wf in (wf, Task { try? await client.fileText(repo, path: wf.path, ref: ref) }) }
            var found: [Int: [DispatchInput]] = [:]
            for (wf, task) in reads {
                if let text = await task.value, let inputs = DispatchParser.inputs(in: text) { found[wf.id] = inputs }
            }
            parsed = found
            branch = ref
            let runnable = all.filter { found[$0.id] != nil }
            skipped = all.count - runnable.count
            workflows = runnable
            selected = runnable.first
            if runnable.isEmpty { error = all.isEmpty ? "This repo has no active workflows." : "None of this repo's workflows can be started by hand: none has a workflow_dispatch trigger." }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadInputs(_ wf: Workflow?) {
        inputs = nil
        error = nil
        guard let wf, let found = parsed[wf.id] else { return }
        values = Dictionary(found.map { ($0.name, $0.defaultValue) }, uniquingKeysWith: { a, _ in a })
        inputs = found
    }

    private func start() async {
        guard let wf = selected, let account = model.account(for: repo) else { return }
        starting = true
        defer { starting = false }
        do {
            let sent = (inputs ?? []).reduce(into: [String: String]()) { out, input in
                if let v = values[input.name], !v.isEmpty { out[input.name] = v }
            }
            try await account.client.dispatch(repo, workflow: wf.id, ref: branch, inputs: sent)
            dismiss()
            // GitHub takes a moment to create the run.
            try? await Task.sleep(for: .seconds(3))
            await model.refreshRuns(repo)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
