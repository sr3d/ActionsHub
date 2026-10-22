// Dev tools, off unless their environment variable is set (see CLAUDE.md):
//   ACTIONSHUB_RESIZE_BENCH=1   resize the window 60 times, log ms per frame to stderr, quit.
//   ACTIONSHUB_SNAPSHOT=<dir>   render the window at three sizes to PNGs in <dir>, quit.
// Both wait 15 s for data to load first.
import AppKit
import QuartzCore

@MainActor enum ResizeBench {
    static func runIfRequested() {
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
            exit(0)
        }
    }
}
