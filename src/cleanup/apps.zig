//! Installed apps, and what they leave behind. One row per app: the bundle in
//! Applications, plus every folder the app keeps in the user's Library, so a
//! single move to the Trash takes all of it. Apple's own apps are never
//! offered — they are part of the system, not installed software.
const std = @import("std");
const builtin = @import("builtin");
const item_mod = @import("item.zig");
const CacheItem = item_mod.CacheItem;
const safety = @import("safety.zig");
const exec = @import("exec.zig");

pub const Options = struct {
    home: []const u8,
    /// Where the apps live. The tests point this at a folder of their own.
    roots: []const []const u8 = &.{"/Applications"},
    max_items: usize = 400,
    /// Where each app's row goes the moment it is made, so the page fills in
    /// while the scan carries on. The scanner measures it and hands it on;
    /// null keeps it here, for the pass to return.
    batch: ?item_mod.Batch = null,
};

pub fn scan(allocator: std.mem.Allocator, io: std.Io, opts: Options) !std.ArrayListUnmanaged(*CacheItem) {
    var items = std.ArrayListUnmanaged(*CacheItem).empty;
    errdefer {
        for (items.items) |item| {
            item.deinit();
            allocator.destroy(item);
        }
        items.deinit(allocator);
    }
    var found: usize = 0;
    for (opts.roots) |root| {
        if (found >= opts.max_items) break;
        found += try scanRoot(allocator, io, opts, &items, root, opts.max_items - found);
    }
    return items;
}

/// One Applications folder, up to `budget` apps; how many it added.
fn scanRoot(allocator: std.mem.Allocator, io: std.Io, opts: Options, items: *std.ArrayListUnmanaged(*CacheItem), root: []const u8, budget: usize) !usize {
    // "/Applications" stands on its own; the tests' roots are under their home.
    const full_root = if (std.fs.path.isAbsolute(root))
        try allocator.dupe(u8, root)
    else
        try std.fs.path.join(allocator, &.{ opts.home, root });
    defer allocator.free(full_root);

    var dir = std.Io.Dir.cwd().openDir(io, full_root, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var found: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (found >= budget) return found;
        if (entry.kind != .directory) continue;
        if (!std.mem.endsWith(u8, entry.name, ".app")) continue;
        if (safety.isProtectedPath(entry.name)) continue;

        const bundle = try std.fs.path.join(allocator, &.{ full_root, entry.name });
        defer allocator.free(bundle);
        const name = entry.name[0 .. entry.name.len - ".app".len];
        if (name.len == 0) continue;

        const id = bundleID(allocator, io, bundle);
        defer if (id) |value| allocator.free(value);
        // Apple's apps belong to the system; removing one is not a cleanup.
        if (id) |value| if (isAppleID(value)) continue;

        try addApp(allocator, io, opts, items, bundle, name, id);
        found += 1;
        // The row is complete: it can be measured and shown without waiting
        // for the rest of Applications.
        if (opts.batch) |b| b.give(b.ctx, .app, items);
    }
    return found;
}

fn addApp(allocator: std.mem.Allocator, io: std.Io, opts: Options, items: *std.ArrayListUnmanaged(*CacheItem), bundle: []const u8, name: []const u8, id: ?[]const u8) !void {
    const info = safety.SafetyInfo.checkFirst(
        "Application",
        "The app itself, and the folders it keeps in your Library. Everything moves to the Trash, so the app can be put back from there.",
        "Drag the app back out of the Trash to use it again; its settings come back with it.",
    );
    const item_id = try std.fmt.allocPrint(allocator, "app:{s}", .{bundle});
    defer allocator.free(item_id);

    const item = try allocator.create(CacheItem);
    errdefer allocator.destroy(item);
    item.* = try CacheItem.init(allocator, item_id, name, info);
    errdefer item.deinit();
    item.category = .app;
    // The bundle is the primary location, and the one that needs the app
    // rule when it is moved (it lives in /Applications).
    try item.addLocationSized(bundle, 0, 0, std.fs.path.basename(std.fs.path.dirname(bundle) orelse ""), false);
    item.locations.items[item.locations.items.len - 1].app_bundle = true;

    // What the app left in the user's Library, matched by its identifier and,
    // for apps whose identifier we could not read, by its name.
    const related = try relatedPaths(allocator, io, opts.home, name, id);
    defer {
        for (related) |path| allocator.free(path);
        allocator.free(related);
    }
    for (related) |path| {
        try item.addLocationSized(path, 0, 0, "Library", false);
    }
    try items.append(allocator, item);
}

fn isAppleID(id: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(id, "com.apple.");
}

/// The app's identifier, from its Info.plist. Binary plists are read through
/// `plutil`, which knows every format macOS writes.
fn bundleID(allocator: std.mem.Allocator, io: std.Io, bundle: []const u8) ?[]u8 {
    const plist = std.fs.path.join(allocator, &.{ bundle, "Contents", "Info.plist" }) catch return null;
    defer allocator.free(plist);

    const data = std.Io.Dir.cwd().readFileAlloc(io, plist, allocator, .limited(4 << 20)) catch return null;
    defer allocator.free(data);

    if (std.mem.startsWith(u8, data, "bplist")) {
        if (comptime builtin.os.tag == .windows) return null;
        const out = exec.run(allocator, &.{ "/usr/bin/plutil", "-extract", "CFBundleIdentifier", "raw", "-o", "-", plist }) catch return null;
        defer allocator.free(out);
        return trimID(allocator, out);
    }
    return idFromXml(allocator, data);
}

/// `<key>CFBundleIdentifier</key><string>…</string>` in an XML plist.
fn idFromXml(allocator: std.mem.Allocator, data: []const u8) ?[]u8 {
    const key = "<key>CFBundleIdentifier</key>";
    const at = std.mem.indexOf(u8, data, key) orelse return null;
    const rest = data[at + key.len ..];
    const open = std.mem.indexOf(u8, rest, "<string>") orelse return null;
    const after = rest[open + "<string>".len ..];
    const close = std.mem.indexOf(u8, after, "</string>") orelse return null;
    return trimID(allocator, after[0..close]);
}

fn trimID(allocator: std.mem.Allocator, raw: []const u8) ?[]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 255) return null;
    for (trimmed) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '-' and ch != '_') return null;
    }
    return allocator.dupe(u8, trimmed) catch null;
}

/// The folders an app keeps in the user's Library, by identifier and by name,
/// keeping only the ones that are really there.
fn relatedPaths(allocator: std.mem.Allocator, io: std.Io, home: []const u8, name: []const u8, id: ?[]const u8) ![]const []const u8 {
    var candidates: std.ArrayListUnmanaged([]const u8) = .empty;
    defer candidates.deinit(allocator);

    const key = id orelse name;
    const by_name = id != null and !std.mem.eql(u8, key, name);
    const shapes = [_]struct { dir: []const u8, suffix: []const u8 }{
        .{ .dir = "Library/Application Support", .suffix = "" },
        .{ .dir = "Library/Caches", .suffix = "" },
        .{ .dir = "Library/Logs", .suffix = "" },
        .{ .dir = "Library/Preferences", .suffix = ".plist" },
        .{ .dir = "Library/Saved Application State", .suffix = ".savedState" },
        .{ .dir = "Library/Containers", .suffix = "" },
        .{ .dir = "Library/HTTPStorages", .suffix = "" },
        .{ .dir = "Library/WebKit", .suffix = "" },
        .{ .dir = "Library/Cookies", .suffix = ".binarycookies" },
        .{ .dir = "Library/LaunchAgents", .suffix = ".plist" },
        .{ .dir = "Library/Application Scripts", .suffix = "" },
    };

    for (shapes) |shape| {
        for ([_]struct { key: []const u8, use: bool }{
            .{ .key = key, .use = true },
            .{ .key = name, .use = by_name },
        }) |candidate| {
            if (!candidate.use) continue;
            const leaf = if (shape.suffix.len == 0)
                try allocator.dupe(u8, candidate.key)
            else
                try std.fmt.allocPrint(allocator, "{s}{s}", .{ candidate.key, shape.suffix });
            defer allocator.free(leaf);
            const path = try std.fs.path.join(allocator, &.{ home, shape.dir, leaf });
            _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
                allocator.free(path);
                continue;
            };
            try candidates.append(allocator, path);
        }
    }
    return candidates.toOwnedSlice(allocator);
}

/// Build a small app bundle for the tests: a name, an identifier and a size.
pub fn fakeApp(allocator: std.mem.Allocator, dir: std.Io.Dir, io: std.Io, root: []const u8, name: []const u8, id: []const u8, size: usize) !void {
    const rel = try std.fmt.allocPrint(allocator, "{s}/{s}.app/Contents", .{ root, name });
    defer allocator.free(rel);
    try dir.createDirPath(io, rel);
    const plist = try std.fmt.allocPrint(allocator, "{s}/{s}.app/Contents/Info.plist", .{ root, name });
    defer allocator.free(plist);
    const body = try std.fmt.allocPrint(allocator, "<?xml version=\"1.0\"?>\n<plist version=\"1.0\"><dict>\n<key>CFBundleIdentifier</key>\n<string>{s}</string>\n</dict></plist>\n", .{id});
    defer allocator.free(body);
    try dir.writeFile(io, .{ .sub_path = plist, .data = body });

    const payload = try std.fmt.allocPrint(allocator, "{s}/{s}.app/Contents/MacOS", .{ root, name });
    defer allocator.free(payload);
    try dir.createDirPath(io, payload);
    const binary = try std.fmt.allocPrint(allocator, "{s}/binary", .{payload});
    defer allocator.free(binary);
    const data = try allocator.alloc(u8, size);
    defer allocator.free(data);
    @memset(data, 'x');
    try dir.writeFile(io, .{ .sub_path = binary, .data = data });
}

test "an app's identifier is read from its plist" {
    const allocator = std.testing.allocator;
    const id = idFromXml(allocator, "<dict><key>CFBundleIdentifier</key>\n<string>com.example.thing</string></dict>").?;
    defer allocator.free(id);
    try std.testing.expectEqualStrings("com.example.thing", id);
    try std.testing.expect(idFromXml(allocator, "<dict></dict>") == null);
    const bad = trimID(allocator, "  com.example.a/b  ");
    try std.testing.expect(bad == null);
    const good = trimID(allocator, "\ncom.example.app\n").?;
    defer allocator.free(good);
    try std.testing.expectEqualStrings("com.example.app", good);
}

test "apps are found with what they left in the Library, and Apple's are not" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];

    try fakeApp(allocator, tmp.dir, io, "Applications", "Thing", "com.example.thing", 2 << 20);
    try fakeApp(allocator, tmp.dir, io, "Applications", "Safari", "com.apple.Safari", 2 << 20);
    try tmp.dir.createDirPath(io, "Library/Application Support/com.example.thing");
    try tmp.dir.writeFile(io, .{ .sub_path = "Library/Application Support/com.example.thing/data", .data = "data" });
    try tmp.dir.createDirPath(io, "Library/Preferences");
    try tmp.dir.writeFile(io, .{ .sub_path = "Library/Preferences/com.example.thing.plist", .data = "plist" });
    try tmp.dir.createDirPath(io, "Library/Application Support/Thing");

    var items = try scan(allocator, io, .{ .home = home, .roots = &.{"Applications"} });
    defer {
        for (items.items) |item| {
            item.deinit();
            allocator.destroy(item);
        }
        items.deinit(allocator);
    }

    // Only the third-party app, with the bundle first and its Library files after.
    try std.testing.expectEqual(@as(usize, 1), items.items.len);
    const item = items.items[0];
    try std.testing.expectEqualStrings("Thing", item.app_name);
    try std.testing.expectEqual(item_mod.Category.app, item.category);
    try std.testing.expect(item.locations.items.len >= 4);
    try std.testing.expect(item.locations.items[0].app_bundle);
    try std.testing.expect(std.mem.endsWith(u8, item.primaryPath(), "Applications/Thing.app"));
    var saw_support = false;
    var saw_prefs = false;
    for (item.locations.items[1..]) |loc| {
        if (std.mem.endsWith(u8, loc.path, "Application Support/com.example.thing")) saw_support = true;
        if (std.mem.endsWith(u8, loc.path, "Preferences/com.example.thing.plist")) saw_prefs = true;
    }
    try std.testing.expect(saw_support and saw_prefs);
}
