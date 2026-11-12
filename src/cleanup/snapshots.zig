//! Time Machine's local snapshots: the space macOS holds between backups.
//! Deleting one is for good, and the next backup simply starts again.
const std = @import("std");
const item_mod = @import("item.zig");
const CacheItem = item_mod.CacheItem;
const safety = @import("safety.zig");
const exec = @import("exec.zig");

pub const Options = struct {
    max_items: usize = 40,
};

pub fn scan(allocator: std.mem.Allocator, io: std.Io, opts: Options) !std.ArrayListUnmanaged(*CacheItem) {
    _ = io;
    var items = std.ArrayListUnmanaged(*CacheItem).empty;
    errdefer discard(allocator, &items);
    if (comptime @import("builtin").os.tag != .macos) return items;

    const out = exec.run(allocator, &.{ "/usr/bin/tmutil", "listlocalsnapshots", "/" }) catch return items;
    defer allocator.free(out);

    var lines = std.mem.tokenizeScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (items.items.len >= opts.max_items) break;
        const text = std.mem.trim(u8, line, " \t\r");
        const marker = "com.apple.TimeMachine.";
        const at = std.mem.indexOf(u8, text, marker) orelse continue;
        var stamp = text[at + marker.len ..];
        if (std.mem.endsWith(u8, stamp, ".local")) stamp = stamp[0 .. stamp.len - ".local".len];
        if (stamp.len == 0) continue;

        const label = try std.fmt.allocPrint(allocator, "Snapshot {s}", .{stamp});
        defer allocator.free(label);
        const id = try std.fmt.allocPrint(allocator, "snapshot:{s}", .{stamp});
        defer allocator.free(id);
        const info = safety.SafetyInfo.checkFirst(
            "Time Machine snapshot",
            "A local snapshot macOS keeps between backups, so a restore point is always near. Deleting it frees the space it holds; the next backup makes a new one.",
            "The next backup starts from where your backup disk left off.",
        );
        const item = try CacheItem.create(allocator, .{
            .id = id,
            .name = label,
            .info = info,
            .category = .junk,
            .path = try std.fmt.allocPrint(allocator, "/{s}", .{stamp}),
            .where = "Time Machine",
            .unknown_size = true,
            .removal = .tm_snapshot,
            .target = stamp,
        });
        try items.append(allocator, item);
    }
    return items;
}

fn discard(allocator: std.mem.Allocator, items: *std.ArrayListUnmanaged(*CacheItem)) void {
    for (items.items) |item| {
        item.deinit();
        allocator.destroy(item);
    }
    items.deinit(allocator);
}

test "snapshots come back as rows with the date as their target" {
    const allocator = std.testing.allocator;
    var items = try scan(allocator, std.testing.io, .{});
    defer discard(allocator, &items);
    for (items.items) |item| {
        try std.testing.expectEqual(item_mod.Removal.tm_snapshot, item.removal);
        try std.testing.expect(!item.measured);
        try std.testing.expect(item.removal_target != null);
        try std.testing.expect(std.mem.startsWith(u8, item.removal_target.?, "20"));
    }
}
