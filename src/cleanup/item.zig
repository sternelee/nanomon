//! Cache item model for cleanup results.

const std = @import("std");
const safety_mod = @import("safety.zig");
const SafetyInfo = safety_mod.SafetyInfo;
const SafetyLevel = safety_mod.SafetyLevel;

/// The Cleanup sidebar's tabs: what each part of the page is for.
pub const Tab = enum {
    /// Not a tab of the sidebar: the read-only rows the disk map measures,
    /// which the Overview page shows beside the machine's own tiles.
    overview,
    caches,
    dev,
    cli,
    large,
    uninstall,

    pub fn title(self: Tab) []const u8 {
        return switch (self) {
            .overview => "Overview",
            .caches => "App Caches",
            .dev => "Dev Tools",
            .cli => "CLI Tools",
            .large => "Large Files",
            .uninstall => "App Uninstaller",
        };
    }

    pub fn icon(self: Tab) []const u8 {
        return switch (self) {
            .overview => "chart.bar.xaxis",
            .caches => "internaldrive",
            .dev => "chevron.left.forwardslash.chevron.right",
            .cli => "terminal",
            .large => "doc",
            .uninstall => "xmark.square",
        };
    }

    /// What the tab is about, under the title.
    pub fn subtitle(self: Tab) []const u8 {
        return switch (self) {
            .overview => "Where the space went, read-only",
            .caches => "Caches, logs and the junk apps leave behind",
            .dev => "Tool caches and the build folders inside projects",
            .cli => "The tools you installed, and their newer versions",
            .large => "The biggest files in your folders",
            .uninstall => "An app, and everything it left in your Library",
        };
    }
};

/// How something is removed. Almost everything goes to the Trash; the few
/// things only their own tool can take away go through that tool, and a
/// read-only row is never removed at all.
pub const Removal = enum {
    /// Move to the Trash, where it can be put back.
    trash,
    /// `xcrun simctl runtime delete <target>`
    simctl_runtime,
    /// `xcrun simctl delete <target>`
    simctl_device,
    /// `xcodebuild -deleteComponent <target>`
    xcode_component,
    /// `brew uninstall <target>`
    brew_formula,
    /// `brew uninstall --cask <target>`
    brew_cask,
    /// `npm uninstall -g <target>`
    npm_global,
    /// `pnpm remove -g <target>`
    pnpm_global,
    /// `bun remove -g <target>`
    bun_global,
    /// `pipx uninstall <target>`
    pipx_venv,
    /// `cargo uninstall <target>`
    cargo_install,
    /// `tmutil deletelocalsnapshots <target>`
    tm_snapshot,
    /// Read-only: nothing here removes this, it is only measured.
    none,

    /// Whether the page may offer to remove it.
    pub fn removable(self: Removal) bool {
        return self != .none;
    }

    /// Whether removing it goes through the Trash (and so can be undone).
    pub fn trashed(self: Removal) bool {
        return self == .trash;
    }

    /// The word the sheet and the footer use.
    pub fn verb(self: Removal) []const u8 {
        return switch (self) {
            .trash => "Move to Trash",
            .simctl_runtime, .simctl_device => "Delete",
            .xcode_component => "Remove",
            .brew_formula, .brew_cask => "Uninstall",
            .npm_global, .pnpm_global, .bun_global, .pipx_venv, .cargo_install => "Uninstall",
            .tm_snapshot => "Delete",
            .none => "Keep",
        };
    }
};

/// How a command-line tool is updated: the manager that installed it knows,
/// and each one is asked for the newest version it offers.
pub const Update = enum {
    /// `brew upgrade <target>`
    brew_upgrade,
    /// `npm install -g <target>@latest`
    npm_latest,
    /// `pnpm update -g --latest <target>`
    pnpm_latest,
    /// `bun update -g --latest <target>`
    bun_latest,
    /// `pipx upgrade <target>`
    pipx_upgrade,
    /// `cargo install <target>`
    cargo_install,

    /// The word the sheet and the footer use.
    pub fn verb(self: Update) []const u8 {
        _ = self;
        return "Update";
    }
};

/// Where a scanned item came from: what the Cleanup page groups by.
pub const Category = enum {
    /// An app's own cache, under ~/Library/Caches or an app's Cache folder.
    cache,
    /// System junk: logs, crash reports, saved window state.
    junk,
    /// A tool's global cache, shared by every project (npm, Xcode, Homebrew).
    dev,
    /// A folder inside one project, rebuildable from that project.
    project,
    /// A large file of the user's own, in their folders.
    large,
    /// An installed app, with what it left in the Library.
    app,
    /// A command-line tool a package manager installed, or one that was
    /// simply downloaded into a folder of the user's.
    cli,
    /// A simulator runtime or a simulator device.
    simulator,
    /// An Xcode component that can be downloaded again.
    xcode,
    /// Something read-only on the overview: a folder, or a whole category.
    other,

    pub fn title(self: Category) []const u8 {
        return switch (self) {
            .cache => "App Cache",
            .junk => "System Junk",
            .dev => "Dev Cache",
            .project => "Project",
            .large => "File",
            .app => "App",
            .cli => "CLI Tool",
            .simulator => "Simulator",
            .xcode => "Xcode",
            .other => "Folder",
        };
    }

    /// Which tab of the Cleanup page this belongs to.
    pub fn tab(self: Category) Tab {
        return switch (self) {
            .cache, .junk => .caches,
            .dev, .project, .simulator, .xcode => .dev,
            .cli => .cli,
            .large => .large,
            .app => .uninstall,
            .other => .overview,
        };
    }
};

/// Where a pass's rows go the moment they are made, so a long pass fills the
/// page in while it runs: the scanner measures what it is handed, drops what
/// is not worth a row, and passes the rest on. A scan with no sink (a test's)
/// keeps its rows and measures them once the pass is done.
pub const Batch = struct {
    ctx: *anyopaque,
    /// Take these items; the caller must not keep them, and must not free them
    /// either: they belong to the scanner now.
    give: *const fn (ctx: *anyopaque, category: Category, items: *std.ArrayListUnmanaged(*CacheItem)) void,
};

/// A single location within a cache item (multiple locations can be merged)
pub const CacheLocation = struct {
    path: []const u8,
    size_bytes: u64,
    last_modified: i64, // Unix timestamp
    folder_name: []const u8,
    /// True when the size walk stopped at its limit: the size is a floor.
    approx: bool = false,
    /// True for an app bundle itself, which lives where apps live and so
    /// needs the app rule when it is moved, not the strict one.
    app_bundle: bool = false,
};

/// A cache item that can be cleaned.
pub const CacheItem = struct {
    /// Unique identifier for this item
    id: []const u8,
    /// Canonical definition key (for explanations)
    definition_key: ?[]const u8,
    /// Locations that make up this item (multiple paths merged)
    locations: std.ArrayListUnmanaged(CacheLocation),
    /// App/folder name
    app_name: []const u8,
    /// Whether this item is selected for cleanup
    selected: bool,
    /// Safety information
    safety_info: SafetyInfo,
    /// Which part of the disk this came from.
    category: Category = .cache,
    /// How it is removed, and what that removal is aimed at (an identifier,
    /// a component name, a snapshot date). `.trash` needs no target.
    removal: Removal = .trash,
    removal_target: ?[]const u8 = null,
    /// How a command-line tool is updated, and what that update aims at.
    /// `null` for everything that is not a tool a manager installed.
    update: ?Update = null,
    /// What is installed, for the Version column.
    installed_version: ?[]const u8 = null,
    /// The version its own update command would install, when there is a
    /// newer one. `null` when the tool is up to date, or nothing knows.
    latest_version: ?[]const u8 = null,
    /// False for something whose size cannot be measured (a Time Machine
    /// snapshot): the page shows a dash rather than a made-up number.
    measured: bool = true,
    /// True when the size in the location is already right, so the scan need
    /// not walk the folder again.
    sized: bool = false,

    allocator: std.mem.Allocator,

    /// Total size across all locations
    pub fn sizeBytes(self: *const CacheItem) u64 {
        var total: u64 = 0;
        for (self.locations.items) |loc| {
            total += loc.size_bytes;
        }
        return total;
    }

    /// Whether its manager offers a newer version.
    pub fn outdated(self: *const CacheItem) bool {
        return self.latest_version != null;
    }

    /// Most recent last modified time
    pub fn lastModified(self: *const CacheItem) i64 {
        var latest: i64 = 0;
        for (self.locations.items) |loc| {
            if (loc.last_modified > latest) latest = loc.last_modified;
        }
        return latest;
    }

    /// Primary path (first location)
    pub fn primaryPath(self: *const CacheItem) []const u8 {
        if (self.locations.items.len == 0) return "";
        return self.locations.items[0].path;
    }

    /// Whether any location's size is a floor rather than the whole folder.
    pub fn approx(self: *const CacheItem) bool {
        for (self.locations.items) |loc| {
            if (loc.approx) return true;
        }
        return false;
    }

    /// What the Kind column says: a cache folder is named by where it came
    /// from, everything else by what it is ("Video", "Simulator runtime",
    /// "Time Machine snapshot", "Application").
    pub fn kind(self: *const CacheItem) []const u8 {
        return switch (self.category) {
            .cache => self.category.title(),
            else => self.safety_info.headline,
        };
    }

    /// What the Where column says: the folder the first location named — for
    /// a command-line tool, the manager that installed it.
    pub fn where(self: *const CacheItem) []const u8 {
        if (self.locations.items.len == 0) return "";
        return self.locations.items[0].folder_name;
    }

    /// Format size as human-readable string
    pub fn formatSize(self: *const CacheItem, buffer: []u8) []const u8 {
        const size = self.sizeBytes();
        return formatBytes(size, buffer);
    }

    /// Initialize a new cache item
    pub fn init(allocator: std.mem.Allocator, id: []const u8, app_name: []const u8, safety_info: SafetyInfo) !CacheItem {
        const id_copy = try allocator.dupe(u8, id);
        errdefer allocator.free(id_copy);
        const name_copy = try allocator.dupe(u8, app_name);
        errdefer allocator.free(name_copy);
        // The safety words are the item's own: some callers build them (a
        // Homebrew row names its cask), so the item frees them either way.
        const headline = try allocator.dupe(u8, safety_info.headline);
        errdefer allocator.free(headline);
        const explanation = try allocator.dupe(u8, safety_info.explanation);
        errdefer allocator.free(explanation);
        const recovery = try allocator.dupe(u8, safety_info.recovery_steps);
        errdefer allocator.free(recovery);
        const reinstall = if (safety_info.reinstall_command) |command| try allocator.dupe(u8, command) else null;
        return .{
            .id = id_copy,
            .definition_key = null,
            .locations = .empty,
            .app_name = name_copy,
            .selected = false,
            .safety_info = .{
                .level = safety_info.level,
                .headline = headline,
                .explanation = explanation,
                .recovery_steps = recovery,
                .reinstall_command = reinstall,
            },
            .allocator = allocator,
        };
    }

    /// Add a location to this item
    pub fn addLocation(self: *CacheItem, path: []const u8, size_bytes: u64, last_modified: i64, folder_name: []const u8) !void {
        return self.addLocationSized(path, size_bytes, last_modified, folder_name, false);
    }

    /// Add a location, saying whether its size is exact.
    pub fn addLocationSized(self: *CacheItem, path: []const u8, size_bytes: u64, last_modified: i64, folder_name: []const u8, is_floor: bool) !void {
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);
        const folder_copy = try self.allocator.dupe(u8, folder_name);
        errdefer self.allocator.free(folder_copy);
        const loc = CacheLocation{
            .path = path_copy,
            .size_bytes = size_bytes,
            .last_modified = last_modified,
            .folder_name = folder_copy,
            .approx = is_floor,
        };
        try self.locations.append(self.allocator, loc);
    }

    /// Say how this item is removed, and what the removal aims at.
    pub fn setRemoval(self: *CacheItem, removal: Removal, target: ?[]const u8) !void {
        if (self.removal_target) |old| self.allocator.free(old);
        self.removal_target = if (target) |value| try self.allocator.dupe(u8, value) else null;
        self.removal = removal;
    }

    /// Say how this item is updated, what is installed, and what its manager
    /// would install instead (`null` when there is nothing newer).
    pub fn setUpdate(self: *CacheItem, update: ?Update, installed: ?[]const u8, latest: ?[]const u8) !void {
        const installed_copy = if (installed) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (installed_copy) |copy| self.allocator.free(copy);
        const latest_copy = if (latest) |value| try self.allocator.dupe(u8, value) else null;
        if (self.installed_version) |old| self.allocator.free(old);
        if (self.latest_version) |old| self.allocator.free(old);
        self.update = update;
        self.installed_version = installed_copy;
        self.latest_version = latest_copy;
    }

    /// What the page needs to build a row.
    pub const Spec = struct {
        id: []const u8,
        name: []const u8,
        info: SafetyInfo,
        category: Category,
        path: []const u8,
        where: []const u8 = "",
        size: u64 = 0,
        /// True when `size` is already known, so the scan need not measure it.
        sized: bool = false,
        /// True when nothing can know the size (a Time Machine snapshot):
        /// the page shows a dash instead.
        unknown_size: bool = false,
        removal: Removal = .trash,
        target: ?[]const u8 = null,
        update: ?Update = null,
        installed_version: ?[]const u8 = null,
        latest_version: ?[]const u8 = null,
    };

    /// Build an item with one location. The caller owns the result.
    pub fn create(allocator: std.mem.Allocator, spec: Spec) !*CacheItem {
        const item = try allocator.create(CacheItem);
        errdefer allocator.destroy(item);
        item.* = try CacheItem.init(allocator, spec.id, spec.name, spec.info);
        errdefer item.deinit();
        item.category = spec.category;
        item.measured = !spec.unknown_size;
        item.sized = spec.sized;
        try item.addLocationSized(spec.path, spec.size, 0, spec.where, false);
        try item.setRemoval(spec.removal, spec.target);
        try item.setUpdate(spec.update, spec.installed_version, spec.latest_version);
        return item;
    }

    /// Deallocate resources
    pub fn deinit(self: *CacheItem) void {
        for (self.locations.items) |*loc| {
            self.allocator.free(loc.path);
            self.allocator.free(loc.folder_name);
        }
        self.locations.deinit(self.allocator);
        if (self.definition_key) |key| {
            self.allocator.free(key);
        }
        if (self.removal_target) |target| {
            self.allocator.free(target);
        }
        if (self.installed_version) |version| {
            self.allocator.free(version);
        }
        if (self.latest_version) |version| {
            self.allocator.free(version);
        }
        self.allocator.free(self.safety_info.headline);
        self.allocator.free(self.safety_info.explanation);
        self.allocator.free(self.safety_info.recovery_steps);
        if (self.safety_info.reinstall_command) |command| self.allocator.free(command);
        self.allocator.free(self.id);
        self.allocator.free(self.app_name);
    }
};

/// Format bytes as human-readable string (e.g., "1.2 GB")
pub fn formatBytes(bytes: u64, buffer: []u8) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value: f64 = @floatFromInt(bytes);
    var unit_index: usize = 0;

    while (value >= 1024 and unit_index < units.len - 1) {
        value /= 1024;
        unit_index += 1;
    }

    if (unit_index == 0) {
        return std.fmt.bufPrint(buffer, "{d} {s}", .{ @as(u64, @intFromFloat(value)), units[unit_index] }) catch "Unknown";
    } else {
        return std.fmt.bufPrint(buffer, "{d:.1} {s}", .{ value, units[unit_index] }) catch "Unknown";
    }
}

test "formatBytes" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", formatBytes(0, &buffer));
    try std.testing.expectEqualStrings("512 B", formatBytes(512, &buffer));
    try std.testing.expectEqualStrings("1.0 KB", formatBytes(1024, &buffer));
    try std.testing.expectEqualStrings("1.5 MB", formatBytes(1572864, &buffer));
    try std.testing.expectEqualStrings("1.0 GB", formatBytes(1073741824, &buffer));
}

test "CacheItem size calculation" {
    var item = try CacheItem.init(std.testing.allocator, "test-id", "TestApp", SafetyInfo.safe("Test", "Test cache"));
    defer item.deinit();

    try item.addLocation("/path1", 1024, 1000, "folder1");
    try item.addLocation("/path2", 2048, 2000, "folder2");

    try std.testing.expectEqual(@as(u64, 3072), item.sizeBytes());
}

test "CacheItem last modified" {
    var item = try CacheItem.init(std.testing.allocator, "test-id", "TestApp", SafetyInfo.safe("Test", "Test cache"));
    defer item.deinit();

    try item.addLocation("/path1", 1024, 1000, "folder1");
    try item.addLocation("/path2", 2048, 2000, "folder2");

    try std.testing.expectEqual(@as(i64, 2000), item.lastModified());
}
