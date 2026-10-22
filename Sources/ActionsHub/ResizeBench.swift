// Dev tools, off unless their environment variable is set (see CLAUDE.md):
//   ACTIONSHUB_RESIZE_BENCH=1   resize the window 60 times, log ms per frame to stderr, quit.
//   ACTIONSHUB_SNAPSHOT=<dir>   render the window at three sizes to PNGs in <dir>, then a failed
//                               run with its log, the alert editors and the alert list; quit.
//   ACTIONSHUB_ALERT_SELFTEST=1 check the alert rules on made-up runs, print PASS/FAIL, quit
//                               (see AlertSelfTest.swift; runs at once).
// Both wait 15 s for data to load first.
import AppKit
import QuartzCore

@MainActor enum ResizeBench {
    static func runIfRequested() {
        AlertSelfTest.runIfRequested()
        if let dir = ProcessInfo.processInfo.environment["ACTIONSHUB_SNAPSHOT"] { snapshot(to: dir); return }
        guard ProcessInfo.processInfo.environment["ACTIONSHUB_RESIZE_BENCH"] != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "ActionsHub" }) else { return }
            let base = NSRect(x: window.frame.minX, y: window.frame.minY, width: 2400, height: 1400)
            window.setFrame(base, display: true)
            var times: [Double] = []
            for i in 0..<60 {
                var f = base
                f.size.width -= CGFloat(i % 20) * 37
                f.size.height -= CGFloat(i % 20) * 19
                let t0 = CACurrentMediaTime()
                window.setFrame(f, display: true)
                window.layoutIfNeeded()
                window.displayIfNeeded()
                CATransaction.flush()
                times.append((CACurrentMediaTime() - t0) * 1000)
            }
            let sorted = times.sorted()
            let line = String(format: "BENCH resize ms: median %.1f  p90 %.1f  max %.1f  (n=%d)\n",
                              sorted[sorted.count / 2], sorted[sorted.count * 9 / 10], sorted.last!, sorted.count)
            FileHandle.standardError.write(line.data(using: .utf8)!)
            exit(0)
        }
    }

    /// Renders the window at a few sizes to PNGs, in-process (no screen recording needed).
    static func snapshot(to dir: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            guard let window = NSApp.windows.first(where: { $0.title == "ActionsHub" }), let view = window.contentView else { return }
            for (w, h) in [(2400, 1400), (1500, 900), (1000, 700)] {
                window.setFrame(NSRect(x: window.frame.minX, y: window.frame.minY, width: CGFloat(w), height: CGFloat(h)), display: true)
                window.layoutIfNeeded()
                window.displayIfNeeded()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(w)x\(h).png"))
            }
            if let extraShots { MainActor.assumeIsolated { extraShots(dir) } } else { exit(0) }
        }
    }

    /// Set by the app: renders the extra windows and sheets (alert editors, alert list), then quits.
    static var extraShots: (@MainActor (String) -> Void)?

    /// The main window as it is now, to `<dir>/<name>.png`.
    static func captureMain(_ name: String, in dir: String) {
        guard let window = NSApp.windows.first(where: { $0.title == "ActionsHub" }), let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }

    /// Every visible window but the main one (sheets, panels) to `<dir>/<name>-<n>.png`.
    static func capture(_ name: String, in dir: String) {
        for (i, window) in NSApp.windows.enumerated() where window.isVisible && window.title != "ActionsHub" {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name)-\(i).png"))
        }
    }
}
