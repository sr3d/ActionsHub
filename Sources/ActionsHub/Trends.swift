import SwiftUI
import AppKit
import Charts

/// Which repo's trends the sheet shows.
struct TrendsTarget: Identifiable, Equatable {
    let repo: String
    var id: String { repo }
}

/// One workflow's recent history: pass rate, durations, slowest steps and flaky commits.
struct WorkflowTrend: Identifiable {
    struct Point: Identifiable {
        let id: Int
        let number: Int
        let minutes: Double
        let state: RunState
    }
    struct Flake: Identifiable {
        let id: String   // head sha
        let title: String
        let branch: String
        /// Jobs that failed on the attempt that later passed (empty until looked up).
        var jobs: [String]
        let url: URL
    }

    let id: String   // workflow file
    let name: String
    var points: [Point]
    var passed: Int
    var failed: Int
    var median: TimeInterval?
    var p90: TimeInterval?
    var slowestSteps: [(name: String, seconds: TimeInterval)] = []
    var flakes: [Flake] = []

    var passRate: Double? { passed + failed == 0 ? nil : Double(passed) / Double(passed + failed) }
}

enum TrendsBuilder {
    /// Per workflow, from completed runs (newest first). A commit is flaky when the same
    /// workflow both failed and passed on it: a re-run that went green, or two runs.
    static func build(_ runs: [WorkflowRun]) -> [WorkflowTrend] {
        let byWorkflow = Dictionary(grouping: runs, by: \.workflowFile)
        return byWorkflow.map { file, list in
            let decided = list.filter { $0.state == .success || $0.state == .failure }
            let times = list.filter { $0.state == .success }.compactMap(\.duration).sorted()
            var trend = WorkflowTrend(
                id: file, name: list.first?.workflowName ?? file,
                points: list.prefix(50).reversed().compactMap { run in
                    run.duration.map { .init(id: run.id, number: run.runNumber, minutes: $0 / 60, state: run.state) }
                },
                passed: decided.filter { $0.state == .success }.count,
                failed: decided.filter { $0.state == .failure }.count,
                median: times.isEmpty ? nil : times[times.count / 2],
                p90: times.isEmpty ? nil : times[min(times.count - 1, times.count * 9 / 10)])
            var seen = Set<String>()
            for run in list where run.state == .success && seen.insert(run.headSha).inserted {
                let sameCommit = list.filter { $0.headSha == run.headSha }
                // A green re-run hides its failed attempt: attempt > 1 and success.
                let flaky = sameCommit.contains { $0.state == .failure } || (run.runAttempt ?? 1) > 1
                if flaky {
                    trend.flakes.append(.init(id: run.headSha, title: run.title, branch: run.headBranch ?? "", jobs: [], url: run.htmlUrl))
                }
            }
            return trend
        }
        .sorted { $0.points.count > $1.points.count }
    }
}

/// A repo's trends, fetched when the sheet opens: the last 100 finished runs, the steps of
/// each workflow's latest green run, and the failed jobs behind up to 8 flaky commits.
@MainActor struct TrendsSheet: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let repo: String

    @State private var trends: [WorkflowTrend]?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Trends · \(repo.split(separator: "/").last.map(String.init) ?? repo)").zFont(.title3, weight: .semibold)
                Spacer()
                Text("Last 100 finished runs").zFont(.caption).foregroundStyle(.secondary)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16 * z)
            Divider()
            if let trends {
                if trends.isEmpty {
                    Text("No finished runs yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18 * z) {
                            ForEach(trends) { WorkflowTrendView(trend: $0) }
                        }
                        .padding(16 * z)
                    }
                }
            } else if let error {
                Text(error).foregroundStyle(.red).padding(16 * z).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Loading history…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Never taller than the screen, whatever the zoom; the list scrolls inside.
        .frame(width: 720 * z, height: min(640 * z, (NSScreen.main?.visibleFrame.height ?? 900) - 80))
        .controlSize(z >= 1.25 ? .large : .regular)
        .task { await load() }
    }

    /// The slowest steps of a workflow's latest green run, and which jobs failed behind its
    /// flaky commits (the attempt before the green one), up to 8.
    nonisolated private static func details(of trend: WorkflowTrend, history: [WorkflowRun], repo: String, client: GitHubClient) async -> WorkflowTrend {
        var trend = trend
        if let latest = history.first(where: { $0.workflowFile == trend.id && $0.state == .success }),
           let jobs = try? await client.jobs(repo, run: latest.id) {
            trend.slowestSteps = jobs.flatMap { job in
                (job.steps ?? []).compactMap { step in step.duration.map { ("\(job.name) › \(step.name)", $0) } }
            }
            .sorted { $0.1 > $1.1 }.prefix(5).map { $0 }
        }
        for f in trend.flakes.indices.prefix(8) {
            let sha = trend.flakes[f].id
            guard let green = history.first(where: { $0.headSha == sha && $0.workflowFile == trend.id && $0.state == .success }) else { continue }
            if let failedRun = history.first(where: { $0.headSha == sha && $0.workflowFile == trend.id && $0.state == .failure }),
               let jobs = try? await client.jobs(repo, run: failedRun.id) {
                trend.flakes[f].jobs = jobs.filter { $0.state == .failure }.map(\.name)
            } else if let attempt = green.runAttempt, attempt > 1,
                      let jobs = try? await client.attemptJobs(repo, run: green.id, attempt: attempt - 1) {
                trend.flakes[f].jobs = jobs.filter { $0.state == .failure }.map(\.name)
            }
        }
        return trend
    }

    private func load() async {
        guard let account = model.account(for: repo) else { error = "No account can see this repo."; return }
        let client = account.client
        do {
            let history = try await client.runHistory(repo)
            var built = TrendsBuilder.build(history)
            // Each workflow's lookups are independent: run them 4 workflows at a time.
            for start in stride(from: 0, to: built.count, by: 4) {
                let tasks = built[start..<min(start + 4, built.count)].map { trend in
                    Task { await Self.details(of: trend, history: history, repo: repo, client: client) }
                }
                for (offset, task) in tasks.enumerated() { built[start + offset] = await task.value }
            }
            trends = built
        } catch {
            self.error = error.localizedDescription
        }
        await model.accounts.noteRateLimit(account.login)
    }
}

@MainActor private struct WorkflowTrendView: View {
    @Environment(\.zoom) private var z
    @Environment(AppModel.self) private var model
    let trend: WorkflowTrend

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * z) {
            HStack(alignment: .firstTextBaseline, spacing: 10 * z) {
                Text(trend.name).zFont(.headline, weight: .semibold)
                Text(trend.id).zFont(.caption, design: .monospaced).foregroundStyle(.secondary)
                Spacer()
                if let rate = trend.passRate {
                    Text("\(Int((rate * 100).rounded()))% passed")
                        .foregroundStyle(rate >= 0.9 ? .green : rate >= 0.7 ? .orange : .red)
                        .fontWeight(.semibold)
                    Text("\(trend.passed) of \(trend.passed + trend.failed)").foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 14 * z) {
                if let median = trend.median { Label("usually \(Format.duration(median))", systemImage: "stopwatch") }
                if let p90 = trend.p90 { Text("9 in 10 under \(Format.duration(p90))").foregroundStyle(.secondary) }
            }
            .zFont(.caption)
            if trend.points.count > 1 {
                Chart(trend.points) { point in
                    BarMark(x: .value("Run", "#\(point.number)"), y: .value("Minutes", point.minutes))
                        .foregroundStyle(point.state.color)
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks { AxisGridLine(); AxisValueLabel().font(.system(size: 9 * z)) }
                }
                .chartYAxisLabel { Text("min").font(.system(size: 9 * z)) }
                .frame(height: 90 * z)
                Text("Each bar is a run, oldest first: green passed, red failed, gray cancelled or skipped.")
                    .zFont(.caption).foregroundStyle(.tertiary)
            }
            if !trend.slowestSteps.isEmpty {
                VStack(alignment: .leading, spacing: 2 * z) {
                    Text("Slowest steps (latest green run)").zFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                    ForEach(trend.slowestSteps, id: \.name) { step in
                        HStack {
                            Text(step.name).lineLimit(1)
                            Spacer()
                            Text(Format.duration(step.seconds)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .zFont(.caption)
                    }
                }
            }
            if !trend.flakes.isEmpty {
                VStack(alignment: .leading, spacing: 2 * z) {
                    Text("Flaky: failed, then passed on the same commit (\(trend.flakes.count))")
                        .zFont(.caption, weight: .semibold).foregroundStyle(.orange)
                    ForEach(trend.flakes.prefix(8)) { flake in
                        HStack(spacing: 6 * z) {
                            Text(String(flake.id.prefix(7))).zFont(.caption, design: .monospaced).foregroundStyle(.secondary)
                            Text(flake.jobs.isEmpty ? flake.title : flake.jobs.joined(separator: ", ")).lineLimit(1)
                            Spacer()
                            Button { model.openInBrowser(flake.url) } label: { Image(systemName: "arrow.up.right.square") }
                                .buttonStyle(.borderless)
                                .help("Open the passing run on GitHub")
                        }
                        .zFont(.caption)
                    }
                }
            }
            Divider().padding(.top, 4 * z)
        }
    }
}
