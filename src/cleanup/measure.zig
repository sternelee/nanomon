//! Measuring what a path holds. A file's size is its size; a folder's is the
//! sum of the files under it, bounded so one huge folder cannot stall a scan.
//! A free function, so the walks can run on several threads, each with its
//! own `io` and its own allocator.
const std = @import("std");

pub const Size = struct {
    bytes: u64 = 0,
    /// True when the walk stopped at its file limit: the sum is a floor.
    truncated: bool = false,
};

/// How many files a folder's size walk may look at before it gives up and
/// reports a floor.
pub const default_max_files: usize = 20000;

pub fn measureAt(allocator: std.mem.Allocator, io: std.Io, path: []const u8, max_files: usize) Size {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return .{};
    if (stat.kind != .directory) return .{ .bytes = stat.size };

    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return .{};
    defer dir.close(io);
    var walker = dir.walk(allocator) catch return .{};
    defer walker.deinit();

    var total: u64 = 0;
    var checked: usize = 0;
    while (walker.next(io)) |maybe| {
        const entry = maybe orelse break;
        if (entry.kind != .file) continue;
        const file = entry.dir.statFile(io, entry.basename, .{}) catch continue;
        total += file.size;
        checked += 1;
        if (checked >= max_files) return .{ .bytes = total, .truncated = true };
    } else |_| {}
    return .{ .bytes = total };
}

test "a file measures as itself, a folder as what it holds" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];

    try tmp.dir.createDirPath(io, "folder");
    const data = try allocator.alloc(u8, 4096);
    defer allocator.free(data);
    @memset(data, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "folder/one", .data = data });
    try tmp.dir.writeFile(io, .{ .sub_path = "folder/two", .data = data });
    try tmp.dir.writeFile(io, .{ .sub_path = "single", .data = data });

    const folder = try std.fs.path.join(allocator, &.{ home, "folder" });
    defer allocator.free(folder);
    const single = try std.fs.path.join(allocator, &.{ home, "single" });
    defer allocator.free(single);

    try std.testing.expectEqual(@as(u64, 8192), measureAt(allocator, io, folder, 100).bytes);
    try std.testing.expectEqual(@as(u64, 4096), measureAt(allocator, io, single, 100).bytes);
    // Past the limit the sum is a floor, and says so.
    const cut = measureAt(allocator, io, folder, 1);
    try std.testing.expect(cut.truncated and cut.bytes == 4096);
    // Something that is not there holds nothing.
    try std.testing.expectEqual(@as(u64, 0), measureAt(allocator, io, "/nope/not/here", 100).bytes);
}
