# Nanomon Space Cleanup Feature Design

> **Status:** implemented. This file records the original design and the
> research behind it. What actually shipped — the catalogs, safety rules,
> threading, limits and tests — is documented in
> [`docs/CLEANUP.md`](docs/CLEANUP.md).

## Research Summary: Purge-app Architecture

### Core Concepts from Purge-app

1. **Scan Categories**
   - **App Caches**: `~/Library/Caches`, Application Support, sandbox containers, system junk (logs, crash reports, installers)
   - **Dev Tools**: Xcode (Derived Data, Archives, DeviceSupport), simulators, Homebrew, npm, pnpm, Yarn, CocoaPods, Gradle, Flutter, Docker, VS Code, JetBrains, Cargo, Terraform, etc.
   - **Large Files**: Documents, Desktop, Downloads, Movies, Music, Pictures, virtual machines, AI models
   - **Everything Else**: Read-only disk space visualization

2. **Scanner Architecture**
   - Separate scanner classes: `CacheScanner`, `DevScanner`, `LargeFileScanner`
   - AsyncStream pattern for streaming results to UI
   - ScanQueue runs scans sequentially (one at a time to avoid disk contention)
   - Full Disk Access requirement for some scans

3. **Safety System**
   - Three safety levels: `.safe` (Safe to Clean), `.medium` (Check First), `.unknown` (Not Sure)
   - Unknown items never surface in UI
   - Safety policies gate every deletion path
   - Files go to Trash by default (never emptied by app)
   - Special exceptions: simulators, Xcode components, Time Machine snapshots, Apple Intelligence models removed for good

4. **Models**
   - `CacheItem`: app name, locations, size, safety info, selection state
   - `DevTool`: tool name, paths, size, safety info
   - `LargeFile`: path, size, category, kind (restore image, VM, AI model, etc.)
   - `SafetyInfo`: level, headline, explanation, recovery steps, reinstall command

## Proposed Scope for Nanomon

### Phase 1: App Caches (Minimum Viable)

**Scanner Implementation**
- Scan `~/Library/Caches` directory
- Scan Application Support caches (Chromium browsers, Electron apps)
- System junk: application logs, crash reports
- Stream results via AsyncStream-like pattern

**UI Components**
- New sidebar page: "Cleanup" (⌘9)
- Table view showing: app name, size, safety label
- Safety labels: ✅ Safe to Clean, ⚠️ Check First
- Selection via checkboxes, ⌘-click, ⇧-click (reuse existing patterns)
- Confirmation sheet before deletion
- Move to Trash (never empty Trash)

**Safety System**
- SafetyLevel enum: safe, medium, unknown
- SafetyInfo struct with explanations
- Simple allowlist: known safe cache paths
- Never scan system-protected locations

### Phase 2: Dev Tools

**Scanner Implementation**
- Xcode Derived Data: `~/Library/Developer/Xcode/DerivedData`
- Xcode Archives: `~/Library/Developer/Xcode/Archives`
- Homebrew cache: `~/Library/Caches/Homebrew`
- npm cache: `~/.npm`
- pnpm store: `~/.pnpm-store`
- Yarn cache: `~/.yarn`
- CocoaPods: `~/Library/Caches/CocoaPods`
- Gradle: `~/.gradle/caches`
- Docker Desktop: `~/Library/Containers/com.docker.docker`

**UI Extensions**
- Dev Tools sub-page or filter within Cleanup
- Group by tool type
- Size thresholds for stale projects

### Out of Scope (for now)

- Large Files scanner (complex, needs category detection)
- iOS Simulators (requires simctl)
- Xcode Components (requires xcodebuild)
- App Uninstaller (complex matching logic)
- Everything Else visualization
- Scheduled cleaning
- Command-line tools
- AI models
- iCloud integration

## Integration with Nanomon UI/UX

### Sidebar
- Add `.cleanup` to `app.Page` enum
- Icon: 🧹 or trash symbol
- Position: after Apps, before About

### Table View
- Reuse `view_table.zig` patterns
- Columns: Name, Size, Safety, Last Modified
- Sort by size, name, date
- Filter by safety level (All, Safe, Check First)

### Sheets
- Confirmation sheet: lists items to delete, total size
- Safety explanation: show explanation for each item
- Progress sheet during deletion

### Colors (Codegraff Theme)
- Safe to Clean: sage green
- Check First: amber
- Table selection: rust highlight
- Use existing nanomon color palette

### Keyboard Shortcuts
- ⌘9: Cleanup page
- ⌘R: Scan current category
- ⌥⌘1-3: Filter by safety level
- ⌘F: Search (reuse existing)
- ⌥⌘Q: Clean selected (new)

## File Structure

```
src/
  cleanup/
    scanner.zig          # App cache scanner
    dev_scanner.zig      # Dev tools scanner
    safety.zig           # Safety levels and policies
    item.zig             # CacheItem model
    view_cleanup.zig     # Cleanup page UI
    view_table.zig       # Cleanup table (or reuse existing)
    sheet.zig            # Confirmation sheet
```

## Implementation Plan

1. **Data Models** (`cleanup/item.zig`, `cleanup/safety.zig`)
   - SafetyLevel enum
   - SafetyInfo struct
   - CacheItem struct

2. **Scanners** (`cleanup/scanner.zig`, `cleanup/dev_scanner.zig`)
   - Async scanning pattern (zig's async/await)
   - Directory walking
   - Size calculation
   - Safety classification

3. **UI** (`cleanup/view_cleanup.zig`)
   - Add Cleanup page to sidebar
   - Table view with selection
   - Safety labels
   - Scan button and progress

4. **Deletion** (`cleanup/sheet.zig`)
   - Confirmation sheet
   - Move to Trash (via std.fs or shell command)
   - Progress feedback

5. **Integration**
   - Update `app.zig` Page enum
   - Update `view.zig` switch statement
   - Update `view_side.zig` sidebar

## Safety Considerations

- Never delete without user confirmation
- Default to Trash, never delete permanently
- Unknown items: never show, never delete
- System-protected paths: exclude from scan
- Git repositories: exclude or mark as Check First
- Running app caches: mark as Check First

## Testing Strategy

- Unit tests for scanners (fake filesystem)
- Safety policy tests
- UI tests via nanoui's Tester
- Deletion tests (verify Trash destination)
