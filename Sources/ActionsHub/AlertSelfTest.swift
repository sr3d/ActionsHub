// Dev tool, off unless ACTIONSHUB_ALERT_SELFTEST is set: runs `AlertDetector` over made-up
// runs and `DispatchParser` over sample workflow files (plus any in ACTIONSHUB_DISPATCH_FILES,
// colon-separated), prints PASS/FAIL per case to stderr, and quits. Touches no settings or log.
import Foundation

enum AlertSelfTest {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["ACTIONSHUB_ALERT_SELFTEST"] != nil else { return }
        var failures = 0
        func check(_ name: String, _ got: [AlertEvent], _ want: [AlertEvent.Kind]) {
            let kinds = got.map(\.kind)
            let ok = kinds == want
            if !ok { failures += 1 }
            FileHandle.standardError.write("\(ok ? "PASS" : "FAIL") \(name): got \(kinds.map(\.rawValue)) want \(want.map(\.rawValue))\n".data(using: .utf8)!)
        }
        let fails = AlertRule(triggers: [.fails])
        let finishes = AlertRule(triggers: [.finishes])
        let approvals = AlertRule(triggers: [.needsApproval])
        let tooLong = AlertRule(triggers: [.tooLong], tooLong: TooLong(mode: .minutes, value: 10))
        func events(_ old: [WorkflowRun]?, _ new: [WorkflowRun], _ rule: AlertRule?, own: Set<Int> = []) -> [AlertEvent] {
            AlertDetector.runEvents(repo: "o/r", old: old, new: new, own: own, rule: { _ in rule },
                                    limit: { t, _ in t.mode == .minutes ? t.value * 60 : nil })
        }

        let running = run(1, "in_progress", nil)
        check("first fetch is a baseline", events(nil, [run(1, "completed", "failure")], fails), [])
        check("running → failed", events([running], [run(1, "completed", "failure")], fails), [.failed])
        check("running → passed, fails only", events([running], [run(1, "completed", "success")], fails), [])
        check("running → passed, finishes", events([running], [run(1, "completed", "success")], finishes), [.succeeded])
        check("running → failed, finishes", events([running], [run(1, "completed", "failure")], finishes), [.failed])
        check("no rule", events([running], [run(1, "completed", "failure")], nil), [])
        check("own cancel stays quiet", events([running], [run(1, "completed", "cancelled")], finishes, own: [1]), [])
        check("queued → waiting", events([run(1, "queued", nil)], [run(1, "waiting", nil)], approvals), [.needsApproval])
        check("still waiting", events([run(1, "waiting", nil)], [run(1, "waiting", nil)], approvals), [])
        check("new run, already failed", events([run(1, "completed", "success")],
                                                [run(2, "completed", "failure"), run(1, "completed", "success")], fails), [.failed])
        check("old run back in the list", events([run(1, "completed", "success")],
                                                 [run(1, "completed", "success"), run(3, "completed", "failure", age: 86_400)], fails), [])
        check("re-run fails again", events([run(1, "completed", "failure")], [run(1, "completed", "failure", attempt: 2)], fails), [.failed])
        check("takes too long", events([running], [run(1, "in_progress", nil, started: 1800)], tooLong), [.tooLong])
        check("not too long yet", events([running], [run(1, "in_progress", nil, started: 120)], tooLong), [])

        let watch = StepWatch(repo: "o/r", workflowFile: "ci.yml", jobName: "build", stepName: "Deploy", runID: 1, rule: fails)
        let before = [job("in_progress", nil)], after = [job("completed", "failure")]
        check("step fails", AlertDetector.stepEvents(repo: "o/r", run: running, watches: [watch], old: before, new: after, own: []), [.failed])
        check("step baseline", AlertDetector.stepEvents(repo: "o/r", run: running, watches: [watch], old: nil, new: after, own: []), [])
        var olderWatch = watch
        olderWatch.created = Date().addingTimeInterval(-3600)
        check("step ended before first look", AlertDetector.stepEvents(repo: "o/r", run: running, watches: [olderWatch], old: nil,
                                                                       new: [job("completed", "failure", completed: Date())], own: []), [.failed])
        check("step ended before the alert", AlertDetector.stepEvents(repo: "o/r", run: running, watches: [watch], old: nil,
                                                                      new: [job("completed", "failure", completed: Date().addingTimeInterval(-3600))], own: []), [])
        check("step passes, fails only", AlertDetector.stepEvents(repo: "o/r", run: running, watches: [watch], old: before,
                                                                  new: [job("completed", "success")], own: []), [])

        // Run Workflow: reading workflow_dispatch inputs.
        func parse(_ name: String, _ yaml: String, _ want: String?) {
            let got = DispatchParser.inputs(in: yaml).map { $0.map(describe).joined(separator: "; ") }
            let ok = got == want
            if !ok { failures += 1 }
            FileHandle.standardError.write("\(ok ? "PASS" : "FAIL") parse \(name): got \(got ?? "nil") want \(want ?? "nil")\n".data(using: .utf8)!)
        }
        parse("no dispatch", "on:\n  push:\n    branches: [main]\n", nil)
        parse("inline", "on: workflow_dispatch\n", "")
        parse("inline list", "on: [push, workflow_dispatch]\n", "")
        parse("block list", "on:\n  - push\n  - workflow_dispatch\njobs: {}\n", "")
        parse("no inputs", "on:\n  push:\n  workflow_dispatch:\njobs:\n  a: {}\n", "")
        parse("inputs", """
        name: Deploy
        on:
          workflow_dispatch:
            inputs:
              env:
                description: "Where to deploy" # comment
                required: true
                type: choice
                options:
                  - staging
                  - 'production'
              dry_run:
                type: boolean
                default: true
              tag:
                description: Image tag, e.g. v1.2 # not part of it
          push:
            branches: [main]
        jobs:
          deploy:
            runs-on: ubuntu-latest
        """, "env choice(staging,production) req default=staging; dry_run boolean default=true; tag string default=")
        parse("inline options", "on:\n  workflow_dispatch:\n    inputs:\n      level:\n        type: choice\n        options: [low, high]\n", "level choice(low,high) default=low")
        parse("duplicate name", "on:\n  workflow_dispatch:\n    inputs:\n      a:\n        default: x\n      a:\n        default: y\n", "a string default=x")
        for path in (ProcessInfo.processInfo.environment["ACTIONSHUB_DISPATCH_FILES"] ?? "").split(separator: ":") {
            let text = (try? String(contentsOfFile: String(path), encoding: .utf8)) ?? ""
            let got = DispatchParser.inputs(in: text).map { $0.map(describe).joined(separator: "; ") } ?? "nil"
            FileHandle.standardError.write("FILE \((path as NSString).lastPathComponent): \(got)\n".data(using: .utf8)!)
        }

        FileHandle.standardError.write("SELFTEST \(failures == 0 ? "OK" : "\(failures) FAILED")\n".data(using: .utf8)!)
        exit(failures == 0 ? 0 : 1)
    }

    private static func describe(_ input: DispatchInput) -> String {
        let kind: String = switch input.kind {
        case .string: "string"
        case .boolean: "boolean"
        case .number: "number"
        case .environment: "environment"
        case .choice(let options): "choice(\(options.joined(separator: ",")))"
        }
        return "\(input.name) \(kind)\(input.required ? " req" : "") default=\(input.defaultValue)"
    }

    private static func run(_ id: Int, _ status: String, _ conclusion: String?, attempt: Int = 1,
                            age: TimeInterval = 60, started: TimeInterval = 60) -> WorkflowRun {
        let f = ISO8601DateFormatter()
        let json: [String: Any?] = [
            "id": id, "name": "CI", "display_title": "Run \(id)", "head_branch": "main", "head_sha": "abc",
            "event": "push", "status": status, "conclusion": conclusion, "run_number": id, "run_attempt": attempt,
            "html_url": "https://github.com/o/r/actions/runs/\(id)", "path": ".github/workflows/ci.yml",
            "created_at": f.string(from: Date().addingTimeInterval(-age)),
            "updated_at": f.string(from: Date()),
            "run_started_at": f.string(from: Date().addingTimeInterval(-started)),
        ]
        let data = try! JSONSerialization.data(withJSONObject: json.compactMapValues { $0 })
        return try! GitHubClient.decoder.decode(WorkflowRun.self, from: data)
    }

    private static func job(_ status: String, _ conclusion: String?, completed: Date? = nil) -> Job {
        let step: [String: Any?] = ["name": "Deploy", "status": status, "conclusion": conclusion, "number": 3,
                                    "completed_at": completed.map { ISO8601DateFormatter().string(from: $0) }]
        let json: [String: Any] = ["id": 9, "name": "build", "status": status, "steps": [step.compactMapValues { $0 }]]
        return try! GitHubClient.decoder.decode(Job.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
