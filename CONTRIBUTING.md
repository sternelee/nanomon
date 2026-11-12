# Repository Guidelines

nanomon is a Zig system monitor built on the nanoui UI framework, targeting
macOS and Linux. `AGENTS.md` documents the cleanup subsystem; this file is the
contributor guide.

## Project Structure & Module Organization

- `src/` — Zig sources. Entry point `src/main.zig`; app state in `src/app.zig`.
- `src/view_*.zig` — one file per page (`src/view_cpu.zig`), shared widgets in
  `src/view_kit.zig`.
- `src/sample_*.zig` — per-platform sampling, with `sample_none.zig` as the
  fallback.
- `src/cleanup/` — scan passes, safety catalog, measuring, removal.
- `src/tests*.zig` — test roots and suites.
- `macos/` — packaging, signing, notarization. `tools/` — helper scripts.
  `docs/` — images plus `docs/CLEANUP.md`. `third_party/licenses/` — license
  texts.
- Never edit `.zig-cache/`, `zig-out/` or `zig-pkg/`.

## Build, Test, and Development Commands

- `zig build run` — build and run nanomon.
- `zig build test` — run the test suite.
- `zig build test-bin` — install `zig-out/bin/nanomon-tests` to run on another
  machine, e.g. a Linux container.
- `zig build video` — build `nanomon-video`, the offscreen renderer.
- `zig fmt src build.zig` — format; run before committing.
- Zig 0.17.0 or later; nanoui is fetched from `build.zig.zon`.

## Coding Style & Naming Conventions

- Four-space indentation; `zig fmt` is authoritative, no other linter runs.
- Files and variables `snake_case`, types `PascalCase`, functions `camelCase`.
- Imports at the top, aliased as `const X = @import("x.zig").X;`.
- Each module opens with a `//!` doc comment; keep comments lowercase and
  sentence-like, matching neighbouring files.
- Guard macOS-only code with `builtin.os.tag == .macos` or `menubar.supported`.
  The worker thread must never touch the window.

## Testing Guidelines

- Tests sit beside their modules and are aggregated in `src/tests.zig`; add a
  `_ = @import("your_module.zig");` line per new file.
- Names describe behavior, e.g. `test "the keyboard: pages, the selection,
  Escape"`.
- Platform tests are conditional: `if (builtin.os.tag == .macos)`.
- Cleanup tests scan with `machine = false`, so they never read the real
  machine.
- Run `zig build test` before pushing; use `test-bin` when verifying on Linux.

## Commit & Pull Request Guidelines

- Recent commits use Conventional Commit prefixes — `feat(cleanup):`, `deps:` —
  while older ones use imperative sentence subjects. Prefer the prefixed form
  with a short imperative subject.
- Pull requests should explain the change and why, list platforms verified
  (macOS, Linux), attach screenshots or `zig build video` output for UI work,
  and link the issue.
- Note untested paths explicitly, and do not touch release credentials or
  `.github/workflows/release.yml` secrets.
