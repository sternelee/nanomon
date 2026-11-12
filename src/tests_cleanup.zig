//! The Cleanup page through the Tester: what the scan found, in order, with
//! its safety; ticking rows, the header's box, the filter and the sheet.
//! Nothing is ever moved: the tests stop at the sheet and cancel.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_mod = @import("app.zig");
const App = app_mod.App;
const view = @import("view.zig");
const theme = @import("theme.zig");
const t_mod = @import("tests.zig");
const side = @import("view_side.zig");
const item_mod = @import("cleanup/item.zig");
const CacheItem = item_mod.CacheItem;
const Category = item_mod.Category;
const safety_mod = @import("cleanup/safety.zig");
const SafetyInfo = safety_mod.SafetyInfo;
const TrashManager = @import("cleanup/trash.zig").TrashManager;

fn addItem(a: *App, name: []const u8, where: []const u8, path: []const u8, size: u64, info: SafetyInfo, category: Category) !void {
    const item = try a.sampler.gpa.create(CacheItem);
    item.* = try CacheItem.init(a.sampler.gpa, path, name, info);
    item.category = category;
    try item.addLocation(path, size, 0, where);
    try a.cleanup_items.append(a.sampler.gpa, item);
}

/// One item for each tab: three app caches of known sizes (one of them Check
/// First), a project folder, a large file, and an app.
fn stage(a: *App) !void {
    try addItem(a, "Chrome cache", "Caches", "/tmp/nanomon-test/com.google.Chrome", 3 << 30, safety_mod.classifyCacheFolder("com.google.Chrome"), .cache);
    try addItem(a, "Some app cache", "Caches", "/tmp/nanomon-test/com.example.app", 2 << 30, safety_mod.classifyCacheFolder("com.example.app"), .cache);
    try addItem(a, "Homebrew cache", "Caches", "/tmp/nanomon-test/Homebrew", 1 << 30, safety_mod.classifyCacheFolder("Homebrew"), .cache);
    try addItem(a, "node_modules", "site", "/tmp/nanomon-test/site/node_modules", 4 << 30, SafetyInfo.safe("node_modules", "Installed dependencies."), .project);
    try addItem(a, "holiday.mov", "Movies", "/tmp/nanomon-test/Movies/holiday.mov", 5 << 30, SafetyInfo.checkFirst("Video", "A file of yours.", "It goes to the Trash."), .large);
    try addItem(a, "Thing", "Applications", "/tmp/nanomon-test/Applications/Thing.app", 6 << 30, SafetyInfo.checkFirst("Application", "The app and its files.", "Put it back from the Trash."), .app);
    a.refreshCleanupView();
}

test "the Cleanup page lists what was found, biggest first, and ticks rows" {
    // The order the page draws in, before any UI is involved.
    {
        const gpa = std.testing.allocator;
        var a: App = .init(gpa, std.testing.io);
        defer a.deinit();
        try t_mod.fake(&a);
        try stage(&a);
        // The App Caches tab holds the three caches, biggest first; the
        // project, the large file and the app belong to the other tabs.
        try std.testing.expectEqual(@as(usize, 3), a.cleanup_visible.items.len);
        try std.testing.expectEqualStrings("Chrome cache", a.cleanup_visible.items[0].app_name);
        try std.testing.expectEqualStrings("Some app cache", a.cleanup_visible.items[1].app_name);
        try std.testing.expectEqualStrings("Homebrew cache", a.cleanup_visible.items[2].app_name);
    }
    const gpa = std.testing.allocator;
    var a: App = .init(gpa, std.testing.io);
    defer a.deinit();
    try t_mod.fake(&a);
    try stage(&a);
    a.page = .cleanup;

    var t: ui.Tester = undefined;
    // Tall enough that the space card is on screen: it sits under the tiles.
    try t.init(gpa, .init(&a, view.view), .{ .width = 1100, .height = 760, .theme = theme.ui(false) });
    defer t.deinit();
    t.settle(2);

    // The header names the tab and counts what it found.
    try std.testing.expect(t.hasText("App Caches") and t.containsText("3 found"));
    try std.testing.expect(t.containsText("6.0 GB"));
    try std.testing.expect(t.hasText("Chrome cache"));
    // Other tabs' items stay out of this one.
    try std.testing.expect(!t.hasText("node_modules") and !t.hasText("holiday.mov"));
    // Biggest first.
    try std.testing.expect(t_mod.below(&t, "Chrome cache", "Some app cache"));
    // The safety of each row, in plain words.
    try std.testing.expect(t.hasText("Safe") and t.hasText("Check"));
    try std.testing.expect(t.hasText("App Cache"));
    try t.screenshot("/tmp/nanomon-cleanup.png");

    // Clicking a row ticks it, and the footer says what that is worth.
    const chrome = t.findText("Chrome cache").?;
    t.click(chrome.x + 10, chrome.y + chrome.h / 2);
    t.settle(1);
    try std.testing.expect(t.hasText("1 ticked"));
    try std.testing.expect(t.containsText("3.0 GB"));
    // The one ticked row explains itself.
    try std.testing.expect(t.containsText("Chrome rebuilds it"));
    try t.screenshot("/tmp/nanomon-cleanup-ticked.png");

    // Clicking it again lets go.
    t.click(chrome.x + 10, chrome.y + chrome.h / 2);
    t.settle(1);
    try std.testing.expect(!t.hasText("1 ticked"));

    // The header's box ticks everything the filter shows, then clears it.
    const header = t.findText("Name").?;
    t.click(side.width + 1 + 15, header.y + header.h / 2);
    t.settle(1);
    try std.testing.expectEqual(@as(usize, 3), a.cleanup_selected.count());
    try std.testing.expect(t.hasText("3 ticked"));
    t.click(side.width + 1 + 15, header.y + header.h / 2);
    t.settle(1);
    try std.testing.expectEqual(@as(usize, 0), a.cleanup_selected.count());
}

test "the Cleanup page sorts by a column and filters by safety" {
    const gpa = std.testing.allocator;
    var a: App = .init(gpa, std.testing.io);
    defer a.deinit();
    try t_mod.fake(&a);
    try stage(&a);
    a.page = .cleanup;

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, view.view), .{ .width = 1100, .height = 760, .theme = theme.ui(false) });
    defer t.deinit();
    t.settle(2);

    // By name, ascending, then flipped.
    try t_mod.open(&t, "Name");
    try std.testing.expect(t_mod.below(&t, "Chrome cache", "Homebrew cache"));
    try t_mod.open(&t, "Name");
    try std.testing.expect(t_mod.below(&t, "Some app cache", "Homebrew cache"));
    // By safety: the Check First row sinks below the safe ones.
    try t_mod.open(&t, "Safety");
    try std.testing.expect(t_mod.below(&t, "Homebrew cache", "Some app cache"));

    // The filter shows only the safe ones, then only the ones to check.
    try t_mod.open(&t, "Safe");
    try std.testing.expect(t.hasText("Chrome cache") and !t.hasText("Some app cache"));
    try std.testing.expect(t.containsText("2 of 3 shown"));
    try t_mod.open(&t, "Check First");
    try std.testing.expect(!t.hasText("Chrome cache") and t.hasText("Some app cache"));
    try t_mod.open(&t, "All");
    try std.testing.expect(t.hasText("Chrome cache") and t.hasText("Some app cache"));
}

test "the Cleanup sheet names what will move, and Cancel leaves it alone" {
    const gpa = std.testing.allocator;
    var a: App = .init(gpa, std.testing.io);
    defer a.deinit();
    try t_mod.fake(&a);
    try stage(&a);
    a.page = .cleanup;

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, view.view), .{ .width = 1100, .height = 760, .theme = theme.ui(false) });
    defer t.deinit();
    t.settle(2);

    const chrome = t.findText("Chrome cache").?;
    t.click(chrome.x + 10, chrome.y + chrome.h / 2);
    t.settle(1);
    try t_mod.open(&t, "Move to Trash…");
    try std.testing.expect(t.hasText("Move 1 item to the Trash?"));
    try std.testing.expect(t.containsText("comes back"));
    try t.screenshot("/tmp/nanomon-cleanup-sheet.png");

    try t_mod.open(&t, "Cancel");
    try std.testing.expect(!t.hasText("Move 1 item to the Trash?"));
    // Nothing was moved: the items are all still there.
    try std.testing.expectEqual(@as(usize, 6), a.cleanup_items.items.len);
    try std.testing.expectEqual(@as(usize, 1), a.cleanup_selected.count());
}

test "a size that is a floor is drawn as such" {
    const gpa = std.testing.allocator;
    var a: App = .init(gpa, std.testing.io);
    defer a.deinit();
    try t_mod.fake(&a);
    const item = try a.sampler.gpa.create(CacheItem);
    item.* = try CacheItem.init(a.sampler.gpa, "floor", "Huge cache", SafetyInfo.safe("Huge cache", "A big one."));
    try item.addLocationSized("/tmp/nanomon-test/huge", 4 << 30, 0, "Caches", true);
    try a.cleanup_items.append(a.sampler.gpa, item);
    a.refreshCleanupView();
    a.page = .cleanup;

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, view.view), .{ .width = 1100, .height = 760, .theme = theme.ui(false) });
    defer t.deinit();
    t.settle(1);
    try std.testing.expect(t.containsText("≈ 4.0 GB"));
    try std.testing.expect(t.containsText("≈ 4.0 GB") and t.containsText("1 found"));
}

test "a real scan runs on its own thread and fills the page" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fakeCache(tmp.dir, io, gpa);
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = home_buf[0..try tmp.dir.realPath(io, &home_buf)];

    var a: App = .init(gpa, io);
    defer a.deinit();
    try t_mod.fake(&a);
    a.cleanup_home = home;
    a.startCleanupScan();
    try std.testing.expect(a.cleanup_scanning);

    // Poll as the window would, until the worker says it is done.
    var spins: usize = 0;
    while (a.pollCleanupScan()) : (spins += 1) {
        if (spins > 200_000) return error.ScanTimedOut;
        std.Thread.yield() catch {};
    }
    try std.testing.expect(!a.cleanup_scanning);
    try std.testing.expect(!a.cleanup_scan_failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), a.cleanup_items.items.len);
    try std.testing.expectEqualStrings("com.google.Chrome", a.cleanup_items.items[0].app_name);
    try std.testing.expectEqual(@as(usize, 1), a.cleanup_visible.items.len);
    try std.testing.expectEqual(@as(u64, 2 << 20), a.cleanupVisibleBytes());
}

test "the page scans by itself the first time it is opened" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fakeCache(tmp.dir, io, gpa);
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = home_buf[0..try tmp.dir.realPath(io, &home_buf)];

    var a: App = .init(gpa, io);
    defer a.deinit();
    try t_mod.fake(&a);
    a.cleanup_auto = true;
    a.cleanup_home = home;
    a.page = .cleanup;
    try std.testing.expect(!a.cleanup_scanned);

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, view.view), .{ .width = 1100, .height = 760, .theme = theme.ui(false) });
    defer t.deinit();
    t.settle(1);
    // Drawing the page asked for a scan, with no button pressed.
    try std.testing.expect(a.cleanup_scanned);
    try std.testing.expect(a.cleanup_scanning or a.cleanup_items.items.len > 0);

    var spins: usize = 0;
    while (a.pollCleanupScan()) : (spins += 1) {
        if (spins > 200_000) return error.ScanTimedOut;
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), a.cleanup_items.items.len);
    t.settle(1);
    try std.testing.expect(t.hasText("com.google.Chrome") and t.containsText("1 found"));
}

fn fakeCache(home: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator) !void {
    try home.createDirPath(io, "Library/Caches/com.google.Chrome");
    const data = try gpa.alloc(u8, 2 << 20);
    defer gpa.free(data);
    @memset(data, 'x');
    try home.writeFile(io, .{ .sub_path = "Library/Caches/com.google.Chrome/f", .data = data });
}

test "the app removes on a worker, and the page waits for it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = home_buf[0..try tmp.dir.realPath(io, &home_buf)];

    // Two real caches in the fake home, and one whose folder has gone.
    try tmp.dir.createDirPath(io, "Library/Caches/com.google.Chrome");
    try tmp.dir.writeFile(io, .{ .sub_path = "Library/Caches/com.google.Chrome/f", .data = "cache" });
    try tmp.dir.createDirPath(io, "Library/Caches/Homebrew");
    try tmp.dir.writeFile(io, .{ .sub_path = "Library/Caches/Homebrew/f", .data = "cache" });
    const chrome = try std.fs.path.join(gpa, &.{ home, "Library/Caches/com.google.Chrome" });
    defer gpa.free(chrome);
    const brew = try std.fs.path.join(gpa, &.{ home, "Library/Caches/Homebrew" });
    defer gpa.free(brew);
    const gone = try std.fs.path.join(gpa, &.{ home, "Library/Caches/gone" });
    defer gpa.free(gone);

    var a: App = .init(gpa, io);
    defer a.deinit();
    try t_mod.fake(&a);
    // Removals go to the temporary trash, never the user's own.
    a.cleanup_trash_home = home;
    try addItem(&a, "Chrome cache", "Caches", chrome, 1024, safety_mod.classifyCacheFolder("com.google.Chrome"), .cache);
    try addItem(&a, "Homebrew cache", "Caches", brew, 1024, safety_mod.classifyCacheFolder("Homebrew"), .cache);
    try addItem(&a, "Gone cache", "Caches", gone, 1024, safety_mod.classifyCacheFolder("com.example.app"), .cache);
    a.refreshCleanupView();
    a.cleanupToggle(findItem(&a, "Chrome cache").?);
    a.cleanupToggle(findItem(&a, "Homebrew cache").?);

    a.cleanupDeleteSelected();
    try std.testing.expect(a.cleanup_removing);
    // The page keeps drawing while the worker works: poll as the window does.
    var spins: usize = 0;
    while (a.pollCleanupRemoval()) : (spins += 1) {
        if (spins > 200_000) return error.RemovalTimedOut;
        std.Thread.yield() catch {};
    }
    try std.testing.expect(!a.cleanup_removing);

    // The two went; the one that could not stays, and the notice says so.
    try std.testing.expectEqual(@as(usize, 1), a.cleanup_items.items.len);
    try std.testing.expectEqualStrings("Gone cache", a.cleanup_items.items[0].app_name);
    try std.testing.expectEqual(@as(usize, 0), a.cleanup_selected.count());
    try std.testing.expect(a.cleanup_notice != null);
    try std.testing.expect(std.mem.indexOf(u8, a.cleanup_notice.?, "Moved 2") != null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, chrome, .{}));
    const in_trash = try std.fs.path.join(gpa, &.{ home, ".Trash", "com.google.Chrome" });
    defer gpa.free(in_trash);
    _ = try std.Io.Dir.cwd().statFile(io, in_trash, .{});
}

test "the Overview page says where the space went, and removes nothing" {
    const gpa = std.testing.allocator;
    var a: App = .init(gpa, std.testing.io);
    defer a.deinit();
    try t_mod.fake(&a);
    a.cleanup_volume = .{ .total = 100 << 30, .used = 40 << 30, .free = 60 << 30 };
    try stage(&a);
    // The read-only folder rows the disk map contributes.
    try addSpec(&a, .{ .name = "Documents", .path = "/tmp/nanomon-test/Documents", .size = 8 << 30, .category = .other, .removal = .none, .headline = "Folder", .where = "Home" });
    try addSpec(&a, .{ .name = "System and other", .path = "/", .size = 22 << 30, .category = .other, .removal = .none, .headline = "System and other", .where = "Disk" });
    a.refreshCleanupView();
    // The top-level Overview carries the space card; Cleanup has no Overview
    // tab of its own.
    a.page = .overview;

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, view.view), .{ .width = 1100, .height = 1500, .theme = theme.ui(false) });
    defer t.deinit();
    t.settle(1);

    // The machine's own tiles are still there, with the disk's figures and
    // what the scan found, tab by tab.
    try std.testing.expect(t.hasText("Busiest Now") and t.hasText("This Mac"));
    try std.testing.expect(t.containsText("Used 40.0 GB of 100.0 GB") and t.containsText("60.0 GB free"));
    try std.testing.expect(t.hasText("Space") and t.hasText("What Cleanup found") and t.hasText("Your folders"));
    try std.testing.expect(t.hasText("Documents") and t.hasText("System and other"));
    try std.testing.expect(t.containsText("Nothing here moves a file"));
    try t.screenshot("/tmp/nanomon-cleanup-overview.png");

    // The Cleanup section lists its four tabs.
    try std.testing.expect(t.hasText("App Caches") and t.hasText("App Uninstaller"));

    // Nothing here is tickable: a click on a folder row selects nothing.
    const documents = t.findText("Documents").?;
    t.click(documents.x + 10, documents.y + documents.h / 2);
    t.settle(1);
    try std.testing.expectEqual(@as(usize, 0), a.cleanup_selected.count());

    // A Cleanup row in the card opens that tab.
    const caches = t.findText("3 · 6.0 GB").?;
    t.click(caches.x + caches.w / 2, caches.y + caches.h / 2);
    t.settle(1);
    try std.testing.expectEqual(app_mod.Page.cleanup, a.page);
    try std.testing.expectEqual(app_mod.CleanupTab.caches, a.cleanup_tab);
    try std.testing.expect(t.hasText("Chrome cache"));
}

fn findItem(a: *App, name: []const u8) ?*CacheItem {
    for (a.cleanup_items.items) |item| {
        if (std.mem.eql(u8, item.app_name, name)) return item;
    }
    return null;
}

/// An item of any kind, for the tests that are about the page rather than
/// the scan.
const Spec = struct {
    name: []const u8,
    path: []const u8,
    size: u64,
    category: Category,
    where: []const u8 = "",
    removal: item_mod.Removal = .trash,
    target: ?[]const u8 = null,
    headline: []const u8 = "Thing",
    /// True when nothing can know the size (a Time Machine snapshot).
    unknown_size: bool = false,
};

fn addSpec(a: *App, spec: Spec) !void {
    const item = try CacheItem.create(a.sampler.gpa, .{
        .id = spec.path,
        .name = spec.name,
        .info = SafetyInfo.checkFirst(spec.headline, "A thing.", "Put it back from the Trash."),
        .category = spec.category,
        .path = spec.path,
        .where = spec.where,
        .size = spec.size,
        .sized = spec.size > 0,
        .unknown_size = spec.unknown_size,
        .removal = spec.removal,
        .target = spec.target,
    });
    try a.cleanup_items.append(a.sampler.gpa, item);
}

test "the sidebar's Cleanup tabs switch what the page shows" {
    const gpa = std.testing.allocator;
    var a: App = .init(gpa, std.testing.io);
    defer a.deinit();
    try t_mod.fake(&a);
    try stage(&a);
    a.page = .cleanup;

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, view.view), .{ .width = 1100, .height = 760, .theme = theme.ui(false) });
    defer t.deinit();
    t.settle(2);

    // All four tabs are in the sidebar, under their own heading, before System.
    try std.testing.expect(t.hasText("Cleanup"));
    try std.testing.expect(t_mod.below(&t, "Cleanup", "App Caches"));
    try std.testing.expect(t_mod.below(&t, "App Uninstaller", "System"));
    // The App Caches tab is the one shown first.
    try std.testing.expect(t.hasText("App Caches") and t.hasText("Chrome cache"));

    // Dev Tools: the project folder, and none of the caches.
    try t_mod.open(&t, "Dev Tools");
    try std.testing.expect(t.hasText("node_modules") and !t.hasText("Chrome cache"));
    try std.testing.expect(t.containsText("4.0 GB"));

    // Large Files: the file, with its kind.
    try t_mod.open(&t, "Large Files");
    try std.testing.expect(t.hasText("holiday.mov") and t.hasText("Video"));
    try std.testing.expect(t.containsText("5.0 GB"));
    try t.screenshot("/tmp/nanomon-cleanup-large.png");

    // App Uninstaller: the app, and Uninstall… rather than Move to Trash….
    try t_mod.open(&t, "App Uninstaller");
    try std.testing.expect(t.hasText("Thing") and t.hasText("Application"));
    try std.testing.expect(t.containsText("6.0 GB"));
    const app = t.findText("Thing").?;
    t.click(app.x + 10, app.y + app.h / 2);
    t.settle(1);
    // A plain app goes to the Trash, so that is what the button says.
    try t_mod.open(&t, "Move to Trash…");
    try std.testing.expect(t.hasText("Move 1 app to the Trash?"));
    try t.screenshot("/tmp/nanomon-cleanup-uninstall.png");
    try t_mod.open(&t, "Cancel");

    // Back to the caches, with the tick cleared by the tab change? It is not:
    // the tick follows the item, not the page.
    try t_mod.open(&t, "App Caches");
    try std.testing.expect(t.hasText("Chrome cache") and !t.hasText("holiday.mov"));
}

test "each kind of item says how it goes, and warns when it is for good" {
    const gpa = std.testing.allocator;
    var a: App = .init(gpa, std.testing.io);
    defer a.deinit();
    try t_mod.fake(&a);
    // A simulator, a Homebrew tool and a snapshot: none of them goes to the
    // Trash, so the page says so before anything happens.
    try addSpec(&a, .{ .name = "iPhone 17 (iOS 26.5)", .where = "CoreSimulator", .path = "/tmp/nanomon-test/device", .size = 2 << 30, .category = .simulator, .removal = .simctl_device, .target = "UDID-1", .headline = "Simulator" });
    try addSpec(&a, .{ .name = "jq", .where = "Cellar", .path = "/tmp/nanomon-test/jq", .size = 1 << 20, .category = .brew, .removal = .brew_formula, .target = "jq", .headline = "Homebrew tool" });
    try addSpec(&a, .{ .name = "Snapshot 2026-11-12-120000", .where = "Time Machine", .path = "/2026-11-12-120000", .size = 0, .category = .junk, .removal = .tm_snapshot, .target = "2026-11-12-120000", .headline = "Time Machine snapshot", .unknown_size = true });
    a.refreshCleanupView();
    a.cleanupSetTab(.dev);
    a.page = .cleanup;

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, view.view), .{ .width = 1100, .height = 760, .theme = theme.ui(false) });
    defer t.deinit();
    t.settle(1);

    // Dev Tools: the simulator and the Homebrew tool, each named for what it
    // is, with the simulator's size.
    try std.testing.expect(t.hasText("Simulator") and t.hasText("Homebrew tool"));
    try std.testing.expect(t.containsText("2.0 GB"));

    // App Caches: the snapshot, whose size tmutil does not report, so it
    // reads as a dash rather than a made-up number.
    try t_mod.open(&t, "App Caches");
    try std.testing.expect(t.hasText("Time Machine snapshot") and t.hasText("—"));
    try t_mod.open(&t, "Dev Tools");

    // Ticking the simulator offers Delete…, and the sheet says it is for good.
    const device = t.findText("iPhone 17 (iOS 26.5)").?;
    t.click(device.x + 10, device.y + device.h / 2);
    t.settle(1);
    try t_mod.open(&t, "Delete…");
    try std.testing.expect(t.hasText("Delete 1 item?"));
    try std.testing.expect(t.containsText("removed for good"));
    try t.screenshot("/tmp/nanomon-cleanup-removal.png");
    try t_mod.open(&t, "Cancel");
    try std.testing.expectEqual(@as(usize, 3), a.cleanup_items.items.len);
}

test "ticked items move to the Trash, and the ones that cannot stay" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = home_buf[0..try tmp.dir.realPath(io, &home_buf)];

    // Two real caches in the fake home…
    try tmp.dir.createDirPath(io, "Library/Caches/com.google.Chrome");
    try tmp.dir.writeFile(io, .{ .sub_path = "Library/Caches/com.google.Chrome/f", .data = "cache" });
    try tmp.dir.createDirPath(io, "Library/Caches/Homebrew");
    try tmp.dir.writeFile(io, .{ .sub_path = "Library/Caches/Homebrew/f", .data = "cache" });
    // …and one item whose folder has already gone.
    const chrome = try std.fs.path.join(gpa, &.{ home, "Library/Caches/com.google.Chrome" });
    defer gpa.free(chrome);
    const brew = try std.fs.path.join(gpa, &.{ home, "Library/Caches/Homebrew" });
    defer gpa.free(brew);
    const gone = try std.fs.path.join(gpa, &.{ home, "Library/Caches/gone" });
    defer gpa.free(gone);

    var a: App = .init(gpa, io);
    defer a.deinit();
    try t_mod.fake(&a);
    try addItem(&a, "Chrome cache", "Caches", chrome, 1024, safety_mod.classifyCacheFolder("com.google.Chrome"), .cache);
    try addItem(&a, "Homebrew cache", "Caches", brew, 1024, safety_mod.classifyCacheFolder("Homebrew"), .cache);
    try addItem(&a, "Gone cache", "Caches", gone, 1024, safety_mod.classifyCacheFolder("com.example.app"), .cache);
    a.refreshCleanupView();

    a.cleanupToggle(findItem(&a, "Chrome cache").?);
    a.cleanupToggle(findItem(&a, "Homebrew cache").?);
    a.cleanupToggle(findItem(&a, "Gone cache").?);
    try std.testing.expectEqual(@as(usize, 3), a.cleanup_selected.count());

    var trash = try TrashManager.initAt(gpa, io, home);
    defer trash.deinit();
    a.cleanupDeleteNow(&trash);

    // The two moved; the one that could not stays, and the notice says so.
    try std.testing.expectEqual(@as(usize, 1), a.cleanup_items.items.len);
    try std.testing.expectEqualStrings("Gone cache", a.cleanup_items.items[0].app_name);
    // What could not be moved stays ticked, ready to try again.
    try std.testing.expectEqual(@as(usize, 1), a.cleanup_selected.count());
    try std.testing.expect(a.cleanupIsSelected(a.cleanup_items.items[0]));
    const notice = a.cleanup_notice orelse return error.NoNotice;
    try std.testing.expect(std.mem.indexOf(u8, notice, "Freed") != null);
    try std.testing.expect(std.mem.indexOf(u8, notice, "1 of 3 could not be removed") != null);

    // Gone from where they were, and in the trash.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, chrome, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, brew, .{}));
    const in_trash = try std.fs.path.join(gpa, &.{ trash.files, "com.google.Chrome" });
    defer gpa.free(in_trash);
    _ = try std.Io.Dir.cwd().statFile(io, in_trash, .{});
}
