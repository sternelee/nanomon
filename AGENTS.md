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
