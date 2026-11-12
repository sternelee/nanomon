# AGENTS.md

This file helps coding agents work safely and efficiently in the nanomon repository.

## Project

nanomon is a Zig-based system monitor that uses the nanoui UI framework. It targets macOS and Linux, with platform-specific sampling code for each OS.

## Build System

Zig 0.17.0 or later is required. The project uses Zig's native build system.

### Common Commands

- `zig build run` — Build and run nanomon
- `zig build test` — Run the test suite
- `zig build test-bin` — Build tests as a standalone binary (for cross-platform testing)
- `zig build video` — Build the offscreen video renderer (nanomon-video)

### Dependencies

The project has one dependency declared in `build.zig.zon`:
- `nanoui` — UI framework (Git dependency)

Zig will fetch dependencies automatically on first build.

## Platform-Specific Code

The build conditionally links IOKit on macOS. Platform-specific sampling modules are organized by target OS:
- `sample_mac.zig`, `sample_iokit_mac.zig`, `sample_sys_mac.zig`, `sample_temp_mac.zig` — macOS sampling
- `sample_linux.zig`, `sample_sys_linux.zig` — Linux sampling
- `sample_none.zig` — Fallback for unsupported platforms

### Async External Command Pattern

The project uses an async pattern for running external commands (like `ps` and `lsof`) without blocking the UI:

1. **Process spawning**: Use `posix_spawn` with `pipe` to redirect stdout to a pipe
2. **Non-blocking I/O**: Set the read end of the pipe to `O_NONBLOCK` via `fcntl`
3. **Event-driven reading**: Use `nanoui.fdwatch.readable` to read data as it arrives
4. **Callback on completion**: When the pipe reaches EOF, parse the accumulated output and notify the sampler

This pattern is used in:
- `src/ps.zig` — Process list from `ps`
- `src/ports.zig` — Listening ports from `lsof` (macOS only)

Key implementation details:
- Errors in `posix_spawn_file_actions_*` are typically ignored (following ps.zig precedent)
- If the external command fails or crashes, the feature degrades gracefully (empty data)
- The pattern requires a `Notify` callback struct with `ctx: *anyopaque` and `func: *const fn (*anyopaque) void`

## Cleanup Feature

Cleanup is its own sidebar section above System, with four tabs: App Caches,
Dev Tools, Large Files and App Uninstaller (⌘9 opens it). It finds space the
machine is done with and removes it — nearly all of it to the Trash, the
tool-owned things through their own tool. Its design follows `purge-app` (an
external reference project, not a dependency): a scan only proposes paths, and
a safety catalog decides what may be offered.

The "where did the space go" view is **not** a Cleanup tab: it is the Space
card at the foot of the machine's own Overview page (`view_overview.zig` calls
`view_cleanup.space`). It shows the disk's figures, each tab's total (a click
opens that tab) and the user's folders, and it removes nothing.

- `src/cleanup/safety.zig` — the three safety tiers, the catalogs (safe app
  caches, system junk, dev caches, project rules), and the deny lists for
  identity/keychain, system UI and endpoint-security caches. A rule can only
  narrow what the deny lists allow; `unknown` never reaches the UI.
- `src/cleanup/item.zig` — `Category` (where an item came from), `Tab` (which
  page it belongs to) and `Removal` (how it goes). `Category.tab()` and
  `Removal.verb()` are the only mappings; `measured` means "the page may show
  a size" and `sized` means "already measured, do not walk it again".
- `src/cleanup/scanner.zig` — thirteen passes (app caches, junk, dev caches,
  Application Support, large files, apps, projects, simulators, Xcode
  components, brew casks, brew formulae, snapshots, disk map). `scanAll` runs
  them together; the app runs them one at a time. Size walks run on up to ten
  threads (capped by the core count), each with its own `std.Io` and
  `std.heap.smp_allocator`; each item is measured by exactly one thread, and
  an app's bundle and Library folders are measured one by one. `initAt` scans
  a home of its own with `machine = false`, so tests never read the real
  machine's simulators, Homebrew list, snapshots or disk.
- `src/cleanup/measure.zig` — `measureAt`: a file is its size, a folder is
  what it holds, bounded by a file limit (past it, the size is a floor).
- `src/cleanup/large.zig` — files over 100 MB in the user's own folders.
- `src/cleanup/apps.zig` — app bundles in `/Applications` and
  `~/Applications`, their `CFBundleIdentifier` (XML parsed directly, binary
  plists through `plutil`), and the Library folders that go with them.
  `com.apple.*` is never offered.
- `src/cleanup/simulators.zig`, `xcode.zig`, `brew.zig`, `snapshots.zig` — the
  tool-owned things, found by asking `simctl`, `xcodebuild`, `brew` and
  `tmutil`, each with the removal its tool provides.
- `src/cleanup/diskmap.zig` — the Space card's read-only rows: `df`'s figures
  and the user's own folders. Items from here have `removal = .none` and no
  tick, and `Tab.overview` exists only to group them (no sidebar tab shows it).
- `src/cleanup/remove.zig` — the one place that decides how an item goes:
  `trash` moves it, the tool removals run their command, `none` refuses.
- `src/cleanup/exec.zig` — running a short command and reading its output,
  blocking, for the worker thread only. It passes a real environment (brew
  needs `$HOME`), merges stderr so error text can be read, and `jsonSlice`
  trims the warnings around a tool's JSON.
- `src/cleanup/trash.zig` — moves to `~/.Trash` on macOS or the freedesktop
  trash on Linux with `rename(2)`, under a unique name. It never deletes for
  good, and re-checks the protected prefixes and deny rules before each move.
  `moveAppToTrash` is the one exception to the protected `/Applications`
  prefix, and accepts only a real `.app` inside an Applications folder.
- `src/app.zig` — `startCleanupScan` spawns the worker and publishes each
  finished pass into a staging list under a spinlock; `pollCleanupScan` drains
  it once per frame. The worker must never touch the window (Cocoa requires
  the main thread). `cleanupSetTab` and `refreshCleanupView` decide what the
  page shows: the current tab, then the safety filter, then the order.
- `src/view_cleanup.zig`, plus `cleanupConfirm` in `src/view_sheet.zig` — the
  page (sort, filter, ticking, footer) and the confirmation sheet, whose
  wording follows the tab ("Uninstall 1 app?").
- `src/view_side.zig` — the sidebar: the Cleanup section and its four tabs,
  each showing what that tab found.

Every walk is bounded: 20,000 files per folder (past that the size is a floor,
drawn as `≈`), 12,000 folders and depth 6 for the project search, and 400
project artifacts, 40,000 folders for large files, 400 apps, 80 simulators,
120 casks, 120 formulae, 40 snapshots, and 12,000 files per folder for the
disk map. Brew's retry rounds get a four-second budget.
`docs/CLEANUP.md` has the full catalog and safety notes.

## Directory Structure

- `src/` — All Zig source code (main entry point: `src/main.zig`)
- `docs/` — Documentation images only (no markdown files)
- `macos/` — macOS packaging, signing, and notarization scripts
- `tools/` — Utility scripts (e.g., `video.sh`)
- `third_party/licenses/` — Third-party license texts

## Generated and Ignored Files

Do not edit these:
- `.zig-cache/` — Zig build cache
- `zig-out/` — Zig build output directory
- `zig-pkg/` — Zig package cache

## License Context

nanomon is MIT-licensed, but incorporates CodeGraff and Harness materials under a modified GNU AGPLv3 license. The graff integration runs graff as an external command (`graff -p --no-local-tools`) and does not bundle graff itself.

See `THIRD_PARTY_NOTICES.md` and `third_party/licenses/CodeGraff-LICENSE.txt` for full third-party license details.

## CI/CD

GitHub Actions (`.github/workflows/release.yml`) handles macOS releases with code signing and notarization. The workflow uses repository secrets for credentials; agents should not attempt to read or reproduce these secrets.
