//! The Cleanup scan: app caches, the junk macOS piles up, the caches tools
//! keep for every project, and the rebuildable folders inside projects.
//!
//! The whole scan runs on a worker thread (app.zig owns it), so nothing here
//! may touch the window. Every walk is bounded: how large a folder's size walk
//! may get, how deep the project search goes, and how many folders it may
//! visit, so a scan always ends in a sensible time.
const std = @import("std");
const item_mod = @import("item.zig");
const CacheItem = item_mod.CacheItem;
const Category = item_mod.Category;
const safety = @import("safety.zig");
const SafetyPolicy = safety.SafetyPolicy;
const SafetyInfo = safety.SafetyInfo;
const measure = @import("measure.zig");
const large = @import("large.zig");
const apps = @import("apps.zig");
const simulators = @import("simulators.zig");
const xcode = @import("xcode.zig");
const brew = @import("brew.zig");
const cli = @import("cli.zig");
const snapshots = @import("snapshots.zig");
const diskmap = @import("diskmap.zig");

const builtin = @import("builtin");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// How many rows pile up before a pass hands them over: small enough that the
/// page moves while a long pass runs, large enough to keep the measuring
/// threads busy.
const stream_batch: usize = 16;

pub const CacheScanner = struct {
    allocator: std.mem.Allocator,
    policy: SafetyPolicy,
    home_dir: []const u8,
    io: std.Io,
    /// Where a pass's rows go as it finds them. Null: the pass keeps them and
    /// the caller owns them (a test's scan, which wants one list at the end).
    sink: ?*const fn (ctx: *anyopaque, item: *CacheItem) void = null,
    sink_ctx: ?*anyopaque = null,
    /// App caches under this size are noise on the page, not space to win back.
    min_bytes: u64 = 1 << 20,
    /// A defensive cap on how many items one scan may produce.
    max_items: usize = 4000,
    /// Bound size walks so one folder cannot stall a scan.
    max_files_for_dir_size: usize = 20000,
    /// How deep the project search may descend below the home folder.
    max_project_depth: usize = 6,
    /// How many folders the project search may visit.
    max_dirs_visited: usize = 12000,
    /// How many project artifacts the search may propose.
    max_project_items: usize = 400,
    /// A file has to be at least this big to be offered as a large file.
    min_large_bytes: u64 = 100 << 20,
    max_large_items: usize = 200,
    /// Where the installed apps live. The tests point this at their own
    /// folder; the app uses the real ones.
    apps_roots: []const []const u8 = &.{ "/Applications", "Applications" },
    max_apps: usize = 400,
    /// How many of each of the tool-found things to keep, biggest first.
    max_simulators: usize = 80,
    max_casks: usize = 120,
    /// How many command-line tools one manager may contribute. A tool is a
    /// row whether or not it is big, so they are not trimmed to the biggest.
    max_tools: usize = 400,
    max_snapshots: usize = 40,
    /// The overview's folders are huge: a smaller bound is enough to say
    /// where the space went.
    disk_map_files: usize = 12000,
    /// Where the disk's figures land for the overview, once a scan has run.
    volume: ?*diskmap.Volume = null,
    /// Whether the passes that ask the machine itself (simctl, xcodebuild,
    /// brew, tmutil, df) may run. The tests scan a home of their own and set
    /// this false, so a test never reads — or offers — the real machine's
    /// things.
    machine: bool = true,
    /// Set by the app when it is going away. The scan stops at its next
    /// check, so quitting never waits for a whole project walk.
    cancel: ?*const std.atomic.Value(bool) = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !CacheScanner {
        const home = if (comptime builtin.os.tag == .windows)
            if (getenv("USERPROFILE")) |p| std.mem.span(p) else return error.HomeNotFound
        else if (getenv("HOME")) |p| std.mem.span(p) else return error.HomeNotFound;
        var scanner = try initAt(allocator, io, home);
        // The real machine: its Applications, and the passes that ask its
        // tools (simctl, xcodebuild, brew, tmutil, df).
        scanner.apps_roots = &.{ "/Applications", "Applications" };
        scanner.machine = true;
        return scanner;
    }

    /// Scan a given home folder: how the tests drive a scan of their own tree.
    /// Everything it looks at lives inside that folder, so a test can never
    /// read (or offer) anything of the real machine's.
    pub fn initAt(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !CacheScanner {
        return .{
            .allocator = allocator,
            .policy = SafetyPolicy.init(allocator),
            .home_dir = home,
            .io = io,
            .apps_roots = &.{"Applications"},
            .machine = false,
        };
    }

    pub fn deinit(self: *CacheScanner) void {
        self.policy.deinit();
    }

    fn cancelled(self: *CacheScanner) bool {
        return if (self.cancel) |flag| flag.load(.acquire) else false;
    }

    /// Every part of the scan, in one list.
    pub fn scanAll(self: *CacheScanner) !std.ArrayListUnmanaged(*CacheItem) {
        var items = std.ArrayListUnmanaged(*CacheItem).empty;
        errdefer self.discard(&items);
        const passes = [_]*const fn (*CacheScanner) anyerror!std.ArrayListUnmanaged(*CacheItem){
            scanLibraryCaches,
            scanApplicationSupport,
            scanSystemJunk,
            scanDevCaches,
            scanLarge,
            scanApps,
            scanProjects,
            scanSimulators,
            scanXcodeComponents,
            scanBrewCasks,
            scanCliTools,
            scanSnapshots,
            scanDiskMap,
        };
        for (passes) |pass| {
            var found = try pass(self);
            defer found.deinit(self.allocator);
            for (found.items) |item| {
                items.append(self.allocator, item) catch {
                    item.deinit();
                    self.allocator.destroy(item);
                };
            }
        }
        return items;
    }

    /// Scan ~/Library/Caches: one item per app's cache folder.
    pub fn scanLibraryCaches(self: *CacheScanner) !std.ArrayListUnmanaged(*CacheItem) {
        var items = std.ArrayListUnmanaged(*CacheItem).empty;
        errdefer self.discard(&items);

        const caches = try std.fs.path.join(self.allocator, &.{ self.home_dir, "Library", "Caches" });
        defer self.allocator.free(caches);

        var dir = std.Io.Dir.cwd().openDir(self.io, caches, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return items;
            return err;
        };
        defer dir.close(self.io);

        var it = dir.iterate();
        var found: usize = 0;
        while (try it.next(self.io)) |entry| {
            if (self.cancelled()) break;
            if (entry.kind != .directory) continue;
            if (found >= self.max_items) break;
            const info = safety.classifyCacheFolder(entry.name);
            if (!info.level.canSurfaceInScanResults()) continue;
            const full = try std.fs.path.join(self.allocator, &.{ caches, entry.name });
            defer self.allocator.free(full);
            const before = items.items.len;
            try self.addUnmeasured(&items, .cache, full, entry.name, "Caches", info);
            if (items.items.len > before) {
                found += 1;
                self.streamBatch(&items, .cache);
            }
        }
        self.finish(&items, .cache, 0);
        return items;
    }

    /// Scan ~/Library/Application Support: only the cache folders inside each
    /// app's data, never the data itself.
    pub fn scanApplicationSupport(self: *CacheScanner) !std.ArrayListUnmanaged(*CacheItem) {
        var items = std.ArrayListUnmanaged(*CacheItem).empty;
        errdefer self.discard(&items);

        const support = try std.fs.path.join(self.allocator, &.{ self.home_dir, "Library", "Application Support" });
        defer self.allocator.free(support);

        var dir = std.Io.Dir.cwd().openDir(self.io, support, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return items;
            return err;
        };
        defer dir.close(self.io);

        // Chromium and Electron keep their cache one level deeper, beside the
        // profile rather than the app.
        const containers = [_][]const u8{ "", "Default", "User Data", "Profile 1" };

        var it = dir.iterate();
        var found: usize = 0;
        while (try it.next(self.io)) |app| {
            if (self.cancelled()) break;
            if (app.kind != .directory) continue;
            if (found >= self.max_items) break;
            const app_path = try std.fs.path.join(self.allocator, &.{ support, app.name });
            defer self.allocator.free(app_path);

            for (containers) |container| {
                const base = if (container.len == 0)
                    try self.allocator.dupe(u8, app_path)
                else
                    try std.fs.path.join(self.allocator, &.{ app_path, container });
                defer self.allocator.free(base);

                var inner = std.Io.Dir.cwd().openDir(self.io, base, .{ .iterate = true }) catch continue;
                defer inner.close(self.io);
                var kids = inner.iterate();
                while (try kids.next(self.io)) |kid| {
                    if (self.cancelled()) break;
                    if (kid.kind != .directory) continue;
                    if (found >= self.max_items) break;
                    const info = safety.classifyAppSupportChild(kid.name);
                    if (!info.level.canSurfaceInScanResults()) continue;
                    const full = try std.fs.path.join(self.allocator, &.{ base, kid.name });
                    defer self.allocator.free(full);
                    const before = items.items.len;
                    try self.addUnmeasured(&items, .cache, full, kid.name, app.name, info);
                    if (items.items.len > before) {
                        found += 1;
                        self.streamBatch(&items, .cache);
                    }
                }
            }
        }
        self.finish(&items, .cache, 0);
        return items;
    }

    /// System junk inside the home folder: logs, saved window state, the
    /// things macOS regenerates.
    pub fn scanSystemJunk(self: *CacheScanner) !std.ArrayListUnmanaged(*CacheItem) {
        var items = std.ArrayListUnmanaged(*CacheItem).empty;
        errdefer self.discard(&items);
        for (safety.system_junk) |target| {
            if (items.items.len >= self.max_items) break;
            try self.addTarget(&items, .junk, target);
        }
        self.finish(&items, .junk, 0);
        return items;
    }

    /// The caches tools keep for every project on the machine.
    pub fn scanDevCaches(self: *CacheScanner) !std.ArrayListUnmanaged(*CacheItem) {
        var items = std.ArrayListUnmanaged(*CacheItem).empty;
        errdefer self.discard(&items);
        for (safety.dev_caches) |target| {
            if (items.items.len >= self.max_items) break;
            try self.addTarget(&items, .dev, target);
        }
        self.finish(&items, .dev, 0);
        return items;
    }

    /// Walk the home folder for projects, and propose the rebuildable folder
    /// inside each one the catalog knows.
    pub fn scanProjects(self: *CacheScanner) !std.ArrayListUnmanaged(*CacheItem) {
        var state = ProjectWalk{ .items = .empty, .seen = .empty };
        defer {
            // The paths are the map's own: a row handed over mid-walk leaves
            // the map behind, so it cannot be the key.
            var keys = state.seen.keyIterator();
            while (keys.next()) |key| self.allocator.free(key.*);
            state.seen.deinit(self.allocator);
        }
        errdefer self.discard(&state.items);
        self.walkProjectDirs(self.home_dir, 0, &state);
        self.finish(&state.items, .project, self.max_project_items);
        return state.items;
    }

    /// The biggest files in the user's own folders.
    pub fn scanLarge(self: *CacheScanner) !std.ArrayListUnmanaged(*CacheItem) {
        var items = try large.scan(self.allocator, self.io, .{
            .home = self.home_dir,
            .min_bytes = self.min_large_bytes,
            .max_items = self.max_large_items,
            .batch = self.batch(),
        });
        self.finish(&items, .large, self.max_large_items);
        return items;
    }

    /// Installed apps, with what each left in the user's Library.
    pub fn scanApps(self: *CacheScanner) !std.ArrayListUnmanaged(*CacheItem) {
        var items = try apps.scan(self.allocator, self.io, .{
            .home = self.home_dir,
            .roots = self.apps_roots,
            .max_items = self.max_apps,
            .batch = self.batch(),
        });
        self.finish(&items, .app, self.max_apps);
        return items;
    }

    /// Simulator runtimes and devices that are not running.
    pub fn scanSimulators(self: *CacheScanner) !std.ArrayListUnmanaged(*CacheItem) {
        if (!self.machine) return .empty;
        var items = try simulators.scan(self.allocator, self.io, .{ .max_items = self.max_simulators });
        self.finish(&items, .simulator, self.max_simulators);
        return items;
    }

    /// Xcode's optional components, when they are installed.
    pub fn scanXcodeComponents(self: *CacheScanner) !std.ArrayListUnmanaged(*CacheItem) {
        if (!self.machine) return .empty;
        var items = try xcode.scan(self.allocator, self.io, .{});
        self.finish(&items, .xcode, 0);
        return items;
    }

    /// The apps Homebrew installed, which only Homebrew should take away.
    pub fn scanBrewCasks(self: *CacheScanner) !std.ArrayListUnmanaged(*CacheItem) {
        if (!self.machine) return .empty;
        var items = try brew.scanCasks(self.allocator, self.io, .{ .max_casks = self.max_casks, .batch = self.batch() });
        self.finish(&items, .app, self.max_casks);
        return items;
    }

    /// The command-line tools the machine has, and their newer versions:
    /// Homebrew's formulae, npm's, pnpm's and bun's global packages, pipx's
    /// environments, cargo's binaries, and the programs downloaded into the
    /// user's own bin folders.
    pub fn scanCliTools(self: *CacheScanner) !std.ArrayListUnmanaged(*CacheItem) {
        var items = try cli.scan(self.allocator, self.io, .{
            .home = self.home_dir,
            .machine = self.machine,
            .max_per_manager = self.max_tools,
            .batch = self.batch(),
        });
        // Every tool is a row, however small: this page is about what is
        // installed, not about the biggest few.
        self.finish(&items, .cli, 0);
        return items;
    }

    /// Time Machine's local snapshots.
    pub fn scanSnapshots(self: *CacheScanner) !std.ArrayListUnmanaged(*CacheItem) {
        if (!self.machine) return .empty;
        var items = try snapshots.scan(self.allocator, self.io, .{ .max_items = self.max_snapshots });
        self.finish(&items, .junk, 0);
        return items;
    }

    /// The overview's read-only map: the user's folders, and the disk itself.
    pub fn scanDiskMap(self: *CacheScanner) !std.ArrayListUnmanaged(*CacheItem) {
        // The map is a picture of the machine, so a scan of a test's own
        // home leaves it alone.
        if (!self.machine) return .empty;
        var items = try diskmap.scan(self.allocator, self.io, .{
            .home = self.home_dir,
            .max_files = self.disk_map_files,
        });
        if (self.volume) |where| if (diskmap.volume(self.allocator)) |disk| {
            where.* = disk;
        };
        self.finish(&items, .other, 0);
        return items;
    }

    const ProjectWalk = struct {
        items: std.ArrayListUnmanaged(*CacheItem),
        /// Every folder proposed, the ones already handed over included: the
        /// walk's own bound, which the batch in `items` cannot be.
        proposed: usize = 0,
        seen: std.StringHashMapUnmanaged(void),
        dirs_visited: usize = 0,
    };

    fn walkProjectDirs(self: *CacheScanner, path: []const u8, depth: usize, st: *ProjectWalk) void {
        if (self.cancelled()) return;
        if (st.dirs_visited >= self.max_dirs_visited or st.proposed >= self.max_project_items) return;
        st.dirs_visited += 1;

        var dir = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        // The names this folder holds are needed only while it is examined.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var files: std.ArrayListUnmanaged([]const u8) = .empty;
        var subdirs: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            switch (entry.kind) {
                .file => files.append(a, a.dupe(u8, entry.name) catch return) catch return,
                .directory => {
                    if (skipProjectDir(entry.name)) continue;
                    subdirs.append(a, a.dupe(u8, entry.name) catch return) catch return;
                },
                else => {},
            }
        }

        self.proposeProjectItems(path, files.items, st);

        if (depth + 1 >= self.max_project_depth) return;
        for (subdirs.items) |name| {
            const child = std.fs.path.join(a, &.{ path, name }) catch continue;
            self.walkProjectDirs(child, depth + 1, st);
        }
    }

    fn proposeProjectItems(self: *CacheScanner, root: []const u8, files: []const []const u8, st: *ProjectWalk) void {
        for (safety.project_rules) |rule| {
            if (st.proposed >= self.max_project_items) return;
            if (!self.ruleMatches(root, rule, files)) continue;

            const full = std.fs.path.join(self.allocator, &.{ root, rule.folder }) catch continue;
            defer self.allocator.free(full);
            if (!self.isDir(full)) continue;
            if (self.refused(rule, full)) continue;
            if (st.seen.contains(full)) continue;

            const info = SafetyInfo{
                .level = rule.level,
                .headline = rule.headline,
                .explanation = rule.explanation,
                .recovery_steps = rule.reinstall orelse "The project rebuilds this folder when you next build it.",
                .reinstall_command = rule.reinstall,
            };
            const name = std.fs.path.basename(rule.folder);
            const project = std.fs.path.basename(root);
            // The path is remembered before the row is made, and the map owns
            // its own copy: the row may be handed over in the next batch.
            const key = self.allocator.dupe(u8, full) catch continue;
            st.seen.put(self.allocator, key, {}) catch {
                self.allocator.free(key);
                continue;
            };
            self.addUnmeasured(&st.items, .project, full, name, project, info) catch continue;
            st.proposed += 1;
            self.streamBatch(&st.items, .project);
        }
    }

    /// Whether the project root really is one this rule applies to: a marker
    /// file, or a marker extension among the root's files.
    fn ruleMatches(self: *CacheScanner, root: []const u8, rule: safety.ProjectRule, files: []const []const u8) bool {
        if (rule.markers.len == 0 and rule.marker_extensions.len == 0) return false;
        for (rule.markers) |marker| {
            if (self.exists(root, marker)) return true;
        }
        if (rule.marker_extensions.len == 0) return false;
        for (files) |name| {
            const ext = std.fs.path.extension(name);
            if (ext.len < 2) continue;
            for (rule.marker_extensions) |wanted| {
                if (std.ascii.eqlIgnoreCase(ext[1..], wanted)) return true;
            }
        }
        return false;
    }

    /// Whether the folder holds something the rule refuses: real state that
    /// happens to sit beside build output, such as `terraform.tfstate`.
    fn refused(self: *CacheScanner, rule: safety.ProjectRule, folder: []const u8) bool {
        for (rule.refuse_when_present) |name| {
            if (self.exists(folder, name)) return true;
        }
        return false;
    }

    /// A file or folder inside `base`, by relative path.
    fn exists(self: *CacheScanner, base: []const u8, rel: []const u8) bool {
        const full = std.fs.path.join(self.allocator, &.{ base, rel }) catch return false;
        defer self.allocator.free(full);
        _ = std.Io.Dir.cwd().statFile(self.io, full, .{}) catch return false;
        return true;
    }

    fn isDir(self: *CacheScanner, path: []const u8) bool {
        var dir = std.Io.Dir.cwd().openDir(self.io, path, .{}) catch return false;
        defer dir.close(self.io);
        return true;
    }

    /// A catalog entry: a whole path, named by its last part.
    fn addTarget(self: *CacheScanner, items: *std.ArrayListUnmanaged(*CacheItem), category: Category, target: safety.Target) !void {
        const full = try std.fs.path.join(self.allocator, &.{ self.home_dir, target.path });
        defer self.allocator.free(full);
        if (!self.isDir(full)) return;
        const name = std.fs.path.basename(target.path);
        const where = std.fs.path.dirname(target.path) orelse "";
        try self.addUnmeasured(items, category, full, name, where, target.info);
    }

    /// Add a candidate, before its size is known, unless a folder already in
    /// the list covers it.
    fn addUnmeasured(self: *CacheScanner, items: *std.ArrayListUnmanaged(*CacheItem), category: Category, path: []const u8, name: []const u8, where: []const u8, info: SafetyInfo) !void {
        for (items.items) |other| {
            const other_path = other.primaryPath();
            if (other_path.len < path.len and std.mem.startsWith(u8, path, other_path) and path[other_path.len] == '/') return;
        }

        const id = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ @tagName(category), path });
        defer self.allocator.free(id);

        const item = try self.allocator.create(CacheItem);
        errdefer self.allocator.destroy(item);
        item.* = try CacheItem.init(self.allocator, id, name, info);
        errdefer item.deinit();
        item.category = category;
        try item.addLocation(path, 0, self.dirModTime(path), where);
        try items.append(self.allocator, item);
    }

    /// Measure the candidates (in parallel: the folders are independent), drop
    /// the ones that hold nothing or too little to be worth a row, and hand
    /// what is left to the sink. A scan with no sink keeps its rows: the pass
    /// returns them and the caller owns them.
    fn publish(self: *CacheScanner, items: *std.ArrayListUnmanaged(*CacheItem), category: Category) void {
        self.measureAll(items.items);
        var keep: usize = 0;
        for (items.items) |item| {
            const size = item.sizeBytes();
            // A cache folder under a megabyte is noise; anything whose size
            // could not be measured (a snapshot) is kept and shown as a dash.
            const worth = if (category == .cache) size >= self.min_bytes else (size > 0 or !item.measured);
            if (worth) {
                items.items[keep] = item;
                keep += 1;
            } else {
                item.deinit();
                self.allocator.destroy(item);
            }
        }
        items.shrinkRetainingCapacity(keep);

        const sink = self.sink orelse return;
        for (items.items) |item| sink(self.sink_ctx.?, item);
        items.clearRetainingCapacity();
    }

    /// Hand a batch over in the middle of a pass, once it is worth showing.
    /// Nothing happens without a sink: the pass keeps its rows and `finish`
    /// measures them all at once.
    fn streamBatch(self: *CacheScanner, items: *std.ArrayListUnmanaged(*CacheItem), category: Category) void {
        if (self.sink == null or items.items.len < stream_batch) return;
        self.publish(items, category);
    }

    /// The scanner's side of a module's batch: its rows are measured and
    /// handed on the same way a pass's own are. A scan with no sink hands out
    /// nothing, so the module keeps its rows and the pass returns them.
    fn batch(self: *CacheScanner) ?item_mod.Batch {
        if (self.sink == null) return null;
        return .{ .ctx = self, .give = &takeBatch };
    }

    fn takeBatch(ctx: *anyopaque, category: Category, items: *std.ArrayListUnmanaged(*CacheItem)) void {
        const self: *CacheScanner = @ptrCast(@alignCast(ctx));
        if (items.items.len == 0) return;
        self.publish(items, category);
    }

    /// Measure the candidates and keep what is worth a row. `max_keep` trims
    /// what is left to the biggest few (0 keeps them all).
    fn finish(self: *CacheScanner, items: *std.ArrayListUnmanaged(*CacheItem), category: Category, max_keep: usize) void {
        self.publish(items, category);
        if (max_keep == 0 or items.items.len <= max_keep) return;
        std.sort.pdq(*CacheItem, items.items, {}, struct {
            fn less(_: void, lhs: *CacheItem, rhs: *CacheItem) bool {
                return lhs.sizeBytes() > rhs.sizeBytes();
            }
        }.less);
        for (items.items[max_keep..]) |item| {
            item.deinit();
            self.allocator.destroy(item);
        }
        items.shrinkRetainingCapacity(max_keep);
    }

    /// Fill in every candidate's size, a few folders at a time. Each item is
    /// handed to exactly one worker, so no item is written twice; the walkers
    /// get their own thread-safe allocator, so the scan's allocator is never
    /// touched off this thread.
    fn measureAll(self: *CacheScanner, items: []const *CacheItem) void {
        if (items.len == 0) return;
        const max_threads = 10;
        const cpus = std.Thread.getCpuCount() catch 4;
        const threads_wanted = @min(max_threads, @max(2, cpus));
        var next = std.atomic.Value(usize).init(0);
        const Worker = struct {
            fn run(list: []const *CacheItem, index: *std.atomic.Value(usize), max_files: usize, stop: ?*const std.atomic.Value(bool)) void {
                var io_impl: std.Io.Threaded = std.Io.Threaded.init_single_threaded;
                const io = io_impl.io();
                while (true) {
                    if (stop) |flag| if (flag.load(.acquire)) return;
                    const i = index.fetchAdd(1, .monotonic);
                    if (i >= list.len) return;
                    const item = list[i];
                    // A row whose size nothing can know (a Time Machine
                    // snapshot), or one already measured, is left alone.
                    if (!item.measured or item.sized) continue;
                    // An app has several locations (its bundle and what it
                    // left in the Library); each is measured on its own.
                    for (item.locations.items) |*loc| {
                        const size = measure.measureAt(std.heap.smp_allocator, io, loc.path, max_files);
                        loc.size_bytes = size.bytes;
                        loc.approx = size.truncated;
                    }
                    // Walked once, however many times a pass publishes: a
                    // batch handed over mid-pass is measured already.
                    item.sized = true;
                }
            }
        };
        var threads: [max_threads]std.Thread = undefined;
        var spawned: usize = 0;
        const helpers = @min(threads_wanted - 1, items.len);
        for (0..helpers) |_| {
            threads[spawned] = std.Thread.spawn(.{}, Worker.run, .{ items, &next, self.max_files_for_dir_size, self.cancel }) catch break;
            spawned += 1;
        }
        // The calling thread works too, so a single item needs no thread.
        Worker.run(items, &next, self.max_files_for_dir_size, self.cancel);
        for (threads[0..spawned]) |t| t.join();
    }

    fn discard(self: *CacheScanner, items: *std.ArrayListUnmanaged(*CacheItem)) void {
        for (items.items) |item| {
            item.deinit();
            self.allocator.destroy(item);
        }
        items.deinit(self.allocator);
    }

    /// When the folder was last written to.
    fn dirModTime(self: *CacheScanner, path: []const u8) i64 {
        const dir = std.Io.Dir.cwd().openDir(self.io, path, .{}) catch return 0;
        defer dir.close(self.io);
        const stat = dir.stat(self.io) catch return 0;
        return @intCast(stat.mtime.nanoseconds);
    }
};

/// Folders the project search never descends into: hidden folders, other
/// people's data, and the artifact folders themselves (a `node_modules` holds
/// no project worth scanning).
fn skipProjectDir(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return true;
    const skipped = [_][]const u8{
        "Library",      "Applications", "Movies", "Music", "Pictures", "Public",
        "node_modules", "target",       "build",  "Pods",  "vendor",   "venv",
        "zig-out",      "DerivedData",  "dist",   "out",   "tmp",      "Trash",
    };
    for (skipped) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

/// Build part of a fake home for the tests: a folder with a file of `size`
/// bytes inside it, and a marker file beside it when asked.
fn fakeTree(allocator: std.mem.Allocator, home: std.Io.Dir, io: std.Io, rel: []const u8, file: []const u8, size: usize) !void {
    try home.createDirPath(io, rel);
    const path = try std.fs.path.join(allocator, &.{ rel, file });
    defer allocator.free(path);
    const data = try allocator.alloc(u8, size);
    defer allocator.free(data);
    @memset(data, 'x');
    try home.writeFile(io, .{ .sub_path = path, .data = data });
}

fn fakeFile(allocator: std.mem.Allocator, home: std.Io.Dir, io: std.Io, rel: []const u8, data: []const u8) !void {
    _ = allocator;
    try home.writeFile(io, .{ .sub_path = rel, .data = data });
}

/// The absolute path of a test's temporary home folder.
fn realHome(allocator: std.mem.Allocator, dir: std.Io.Dir, io: std.Io) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try dir.realPath(io, &buf);
    return allocator.dupe(u8, buf[0..len]);
}

test "scan finds app caches, junk, dev caches and project artifacts" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const home = tmp.dir;

    // A known app cache, an unknown app's cache, and a denied one.
    try fakeTree(allocator, home, io, "Library/Caches/com.google.Chrome", "f", 2 << 20);
    try fakeTree(allocator, home, io, "Library/Caches/com.example.app", "f", 2 << 20);
    try fakeTree(allocator, home, io, "Library/Caches/com.apple.akd", "f", 2 << 20);
    try fakeTree(allocator, home, io, "Library/Caches/com.apple.finder", "f", 2 << 20);
    // System junk, and an app's Application Support cache (not its data).
    try fakeTree(allocator, home, io, "Library/Logs", "app.log", 2 << 20);
    try fakeTree(allocator, home, io, "Library/Application Support/com.example.app/GPUCache", "f", 2 << 20);
    try fakeTree(allocator, home, io, "Library/Application Support/com.example.app/Bookmarks", "f", 2 << 20);
    // A global dev cache, and a project with a rebuildable folder.
    try fakeTree(allocator, home, io, ".npm/_cacache", "f", 2 << 20);
    try fakeTree(allocator, home, io, "work/site/node_modules", "f", 2 << 20);
    try fakeFile(allocator, home, io, "work/site/package.json", "{}");

    const home_path = try realHome(allocator, home, io);
    defer allocator.free(home_path);
    var scanner = try CacheScanner.initAt(allocator, io, home_path);
    defer scanner.deinit();
    var items = try scanner.scanAll();
    defer {
        for (items.items) |item| {
            item.deinit();
            allocator.destroy(item);
        }
        items.deinit(allocator);
    }

    var found = std.StringHashMapUnmanaged(void).empty;
    defer found.deinit(allocator);
    for (items.items) |item| try found.put(allocator, item.primaryPath(), {});

    const endsWith = struct {
        fn f(map: *std.StringHashMapUnmanaged(void), suffix: []const u8) bool {
            var it = map.keyIterator();
            while (it.next()) |key| if (std.mem.endsWith(u8, key.*, suffix)) return true;
            return false;
        }
    }.f;

    try std.testing.expect(endsWith(&found, "Caches/com.google.Chrome"));
    try std.testing.expect(endsWith(&found, "Caches/com.example.app"));
    try std.testing.expect(!endsWith(&found, "Caches/com.apple.akd"));
    try std.testing.expect(!endsWith(&found, "Caches/com.apple.finder"));
    try std.testing.expect(endsWith(&found, "Library/Logs"));
    try std.testing.expect(endsWith(&found, "GPUCache"));
    try std.testing.expect(!endsWith(&found, "Bookmarks"));
    try std.testing.expect(endsWith(&found, "_cacache"));
    try std.testing.expect(endsWith(&found, "node_modules"));
}

test "only a project's own artifacts are proposed" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const home = tmp.dir;

    // A Rust project with a target folder, and a folder named "target" with no
    // project around it: only the first is proposed.
    try fakeTree(allocator, home, io, "code/thing/target", "f", 2 << 20);
    try fakeFile(allocator, home, io, "code/thing/Cargo.toml", "[package]");
    try fakeTree(allocator, home, io, "loose/target", "f", 2 << 20);

    const home_path = try realHome(allocator, home, io);
    defer allocator.free(home_path);
    var scanner = try CacheScanner.initAt(allocator, io, home_path);
    defer scanner.deinit();
    var items = try scanner.scanProjects();
    defer {
        for (items.items) |item| {
            item.deinit();
            allocator.destroy(item);
        }
        items.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), items.items.len);
    try std.testing.expect(std.mem.endsWith(u8, items.items[0].primaryPath(), "code/thing/target"));
    try std.testing.expectEqual(Category.project, items.items[0].category);
    try std.testing.expectEqualStrings("target", items.items[0].app_name);
    try std.testing.expectEqualStrings("thing", items.items[0].locations.items[0].folder_name);
}

test "a terraform folder holding state is refused" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const home = tmp.dir;

    try fakeTree(allocator, home, io, "infra/.terraform/providers", "f", 2 << 20);
    try fakeFile(allocator, home, io, "infra/main.tf", "");
    try fakeFile(allocator, home, io, "infra/.terraform/terraform.tfstate", "{}");

    const home_path = try realHome(allocator, home, io);
    defer allocator.free(home_path);
    var scanner = try CacheScanner.initAt(allocator, io, home_path);
    defer scanner.deinit();
    var items = try scanner.scanProjects();
    defer {
        for (items.items) |item| {
            item.deinit();
            allocator.destroy(item);
        }
        items.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 0), items.items.len);
}

test "a scan of an empty home finds nothing and does not fail" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const home_path = try realHome(allocator, tmp.dir, io);
    defer allocator.free(home_path);
    var scanner = try CacheScanner.initAt(allocator, io, home_path);
    defer scanner.deinit();
    var items = try scanner.scanAll();
    defer {
        for (items.items) |item| {
            item.deinit();
            allocator.destroy(item);
        }
        items.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 0), items.items.len);
}

test "CacheScanner protected paths" {
    var scanner = try CacheScanner.init(std.testing.allocator, std.testing.io);
    defer scanner.deinit();
    try std.testing.expect(scanner.policy.isProtected("/System/Library"));
}

test "a size walk that hits its limit says the size is a floor" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const home = tmp.dir;

    try fakeTree(allocator, home, io, "Library/Caches/com.google.Chrome", "big", 2 << 20);
    try fakeFile(allocator, home, io, "Library/Caches/com.google.Chrome/small", "x");

    const home_path = try realHome(allocator, home, io);
    defer allocator.free(home_path);
    var scanner = try CacheScanner.initAt(allocator, io, home_path);
    defer scanner.deinit();
    // One file is all the walk may look at: the sum is a floor.
    scanner.max_files_for_dir_size = 1;

    var items = try scanner.scanLibraryCaches();
    defer {
        for (items.items) |item| {
            item.deinit();
            allocator.destroy(item);
        }
        items.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), items.items.len);
    try std.testing.expect(items.items[0].approx());
}

test "a cancelled scan stops instead of proposing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const home = tmp.dir;

    try fakeTree(allocator, home, io, "code/thing/target", "f", 2 << 20);
    try fakeFile(allocator, home, io, "code/thing/Cargo.toml", "[package]");

    const home_path = try realHome(allocator, home, io);
    defer allocator.free(home_path);
    var scanner = try CacheScanner.initAt(allocator, io, home_path);
    defer scanner.deinit();
    var stop = std.atomic.Value(bool).init(true);
    scanner.cancel = &stop;

    var items = try scanner.scanProjects();
    defer items.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), items.items.len);
}
