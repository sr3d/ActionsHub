# Learnings

- Continuous animation via SwiftUI `TimelineView(.animation)` re-lays out the whole window every frame; use a Core Animation layer (`SpinnerRing`) instead (#6).
- `withTaskGroup` + `for await` inside a @MainActor method ended before its children finished (Swift 6.4), silently returning nothing; use awaited `Task`s and check results are non-empty (#1).
- `ViewThatFits` in a repeated row re-measures every variant on each resize frame (~30 ms for a 4x3 grid); rounding the offered width didn't help. A `Layout` that caches natural sizes did (#8).
- A size-dependent Layout next to a Spacer in an HStack splits the leftover width with it; place both in one Layout that decides who gets room first (#11)
- `leaks` on macOS 26 reports ~200–300 small XPC/NSSet "leaks" from system frameworks in every build, old ones too; look for app types and compare with the previous build instead of the count (#13).
- The job-log endpoint redirects to a signed blob URL that rejects our token: stop the redirect (delegate returns nil) and fetch the Location without auth. A job that never started has no log (404 BlobNotFound) (#16).
- `MetaLine` drops a whole tier at once: a new header button in an existing tier hides the others with it; give new buttons their own, higher tier (#13).
