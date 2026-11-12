//! What Homebrew installed: the casks, which are apps, and the formulae,
//! which are command-line tools. Homebrew removes them for good — they do not
//! go to the Trash — so every row says so before it is removed.
const std = @import("std");
const item_mod = @import("item.zig");
const CacheItem = item_mod.CacheItem;
const safety = @import("safety.zig");
const exec = @import("exec.zig");
const remove = @import("remove.zig");

pub const Options = struct {
    max_casks: usize = 120,
    max_formulae: usize = 120,
};

/// The casks, as app rows: the .app Homebrew put in Applications.
pub fn scanCasks(allocator: std.mem.Allocator, io: std.Io, opts: Options) !std.ArrayListUnmanaged(*CacheItem) {
    var items = std.ArrayListUnmanaged(*CacheItem).empty;
    errdefer discard(allocator, &items);
    const brew = remove.brewPath() orelse return items;

    const listed = exec.run(allocator, &.{ brew, "list", "--cask" }) catch return items;
    defer allocator.free(listed);
    var tokens: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (tokens.items) |token| allocator.free(token);
        tokens.deinit(allocator);
    }
    var lines = std.mem.tokenizeScalar(u8, listed, '\n');
    while (lines.next()) |line| {
        const token = std.mem.trim(u8, line, " \t\r");
        if (token.len == 0) continue;
        // A cask from someone else's tap (`user/tap/thing`) is refused by
        // brew until the tap is trusted, and asking about one fails the whole
        // call, so they are left to their owner.
        if (std.mem.indexOfScalar(u8, token, '/') != null) continue;
        try tokens.append(allocator, try allocator.dupe(u8, token));
    }
    if (tokens.items.len == 0) return items;

    // A few at a time: brew info takes many names at once, and a chunk that
    // fails does not take the rest of the list with it.
    const chunk = 20;
    // brew is a Ruby program: each call costs about half a second, so the
    // retry rounds are given a budget rather than run to the last name.
    const began = std.Io.Clock.now(.awake, io).nanoseconds;
    const budget_ns: i96 = 4 * std.time.ns_per_s;
    var start: usize = 0;
    var refused: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (refused.items) |name| allocator.free(name);
        refused.deinit(allocator);
    }
    while (start < tokens.items.len and items.items.len < opts.max_casks) : (start += chunk) {
        const end = @min(start + chunk, tokens.items.len);
        const slice = tokens.items[start..end];
        // One bad cask (an untrusted tap, a broken install) makes brew refuse
        // the whole call. It names them, so ask again without them, until it
        // answers or stops naming anyone new.
        var remaining: std.ArrayListUnmanaged([]const u8) = .empty;
        defer remaining.deinit(allocator);
        try remaining.appendSlice(allocator, slice);
        var attempt: usize = 0;
        while (attempt < 5 and remaining.items.len > 0) : (attempt += 1) {
            if (attempt > 0 and std.Io.Clock.now(.awake, io).nanoseconds - began > budget_ns) break;
            const known = refused.items.len;
            if (try addCasks(allocator, brew, remaining.items, opts, &items, &refused)) break;
            if (refused.items.len == known) break;
            var keep: std.ArrayListUnmanaged([]const u8) = .empty;
            defer keep.deinit(allocator);
            for (remaining.items) |token| {
                if (!isRefused(refused.items, token)) try keep.append(allocator, token);
            }
            remaining.clearRetainingCapacity();
            try remaining.appendSlice(allocator, keep.items);
        }
    }
    return items;
}

/// Ask brew about a handful of casks; false when it would not answer.
fn addCasks(
    allocator: std.mem.Allocator,
    brew: []const u8,
    tokens: []const []const u8,
    opts: Options,
    items: *std.ArrayListUnmanaged(*CacheItem),
    refused: *std.ArrayListUnmanaged([]const u8),
) !bool {
    if (tokens.len == 0) return true;
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ brew, "info", "--cask", "--json=v2" });
    try argv.appendSlice(allocator, tokens);

    const answer = exec.runOk(allocator, argv.items) catch return false;
    defer allocator.free(answer.out);
    if (!answer.ok) {
        try noteRefused(allocator, answer.out, refused);
        return false;
    }
    if (answer.out.len == 0) return false;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, exec.jsonSlice(answer.out), .{}) catch return false;
    defer parsed.deinit();

    const casks = parsed.value.object.get("casks") orelse return false;
    for (casks.array.items) |entry| {
        if (items.items.len >= opts.max_casks) break;
        const object = entry.object;
        const token = stringOf(object.get("token")) orelse continue;
        const bundle = appTarget(object) orelse continue;
        if (!exists(bundle)) continue;
        const name = std.fs.path.basename(bundle);
        const display = if (std.mem.endsWith(u8, name, ".app")) name[0 .. name.len - 4] else name;

        const label = try allocator.dupe(u8, display);
        defer allocator.free(label);
        const id = try std.fmt.allocPrint(allocator, "brew-cask:{s}", .{token});
        defer allocator.free(id);
        // The item keeps its own copy of these.
        const explanation = try std.fmt.allocPrint(allocator, "Installed by Homebrew. `brew uninstall --cask {s}` removes the app and its files for good — it does not go to the Trash.", .{token});
        defer allocator.free(explanation);
        const reinstall = try std.fmt.allocPrint(allocator, "brew install --cask {s}", .{token});
        defer allocator.free(reinstall);

        const item = try CacheItem.create(allocator, .{
            .id = id,
            .name = label,
            .info = .{
                .level = .medium,
                .headline = "Homebrew app",
                .explanation = explanation,
                .recovery_steps = reinstall,
                .reinstall_command = reinstall,
            },
            .category = .app,
            .path = bundle,
            .where = "Applications",
            .removal = .brew_cask,
            .target = token,
        });
        try items.append(allocator, item);
    }
    return true;
}

/// The casks brew refused to load, from its own words:
/// `Refusing to load cask <name> from untrusted tap <tap>.`
fn noteRefused(allocator: std.mem.Allocator, output: []const u8, refused: *std.ArrayListUnmanaged([]const u8)) !void {
    const marker = "Refusing to load cask ";
    var rest = output;
    while (std.mem.indexOf(u8, rest, marker)) |at| {
        rest = rest[at + marker.len ..];
        const end = std.mem.indexOfAny(u8, rest, " \n") orelse rest.len;
        const full = rest[0..end];
        const name = std.fs.path.basename(full);
        if (name.len == 0) continue;
        var known = false;
        for (refused.items) |existing| {
            if (std.mem.eql(u8, existing, name)) known = true;
        }
        if (!known) try refused.append(allocator, try allocator.dupe(u8, name));
    }
}

fn isRefused(refused: []const []const u8, token: []const u8) bool {
    for (refused) |name| {
        if (std.mem.eql(u8, name, token)) return true;
    }
    return false;
}

/// The formulae, as command-line tools. Their size is their Cellar folder,
/// measured with everything else.
pub fn scanFormulae(allocator: std.mem.Allocator, io: std.Io, opts: Options) !std.ArrayListUnmanaged(*CacheItem) {
    var items = std.ArrayListUnmanaged(*CacheItem).empty;
    errdefer discard(allocator, &items);
    const brew = remove.brewPath() orelse return items;

    const cellar = try cellarOf(allocator, brew);
    defer allocator.free(cellar);

    const listed = exec.run(allocator, &.{ brew, "list", "--formula" }) catch return items;
    defer allocator.free(listed);

    var lines = std.mem.tokenizeScalar(u8, listed, '\n');
    while (lines.next()) |line| {
        if (items.items.len >= opts.max_formulae) break;
        const name = std.mem.trim(u8, line, " \t\r");
        if (name.len == 0) continue;
        const path = try std.fs.path.join(allocator, &.{ cellar, name });
        defer allocator.free(path);
        if (!isDir(io, path)) continue;

        const id = try std.fmt.allocPrint(allocator, "brew-formula:{s}", .{name});
        defer allocator.free(id);
        const explanation = try std.fmt.allocPrint(allocator, "A command-line tool Homebrew installed. `brew uninstall {s}` removes it for good — it does not go to the Trash.", .{name});
        defer allocator.free(explanation);
        const reinstall = try std.fmt.allocPrint(allocator, "brew install {s}", .{name});
        defer allocator.free(reinstall);
        try items.append(allocator, try CacheItem.create(allocator, .{
            .id = id,
            .name = name,
            .info = .{
                .level = .medium,
                .headline = "Homebrew tool",
                .explanation = explanation,
                .recovery_steps = reinstall,
                .reinstall_command = reinstall,
            },
            .category = .brew,
            .path = path,
            .where = "Cellar",
            .removal = .brew_formula,
            .target = name,
        }));
    }
    return items;
}

/// Homebrew's Cellar: the folder each formula keeps its files in.
fn cellarOf(allocator: std.mem.Allocator, brew: []const u8) ![]u8 {
    const prefix = std.fs.path.dirname(std.fs.path.dirname(brew) orelse "/opt/homebrew") orelse "/opt/homebrew";
    return std.fs.path.join(allocator, &.{ prefix, "Cellar" });
}

/// The .app a cask installs, from its artifacts.
fn appTarget(cask: std.json.ObjectMap) ?[]const u8 {
    const artifacts = cask.get("artifacts") orelse return null;
    for (artifacts.array.items) |artifact| {
        const object = switch (artifact) {
            .object => |o| o,
            else => continue,
        };
        const target = stringOf(object.get("target")) orelse continue;
        if (std.mem.endsWith(u8, target, ".app")) return target;
    }
    return null;
}

fn stringOf(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

fn exists(path: []const u8) bool {
    const copy = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return false;
    defer std.heap.page_allocator.free(copy);
    @memcpy(copy, path);
    return access(copy.ptr, 0) == 0;
}

fn isDir(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

fn discard(allocator: std.mem.Allocator, items: *std.ArrayListUnmanaged(*CacheItem)) void {
    for (items.items) |item| {
        item.deinit();
        allocator.destroy(item);
    }
    items.deinit(allocator);
}

test "the Cellar sits beside the brew that lives in it" {
    const allocator = std.testing.allocator;
    const arm = try cellarOf(allocator, "/opt/homebrew/bin/brew");
    defer allocator.free(arm);
    try std.testing.expectEqualStrings("/opt/homebrew/Cellar", arm);
    const intel = try cellarOf(allocator, "/usr/local/bin/brew");
    defer allocator.free(intel);
    try std.testing.expectEqualStrings("/usr/local/Cellar", intel);
}

test "casks are apps Homebrew put in Applications" {
    const allocator = std.testing.allocator;
    if (remove.brewPath() == null) return error.SkipZigTest;
    var items = try scanCasks(allocator, std.testing.io, .{});
    defer discard(allocator, &items);
    for (items.items) |item| {
        try std.testing.expectEqual(item_mod.Category.app, item.category);
        try std.testing.expectEqual(item_mod.Removal.brew_cask, item.removal);
        try std.testing.expect(std.mem.endsWith(u8, item.primaryPath(), ".app"));
    }
}
