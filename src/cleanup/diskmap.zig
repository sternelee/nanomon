//! The overview's measurements: how full the disk is, and how much of it the
//! user's own folders hold. Read-only — nothing here is offered for removal,
//! it only says where the space went.
const std = @import("std");
const item_mod = @import("item.zig");
const CacheItem = item_mod.CacheItem;
const safety = @import("safety.zig");
const exec = @import("exec.zig");
const measure = @import("measure.zig");

pub const Volume = struct {
    total: u64,
    used: u64,
    free: u64,
};

pub const Options = struct {
    home: []const u8,
    /// A smaller bound than the cache scans: these folders are huge, and a
    /// floor is good enough to say where the space went.
    max_files: usize = 12000,
};

/// The folders that hold the user's own things.
const folders = [_][]const u8{ "Documents", "Downloads", "Desktop", "Movies", "Music", "Pictures", "Public", "Library" };

/// How full the disk is, from `df`.
pub fn volume(allocator: std.mem.Allocator) ?Volume {
    const out = exec.run(allocator, &.{ "/bin/df", "-k", "/" }) catch return null;
    defer allocator.free(out);

    var lines = std.mem.tokenizeScalar(u8, out, '\n');
    _ = lines.next() orelse return null; // the header
    const row = lines.next() orelse return null;
    var fields = std.mem.tokenizeAny(u8, row, " \t");
    _ = fields.next() orelse return null; // the device
    const total = parseKilobytes(fields.next()) orelse return null;
    const used = parseKilobytes(fields.next()) orelse return null;
    const free = parseKilobytes(fields.next()) orelse return null;
    return .{ .total = total, .used = used, .free = free };
}

fn parseKilobytes(field: ?[]const u8) ?u64 {
    const text = field orelse return null;
    const value = std.fmt.parseInt(u64, text, 10) catch return null;
    return value * 1024;
}

/// One read-only row per folder, and one for everything the rows do not
/// account for.
pub fn scan(allocator: std.mem.Allocator, io: std.Io, opts: Options) !std.ArrayListUnmanaged(*CacheItem) {
    var items = std.ArrayListUnmanaged(*CacheItem).empty;
    errdefer discard(allocator, &items);

    var measured_total: u64 = 0;
    for (folders) |folder| {
        const path = try std.fs.path.join(allocator, &.{ opts.home, folder });
        defer allocator.free(path);
        const size = measure.measureAt(allocator, io, path, opts.max_files);
        if (size.bytes == 0) continue;
        measured_total += size.bytes;

        const id = try std.fmt.allocPrint(allocator, "map:{s}", .{folder});
        defer allocator.free(id);
        const info = safety.SafetyInfo.safe("Folder", "One of your folders. This page only measures; nothing here removes it.");
        const item = try CacheItem.create(allocator, .{
            .id = id,
            .name = folder,
            .info = info,
            .category = .other,
            .path = path,
            .where = "Home",
            .size = size.bytes,
            .sized = true,
            .removal = .none,
        });
        item.locations.items[0].approx = size.truncated;
        try items.append(allocator, item);
    }

    // What the folders above do not account for: the system, other volumes,
    // and everything outside the home folder.
    if (volume(allocator)) |disk| {
        const rest = disk.used -| measured_total;
        if (rest > 0) {
            const info = safety.SafetyInfo.safe("System and other", "macOS itself, the system's own data, and anything outside your home folder. Read-only.");
            try items.append(allocator, try CacheItem.create(allocator, .{
                .id = "map:system",
                .name = "System and other",
                .info = info,
                .category = .other,
                .path = "/",
                .where = "Disk",
                .size = rest,
                .sized = true,
                .removal = .none,
            }));
        }
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

test "df's row reads as bytes" {
    const allocator = std.testing.allocator;
    const disk = volume(allocator) orelse return error.SkipZigTest;
    try std.testing.expect(disk.total > 0);
    try std.testing.expect(disk.used > 0);
    try std.testing.expect(disk.free > 0);
    try std.testing.expect(disk.used + disk.free <= disk.total + (1 << 20));
}

test "the map is read-only and names the folders" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];

    try tmp.dir.createDirPath(io, "Documents");
    const data = try allocator.alloc(u8, 4096);
    defer allocator.free(data);
    @memset(data, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "Documents/notes.txt", .data = data });

    var items = try scan(allocator, io, .{ .home = home });
    defer discard(allocator, &items);
    var found = false;
    for (items.items) |item| {
        try std.testing.expectEqual(item_mod.Removal.none, item.removal);
        try std.testing.expectEqual(item_mod.Category.other, item.category);
        if (std.mem.eql(u8, item.app_name, "Documents")) {
            found = true;
            try std.testing.expectEqual(@as(u64, 4096), item.sizeBytes());
        }
    }
    try std.testing.expect(found);
}
