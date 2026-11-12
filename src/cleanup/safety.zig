//! Safety levels, and the catalogs that decide what the Cleanup page may
//! offer. The shape follows purge-app (github.com/jithin-sabu/purge-app): a
//! scan only ever *proposes* a path, and every proposal is classified here
//! before it can reach the UI.
//!
//! Three tiers, and the third never surfaces:
//!
//!   .safe    known cache or junk: deleting it costs nothing but a rebuild
//!   .medium  "Check First": real data that comes back, but at a cost
//!   .unknown the resolver could not vouch for it, or it is on a deny list;
//!            dropped at the scan boundary
//!
//! The deny lists are the safety net. Identity, keychain and payment caches,
//! system UI caches, and endpoint-security agents are refused by exact name,
//! fragment and prefix, so a name we have never seen is still refused: the
//! list has to be extended once per discovery, but the fragment and prefix
//! rules close the class in the meantime.
const std = @import("std");

/// The classification a scanned item can carry.
pub const SafetyLevel = enum {
    /// Safe to Clean: known cache or rebuildable artifact
    safe,
    /// Check First: may be safe, but could cause inconvenience
    medium,
    /// Not Sure: the resolver could not identify this
    /// Unknown items never surface in scan results
    unknown,

    /// The only classifications permitted to surface in scan results.
    /// Anything else is dropped at the assembly boundary as a safety net.
    pub fn canSurfaceInScanResults(self: SafetyLevel) bool {
        return self == .safe or self == .medium;
    }

    /// Display name for the safety level
    pub fn displayName(self: SafetyLevel) []const u8 {
        return switch (self) {
            .safe => "Safe to Clean",
            .medium => "Check First",
            .unknown => "Not Sure",
        };
    }

    /// A short name for the table's Safety column.
    pub fn shortName(self: SafetyLevel) []const u8 {
        return switch (self) {
            .safe => "Safe",
            .medium => "Check",
            .unknown => "Unknown",
        };
    }

    /// Sort order for filtering
    pub fn sortOrder(self: SafetyLevel) u8 {
        return switch (self) {
            .safe => 0,
            .medium => 1,
            .unknown => 2,
        };
    }
};

/// Safety information for a cleanup item.
pub const SafetyInfo = struct {
    level: SafetyLevel,
    headline: []const u8,
    explanation: []const u8,
    recovery_steps: []const u8,
    reinstall_command: ?[]const u8 = null,

    /// Create a safe safety info
    pub fn safe(headline: []const u8, explanation: []const u8) SafetyInfo {
        return .{
            .level = .safe,
            .headline = headline,
            .explanation = explanation,
            .recovery_steps = "The app rebuilds this cache automatically.",
            .reinstall_command = null,
        };
    }

    /// Create a check-first safety info
    pub fn checkFirst(headline: []const u8, explanation: []const u8, recovery: []const u8) SafetyInfo {
        return .{
            .level = .medium,
            .headline = headline,
            .explanation = explanation,
            .recovery_steps = recovery,
            .reinstall_command = null,
        };
    }

    /// Create an unknown safety info (should not surface)
    pub fn unknown(_: []const u8) SafetyInfo {
        return .{
            .level = .unknown,
            .headline = "Unknown",
            .explanation = "This folder's purpose is not recognized.",
            .recovery_steps = "Review the folder's contents before deletion.",
            .reinstall_command = null,
        };
    }
};

/// A path the app must never scan or delete, whatever a rule proposes.
pub const protected_prefixes = [_][]const u8{
    "/System",
    "/Library",
    "/usr",
    "/bin",
    "/sbin",
    "/etc",
    "/var",
    "/private",
    "/Applications",
    "/Volumes",
    "/cores",
    "/opt",
};

/// Folders under ~/Library/Caches that must never be offered.
///
/// CloudKit and FamilyCircle are macOS-protected. The account and identity
/// daemons are deletable, but wiping them makes accountsd/akd lose their
/// cached authorization state and re-hit the login keychain for every
/// service: the storm of "wants to use the login keychain" prompts.
pub const denied_names = [_][]const u8{
    "CloudKit",
    "FamilyCircle",
    "PassKit",
    "com.apple.accountsd",
    "com.apple.appleaccountd",
    "com.apple.amsaccountsd",
    "com.apple.akd",
    "com.apple.identityservicesd",
    "com.apple.AuthenticationServicesCore.AuthenticationServicesAgent",
    "com.apple.iCloudHelper",
    "com.apple.icloudwebd",
    "com.apple.itunescloudd",
    "com.apple.iCloudNotificationAgent",
    "com.apple.containermanagerd",
};

/// Case-insensitive fragments that mark a folder as identity, authentication
/// or payment state. Over-matching is the safe direction: the folder is
/// simply not offered, and these caches are negligible in size.
pub const denied_fragments = [_][]const u8{
    "account",
    "icloud",
    "itunescloud",
    "appleid",
    "authkit",
    "authentication",
    "authorization",
    "identityservice",
    "keychain",
    "passkit",
    "screentime",
    "1password",
    "agilebits",
    "bitwarden",
    "lastpass",
    "dashlane",
    "keepass",
    "authy",
    "yubico",
    "inputmethod",
};

/// Case-insensitive prefixes that must never be offered even though the names
/// look like ordinary app caches: system UI (deleting Finder's or the Dock's
/// cache while they run can leave panels blank until logout), and endpoint
/// security and MDM agents (touching a sensor's files can trip tamper
/// detection).
pub const denied_prefixes = [_][]const u8{
    "com.apple.finder",
    "com.apple.dock",
    "com.apple.controlcenter",
    "com.apple.systempreferences",
    "com.apple.settings",
    "com.apple.systemsettings",
    "com.apple.home",
    "com.apple.homed",
    "com.apple.homekit",
    "com.crowdstrike.",
    "com.sentinelone.",
    "com.sentinel-labs.",
    "com.eset.",
    "com.jamf.",
    "com.jamfsoftware.",
    "com.paloaltonetworks.",
    "com.cisco.anyconnect",
    "com.cisco.secureclient",
};

/// One known-safe cache folder: an exact name, or a prefix when a vendor
/// names its caches per version.
const Rule = struct {
    name: []const u8,
    prefix: bool = false,
    headline: []const u8,
    explanation: []const u8,
};

/// App and tool caches under ~/Library/Caches (and container Cache folders)
/// that are safe to remove: each one comes back on its own.
pub const safe_cache_rules = [_]Rule{
    // Browsers
    .{ .name = "com.google.Chrome", .headline = "Chrome cache", .explanation = "Chrome rebuilds it as you browse." },
    .{ .name = "Google", .headline = "Chrome cache", .explanation = "Chrome rebuilds it as you browse." },
    .{ .name = "com.apple.Safari", .headline = "Safari cache", .explanation = "Safari rebuilds it as you browse." },
    .{ .name = "com.mozilla.firefox", .headline = "Firefox cache", .explanation = "Firefox rebuilds it as you browse." },
    .{ .name = "Firefox", .headline = "Firefox cache", .explanation = "Firefox rebuilds it as you browse." },
    .{ .name = "com.microsoft.edgemac", .headline = "Edge cache", .explanation = "Edge rebuilds it as you browse." },
    .{ .name = "com.brave.Browser", .headline = "Brave cache", .explanation = "Brave rebuilds it as you browse." },
    .{ .name = "com.operasoftware.Opera", .headline = "Opera cache", .explanation = "Opera rebuilds it as you browse." },
    .{ .name = "com.vivaldi.Vivaldi", .headline = "Vivaldi cache", .explanation = "Vivaldi rebuilds it as you browse." },
    .{ .name = "com.tencent.xinWeChat", .headline = "WeChat cache", .explanation = "WeChat rebuilds it as you chat." },
    .{ .name = "com.tencent.qq", .headline = "QQ cache", .explanation = "QQ rebuilds it as you chat." },
    // Editors and app frameworks
    .{ .name = "com.microsoft.VSCode", .headline = "VS Code cache", .explanation = "VS Code rebuilds it on the next start." },
    .{ .name = "com.todesktop.", .prefix = true, .headline = "Cursor cache", .explanation = "Cursor rebuilds it on the next start." },
    .{ .name = "com.jetbrains.", .prefix = true, .headline = "JetBrains cache", .explanation = "The IDE reindexes and rebuilds it." },
    .{ .name = "com.github.GitHubClient", .headline = "GitHub Desktop cache", .explanation = "GitHub Desktop rebuilds it." },
    .{ .name = "com.apple.dt.Xcode", .headline = "Xcode cache", .explanation = "Xcode rebuilds it as you build." },
    .{ .name = "com.tinyspeck.slackmacgap", .headline = "Slack cache", .explanation = "Slack rebuilds it as you use it." },
    .{ .name = "com.hnc.Discord", .headline = "Discord cache", .explanation = "Discord rebuilds it as you use it." },
    .{ .name = "com.spotify.client", .headline = "Spotify cache", .explanation = "Spotify rebuilds it as you listen." },
    // Tool caches that live under ~/Library/Caches
    .{ .name = "Homebrew", .headline = "Homebrew cache", .explanation = "Homebrew re-downloads what it needs; `brew cleanup` does the same." },
    .{ .name = "CocoaPods", .headline = "CocoaPods cache", .explanation = "CocoaPods re-fetches pods on the next install." },
    .{ .name = "pip", .headline = "pip cache", .explanation = "pip re-downloads packages when needed." },
    .{ .name = "npm", .headline = "npm cache", .explanation = "npm re-fetches packages when needed." },
    .{ .name = "pnpm", .headline = "pnpm cache", .explanation = "pnpm re-fetches packages when needed." },
    .{ .name = "Yarn", .headline = "Yarn cache", .explanation = "Yarn re-fetches packages when needed." },
    .{ .name = "node-gyp", .headline = "node-gyp cache", .explanation = "node-gyp rebuilds what it needs." },
    .{ .name = "go-build", .headline = "Go build cache", .explanation = "Go rebuilds it on the next build." },
    .{ .name = "typescript", .headline = "TypeScript cache", .explanation = "TypeScript rebuilds it on the next check." },
    .{ .name = "ms-playwright", .headline = "Playwright browsers", .explanation = "Playwright re-installs browsers when asked." },
    .{ .name = "Cypress", .headline = "Cypress cache", .explanation = "Cypress re-downloads its binary when asked." },
    .{ .name = "Puppeteer", .headline = "Puppeteer cache", .explanation = "Puppeteer re-downloads Chromium when asked." },
    .{ .name = "electron", .headline = "Electron cache", .explanation = "Electron re-downloads its binaries when asked." },
    .{ .name = "Qt", .headline = "Qt cache", .explanation = "Qt rebuilds what it needs." },
    .{ .name = "SwiftPM", .headline = "SwiftPM cache", .explanation = "SwiftPM re-fetches packages." },
    .{ .name = "composer", .headline = "Composer cache", .explanation = "Composer re-fetches packages." },
    .{ .name = "gradle", .headline = "Gradle cache", .explanation = "Gradle re-downloads what it needs." },
    .{ .name = "maven", .headline = "Maven cache", .explanation = "Maven re-downloads what it needs." },
    .{ .name = "cargo", .headline = "Cargo cache", .explanation = "Cargo re-fetches crates." },
    .{ .name = "com.apple.pkg", .prefix = true, .headline = "Installer cache", .explanation = "macOS re-downloads installers if it needs them." },
    .{ .name = "Docker", .headline = "Docker cache", .explanation = "Docker rebuilds it as you pull and build." },
};

/// A path relative to the home folder, with what it is and how safe it is.
pub const Target = struct {
    path: []const u8,
    info: SafetyInfo,
};

/// Junk macOS piles up on its own, inside the home folder.
pub const system_junk = [_]Target{
    .{ .path = "Library/Logs", .info = SafetyInfo.checkFirst("Application logs", "Logs apps and the system write as they run, crash reports included; new ones appear on their own.", "Apps write fresh logs as they run.") },
    .{ .path = "Library/Saved Application State", .info = SafetyInfo.safe("Saved window state", "Each app's last window layout; apps reopen with their defaults.") },
    .{ .path = "Library/Developer/CoreSimulator/Caches", .info = SafetyInfo.safe("Simulator caches", "The Simulator rebuilds them the next time it runs.") },
    .{ .path = "Library/Developer/Xcode/iOS DeviceSupport", .info = SafetyInfo.checkFirst("iOS device support files", "Debug symbols for each iOS version you have connected. Xcode fetches them again the next time the device plugs in.", "Xcode downloads them again when the device next connects.") },
};

/// Global caches shared by every project on the machine.
pub const dev_caches = [_]Target{
    .{ .path = ".npm/_cacache", .info = SafetyInfo.safe("npm cache", "npm re-fetches packages when needed.") },
    .{ .path = ".yarn/cache", .info = SafetyInfo.safe("Yarn cache", "Yarn re-fetches packages when needed.") },
    .{ .path = ".pnpm-store", .info = SafetyInfo.safe("pnpm store", "pnpm re-fetches packages when needed.") },
    .{ .path = ".cache/pip", .info = SafetyInfo.safe("pip cache", "pip re-downloads packages when needed.") },
    .{ .path = ".cache/go-build", .info = SafetyInfo.safe("Go build cache", "Go rebuilds it on the next build.") },
    .{ .path = ".cache/uv", .info = SafetyInfo.safe("uv cache", "uv re-downloads packages when needed.") },
    .{ .path = ".cache/huggingface", .info = SafetyInfo.checkFirst("Hugging Face models", "Downloaded model weights; they come back the next time you download them.", "Re-download the models when you need them.") },
    .{ .path = "go/pkg/mod", .info = SafetyInfo.checkFirst("Go module cache", "Downloaded module sources; Go fetches them again on the next build.", "Go fetches the modules again on the next build.") },
    .{ .path = ".cargo/registry/cache", .info = SafetyInfo.safe("Cargo cache", "Cargo re-fetches crates when needed.") },
    .{ .path = ".gradle/caches", .info = SafetyInfo.safe("Gradle caches", "Gradle re-downloads what it needs.") },
    .{ .path = ".gradle/wrapper/dists", .info = SafetyInfo.safe("Gradle distributions", "The wrapper re-downloads the versions it needs.") },
    .{ .path = ".m2/repository", .info = SafetyInfo.checkFirst("Maven repository", "Downloaded JARs; Maven fetches them again on the next build.", "Maven re-downloads the artifacts on the next build.") },
    // Homebrew's, CocoaPods' and Playwright's caches live under
    // ~/Library/Caches, so the app-cache scan already covers them.
    .{ .path = "Library/Developer/Xcode/DerivedData", .info = SafetyInfo.safe("Xcode DerivedData", "Build products and indexes; Xcode rebuilds them as you build.") },
    .{ .path = "Library/Developer/Xcode/Archives", .info = SafetyInfo.checkFirst("Xcode archives", "Signed builds kept for upload or export; deleting them loses those builds.", "Rebuild and re-archive the app when you need it.") },
    .{ .path = "Library/Containers/com.docker.docker", .info = SafetyInfo.checkFirst("Docker Desktop data", "Images, containers and volumes. Docker Desktop starts fresh, but your containers and images go with it.", "Pull the images and rebuild the containers you need.") },
    .{ .path = ".terraform.d/plugin-cache", .info = SafetyInfo.safe("Terraform plugin cache", "Terraform re-downloads providers on the next `terraform init`.") },
};

/// One kind of folder inside a project, and what identifies the project.
pub const ProjectRule = struct {
    /// Marker files at the project root; any one of them identifies it.
    markers: []const []const u8,
    /// Marker extensions (the root is listed for these), for ecosystems with
    /// no fixed filename: `.csproj`, `.sln`, `.tf`, `.uproject`.
    marker_extensions: []const []const u8 = &.{},
    /// Folder to remove, relative to the project root. May hold a subpath.
    folder: []const u8,
    /// What brings it back, with `{root}` standing for the project folder.
    reinstall: ?[]const u8 = null,
    level: SafetyLevel = .safe,
    headline: []const u8,
    explanation: []const u8,
    /// Filenames that, found inside the folder, disqualify it: real state
    /// that happens to live beside build output.
    refuse_when_present: []const []const u8 = &.{},
};

/// The project artifacts the scan proposes. Adding an ecosystem means adding a
/// row here; a rule can only narrow what the deny lists allow, never widen it.
pub const project_rules = [_]ProjectRule{
    // JavaScript / TypeScript
    .{ .markers = &.{"package.json"}, .folder = "node_modules", .reinstall = "cd \"{root}\" && npm install", .headline = "node_modules", .explanation = "Installed dependencies; the package manager fetches them again." },
    .{ .markers = &.{"package.json"}, .folder = ".next", .reinstall = "cd \"{root}\" && npm run build", .headline = "Next.js build", .explanation = "Next.js build output; the next build recreates it." },
    .{ .markers = &.{ "nuxt.config.ts", "nuxt.config.js", "nuxt.config.mjs", "nuxt.config.cjs" }, .folder = ".nuxt", .reinstall = "cd \"{root}\" && npm run build", .headline = "Nuxt build", .explanation = "Nuxt build output; the next build recreates it." },
    .{ .markers = &.{ "nuxt.config.ts", "nuxt.config.js", "nuxt.config.mjs", "nuxt.config.cjs" }, .folder = ".output", .reinstall = "cd \"{root}\" && npm run build", .headline = "Nuxt output", .explanation = "Nuxt's built server bundle; the next build recreates it." },
    .{ .markers = &.{"package.json"}, .folder = ".svelte-kit", .reinstall = "cd \"{root}\" && npm run build", .headline = "SvelteKit build", .explanation = "SvelteKit's generated files; the next build recreates them." },
    .{ .markers = &.{"package.json"}, .folder = ".astro", .reinstall = "cd \"{root}\" && npm run build", .headline = "Astro build", .explanation = "Astro's generated files; the next build recreates them." },
    .{ .markers = &.{"package.json"}, .folder = ".angular", .reinstall = "cd \"{root}\" && npm run build", .headline = "Angular cache", .explanation = "Angular's build cache; the next build recreates it." },
    .{ .markers = &.{"package.json"}, .folder = ".turbo", .reinstall = "cd \"{root}\" && npm run build", .headline = "Turborepo cache", .explanation = "Turborepo's task cache; the next run recreates it." },
    .{ .markers = &.{"package.json"}, .folder = ".parcel-cache", .reinstall = "cd \"{root}\" && npm run build", .headline = "Parcel cache", .explanation = "Parcel's build cache; the next build recreates it." },
    .{ .markers = &.{"package.json"}, .folder = "node_modules/.vite", .reinstall = "cd \"{root}\" && npm run dev", .headline = "Vite cache", .explanation = "Vite's dependency pre-bundle; the next dev run recreates it." },
    // Rust
    .{ .markers = &.{"Cargo.toml"}, .folder = "target", .reinstall = "cd \"{root}\" && cargo build", .headline = "Cargo target", .explanation = "Rust build artifacts; the next `cargo build` recreates them." },
    // Zig
    .{ .markers = &.{"build.zig"}, .folder = "zig-out", .reinstall = "cd \"{root}\" && zig build", .headline = "zig-out", .explanation = "Zig's build output; the next `zig build` recreates it." },
    .{ .markers = &.{"build.zig"}, .folder = ".zig-cache", .reinstall = "cd \"{root}\" && zig build", .headline = "Zig cache", .explanation = "Zig's build cache; the next `zig build` recreates it." },
    // Python
    .{ .markers = &.{ "pyproject.toml", "requirements.txt" }, .folder = ".venv", .headline = "Python environment", .explanation = "A virtual environment; recreate it with your usual install command." },
    .{ .markers = &.{ "pyproject.toml", "requirements.txt" }, .folder = "venv", .headline = "Python environment", .explanation = "A virtual environment; recreate it with your usual install command." },
    .{ .markers = &.{ "pyproject.toml", "requirements.txt" }, .folder = ".pytest_cache", .headline = "pytest cache", .explanation = "Recreated the next time you run your tests." },
    .{ .markers = &.{ "pyproject.toml", "requirements.txt" }, .folder = ".mypy_cache", .headline = "mypy cache", .explanation = "Recreated the next time you run mypy." },
    .{ .markers = &.{ "pyproject.toml", "requirements.txt" }, .folder = ".ruff_cache", .headline = "ruff cache", .explanation = "Recreated the next time you run ruff." },
    // Dart / Flutter
    .{ .markers = &.{"pubspec.yaml"}, .folder = "build", .reinstall = "cd \"{root}\" && flutter pub get", .headline = "Flutter build", .explanation = "Flutter build output; the next build recreates it." },
    .{ .markers = &.{"pubspec.yaml"}, .folder = ".dart_tool", .reinstall = "cd \"{root}\" && flutter pub get", .headline = "Dart tool cache", .explanation = "Dart's package and build cache; `flutter pub get` recreates it." },
    // Android / JVM
    .{ .markers = &.{ "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts" }, .folder = "build", .reinstall = "cd \"{root}\" && ./gradlew build", .headline = "Gradle build", .explanation = "Gradle build output; the next build recreates it." },
    .{ .markers = &.{ "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts" }, .folder = ".gradle", .headline = "Gradle cache", .explanation = "Gradle's project cache; the next build recreates it." },
    .{ .markers = &.{"pom.xml"}, .folder = "target", .reinstall = "cd \"{root}\" && mvn package", .headline = "Maven target", .explanation = "Maven build output; the next build recreates it." },
    .{ .markers = &.{"build.sbt"}, .folder = "target", .reinstall = "cd \"{root}\" && sbt compile", .headline = "sbt target", .explanation = "sbt build output; the next compile recreates it." },
    .{ .markers = &.{"build.sbt"}, .folder = "project/target", .reinstall = "cd \"{root}\" && sbt compile", .headline = "sbt project target", .explanation = "sbt's meta-build output; the next compile recreates it." },
    // Xcode / CocoaPods / SwiftPM
    .{ .markers = &.{"Podfile"}, .folder = "Pods", .reinstall = "cd \"{root}\" && pod install", .headline = "CocoaPods", .explanation = "Installed pods; `pod install` fetches them again." },
    .{ .markers = &.{"ios/Podfile"}, .folder = "ios/Pods", .reinstall = "cd \"{root}/ios\" && pod install", .headline = "CocoaPods", .explanation = "Installed pods; `pod install` fetches them again." },
    .{ .markers = &.{"Package.swift"}, .folder = ".build", .reinstall = "cd \"{root}\" && swift build", .headline = "SwiftPM build", .explanation = "SwiftPM's build output; the next build recreates it." },
    // Elixir
    .{ .markers = &.{"mix.exs"}, .folder = "_build", .reinstall = "cd \"{root}\" && mix compile", .headline = "Elixir build", .explanation = "Compiled Elixir output; the next compile recreates it." },
    .{ .markers = &.{"mix.exs"}, .folder = "deps", .reinstall = "cd \"{root}\" && mix deps.get", .headline = "Elixir deps", .explanation = "Fetched dependencies; `mix deps.get` fetches them again." },
    // PHP / Ruby
    .{ .markers = &.{"composer.json"}, .folder = "vendor", .reinstall = "cd \"{root}\" && composer install", .headline = "Composer vendor", .explanation = "Installed packages; `composer install` fetches them again." },
    .{ .markers = &.{"Gemfile"}, .folder = "vendor/bundle", .reinstall = "cd \"{root}\" && bundle install", .headline = "Bundler gems", .explanation = "Installed gems; `bundle install` fetches them again." },
    // .NET
    .{ .markers = &.{}, .marker_extensions = &.{ "csproj", "fsproj", "vbproj", "sln" }, .folder = "bin", .reinstall = "cd \"{root}\" && dotnet build", .headline = ".NET bin", .explanation = ".NET build output; the next build recreates it." },
    .{ .markers = &.{}, .marker_extensions = &.{ "csproj", "fsproj", "vbproj", "sln" }, .folder = "obj", .reinstall = "cd \"{root}\" && dotnet build", .headline = ".NET obj", .explanation = ".NET's intermediate output; the next build recreates it." },
    // Haskell / OCaml / CMake
    .{ .markers = &.{"stack.yaml"}, .folder = ".stack-work", .reinstall = "cd \"{root}\" && stack build", .headline = "Stack work", .explanation = "Stack's build output; the next build recreates it." },
    .{ .markers = &.{}, .marker_extensions = &.{"cabal"}, .folder = "dist-newstyle", .reinstall = "cd \"{root}\" && cabal build", .headline = "Cabal build", .explanation = "Cabal's build output; the next build recreates it." },
    .{ .markers = &.{"dune-project"}, .folder = "_build", .reinstall = "cd \"{root}\" && dune build", .headline = "Dune build", .explanation = "Dune's build output; the next build recreates it." },
    .{ .markers = &.{"CMakeLists.txt"}, .folder = "build", .headline = "CMake build", .explanation = "CMake's build tree; re-run your configure and build steps." },
    // Infrastructure and engines
    .{ .markers = &.{}, .marker_extensions = &.{"tf"}, .folder = ".terraform", .reinstall = "cd \"{root}\" && terraform init", .level = .medium, .headline = "Terraform plugins", .explanation = "Downloaded providers and modules; `terraform init` fetches them again.", .refuse_when_present = &.{ "terraform.tfstate", "terraform.tfstate.backup", "environment" } },
    .{ .markers = &.{"project.godot"}, .folder = ".godot", .headline = "Godot cache", .explanation = "Rebuilt the next time you open the project in Godot." },
    .{ .markers = &.{"ProjectSettings/ProjectVersion.txt"}, .folder = "Library", .level = .medium, .headline = "Unity Library", .explanation = "Unity reimports the project the next time you open it; on a large project this can take a long time." },
    .{ .markers = &.{"ProjectSettings/ProjectVersion.txt"}, .folder = "Temp", .level = .medium, .headline = "Unity Temp", .explanation = "Recreated the next time you open the project in Unity." },
    .{ .markers = &.{}, .marker_extensions = &.{"uproject"}, .folder = "Intermediate", .level = .medium, .headline = "Unreal Intermediate", .explanation = "Regenerated the next time you build the project in Unreal." },
    .{ .markers = &.{}, .marker_extensions = &.{"uproject"}, .folder = "DerivedDataCache", .level = .medium, .headline = "Unreal derived data", .explanation = "Unreal rebuilds this cache on the next build, including shader compilation." },
};

/// Whether `haystack` contains `needle`, ignoring case.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Whether a folder name is on a deny list: an exact name, a fragment, or a
/// prefix. Case-insensitive, as macOS file names are.
pub fn isDeniedName(name: []const u8) bool {
    for (denied_names) |n| {
        if (std.ascii.eqlIgnoreCase(name, n)) return true;
    }
    for (denied_fragments) |f| {
        if (containsIgnoreCase(name, f)) return true;
    }
    for (denied_prefixes) |p| {
        if (std.ascii.startsWithIgnoreCase(name, p)) return true;
    }
    return false;
}

/// Whether a path is protected (never scanned, never deleted).
pub fn isProtectedPath(path: []const u8) bool {
    for (protected_prefixes) |p| {
        if (std.mem.startsWith(u8, path, p)) return true;
    }
    return false;
}

/// Classify a folder found under ~/Library/Caches (or an app's container).
/// A cache folder is, by definition, rebuildable: a name on the safe list is
/// `.safe`, anything else is `.medium` unless a deny rule refuses it.
pub fn classifyCacheFolder(name: []const u8) SafetyInfo {
    if (isDeniedName(name)) return SafetyInfo.unknown(name);
    for (safe_cache_rules) |r| {
        const hit = if (r.prefix) std.ascii.startsWithIgnoreCase(name, r.name) else std.ascii.eqlIgnoreCase(name, r.name);
        if (hit) return SafetyInfo.safe(r.headline, r.explanation);
    }
    return SafetyInfo.checkFirst(
        "App cache",
        "A cache folder an app keeps. The app rebuilds it the next time it needs it.",
        "The app recreates the cache on its own.",
    );
}

/// Folder names inside an app's Application Support directory that hold a
/// cache rather than the app's real data. Only these are offered: the rest of
/// Application Support is data, and deleting it is not a cleanup.
pub const app_support_cache_children = [_][]const u8{
    "Cache",
    "CacheStorage",
    "CachedData",
    "CachedDataBackup",
    "CachedExtensions",
    "CachedExtensionVSIXs",
    "Code Cache",
    "GPUCache",
    "DawnGraphiteCache",
    "DawnWebGPUCache",
    "ShaderCache",
    "GrShaderCache",
    "Service Worker",
    "blob_storage",
    "Crashpad",
};

/// Classify a child of ~/Library/Application Support: a known cache folder is
/// `.medium` (the app regenerates it, but it is data rather than a cache
/// directory), anything else is `.unknown` and is not offered.
pub fn classifyAppSupportChild(name: []const u8) SafetyInfo {
    for (app_support_cache_children) |c| {
        if (std.ascii.eqlIgnoreCase(name, c)) {
            return SafetyInfo.checkFirst(
                "App cache",
                "A cache folder inside the app's data; the app rebuilds it when it next needs it.",
                "The app recreates the cache on its own.",
            );
        }
    }
    return SafetyInfo.unknown(name);
}

/// Safety policy for determining what can be cleaned. All deletions must go
/// through this policy. The catalogs above are static, so this holds no state
/// of its own beyond the allocator it was created with.
pub const SafetyPolicy = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SafetyPolicy {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *SafetyPolicy) void {}

    /// Check if a path is protected (should never be scanned or deleted)
    pub fn isProtected(_: *const SafetyPolicy, path: []const u8) bool {
        return isProtectedPath(path);
    }

    /// Determine safety level for a cache folder
    pub fn safetyForCacheFolder(_: *const SafetyPolicy, folder_name: []const u8, _: []const u8) SafetyInfo {
        return classifyCacheFolder(folder_name);
    }

    /// Check if an item can be offered for cleanup
    pub fn isOfferedForCleanup(_: *const SafetyPolicy, path: []const u8) bool {
        return !isProtectedPath(path);
    }
};

test "SafetyLevel display names" {
    try std.testing.expectEqualStrings("Safe to Clean", SafetyLevel.safe.displayName());
    try std.testing.expectEqualStrings("Check First", SafetyLevel.medium.displayName());
    try std.testing.expectEqualStrings("Not Sure", SafetyLevel.unknown.displayName());
}

test "SafetyLevel can surface" {
    try std.testing.expect(SafetyLevel.safe.canSurfaceInScanResults());
    try std.testing.expect(SafetyLevel.medium.canSurfaceInScanResults());
    try std.testing.expect(!SafetyLevel.unknown.canSurfaceInScanResults());
}

test "SafetyLevel sort order" {
    try std.testing.expect(@as(u8, 0) == SafetyLevel.safe.sortOrder());
    try std.testing.expect(@as(u8, 1) == SafetyLevel.medium.sortOrder());
    try std.testing.expect(@as(u8, 2) == SafetyLevel.unknown.sortOrder());
}

test "protected paths" {
    var policy = SafetyPolicy.init(std.testing.allocator);
    defer policy.deinit();

    try std.testing.expect(policy.isProtected("/System/Library"));
    try std.testing.expect(policy.isProtected("/Library/Caches"));
    try std.testing.expect(policy.isProtected("/private/var/log"));
    try std.testing.expect(!policy.isProtected("/Users/test/Library/Caches"));
    try std.testing.expect(!policy.isProtected("/Users/test/project/node_modules"));
}

test "known safe caches classify as safe" {
    try std.testing.expectEqual(SafetyLevel.safe, classifyCacheFolder("com.google.Chrome").level);
    try std.testing.expectEqual(SafetyLevel.safe, classifyCacheFolder("Homebrew").level);
    try std.testing.expectEqualStrings("Chrome cache", classifyCacheFolder("com.google.Chrome").headline);
    // A prefix rule, for vendors that version their cache folders.
    try std.testing.expectEqual(SafetyLevel.safe, classifyCacheFolder("com.jetbrains.intellij.ce").level);
}

test "an unknown app cache is Check First, not Unknown" {
    const info = classifyCacheFolder("com.example.someapp");
    try std.testing.expectEqual(SafetyLevel.medium, info.level);
    try std.testing.expect(info.level.canSurfaceInScanResults());
}

test "identity and keychain caches are denied" {
    for ([_][]const u8{
        "CloudKit",
        "FamilyCircle",
        "PassKit",
        "com.apple.akd",
        "com.apple.identityservicesd",
        "com.1password.1password",
        "com.bitwarden.desktop",
        "com.agilebits.onepassword",
        "com.apple.ScreenTimeAgent",
        "com.apple.containermanagerd",
        "com.apple.imkinputmethod",
    }) |name| {
        try std.testing.expectEqual(SafetyLevel.unknown, classifyCacheFolder(name).level);
        try std.testing.expect(!classifyCacheFolder(name).level.canSurfaceInScanResults());
    }
}

test "system UI and endpoint security caches are denied" {
    for ([_][]const u8{
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.systempreferences",
        "com.crowdstrike.falcon",
        "com.sentinelone.agent",
        "com.jamf.management",
        "com.paloaltonetworks.globalprotect",
        "com.cisco.secureclient",
    }) |name| {
        try std.testing.expectEqual(SafetyLevel.unknown, classifyCacheFolder(name).level);
    }
}

test "Application Support offers only cache children" {
    try std.testing.expectEqual(SafetyLevel.medium, classifyAppSupportChild("Cache").level);
    try std.testing.expectEqual(SafetyLevel.medium, classifyAppSupportChild("Code Cache").level);
    try std.testing.expectEqual(SafetyLevel.medium, classifyAppSupportChild("GPUCache").level);
    try std.testing.expectEqual(SafetyLevel.unknown, classifyAppSupportChild("Bookmarks").level);
    try std.testing.expectEqual(SafetyLevel.unknown, classifyAppSupportChild("Local Storage").level);
}

test "deny matching ignores case" {
    try std.testing.expect(isDeniedName("COM.APPLE.AKD"));
    try std.testing.expect(isDeniedName("cloudkit"));
    try std.testing.expect(!isDeniedName("com.example.notepad"));
}
