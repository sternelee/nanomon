//! nanomon's state: the sampler, when it last sampled (unless paused), the
//! page shown and the time its graphs span, which processes show (all, the
//! user's, the system's) and in what order, processes grouped as apps, the
//! selection, the inspector and a process to quit once asked.
const std = @import("std");
const model = @import("model.zig");
const sample = @import("sample.zig");
const search = @import("search.zig");
const icons = @import("icons.zig");
const nanoui = @import("nanoui");
const builtin = @import("builtin");

const item_mod = @import("cleanup/item.zig");
const CacheItem = item_mod.CacheItem;
const CacheScanner = @import("cleanup/scanner.zig").CacheScanner;
const TrashManager = @import("cleanup/trash.zig").TrashManager;
const remove = @import("cleanup/remove.zig");

/// What a removal did, for the notice the page shows afterwards.
pub const RemovalReport = struct {
    moved: usize = 0,
    removed: usize = 0,
    failed: usize = 0,
    freed: u64 = 0,
};

/// The Cleanup sidebar's tabs (App Caches, Dev Tools, Large Files, App
/// Uninstaller), as the item model names them.
pub const CleanupTab = item_mod.Tab;

/// How many passes one Cleanup scan runs, for the "N of 13" the page shows.
pub const cleanup_pass_count: u8 = 13;

/// The disk's own figures, for the overview's bar.
pub const Volume = @import("cleanup/diskmap.zig").Volume;

/// How many items a tab holds, and what they are worth.
pub const TabTotals = struct { count: usize, bytes: u64 };

/// How the Cleanup page orders what it found.
pub const CleanupSort = enum {
    size,
    name,
    safety,
};

/// Which of what was found the Cleanup page shows.
pub const CleanupFilter = enum {
    all,
    safe,
    check,

    pub fn title(self: CleanupFilter) []const u8 {
        return switch (self) {
            .all => "All",
            .safe => "Safe",
            .check => "Check First",
        };
    }
};

/// Runs the whole Cleanup scan off the UI thread. The main thread only polls
/// `cleanup_done` and joins, so no window/UI call is ever made from here
/// (Cocoa requires the main thread).
fn cleanupScanWorker(a: *App) void {
    var io_impl: std.Io.Threaded = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();

    // `cleanup_home` lets the tests scan a home of their own; the app leaves
    // it null and the scan follows $HOME.
    var scanner = (if (a.cleanup_home) |home| CacheScanner.initAt(a.sampler.gpa, io, home) else CacheScanner.init(a.sampler.gpa, io)) catch {
        a.cleanup_scan_failed.store(true, .release);
        a.cleanup_done.store(true, .release);
        return;
    };
    defer scanner.deinit();
    scanner.cancel = &a.cleanup_stop;
    var volume: Volume = .{ .total = 0, .used = 0, .free = 0 };
    scanner.volume = &volume;

    // One pass at a time, publishing each as it finishes: the page fills in
    // while the slower project walk carries on.
    const Pass = struct { f: *const fn (*CacheScanner) anyerror!std.ArrayListUnmanaged(*CacheItem) };
    const passes = [_]Pass{
        .{ .f = CacheScanner.scanLibraryCaches },
        .{ .f = CacheScanner.scanSystemJunk },
        .{ .f = CacheScanner.scanDevCaches },
        .{ .f = CacheScanner.scanApplicationSupport },
        .{ .f = CacheScanner.scanLarge },
        .{ .f = CacheScanner.scanApps },
        .{ .f = CacheScanner.scanProjects },
        .{ .f = CacheScanner.scanSimulators },
        .{ .f = CacheScanner.scanXcodeComponents },
        .{ .f = CacheScanner.scanBrewCasks },
        .{ .f = CacheScanner.scanBrewFormulae },
        .{ .f = CacheScanner.scanSnapshots },
        .{ .f = CacheScanner.scanDiskMap },
    };
    for (passes, 0..) |pass, i| {
        if (a.cleanup_stop.load(.acquire)) break;
        if (pass.f(&scanner)) |result| {
            var list = result;
            publishCleanupResult(a, &list);
        } else |_| {}
        a.cleanup_progress.store(@intCast(i + 1), .release);
    }

    // The disk's figures come with the map, and are handed over like the
    // items are: the main thread takes them under the same lock.
    if (volume.total > 0) {
        a.lockCleanup();
        a.cleanup_volume_staged = volume;
        a.unlockCleanup();
    }
    a.cleanup_done.store(true, .release);
}

/// Hand a finished pass to the main thread without touching the UI here.
fn publishCleanupResult(a: *App, list: *std.ArrayListUnmanaged(*CacheItem)) void {
    defer list.deinit(a.sampler.gpa);
    a.lockCleanup();
    defer a.unlockCleanup();
    for (list.items) |item| {
        a.cleanup_staging.append(a.sampler.gpa, item) catch {
            item.deinit();
            a.sampler.gpa.destroy(item);
        };
    }
}

/// Removes what the page ticked, off the UI thread. It touches the filesystem
/// and the flags it was handed, and nothing of the window.
fn cleanupRemoveWorker(a: *App) void {
    var io_impl: std.Io.Threaded = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();

    var report: RemovalReport = .{ .failed = a.cleanup_removal_items.items.len };
    if (a.cleanupTrash(io)) |trash| {
        var owned = trash;
        defer owned.deinit();
        report = a.performRemovals(&owned);
    } else |_| {}

    a.lockCleanup();
    a.cleanup_removal_staged = report;
    a.unlockCleanup();
    a.cleanup_removal_done.store(true, .release);
}

extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn getuid() c_uint;
extern "c" fn getpid() c_int;

fn sendSignal(pid: c_int, sig: c_int) callconv(.c) c_int {
    if (comptime builtin.os.tag == .windows) return -1;
    return kill(pid, sig);
}

/// Seconds between samples, as Activity Monitor's default.
pub const interval = 2.0;

/// Activity Monitor's View menu: which processes the table shows.
pub const Filter = enum {
    all,
    mine,
    system,

    pub fn title(f: Filter) []const u8 {
        return switch (f) {
            .all => "All Processes",
            .mine => "My Processes",
            .system => "System Processes",
        };
    }
};

/// The sidebar's pages.
pub const Page = enum { overview, processes, cpu, memory, gpu, disk, network, apps, cleanup, about };
/// How far back the graphs reach.
pub const Range = enum {
    m1,
    m5,
    m15,
    h1,

    pub fn seconds(r: Range) f32 {
        return switch (r) {
            .m1 => 60,
            .m5 => 300,
            .m15 => 900,
            .h1 => 3600,
        };
    }

    pub fn samples(r: Range) usize {
        return @intFromFloat(r.seconds() / interval);
    }

    pub fn title(r: Range) []const u8 {
        return switch (r) {
            .m1 => "1m",
            .m5 => "5m",
            .m15 => "15m",
            .h1 => "1h",
        };
    }
};

/// An app: its processes together (Chrome and its helpers).
pub const AppRow = struct {
    name: []const u8,
    bundle: []const u8,
    processes: u32 = 0,
    cpu: f32 = 0,
    memory: u64 = 0,
    threads: u32 = 0,
    /// Its first process, for the inspector.
    pid: i32 = 0,
};

pub const AppSort = enum { name, processes, cpu, memory, threads };

/// What a graph's column under the pointer holds: how long ago, and each
/// series' value.
pub const Hover = struct { ago: f32, values: [4]f32 = @splat(0) };

/// The graphs that read out their column under the pointer.
pub const Graph = enum { cpu, memory, gpu, disk, network };

pub const App = struct {
    sampler: sample.Sampler,
    icons: icons.Icons,
    /// Samples by itself (tests fill it instead).
    live: bool = true,
    last: f64 = -1e9,
    tab: model.Tab = .cpu,
    page: Page = .overview,
    range: Range = .m1,
    /// Sampling stopped: the graphs hold still.
    paused: bool = false,
    apps: std.ArrayList(AppRow) = .empty,
    app_sort: AppSort = .cpu,
    app_ascending: bool = false,
    /// Where the filter's menu opens, under its button.
    menu_at: [2]f32 = .{ 0, 0 },
    /// Each graph's column under the pointer, as last drawn.
    hovers: std.EnumArray(Graph, ?Hover) = .initFill(null),
    /// Processes marked to quit together, and the sheet asking first.
    marked: std.AutoArrayHashMapUnmanaged(i32, void) = .empty,
    confirm_marked: bool = false,
    /// What quitting did, shown for a while.
    notice: [120]u8 = undefined,
    notice_len: usize = 0,
    notice_until: f64 = 0,
    /// The clock as the view last saw it.
    now: f64 = 0,
    /// The graff bubble.
    graff: @import("graff.zig").Graff = .{},
    /// How a signal is sent (tests record instead).
    send: *const fn (pid: c_int, sig: c_int) callconv(.c) c_int = sendSignal,
    filter: Filter = .all,
    sort: model.Sort = .cpu,
    ascending: bool = false,
    query: nanoui.ui.TextBuffer = .{},
    /// Where the search's suggestions go, under the field: the frame that
    /// draws the field leaves it, the one after draws them there; and the
    /// field's box, for a press in them.
    suggest_at: ?[2]f32 = null,
    search_id: u64 = 0,
    /// The table's order: indices into the sample's processes.
    rows: std.ArrayList(u32) = .empty,
    dirty: bool = true,
    selected: ?i32 = null,
    /// A process to quit, waiting for the user to confirm; one inspected.
    confirm: ?i32 = null,
    inspect: ?i32 = null,
    /// The View menu (the toolbar's ⋯) is open.
    menu: bool = false,
    /// The keyboard moved the selection: scroll it into view.
    reveal: bool = false,
    /// ⌘F: the search takes the keys.
    find_search: bool = false,
    /// The user running nanomon: "My Processes".
    uid: u32 = 0,
    /// Light or dark, fixed (tests); else as the system shows.
    dark: ?bool = null,
    /// Drawn again when figures come between samples.
    window: ?*nanoui.Window = null,
    /// ps has answered since the last frame.
    fresh: bool = false,
    /// Updates from the releases, and the app to quit to install one.
    updater: ?*nanoui.Updater = null,
    nanoapp: ?*nanoui.App = null,
    /// The menu bar's readout and panel (macOS), what it shows, and whether
    /// the panel shows its settings.
    menubar: ?*@import("menubar.zig").MenuBar = null,
    bar_items: @import("menubar.zig").Items = .{},
    settings_open: bool = false,
    /// The clock samples go by when several views share them (the window
    /// and the panel each have their own frame clock); tests leave it null.
    clock: ?*const fn () f64 = null,
    /// Cleanup: published scan results (CacheItem pointers)
    cleanup_items: std.ArrayListUnmanaged(*CacheItem) = .empty,
    /// Cleanup: a scan is running on a background thread
    cleanup_scanning: bool = false,
    /// Set by the worker when its results are ready; polled once per frame.
    cleanup_done: std.atomic.Value(bool) = .init(false),
    /// What the worker has finished so far, handed over under the mutex.
    cleanup_staging: std.ArrayListUnmanaged(*CacheItem) = .empty,
    /// A spinlock for the handover: the critical sections move a handful of
    /// pointers, so waiting is a few instructions, never a syscall.
    cleanup_lock: std.atomic.Value(bool) = .init(false),
    /// How many of the scan's passes have finished (for "3 of 5").
    cleanup_progress: std.atomic.Value(u8) = .init(0),
    /// The disk's figures, handed over with the results for the overview.
    cleanup_volume_staged: ?Volume = null,
    cleanup_volume: ?Volume = null,
    /// Cleanup: a removal is running on a background thread (brew uninstall
    /// and simctl delete take seconds; the window must keep drawing).
    cleanup_removing: bool = false,
    cleanup_removal_thread: ?std.Thread = null,
    /// The items being removed, and which of them went: the worker fills the
    /// second, the main thread reads it after joining.
    cleanup_removal_items: std.ArrayListUnmanaged(*CacheItem) = .empty,
    cleanup_removal_ok: std.ArrayListUnmanaged(bool) = .empty,
    cleanup_removal_staged: ?RemovalReport = null,
    cleanup_removal_done: std.atomic.Value(bool) = .init(false),
    /// Set when the app is going away, so a long scan stops promptly.
    cleanup_stop: std.atomic.Value(bool) = .init(false),
    /// The home folder the tests scan; null in the app, which uses $HOME.
    /// Borrowed: whoever sets it keeps it alive for the scan.
    cleanup_home: ?[]const u8 = null,
    /// The home whose Trash removals go to; null in the app, which uses the
    /// user's own. Borrowed, like `cleanup_home`.
    cleanup_trash_home: ?[]const u8 = null,
    /// Whether the page scans by itself the first time it is opened (as
    /// purge does); the tests turn it off and stage their own items.
    cleanup_auto: bool = true,
    /// Whether a scan has been asked for at all, so the page only starts one
    /// on its own the first time.
    cleanup_scanned: bool = false,
    /// The worker thread, joined once it signals done.
    cleanup_thread: ?std.Thread = null,
    /// True if the scan could not be started.
    cleanup_scan_failed: std.atomic.Value(bool) = .init(false),
    /// Cleanup: what the page shows: the items the filter lets through, in
    /// the chosen order. Rebuilt whenever the items, the filter or the order
    /// change, never while drawing.
    cleanup_visible: std.ArrayListUnmanaged(*CacheItem) = .empty,
    /// Cleanup: the items ticked for deletion, by item, so sorting and
    /// filtering never lose the tick.
    cleanup_selected: std.AutoArrayHashMapUnmanaged(*CacheItem, void) = .empty,
    /// Cleanup: how the list is ordered, and which way.
    cleanup_sort: CleanupSort = .size,
    cleanup_ascending: bool = false,
    /// Cleanup: which safety levels show.
    cleanup_filter: CleanupFilter = .all,
    /// Cleanup: which tab of the page shows.
    cleanup_tab: CleanupTab = .caches,
    /// Cleanup: confirm deletion
    cleanup_confirm: bool = false,
    /// Cleanup: what just happened (moved to the Trash, or why not).
    cleanup_notice: ?[]const u8 = null,
    cleanup_notice_error: bool = false,
    pub fn init(gpa: std.mem.Allocator, io: std.Io) App {
        const uid: u32 = if (comptime builtin.os.tag != .windows) getuid() else 0;
        return .{ .sampler = .{ .gpa = gpa, .io = io }, .icons = .{ .gpa = gpa }, .uid = uid };
    }

    fn lockCleanup(a: *App) void {
        while (a.cleanup_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn unlockCleanup(a: *App) void {
        a.cleanup_lock.store(false, .release);
    }

    /// Starts a background Cleanup scan. Safe to call from the page's Scan
    /// button: it only does bookkeeping, then hands all I/O to a worker.
    pub fn startCleanupScan(a: *App) void {
        // A removal holds pointers into the list a scan would free.
        if (a.cleanup_scanning or a.cleanup_removing) return;

        for (a.cleanup_items.items) |item| {
            item.deinit();
            a.sampler.gpa.destroy(item);
        }
        a.cleanup_items.clearRetainingCapacity();
        a.cleanup_visible.clearRetainingCapacity();
        a.cleanup_selected.clearRetainingCapacity();
        a.lockCleanup();
        for (a.cleanup_staging.items) |item| {
            item.deinit();
            a.sampler.gpa.destroy(item);
        }
        a.cleanup_staging.clearRetainingCapacity();
        a.unlockCleanup();
        a.cleanup_confirm = false;
        a.clearCleanupNotice();
        a.cleanup_scanned = true;
        a.cleanup_scan_failed.store(false, .release);
        a.cleanup_progress.store(0, .release);
        a.cleanup_stop.store(false, .release);
        a.cleanup_done.store(false, .release);
        a.cleanup_scanning = true;

        const t = std.Thread.spawn(.{}, cleanupScanWorker, .{a}) catch {
            a.cleanup_thread = null;
            a.cleanup_scanning = false;
            a.cleanup_scan_failed.store(true, .release);
            return;
        };
        a.cleanup_thread = t;
    }

    /// Called once per frame from view.zig. Keeps the frame loop alive while
    /// the worker runs; when it signals done, joins it (a happens-before
    /// barrier), publishes the results and stops. Returns true while a scan
    /// still needs frames.
    pub fn pollCleanupScan(a: *App) bool {
        if (!a.cleanup_scanning) return false;

        // Take whatever the worker has finished since the last frame, so the
        // page fills in while the slower passes carry on.
        var took = false;
        a.lockCleanup();
        if (a.cleanup_staging.items.len > 0) {
            for (a.cleanup_staging.items) |item| {
                a.cleanup_items.append(a.sampler.gpa, item) catch {
                    item.deinit();
                    a.sampler.gpa.destroy(item);
                };
            }
            a.cleanup_staging.clearRetainingCapacity();
            took = true;
        }
        if (a.cleanup_volume_staged) |disk| {
            a.cleanup_volume = disk;
            a.cleanup_volume_staged = null;
            took = true;
        }
        a.unlockCleanup();
        if (took) {
            a.refreshCleanupView();
            if (a.window) |w| w.redraw();
        }

        if (!a.cleanup_done.load(.acquire)) return true;

        if (a.cleanup_thread) |t| {
            t.join();
            a.cleanup_thread = null;
        }
        a.cleanup_scanning = false;
        a.cleanup_progress.store(0, .release);
        a.refreshCleanupView();
        if (a.window) |w| w.redraw();
        return false;
    }

    /// Rebuild what the page shows: the items the filter lets through, in the
    /// chosen order. Cheap enough to run whenever anything changes.
    pub fn refreshCleanupView(a: *App) void {
        a.cleanup_visible.clearRetainingCapacity();
        for (a.cleanup_items.items) |item| {
            if (item.category.tab() != a.cleanup_tab) continue;
            const level = item.safety_info.level;
            const keep = switch (a.cleanup_filter) {
                .all => true,
                .safe => level == .safe,
                .check => level == .medium,
            };
            if (keep) a.cleanup_visible.append(a.sampler.gpa, item) catch {};
        }
        std.sort.pdq(*CacheItem, a.cleanup_visible.items, a, cleanupLessThan);
    }

    /// Show another tab of the Cleanup page.
    pub fn cleanupSetTab(a: *App, tab: CleanupTab) void {
        a.cleanup_tab = tab;
        a.refreshCleanupView();
    }

    /// What everything found for one tab is worth, and how many items.
    pub fn cleanupTabTotals(a: *App, tab: CleanupTab) TabTotals {
        var count: usize = 0;
        var bytes: u64 = 0;
        for (a.cleanup_items.items) |item| {
            if (item.category.tab() != tab) continue;
            count += 1;
            bytes += item.sizeBytes();
        }
        return .{ .count = count, .bytes = bytes };
    }

    fn cleanupLessThan(a: *App, lhs: *CacheItem, rhs: *CacheItem) bool {
        const rank = switch (a.cleanup_sort) {
            .size => std.math.order(lhs.sizeBytes(), rhs.sizeBytes()),
            .name => std.mem.order(u8, lhs.app_name, rhs.app_name),
            .safety => std.math.order(lhs.safety_info.level.sortOrder(), rhs.safety_info.level.sortOrder()),
        };
        if (rank != .eq) {
            const first = rank == .lt;
            return if (a.cleanup_ascending) first else !first;
        }
        // A tie: the bigger one first, then by name, so the order never
        // depends on the order the scan happened to find them in.
        if (lhs.sizeBytes() != rhs.sizeBytes()) return lhs.sizeBytes() > rhs.sizeBytes();
        return std.mem.lessThan(u8, lhs.app_name, rhs.app_name);
    }

    /// Clicking a column header: same column flips the order, a new one
    /// starts with the biggest (or first) on top.
    pub fn cleanupSortBy(a: *App, sort: CleanupSort) void {
        if (a.cleanup_sort == sort) {
            a.cleanup_ascending = !a.cleanup_ascending;
        } else {
            a.cleanup_sort = sort;
            // Size starts with the biggest, the way a cleanup list should;
            // names and safety start at their beginning.
            a.cleanup_ascending = sort != .size;
        }
        a.refreshCleanupView();
    }

    pub fn cleanupSetFilter(a: *App, filter: CleanupFilter) void {
        a.cleanup_filter = filter;
        a.refreshCleanupView();
    }

    pub fn cleanupIsSelected(a: *App, item: *CacheItem) bool {
        return a.cleanup_selected.contains(item);
    }

    pub fn cleanupToggle(a: *App, item: *CacheItem) void {
        if (a.cleanup_selected.contains(item)) {
            _ = a.cleanup_selected.swapRemove(item);
        } else {
            a.cleanup_selected.put(a.sampler.gpa, item, {}) catch {};
        }
    }

    /// Whether everything the page shows is already ticked.
    pub fn cleanupAllSelected(a: *App) bool {
        if (a.cleanup_visible.items.len == 0) return false;
        for (a.cleanup_visible.items) |item| {
            if (!a.cleanup_selected.contains(item)) return false;
        }
        return true;
    }

    /// The header's box: tick everything the filter shows, or clear it.
    pub fn cleanupToggleAll(a: *App) void {
        if (a.cleanupAllSelected()) {
            a.cleanup_selected.clearRetainingCapacity();
            return;
        }
        for (a.cleanup_visible.items) |item| {
            a.cleanup_selected.put(a.sampler.gpa, item, {}) catch {};
        }
    }

    /// What the ticked items would give back.
    pub fn cleanupSelectedBytes(a: *App) u64 {
        var total: u64 = 0;
        var it = a.cleanup_selected.iterator();
        while (it.next()) |entry| total += entry.key_ptr.*.sizeBytes();
        return total;
    }

    /// The word for what the ticked items are about to get: the same one when
    /// they agree, "Remove" when they do not.
    pub fn cleanupSelectionVerb(a: *App) []const u8 {
        var verb: ?[]const u8 = null;
        var it = a.cleanup_selected.iterator();
        while (it.next()) |entry| {
            const word = entry.key_ptr.*.removal.verb();
            if (verb) |have| {
                if (!std.mem.eql(u8, have, word)) return "Remove";
            } else verb = word;
        }
        return verb orelse "Remove";
    }

    /// Whether everything ticked goes to the Trash (so it can be put back).
    pub fn cleanupSelectionUndoable(a: *App) bool {
        var it = a.cleanup_selected.iterator();
        while (it.next()) |entry| {
            if (!entry.key_ptr.*.removal.trashed()) return false;
        }
        return true;
    }

    /// What the rows the page is showing are worth.
    pub fn cleanupVisibleBytes(a: *App) u64 {
        var total: u64 = 0;
        for (a.cleanup_visible.items) |item| total += item.sizeBytes();
        return total;
    }

    /// Whether any size on show is a floor: a folder's walk hit its file
    /// limit. Only what the page is showing counts.
    pub fn cleanupApprox(a: *App) bool {
        for (a.cleanup_visible.items) |item| {
            if (item.approx()) return true;
        }
        return false;
    }

    /// How many of the scan's passes have finished.
    pub fn cleanupProgress(a: *App) u8 {
        return a.cleanup_progress.load(.acquire);
    }

    fn setCleanupNotice(a: *App, text: []const u8, is_error: bool) void {
        a.clearCleanupNotice();
        a.cleanup_notice = a.sampler.gpa.dupe(u8, text) catch null;
        a.cleanup_notice_error = is_error;
    }

    pub fn clearCleanupNotice(a: *App) void {
        if (a.cleanup_notice) |text| a.sampler.gpa.free(text);
        a.cleanup_notice = null;
        a.cleanup_notice_error = false;
    }

    /// Remove the ticked items. The work goes to a worker — `brew uninstall`
    /// and `simctl delete` take seconds, and the window must keep drawing —
    /// and `pollCleanupRemoval` applies what it did.
    pub fn cleanupDeleteSelected(a: *App) void {
        a.cleanup_confirm = false;
        if (a.cleanup_removing) return;
        if (a.collectRemovals() == 0) return;

        a.cleanup_removal_done.store(false, .release);
        a.cleanup_removing = true;
        const t = std.Thread.spawn(.{}, cleanupRemoveWorker, .{a}) catch {
            // No thread to be had: do it here rather than not at all.
            a.cleanup_removing = false;
            a.cleanupDeleteNow(null);
            return;
        };
        a.cleanup_removal_thread = t;
    }

    /// Called once per frame from view.zig while a removal runs. Returns true
    /// while the page still has to wait for frames.
    pub fn pollCleanupRemoval(a: *App) bool {
        if (!a.cleanup_removing) return false;
        if (!a.cleanup_removal_done.load(.acquire)) return true;

        if (a.cleanup_removal_thread) |t| {
            t.join();
            a.cleanup_removal_thread = null;
        }
        a.cleanup_removing = false;
        const report = blk: {
            a.lockCleanup();
            defer a.unlockCleanup();
            const staged = a.cleanup_removal_staged orelse RemovalReport{ .failed = a.cleanup_removal_items.items.len };
            a.cleanup_removal_staged = null;
            break :blk staged;
        };
        a.applyRemovals(report);
        return false;
    }

    /// The removals, done here and now: the tests' way in (they hand a Trash
    /// inside their own home). The app runs the same work on a worker.
    pub fn cleanupDeleteNow(a: *App, trash: ?*TrashManager) void {
        a.cleanup_confirm = false;
        if (a.cleanup_removing) return;
        if (a.collectRemovals() == 0) return;

        if (trash) |given| {
            a.applyRemovals(a.performRemovals(given));
            return;
        }
        var own = a.cleanupTrash(a.sampler.io) catch {
            a.cleanup_removal_items.clearRetainingCapacity();
            a.cleanup_removal_ok.clearRetainingCapacity();
            a.setCleanupNotice("There is no Trash to move these to.", true);
            return;
        };
        defer own.deinit();
        a.applyRemovals(a.performRemovals(&own));
    }

    /// The Trash removals go to: the user's own, or the tests' temporary one.
    fn cleanupTrash(a: *App, io: std.Io) !TrashManager {
        if (a.cleanup_trash_home) |home| return TrashManager.initAt(a.sampler.gpa, io, home);
        return TrashManager.init(a.sampler.gpa, io);
    }

    /// Take the ticked items into the removal list, one flag each.
    fn collectRemovals(a: *App) usize {
        a.cleanup_removal_items.clearRetainingCapacity();
        a.cleanup_removal_ok.clearRetainingCapacity();
        for (a.cleanup_items.items) |item| {
            if (!a.cleanup_selected.contains(item)) continue;
            if (!item.removal.removable()) continue;
            a.cleanup_removal_items.append(a.sampler.gpa, item) catch continue;
            a.cleanup_removal_ok.append(a.sampler.gpa, false) catch {};
        }
        return a.cleanup_removal_items.items.len;
    }

    /// Do the removals. Touches the filesystem and the flags, nothing else,
    /// so it can run on a worker.
    fn performRemovals(a: *App, trash: *TrashManager) RemovalReport {
        var report: RemovalReport = .{};
        for (a.cleanup_removal_items.items, 0..) |item, i| {
            const gone = remove.remove(a.sampler.gpa, trash, item) == .removed;
            if (i < a.cleanup_removal_ok.items.len) a.cleanup_removal_ok.items[i] = gone;
            if (!gone) {
                report.failed += 1;
                continue;
            }
            report.freed += item.sizeBytes();
            if (item.removal.trashed()) report.moved += 1 else report.removed += 1;
        }
        return report;
    }

    /// Take what went off the page, free it, and say what happened.
    fn applyRemovals(a: *App, report: RemovalReport) void {
        var i: usize = 0;
        while (i < a.cleanup_items.items.len) {
            const item = a.cleanup_items.items[i];
            var gone = false;
            for (a.cleanup_removal_items.items, 0..) |candidate, at| {
                if (candidate != item) continue;
                gone = at < a.cleanup_removal_ok.items.len and a.cleanup_removal_ok.items[at];
                break;
            }
            if (gone) {
                _ = a.cleanup_selected.swapRemove(item);
                item.deinit();
                a.sampler.gpa.destroy(item);
                _ = a.cleanup_items.swapRemove(i);
                continue;
            }
            i += 1;
        }
        a.cleanup_removal_items.clearRetainingCapacity();
        a.cleanup_removal_ok.clearRetainingCapacity();

        var buf: [160]u8 = undefined;
        var size_buf: [32]u8 = undefined;
        const size = @import("cleanup/item.zig").formatBytes(report.freed, &size_buf);
        if (report.failed == 0) {
            const text = if (report.removed == 0)
                std.fmt.bufPrint(&buf, "Moved {d} item{s} ({s}) to the Trash.", .{ report.moved, if (report.moved == 1) "" else "s", size }) catch "Moved to the Trash."
            else if (report.moved == 0)
                std.fmt.bufPrint(&buf, "Removed {d} item{s} ({s}).", .{ report.removed, if (report.removed == 1) "" else "s", size }) catch "Removed."
            else
                std.fmt.bufPrint(&buf, "Moved {d} to the Trash and removed {d} ({s}).", .{ report.moved, report.removed, size }) catch "Done.";
            a.setCleanupNotice(text, false);
        } else {
            const text = std.fmt.bufPrint(&buf, "Freed {s}; {d} of {d} could not be removed.", .{ size, report.failed, report.failed + report.moved + report.removed }) catch "Some items could not be removed.";
            a.setCleanupNotice(text, true);
        }
        a.refreshCleanupView();
        if (a.window) |w| w.redraw();
    }

    /// Hears of ps's answers; `a` must stay where it is from now on.
    pub fn listen(a: *App, window: ?*nanoui.Window) void {
        a.window = window;
        a.sampler.on_update = .{ .ctx = a, .func = answered };
        a.graff.notify = .{ .ctx = a, .func = graffAnswered };
    }

    /// Opens the window (again, once closed: nanomon stays in the menu bar).
    pub fn openWindow(a: *App) void {
        if (a.menubar) |m| m.hidePopover();
        if (a.window) |w| return w.focus();
        const app = a.nanoapp orelse return;
        const theme = @import("theme.zig");
        a.window = app.newWindow(.{
            .title = "nanomon",
            .width = 1020,
            .height = 660,
            .min_width = 720,
            .min_height = 420,
            // The toolbar is the title bar, as Activity Monitor's.
            .title_bar = .hidden,
            .theme = theme.ui(nanoui.isDark()),
            .content = .{ .view = .init(a, @import("view.zig").view) },
            .on_close = .{ .ctx = a, .func = windowClosed },
        }) catch return;
        a.window.?.focus();
    }

    fn windowClosed(ctx: *anyopaque, _: *nanoui.Window) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        a.window = null;
    }

    /// The menu bar panel's height for what it shows.
    pub fn popoverHeight(a: *App) f64 {
        return @import("view_popover.zig").height(a);
    }

    /// Draws again: an answer came, or an update is ready.
    pub fn graffAnswered(ctx: *anyopaque) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        if (a.window) |w| w.redraw();
    }

    fn answered(ctx: *anyopaque) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        a.fresh = true;
        if (a.window) |w| w.redraw();
        if (a.menubar) |m| if (m.popover) |p| if (p.isVisible()) p.redraw();
    }

    pub fn deinit(a: *App) void {
        // A scan may still be running; join it before freeing what it owns.
        if (a.cleanup_thread) |t| {
            a.cleanup_stop.store(true, .release);
            t.join();
            a.cleanup_thread = null;
        }
        // So may a removal.
        if (a.cleanup_removal_thread) |t| {
            t.join();
            a.cleanup_removal_thread = null;
        }
        a.cleanup_removal_items.deinit(a.sampler.gpa);
        a.cleanup_removal_ok.deinit(a.sampler.gpa);
        for (a.cleanup_staging.items) |item| {
            item.deinit();
            a.sampler.gpa.destroy(item);
        }
        a.cleanup_staging.deinit(a.sampler.gpa);
        a.rows.deinit(a.sampler.gpa);
        a.apps.deinit(a.sampler.gpa);
        a.marked.deinit(a.sampler.gpa);
        a.graff.deinit(a.sampler.gpa);
        a.icons.deinit();
        a.sampler.deinit();
        for (a.cleanup_items.items) |item| {
            item.deinit();
            a.sampler.gpa.destroy(item);
        }
        a.cleanup_items.deinit(a.sampler.gpa);
        a.cleanup_visible.deinit(a.sampler.gpa);
        a.cleanup_selected.deinit(a.sampler.gpa);
        a.clearCleanupNotice();
    }

    /// Samples when it is time; returns the seconds until the next.
    pub fn tick(a: *App, now: f64) f32 {
        if (a.paused) {
            if (a.dirty) a.order();
            return 3600;
        }
        if (a.live and now - a.last >= interval) {
            a.sampler.sample(now);
            a.last = now;
            a.dirty = true;
            // The first percentages soon, not a whole interval later.
            if (a.sampler.samples == 1) a.last = now - interval + 0.6;
        }
        a.now = now;
        if (a.fresh) {
            a.fresh = false;
            a.sampler.refill(now);
            a.dirty = true;
        }
        if (a.dirty) a.order();
        return @floatCast(@max(0.05, interval - (now - a.last)));
    }

    /// The table: shown by the filter, matching the search, in order.
    pub fn order(a: *App) void {
        a.dirty = false;
        const procs = a.sampler.procs.items;
        model.sort(procs, a.sort, a.ascending);
        a.rows.clearRetainingCapacity();
        const q = search.parse(a.query.text());
        for (procs, 0..) |p, i| {
            switch (a.filter) {
                .all => {},
                .mine => if (p.uid != a.uid) continue,
                .system => if (p.uid != 0) continue,
            }
            if (!q.empty() and !search.matches(p, q, &a.sampler.ports)) continue;
            a.rows.append(a.sampler.gpa, @intCast(i)) catch return;
        }
        a.group();
    }

    /// Processes from the same app bundle, together, in the apps' order.
    fn group(a: *App) void {
        const gpa = a.sampler.gpa;
        a.apps.clearRetainingCapacity();
        var at: std.StringHashMapUnmanaged(usize) = .empty;
        defer at.deinit(gpa);
        const q = search.parse(a.query.text());
        for (a.sampler.procs.items) |p| {
            if (p.bundle.len == 0) continue;
            // Helpers inside an app count as the outermost app.
            const outer = outerBundle(p.bundle);
            const gop = at.getOrPut(gpa, outer) catch return;
            if (!gop.found_existing) {
                gop.value_ptr.* = a.apps.items.len;
                const name = std.fs.path.stem(outer);
                a.apps.append(gpa, .{ .name = name, .bundle = outer, .pid = p.pid }) catch return;
            }
            const r = &a.apps.items[gop.value_ptr.*];
            r.processes += 1;
            r.cpu += p.cpu;
            r.memory += p.memory;
            r.threads += p.threads;
        }
        if (!q.empty()) {
            var keep: usize = 0;
            for (a.apps.items) |r| if (search.names(q, r.name)) {
                a.apps.items[keep] = r;
                keep += 1;
            };
            a.apps.shrinkRetainingCapacity(keep);
        }
        const Ctx = struct { by: AppSort, asc: bool };
        std.mem.sort(AppRow, a.apps.items, Ctx{ .by = a.app_sort, .asc = a.app_ascending }, struct {
            fn lt(ctx: Ctx, x: AppRow, y: AppRow) bool {
                const o: std.math.Order = switch (ctx.by) {
                    .name => std.ascii.orderIgnoreCase(x.name, y.name),
                    .processes => std.math.order(x.processes, y.processes),
                    .cpu => std.math.order(x.cpu, y.cpu),
                    .memory => std.math.order(x.memory, y.memory),
                    .threads => std.math.order(x.threads, y.threads),
                };
                if (o == .eq) return std.ascii.lessThanIgnoreCase(x.name, y.name);
                return (o == .lt) == ctx.asc;
            }
        }.lt);
    }

    pub fn sortApps(a: *App, by: AppSort) void {
        if (a.app_sort == by) a.app_ascending = !a.app_ascending else {
            a.app_sort = by;
            a.app_ascending = by == .name;
        }
        a.dirty = true;
    }

    /// The outermost app bundle in `path`: Chrome for its helpers.
    pub fn outerBundle(path: []const u8) []const u8 {
        const end = std.mem.indexOf(u8, path, ".app") orelse return path;
        return path[0 .. end + 4];
    }

    /// Sorts by `key`; again on the same key turns the order around.
    pub fn sortBy(a: *App, key: model.Sort) void {
        if (a.sort == key) a.ascending = !a.ascending else {
            a.sort = key;
            a.ascending = key == .name or key == .user or key == .pid;
        }
        a.dirty = true;
    }

    /// Shows another tab, sorted by what it is about.
    pub fn show(a: *App, tab: model.Tab) void {
        if (a.tab == tab) return;
        a.tab = tab;
        a.sort = switch (tab) {
            .cpu => .cpu,
            .memory => .memory,
            .disk => .written,
        };
        a.ascending = false;
        a.dirty = true;
    }

    pub fn setFilter(a: *App, f: Filter) void {
        a.filter = f;
        a.menu = false;
        a.dirty = true;
    }

    pub fn find(a: *App, pid: i32) ?model.Process {
        for (a.sampler.procs.items) |p| if (p.pid == pid) return p;
        return null;
    }

    /// The selection moved up or down the table by `by` rows.
    pub fn step(a: *App, by: i32) void {
        const procs = a.sampler.procs.items;
        if (a.rows.items.len == 0) return;
        const last: i32 = @intCast(a.rows.items.len - 1);
        const at: i32 = if (a.selectedRow()) |i| @intCast(i) else -1;
        const next: i32 = if (at < 0) 0 else std.math.clamp(at + by, 0, last);
        a.selected = procs[a.rows.items[@intCast(next)]].pid;
    }

    /// The selected row's place in the table, if it is shown.
    pub fn selectedRow(a: *App) ?usize {
        const pid = a.selected orelse return null;
        const procs = a.sampler.procs.items;
        for (a.rows.items, 0..) |r, i| if (procs[r].pid == pid) return i;
        return null;
    }

    /// Marks `pid` to quit with others, or unmarks it.
    pub fn mark(a: *App, pid: i32) void {
        if (a.marked.swapRemove(pid)) return;
        a.marked.put(a.sampler.gpa, pid, {}) catch {};
    }

    /// Marks every row from the selected one to `pid`'s, as a shift-click.
    pub fn markTo(a: *App, pid: i32) void {
        const procs = a.sampler.procs.items;
        const from = a.selectedRow() orelse return a.mark(pid);
        var to: usize = from;
        for (a.rows.items, 0..) |r, i| if (procs[r].pid == pid) {
            to = i;
        };
        for (a.rows.items[@min(from, to) .. @max(from, to) + 1]) |r| a.marked.put(a.sampler.gpa, procs[r].pid, {}) catch {};
    }

    /// Marks every row shown, or (if they all are) none.
    pub fn markAll(a: *App) void {
        const procs = a.sampler.procs.items;
        var all = a.rows.items.len > 0;
        for (a.rows.items) |r| if (!a.marked.contains(procs[r].pid)) {
            all = false;
            break;
        };
        if (all) return a.marked.clearRetainingCapacity();
        for (a.rows.items) |r| a.marked.put(a.sampler.gpa, procs[r].pid, {}) catch {};
    }

    /// Marks that still name a process, and what they hold together.
    pub fn markedSummary(a: *App) struct { count: usize, cpu: f32, memory: u64, system: usize } {
        var cpu: f32 = 0;
        var memory: u64 = 0;
        var system: usize = 0;
        var n: usize = 0;
        for (a.marked.keys()) |pid| if (a.find(pid)) |p| {
            n += 1;
            cpu += p.cpu;
            memory += p.memory;
            if (p.uid != a.uid) system += 1;
        };
        return .{ .count = n, .cpu = cpu, .memory = memory, .system = system };
    }

    /// Whether quitting `pid` is out of the question: nanomon itself,
    /// launchd, the kernel.
    pub fn untouchable(pid: i32) bool {
        return pid <= 1 or (comptime builtin.os.tag != .windows) and pid == getpid();
    }

    /// Quits every marked process (asks, or with `force` makes it); says
    /// how many did and how many could not be (not the user's).
    pub fn quitMarked(a: *App, force: bool) void {
        var done: usize = 0;
        var refused: usize = 0;
        var i: usize = 0;
        while (i < a.marked.count()) {
            const pid = a.marked.keys()[i];
            if (a.find(pid) == null or untouchable(pid)) {
                a.marked.swapRemoveAt(i);
                continue;
            }
            const ok = a.send(pid, if (force) 9 else 15) == 0;
            if (ok) {
                done += 1;
                a.marked.swapRemoveAt(i);
            } else {
                refused += 1;
                i += 1;
            }
        }
        a.confirm_marked = false;
        a.last = -1e9;
        const verb = if (force) "Force quit" else "Asked";
        const text: anyerror![]u8 = if (refused == 0)
            std.fmt.bufPrint(&a.notice, "{s} {d} process{s} to quit", .{ verb, done, if (done == 1) "" else "es" })
        else
            std.fmt.bufPrint(&a.notice, "{s} {d} to quit · {d} not yours to quit (left marked)", .{ verb, done, refused });
        a.notice_len = if (text) |t| t.len else |_| 0;
        a.notice_until = a.now + 6;
    }

    pub fn noticeText(a: *App) ?[]const u8 {
        if (a.notice_len == 0 or a.now > a.notice_until) return null;
        return a.notice[0..a.notice_len];
    }

    /// Asks process `pid` to quit (SIGTERM), or makes it (SIGKILL).
    pub fn quit(a: *App, pid: i32, force: bool) void {
        if (!untouchable(pid)) _ = a.send(pid, if (force) 9 else 15);
        a.confirm = null;
        a.last = -1e9;
    }
};

test "the table follows the filter, the search and the sort" {
    var a: App = .init(std.testing.allocator, std.testing.io);
    defer a.deinit();
    a.live = false;
    a.uid = 501;
    try a.sampler.procs.appendSlice(std.testing.allocator, &.{
        .{ .pid = 10, .ppid = 1, .uid = 0, .name = "launchd", .user = "root", .cpu = 1, .known = true },
        .{ .pid = 20, .ppid = 1, .uid = 501, .name = "Safari", .user = "me", .cpu = 30, .known = true, .memory = 5 },
        .{ .pid = 30, .ppid = 1, .uid = 501, .name = "Mail", .user = "me", .cpu = 3, .known = true, .memory = 9 },
    });
    _ = a.tick(0);
    try std.testing.expectEqualStrings("Safari", a.sampler.procs.items[a.rows.items[0]].name);
    a.query.set("ma");
    a.dirty = true;
    _ = a.tick(0);
    try std.testing.expectEqual(@as(usize, 1), a.rows.items.len);
    a.sortBy(.name);
    a.query.set("");
    _ = a.tick(0);
    try std.testing.expectEqualStrings("launchd", a.sampler.procs.items[a.rows.items[0]].name);
    a.setFilter(.mine);
    _ = a.tick(0);
    try std.testing.expectEqual(@as(usize, 2), a.rows.items.len);
    a.setFilter(.system);
    _ = a.tick(0);
    try std.testing.expectEqual(@as(usize, 1), a.rows.items.len);
    a.setFilter(.all);
    a.show(.memory);
    _ = a.tick(0);
    try std.testing.expectEqualStrings("Mail", a.sampler.procs.items[a.rows.items[0]].name);
    a.step(1);
    try std.testing.expectEqual(@as(?i32, 30), a.selected);
    a.step(1);
    try std.testing.expectEqual(@as(?i32, 20), a.selected);
}
