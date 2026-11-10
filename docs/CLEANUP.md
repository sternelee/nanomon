# Cleanup Feature

The Cleanup feature (⌘7) allows scanning and deleting app caches, system junk, and development tool artifacts.

## Architecture

### Safety System

Three-tier safety classification with Trash-by-default policy:

- **Safe (green)**: Caches that can be safely deleted without user impact
  - Recognized browser caches (Chrome, Firefox, Safari)
  - macOS system caches with safe patterns
- **Medium (orange)**: Caches that may require regeneration after deletion
  - Application Support folders not in safe whitelist
  - Dev Tools directories (node_modules, .venv, build cache)
- **Unknown (gray)**: Caches with uncertain safety profile
  - Files not matching known patterns

### Protected Paths

The following paths are never scanned or deleted:

- `/System`
- `/Library`
- `/usr/local`

### Scanner

`CacheScanner` in `src/cleanup/scanner.zig` provides three scan functions:

1. **Library Caches**: Scans `~/Library/Caches` for browser and app caches
2. **Application Support**: Scans `~/Library/Application Support` for app data
3. **Dev Tools**: Scans home directory for development artifacts:
   - `node_modules` (Node.js)
   - `.venv`, `venv`, `.virtualenv` (Python)
   - `zig-cache`, `zig-out` (Zig)
   - `.gradle`, `target`, `build` (Various build systems)

**Non-blocking UI**: Scanning runs in phases to prevent UI freezing:
- Each scanner processes up to 50 entries per call (chunked)
- Directory size calculation checks at most 100 files per directory
- Scans run in 3 phases (Library Caches → Application Support → Dev Tools)
- UI redraws between phases to maintain responsiveness

Dev Tools scanning is depth-limited to 3 levels to avoid scanning the entire home directory.
### Trash Manager

`TrashManager` in `src/cleanup/trash.zig` handles safe file deletion:

- **macOS**: Moves files to `~/.Trash`
- **Linux**: Moves files to `~/.local/share/Trash` (freedesktop.org standard)

## Usage

1. Press ⌘7 to open the Cleanup page
2. Click "Scan" to find caches and system junk
3. Review the results table showing:
   - Name (app/folder name)
   - Location (folder name)
   - Size (human-readable)
   - Safety level (color-coded)
4. Select items with checkboxes
5. Click "Delete Selected" to move items to Trash
6. Confirm deletion in the dialog

## Current Limitations

### Zig 0.17 Compatibility

The following features are stubbed for Zig 0.17 compatibility:

- **TrashManager.moveToTrash**: Returns `error.NotImplemented`
  - File existence check (`std.fs.statFile`) unavailable
  - File rename (`std.fs.renameAbsolute`) unavailable
  - File access check (`std.fs.accessAbsolute`) unavailable
  - Unique name generation simplified (no existence check)

- **Dev Tools Scanner**: Depth-limited to 3 levels
  - Prevents scanning entire home directory
  - May miss deeply nested dev tools directories

## Implementation

### Modules

- `src/cleanup/safety.zig`: SafetyLevel enum, SafetyInfo struct, SafetyPolicy
- `src/cleanup/item.zig`: CacheItem struct, CacheLocation struct, size formatting
- `src/cleanup/scanner.zig`: CacheScanner with three scan functions
- `src/cleanup/trash.zig`: TrashManager for safe file deletion
- `src/view_cleanup.zig`: Cleanup page UI (⌘7)

### State

`App` struct in `src/app.zig` includes:

- `cleanup_items`: ArrayListUnmanaged of CacheItem pointers
- `cleanup_scanning`: bool flag for scan in progress
- `cleanup_scan_phase`: u8 scan phase (0=Library Caches, 1=Application Support, 2=Dev Tools, 3=done)
- `cleanup_selected`: AutoArrayHashMap for selected items
- `cleanup_confirm`: bool flag for confirmation dialog
## Testing

Run tests with:

```bash
zig build test
```

All cleanup module tests pass:
- Safety policy tests (6 tests)
- Cache item tests (9 tests)
- Scanner tests (2 tests)
- Trash manager tests (1 test)
