# Cleanup

Cleanup has its own section in the sidebar, above System, with five tabs
(⌘9 opens it):

| Tab | What it is for |
| --- | --- |
| **App Caches** | What apps leave behind: caches, logs, crash reports, saved window state. |
| **Dev Tools** | Caches tools keep for every project, the build folders inside projects, simulator runtimes and devices, and Xcode components. |
| **CLI Tools** | The command-line tools the machine has — Homebrew's, npm's, pnpm's, bun's, pipx's, cargo's and the ones downloaded by hand — and the newer versions their managers offer. |
| **Large Files** | The biggest files in the user's own folders, with what each one is. |
| **App Uninstaller** | An installed app (including the ones Homebrew installed), together with what it left in the user's Library. |

Where the space went is not a tab: the **Space** card at the foot of the
machine's own Overview page carries it — the disk's figures, what each tab
found (a click opens that tab), and the size of the user's folders. It is
read-only, and it is filled by the same scan.

The design follows [purge-app](https://github.com/jithin-sabu/purge-app): a
scan only ever *proposes* a path, a safety catalog decides whether it may be
offered, and everything removed goes to the Trash.

## App Caches

| Where | What |
| --- | --- |
| `~/Library/Caches` | One row per cache folder. Known caches are Safe; an unrecognized app's cache is Check First; denied names never surface. Folders under 1 MB are skipped as noise. |
| `~/Library/Application Support` | Only cache folders inside an app's data (`Cache`, `Code Cache`, `GPUCache`, `CachedData`, `ShaderCache`, `Service Worker`, `Crashpad`, …), including one level deeper for Chromium profiles (`Default`, `User Data`). An app's real data is never offered. |
| System junk | `~/Library/Logs`, `~/Library/Saved Application State`, Simulator caches, `~/Library/Developer/Xcode/iOS DeviceSupport`. |
| Time Machine | The local snapshots `tmutil` lists, one row each. Their size is not reported by macOS, so the Size column shows a dash. |

## Dev Tools

Global caches, shared by every project on the machine:

| Tool | Cache |
| --- | --- |
| npm, Yarn, pnpm, bun, uv | `~/.npm/_cacache`, `~/.yarn/cache`, `~/.pnpm-store`, `~/Library/pnpm/store`, `~/.bun/install/cache`, `~/.cache/uv` |
| pip, Hugging Face | `~/.cache/pip`, `~/.cache/huggingface` (Check First) |
| Go | `~/.cache/go-build`, `~/go/pkg/mod` (Check First) |
| Rust | `~/.cargo/registry/cache` |
| JVM | `~/.gradle/caches`, `~/.gradle/wrapper/dists`, `~/.m2/repository` (Check First) |
| Xcode | `~/Library/Developer/Xcode/DerivedData`, `~/Library/Developer/Xcode/Archives` (Check First) |
| Docker Desktop | `~/Library/Containers/com.docker.docker` (Check First) |
| Terraform | `~/.terraform.d/plugin-cache` |

Homebrew's own cache is `~/Library/Caches/Homebrew`, so the app-cache scan
already covers it. The formulae it installed are not a cache: they are rows
on the CLI Tools page.

And the rebuildable folder inside each project the walk finds:

| Ecosystem | Marker | Folder |
| --- | --- | --- |
| Node | `package.json` | `node_modules`, `.next`, `.nuxt`, `.output`, `.svelte-kit`, `.astro`, `.angular`, `.turbo`, `.parcel-cache`, `node_modules/.vite` |
| Rust | `Cargo.toml` | `target` |
| Zig | `build.zig` | `zig-out`, `.zig-cache` |
| Python | `pyproject.toml`, `requirements.txt` | `.venv`, `venv`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache` |
| Flutter | `pubspec.yaml` | `build`, `.dart_tool` |
| Android / JVM | `build.gradle[.kts]`, `settings.gradle[.kts]`, `pom.xml`, `build.sbt` | `build`, `.gradle`, `target`, `project/target` |
| Xcode / Swift | `Podfile`, `ios/Podfile`, `Package.swift` | `Pods`, `ios/Pods`, `.build` |
| Elixir | `mix.exs` | `_build`, `deps` |
| PHP / Ruby | `composer.json`, `Gemfile` | `vendor`, `vendor/bundle` |
| .NET | `*.csproj`, `*.fsproj`, `*.vbproj`, `*.sln` | `bin`, `obj` |
| JVM / native | `CMakeLists.txt`, `dune-project`, `stack.yaml`, `*.cabal` | `build`, `_build`, `.stack-work`, `dist-newstyle` |
| Infrastructure / engines | `*.tf`, `project.godot`, Unity's `ProjectSettings/ProjectVersion.txt`, `*.uproject` | `.terraform`, `.godot`, `Library`, `Temp`, `Intermediate`, `DerivedDataCache` |

And the tools Xcode and the Simulator keep:

| What | How it is found | How it goes |
| --- | --- | --- |
| Simulator runtimes | `xcrun simctl list runtimes --json`, sized from each runtime's bundle. A runtime with a running simulator is left alone. | `xcrun simctl runtime delete <identifier>` |
| Simulator devices | `xcrun simctl list devices --json`, sized from `dataPathSize`. A booted device is left alone. | `xcrun simctl delete <udid>` |
| Xcode components | `xcodebuild -showComponent <name> -json`, and only when its `status` is `installed` (today: the Metal toolchain). | `xcodebuild -deleteComponent <name>` |

A `.terraform` folder holding `terraform.tfstate`, `terraform.tfstate.backup`
or `environment` is refused: that is state, not a cache. Unity and Unreal
folders are Check First, because reimporting a large project can take a long
time.

## CLI Tools

One row per command-line tool, from whatever installed it. The Version
column says what is installed and, when its manager offers something newer,
what that manager would install instead; **Update** installs it, and
**Uninstall** takes the tool away.

| Where it came from | Found by | Updated by | Removed by |
| --- | --- | --- | --- |
| Homebrew | `brew list --formula --versions`, sized by the Cellar folder | `brew upgrade <name>` | `brew uninstall <name>` |
| npm | `npm ls -g --depth=0 --json`, sized by the package folder | `npm install -g <name>@latest` | `npm uninstall -g <name>` |
| pnpm | `pnpm ls -g --depth 0 --json`, sized by the package folder | `pnpm update -g --latest <name>` | `pnpm remove -g <name>` |
| bun | `bun pm ls -g`, sized by the package folder | `bun update -g --latest <name>` | `bun remove -g <name>` |
| pipx | `pipx list --json`, sized by the tool's own environment | `pipx upgrade <name>` | `pipx uninstall <name>` |
| cargo | `cargo install --list`, sized by the first binary | `cargo install <name>` (the newest) | `cargo uninstall <name>` |
| Downloaded by hand | an executable in `~/.local/bin` or `~/bin` that no manager owns | — | the Trash, so it can be put back |

Each manager is asked twice: what it has installed, which is local and quick,
and what it would install instead — its own `outdated`, which is the one part
of a scan that reaches the network. `brew outdated --json=v2`,
`npm outdated -g --json`, `pnpm outdated -g --format json` and
`bun outdated -g` are read for that. A manager that is not on the machine, or
that will not answer, leaves no rows behind and does not fail the pass.

Nothing local says whether a crate is behind, so cargo's rows carry the
version installed and an Update that installs the newest — which is what
`cargo install` does. pipx is the same: its `upgrade` fetches the newest.

The downloaded ones are the `curl`-and-a-binary kind. Only real files count:
the managers put their own commands in those folders as symlinks, and a
symlink belongs to the manager that made it. Every row here is Check First —
uninstalling a tool is real, even when it can be put back.

Nothing on this page is a cache: those are Dev Tools' business. And what
plain `pip` writes goes into Homebrew's or the system's own prefix, which
nanomon never touches, so a Python command-line program is offered when pipx
installed it.

## Large Files

The biggest files in `~/Downloads`, `~/Desktop`, `~/Documents`, `~/Movies`,
`~/Music` and `~/Pictures`, at least 100 MB each. Nothing here is judged junk:
every row is Check First, and the Kind column says what the file is — a disk
image, a virtual machine, an AI model, an archive, a video, a photo, an
installer, a backup, or simply a large file. The Where column shows the folder
inside the home folder, so a row reads `holiday.mov · Movies`.

The walk skips hidden folders, `.Trash`, and the build folders Dev Tools
already covers, and it is bounded (40,000 folders, depth 8, 200 rows).

## App Uninstaller

Every app in `/Applications` and `~/Applications`, with the files it keeps in
the user's Library:

| Shape | Where |
| --- | --- |
| The bundle | `/Applications/<App>.app` |
| Data and caches | `~/Library/Application Support/<id>`, `~/Library/Caches/<id>`, `~/Library/Logs/<id>` |
| Settings and state | `~/Library/Preferences/<id>.plist`, `~/Library/Saved Application State/<id>.savedState`, `~/Library/HTTPStorages/<id>`, `~/Library/WebKit/<id>`, `~/Library/Cookies/<id>.binarycookies`, `~/Library/LaunchAgents/<id>.plist`, `~/Library/Application Scripts/<id>` |
| Sandboxed data | `~/Library/Containers/<id>` |

`<id>` is the bundle's `CFBundleIdentifier`, read from `Contents/Info.plist`
(XML is parsed directly; a binary plist goes through `plutil -extract`).
Folders that match the app's *name* are looked for too, for apps whose
identifier differs from what they write on disk. Only paths that really exist
become locations, so a row's `+N` is the number of extra folders that will go
with the app.

**Apple's own apps are never offered** (`com.apple.*`), and neither is
anything outside the two Applications folders. Uninstalling is Check First,
and the sheet says what it is about to take.

Apps Homebrew installed are marked as such (`brew list --cask`, and
`brew info --cask --json=v2` for the `.app` each cask puts in Applications),
and go through `brew uninstall --cask` instead. A cask brew refuses to load
(an untrusted tap) is named in brew's own error, and the rest of the list is
asked for without it.

An app's Library folders also appear as rows in App Caches, because they are
caches. Removing the app takes them with it; the rows left behind then fail to
move, and the page says so rather than pretending otherwise.

## How something is removed, and updated

Almost everything moves to the Trash, where it can be put back. A few things
belong to a tool that will not use the Trash, and those are removed for good —
the sheet says so before it happens, and the button carries the tool's own
word:

| Removed by | Items | What happens |
| --- | --- | --- |
| The Trash | caches, junk, project folders, large files, apps, leftovers | `rename(2)` into `~/.Trash`, undoable |
| `simctl` | simulator runtimes and devices | deleted; Xcode downloads or creates them again |
| `xcodebuild` | Xcode components | deleted; Xcode downloads them again |
| `brew` | casks, and the formulae the CLI Tools page lists | uninstalled; `brew install` brings them back |
| `npm`, `pnpm`, `bun` | global packages | uninstalled; the same manager installs them again |
| `pipx`, `cargo` | pipx environments, cargo binaries | uninstalled; `pipx install` or `cargo install` brings them back |
| `tmutil` | Time Machine snapshots | deleted; the next backup makes a new one |

Read-only rows (the overview's) have no removal at all: nothing on that page
moves a file.

An update is not a removal: nothing is taken away, so no Trash is involved and
the row stays on the page — with the version its manager just installed, and
no longer behind. The footer offers **Update** only when something ticked has
a manager that can bring it up to date, and the sheet says which managers will
be asked before anything runs.

## Safety

Three tiers, and the third never reaches the UI:

- **Safe to Clean** — a known cache or junk: it comes back on its own.
- **Check First** — real data that does come back, but at a cost (an
  unrecognized app cache, Xcode archives, Docker's images, Unity's Library,
  any large file, any app).
- **Not Sure** — the resolver could not vouch for it. Dropped at the scan
  boundary, so a classification mistake cannot leak a row into the page.

Deny lists are the safety net, checked twice: when a folder is classified, and
again when a path is about to move.

- Exact names: CloudKit, FamilyCircle, PassKit, the account/identity daemons
  (`com.apple.akd`, `com.apple.identityservicesd`, …), and
  `com.apple.containermanagerd`. Wiping identity caches makes macOS re-hit the
  login keychain for every service.
- Fragments: `account`, `icloud`, `appleid`, `authkit`, `authentication`,
  `authorization`, `keychain`, `passkit`, `screentime`, password managers
  (`1password`, `agilebits`, `bitwarden`, `lastpass`, `dashlane`, `keepass`,
  `authy`, `yubico`), and `inputmethod` (learned words live beside the cache).
- Prefixes: system UI (`com.apple.finder`, `com.apple.dock`,
  `com.apple.controlcenter`, `com.apple.systempreferences`, …) and endpoint
  security / MDM agents (CrowdStrike, SentinelOne, ESET, Jamf, Palo Alto,
  Cisco Secure Client). Touching these can blank panels until logout or trip
  tamper detection.
- Protected path prefixes are never scanned or removed: `/System`, `/Library`,
  `/usr`, `/bin`, `/sbin`, `/etc`, `/var`, `/private`, `/Applications`,
  `/Volumes`, `/cores`, `/opt`. An app bundle is the one exception: it is
  moved by `moveAppToTrash`, which accepts only a real `.app` directly inside
  an Applications folder.

## How a scan runs

The UI thread never touches the filesystem.

- `App.startCleanupScan` spawns one worker thread. The worker owns its own
  `std.Io` and a `CacheScanner`.
- Thirteen passes run in order: app caches, system junk, dev caches,
  Application Support, large files, apps, projects, simulators, Xcode
  components, Homebrew casks, CLI tools, Time Machine snapshots, and the
  read-only disk map that fills the Overview's Space card. Each is published
  as it finishes. The handover is a small staging list guarded by a spinlock;
  the worker never calls into the window.
- The app asks for a scan the first time it is opened, so the Overview has
  something to say; Scan (on the Overview's card or a Cleanup page) asks again.
- `view.zig` polls once per frame (`pollCleanupScan`), drains what is staged,
  re-sorts and redraws. Rows appear progressively and the header reads
  "Scanning… N of 13 done".
- The passes that ask a tool (`simctl`, `xcodebuild`, `brew`, `tmutil`, `df`,
  and the CLI tools' six managers) run one command at a time on the worker
  thread, and brew's retry rounds are given a four-second budget so a long
  list of untrusted casks cannot hold the scan up.
- Sizes are measured on up to ten threads (never more than the machine has
  cores), each with its own `std.Io` and the SMP allocator. Every item is
  measured by exactly one thread; an app's bundle and each of its Library
  folders are measured separately.
- Every walk is bounded: 20,000 files per folder (past that the size is a
  floor, shown as `≈ 4.0 GB`), 12,000 folders for the project search, depth 6,
  400 project artifacts, 40,000 folders for large files, 400 apps, and 400
  tools per manager.
- The CLI tools pass is the heaviest of the thirteen: it asks six managers,
  and the `outdated` questions are the only part of a scan that uses the
  network. On a machine with a few hundred tools it takes some fifteen
  seconds. Everything else has been on the page long before it.
- A scan of a developer's Mac takes a few seconds to half a minute; the caches
  and the disk map appear first, and the tool passes (simulators, brew, CLI
  tools) fill in behind them.

## Trash

- **macOS**: `~/.Trash`, moved with `rename(2)` under a unique name
  (`report.pdf`, `report 2.pdf`), so Finder's Put Back keeps working.
- **Linux**: the freedesktop.org trash, `~/.local/share/Trash/files` plus
  `info/<name>.trashinfo` with the percent-encoded origin and deletion date.
- A failed move leaves the row on the page, still ticked, and the footer
  notices how many moved and how many did not.

## The page

- Header: the tab's name, how many items it found and what they are worth,
  the filter (All / Safe / Check First), and Scan (⌘R).
- Columns: Name, Kind, Where, Size (sortable; biggest first), Safety
  (sortable). An app's `+N` is how many extra folders go with it. The list is
  virtualized (`ui.list`).
- The CLI Tools page sorts by Kind and Where as well, because that is how a
  list of several hundred tools is read: by what they are, and by the manager
  that owns them. Every other tab sorts by Name, Size and Safety.
- Scan's arrow turns while the scan runs, one turn a second off the frame
  clock: a `ui.button` draws its own icon, so a scan in flight is drawn by the
  page itself, and the frames keep coming until it is done.
- Click a row to tick it. The header's box ticks every row the filter shows,
  or clears them. A tick follows its item across tabs.
- Footer: ticked count and size, Clear, and Move to Trash… — or Uninstall… on
  the App Uninstaller tab. Either opens a sheet naming the items first, and
  with one row ticked the row's explanation and rebuild command show beneath.

## Files

| File | What it holds |
| --- | --- |
| `src/cleanup/safety.zig` | Safety levels, deny lists, and the cache, junk and dev-tool catalogs. |
| `src/cleanup/item.zig` | `CacheItem`, `CacheLocation`, `Category` and the `Tab` the page groups by. |
| `src/cleanup/measure.zig` | Measuring a file or a folder, bounded, on any thread. |
| `src/cleanup/scanner.zig` | The thirteen passes, the bounded project walk, parallel measurement. |
| `src/cleanup/large.zig` | The Large Files walk and what each file is. |
| `src/cleanup/apps.zig` | App bundles, bundle identifiers, and what each app left behind. |
| `src/cleanup/simulators.zig` | Simulator runtimes and devices, through `simctl`. |
| `src/cleanup/xcode.zig` | Xcode's optional components. |
| `src/cleanup/brew.zig` | Homebrew's casks: the apps it put in Applications, and its environment for every call. |
| `src/cleanup/cli.zig` | The CLI Tools rows: brew formulae, npm/pnpm/bun globals, pipx tools, cargo binaries, and the programs downloaded by hand, with each manager's `outdated`. |
| `src/cleanup/snapshots.zig` | Time Machine's local snapshots, through `tmutil`. |
| `src/cleanup/diskmap.zig` | The overview: the disk's figures and the user's folders. |
| `src/cleanup/remove.zig` | How each kind of item is removed or updated, and the command that does it. |
| `src/cleanup/exec.zig` | Running a short command off the UI thread, finding a tool, and reading what it said. |
| `src/cleanup/trash.zig` | Moving to the macOS or freedesktop trash, and the app rule. |
| `src/view_cleanup.zig` | The page: tabs, list, sorting, filtering, ticking, footer. |
| `src/view_overview.zig` | The machine's Overview page, which carries the Space card (`view_cleanup.space`). |
| `src/view_side.zig` | The sidebar, with Cleanup and its five tabs above System. |
| `src/view_sheet.zig` | The confirmation sheet (`cleanupConfirm`). |
| `src/tests_cleanup.zig` | The page and the tabs through `ui.Tester`, and the move end to end. |

The app state lives in `src/app.zig`: `cleanup_items`, `cleanup_visible`,
`cleanup_selected`, the tab, sort and filter, the worker and its staging list,
and the notice.

## Tests

`zig build test` covers:

- the catalogs: safe, Check First, denied names/fragments/prefixes, and
  Application Support's cache-only children;
- the scanner against a fake home: what surfaces, what is denied, project
  markers, Terraform state refusal, an empty home, cancellation, and sizes
  that are floors;
- measuring: a file, a folder, the file limit, a path that is not there;
- large files: the threshold, the folder a row names, and what each kind is;
- apps: the identifier from an XML plist, Apple's apps refused, and an app's
  Library folders found beside its bundle;
- simulators: an identifier read as a name, and the runtimes a machine has;
- Xcode: a path found in the component's answer, and only installed
  components becoming rows;
- Homebrew: the casks as apps in Applications, and a command for every kind
  of removal;
- the CLI tools: each manager's own answer (brew's list, npm's and pnpm's
  JSON, bun's tree, cargo's list, pipx's JSON), the newer versions from
  `outdated`, the last line of a warning-wrapped path, a manager that is not
  there leaving no rows, and a downloaded program counting only when it is a
  real file rather than a manager's symlink;
- the disk map: `df`'s row read as bytes, and the folders measured read-only;
- the Trash: a file and a folder move and can be put back, name collisions,
  protected paths refused, and an app bundle accepted only where apps live;
- the page through `ui.Tester`: biggest first, sorting, filtering, ticking,
  the header's box, the five tabs and their wording, the "removed for good"
  warning, and the sheet (which is cancelled, never confirmed);
- the CLI Tools page: the installed and the newer version side by side, and
  Update offered only for a ticked row that is behind;
- the Overview page: its tiles, the Space card's figures, the Cleanup rows
  opening their tab, and that nothing there is tickable.
- the move end to end against a temporary trash, including the failure path.

## Not included

Package managers nanomon does not read — MacPorts, Nix, asdf, and plain `pip`,
whose installs land in a prefix nanomon never touches — purge's treemap
drawing (the overview is a list of bars instead), and scheduled cleaning.
