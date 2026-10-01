# ActionsHub

A native macOS dashboard for GitHub Actions and pull requests across several repositories at once — without living in a browser tab.

- **Only what needs you.** By default it shows runs that are **awaiting approval**, **running / queued**, or **failed** — and a failure only counts while it's still the latest run of that workflow on that branch. Everything else is one click away under **All**.
- **Split panes.** Pick a rows × columns grid (up to 4 × 4). Panes show the group's repos in sidebar order and stay put — drag repos in the sidebar to rearrange them. With a single pane, clicking a repo switches to it.
- **Pull requests.** A docked pane (⇧⌘P) lists open PRs across the group — review requested from you, your own, review requested from your team, and the rest — with CI status and review state. Click one to open it on GitHub. Drafts and PRs idle for 30+ days are hidden by default.
- **Per-repo PRs.** The PR button in each pane's header opens that repo's own pull requests under its runs (drag the divider to resize).
- **Colors.** Give each repo a color (the dot in its pane header, or right-click it in the sidebar) so panes are easy to tell apart.
- **Groups.** Save sets of repos as groups (e.g. "Deploys", "Infra"), each with its own pane layout, and flip between them with ⌥⌘1–9.
- **Fast switching.** ⌘K fuzzy-finds any repo you can access; ⌘1–9 jumps to the group's repos.
- **Drill in.** Expand a run to see its jobs and the step that failed; re-run, re-run failed jobs, or cancel from the context menu.
- **Easy on the rate limit.** Polls every 15 s while something is running (60 s otherwise) using conditional requests, which GitHub doesn't count against your quota.
- **Zoom.** ⌘= / ⌘- / ⌘0 scale the whole interface, for large high-resolution displays.

## Install

Download the latest `.dmg` from [Releases](../../releases), open it, and drag **ActionsHub** to Applications.

The app is ad-hoc signed, not notarized, so on first launch macOS will refuse to open it. Either right-click the app → **Open** → **Open**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/ActionsHub.app
```

Requires macOS 14 (Sonoma) or later.

## Signing in

ActionsHub looks for a GitHub token in this order:

1. The `GH_TOKEN` or `GITHUB_TOKEN` environment variable
2. The [GitHub CLI](https://cli.github.com) — `gh auth token` (if you're logged in with `gh`, there's nothing to set up)
3. A personal access token you paste into the app on first launch, stored in your macOS Keychain

Apps opened from the Dock or Finder don't see variables exported in your shell profile (`.bash_profile`, `.zshrc`), so in practice the token comes from `gh` or the Keychain. To use a different account, switch it in `gh` (`gh auth switch`).

A token needs the **`repo`** and **`workflow`** scopes (classic) to read runs and to re-run or cancel them.

## Where your data lives

Nothing is sent anywhere except `api.github.com`.

| What | Where |
| --- | --- |
| Pasted access token | macOS Keychain (service `ActionsHub`) |
| Groups, pane layouts, filters, zoom | App preferences (`com.sr3d.actionshub`) |
| Cached repository list (for instant ⌘K) | `~/Library/Application Support/ActionsHub/repos.json` |

To reset everything: `defaults delete com.sr3d.actionshub`, delete that folder, and remove the `ActionsHub` Keychain item.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘K | Quick open a repository (jumps to its pane if it's already shown, otherwise puts it in the focused pane) |
| ⌘↩ (in quick open) | Add / remove the highlighted repo from the current group |
| ⇧⌘K | Add repositories to the current group |
| ⌘1 – ⌘9 | Jump to the group's Nth repo (in single-pane mode, show it) |
| ⌥⌘1 – ⌥⌘9 | Switch group |
| ⌥⌘N | New group |
| ⌥⌘← / ⌥⌘→ | Focus previous / next pane |
| ⇧⌘A | Toggle showing all runs |
| ⇧⌘P | Show / hide the Pull Requests pane |
| ⌘R | Refresh the focused pane |
| ⌘D | Add / remove the focused repo from the group |
| ⇧⌘O | Open the focused repo's Actions page in the browser |
| ⌘= / ⌘- / ⌘0 | Zoom in / out / actual size |

Drag repos in the sidebar to reorder them (and so the panes), or drag one onto a pane to swap it into that spot.

## Building from source

Only the Command Line Tools are needed for a local build:

```sh
./build.sh              # → dist/ActionsHub.app
./build.sh --install    # …and copy it to /Applications
./package.sh            # → dist/ActionsHub-<version>.dmg
```

A universal (arm64 + x86_64) build needs full Xcode: `ARCHS="arm64 x86_64" ./package.sh`.

The icon is drawn in code — edit `Icon/generate-icon.swift` and run `swift Icon/generate-icon.swift` to regenerate `Icon/AppIcon.icns`.

## Releasing

Push a version tag; the **Release** workflow builds a universal `.dmg` and publishes a GitHub Release with it:

```sh
git tag v0.1.0
git push origin v0.1.0
```

## License

[MIT](LICENSE)
