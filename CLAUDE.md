# ActionsHub

Native macOS SwiftUI app (SwiftPM, no Xcode project). `swift build` to compile, `./build.sh` for
`dist/ActionsHub.app`, `./build.sh --install` to replace the copy in /Applications.

**After every change, rebuild, reinstall and relaunch** so the user can test it right away:
`./build.sh --install && { pkill -x ActionsHub; sleep 1; open /Applications/ActionsHub.app; }`
(the project's Rebuild/Install/Launch command). Don't leave a change only in `dist/` or `.build/`.

## Performance is the #1 priority

No performance regressions and no memory leaks, ever. This outranks features and polish: if a change
makes the app slower or leakier, it isn't done.

- **Main thread is for UI only.** Network, JSON decoding/encoding, file I/O, Keychain and `gh`
  subprocesses run off the main actor (`GitHubClient` is an actor; discovery runs detached; the repo
  cache is written on a background queue). Keep it that way for anything new.
- **Nothing redraws on a clock it doesn't need.** No `TimelineView(.animation)` or per-frame SwiftUI
  state for decoration: continuous motion goes through Core Animation (see `SpinnerRing`), which the
  render server runs without touching the main thread. A 30 fps SwiftUI spinner per running icon
  re-laid-out the whole window and pinned the main thread at ~90% with a 4x3 grid.
- **Layout once per frame.** Views repeated per pane or per row avoid `ViewThatFits` and stacks
  that negotiate sizes (HStack + Spacer + flexible frames): they re-measure every child on each
  resize frame. Use a `Layout` that caches natural sizes (`PaneGrid`, `RunRowLayout`, `MetaLine`).
- **Views read cheap values.** Anything a view body reads (sidebar rows above all: one per repo, every
  render) must be stored or cached, never rebuilt per access. Example: `prSnapshot` is stored and
  rebuilt only when its inputs change.
- **Watch the API budget.** Every poll is up to 5 requests per repo; rely on ETags (304s are free)
  and don't add per-repo calls to the polling loop without measuring.
- **No leaks.** No retain cycles in closures/tasks (`[weak self]` in long-lived tasks), cancel tasks
  you own, keep caches bounded.
- **Measure, don't guess.** For any change to views, polling or loading, compare before and after on a
  big layout (9+ repos in a 4x3 grid, something running):
  - CPU: `top -l 4 -s 3 -pid <pid> -stats pid,cpu,mem`
  - Main thread: `sample <pid> 5`; the main thread should be mostly idle in
    `__CFRunLoopServiceMachPort`, with little time in `NSHostingView.layout`.
  - Memory: `leaks <pid>` shows no app-owned objects, and RSS stays flat over a few minutes.
  - Resize cost: `open -n --env ACTIONSHUB_RESIZE_BENCH=1 --stderr /tmp/bench.log dist/ActionsHub.app`,
    then read the `BENCH` line (median/p90 ms per frame; 60 fps needs under 16.7 ms). Copy each build
    to its own .app to A/B them.
  - Look at the UI without screen recording: `--env ACTIONSHUB_SNAPSHOT=<dir>` writes PNGs at three
    window sizes.
  - Run the old and new builds side by side (`open -n dist/ActionsHub.app`); they share settings, so
    they show the same group.
