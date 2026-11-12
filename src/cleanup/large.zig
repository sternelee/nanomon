//! Large files: the biggest files in the user's own folders. Read as they
//! are — nothing here is judged junk — so each row is Check First, and moving
//! one to the Trash is always reversible.
const std = @import("std");
const item_mod = @import("item.zig");
const CacheItem = item_mod.CacheItem;
const safety = @import("safety.zig");

pub const Options = struct {
    home: []const u8,
    /// Folders to look in, relative to the home folder.
    roots: []const []const u8 = &.{ "Downloads", "Desktop", "Documents", "Movies", "Music", "Pictures" },
    /// A file has to be at least this big to be worth a row.
    min_bytes: u64 = 100 << 20,
    max_depth: usize = 8,
    max_visited: usize = 40000,
    max_items: usize = 200,
};

/// What a big file is, from its name: what the Kind column says.
pub fn kindOf(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    if (ext.len < 2) return "Large file";
    const e = ext[1..];
    const kinds = [_]struct { exts: []const []const u8, kind: []const u8 }{
        .{ .exts = &.{ "vmdk", "qcow2", "vdi", "vhd", "vhdx", "pvm", "hdd", "sparseimage" }, .kind = "Virtual machine" },
        .{ .exts = &.{ "gguf", "safetensors", "onnx", "pt", "pth", "ckpt", "mlmodel", "mlpackage", "ggml" }, .kind = "AI model" },
        .{ .exts = &.{ "dmg", "iso", "img", "toast" }, .kind = "Disk image" },
        .{ .exts = &.{ "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "zst" }, .kind = "Archive" },
        .{ .exts = &.{ "mp4", "mov", "mkv", "avi", "m4v", "webm", "flv" }, .kind = "Video" },
        .{ .exts = &.{ "raw", "cr2", "cr3", "nef", "arw", "dng", "raf" }, .kind = "Photo" },
        .{ .exts = &.{ "pkg", "xip" }, .kind = "Installer" },
        .{ .exts = &.{ "backup", "sparsebundle" }, .kind = "Backup" },
    };
    for (kinds) |group| {
        for (group.exts) |candidate| {
            if (std.ascii.eqlIgnoreCase(e, candidate)) return group.kind;
        }
    }
    return "Large file";
}

pub fn scan(allocator: std.mem.Allocator, io: std.Io, opts: Options) !std.ArrayListUnmanaged(*CacheItem) {
    var state = Walk{ .items = .empty };
    errdefer {
        for (state.items.items) |item| {
            item.deinit();
            allocator.destroy(item);
        }
        state.items.deinit(allocator);
    }
    for (opts.roots) |root| {
        if (state.visited >= opts.max_visited or state.items.items.len >= opts.max_items) break;
        const full = std.fs.path.join(allocator, &.{ opts.home, root }) catch continue;
        defer allocator.free(full);
        walk(allocator, io, opts, &state, full, root, 0);
    }
    return state.items;
}

const Walk = struct {
    items: std.ArrayListUnmanaged(*CacheItem),
    visited: usize = 0,
};

fn walk(allocator: std.mem.Allocator, io: std.Io, opts: Options, st: *Walk, path: []const u8, label: []const u8, depth: usize) void {
    if (st.visited >= opts.max_visited or st.items.items.len >= opts.max_items) return;
    if (depth > opts.max_depth) return;
    st.visited += 1;

    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (st.items.items.len >= opts.max_items) return;
        switch (entry.kind) {
            .file => {
                const stat = dir.statFile(io, entry.name, .{}) catch continue;
                if (stat.size < opts.min_bytes) continue;
                const full = std.fs.path.join(a, &.{ path, entry.name }) catch continue;
                addFile(allocator, &st.items, full, label, entry.name, stat.size) catch continue;
            },
            .directory => {
                if (skipDir(entry.name)) continue;
                const child = std.fs.path.join(a, &.{ path, entry.name }) catch continue;
                const child_label = std.fs.path.join(a, &.{ label, entry.name }) catch continue;
                walk(allocator, io, opts, st, child, child_label, depth + 1);
            },
            else => {},
        }
    }
}

/// Folders the search never descends into: hidden ones (`.git`, `.Trash`) and
/// the build folders that hold no one's big file.
fn skipDir(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return true;
    const skipped = [_][]const u8{ "node_modules", "target", "build", "zig-out", "Pods", "venv", "DerivedData" };
    for (skipped) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

fn addFile(allocator: std.mem.Allocator, items: *std.ArrayListUnmanaged(*CacheItem), path: []const u8, where: []const u8, name: []const u8, size: u64) !void {
    const kind = kindOf(name);
    const info = safety.SafetyInfo.checkFirst(
        kind,
        "A file of yours. Nothing rebuilds it, so it is only offered because of its size.",
        "It goes to the Trash: put it back from there if you still need it.",
    );
    const id = try std.fmt.allocPrint(allocator, "large:{s}", .{path});
    defer allocator.free(id);

    const item = try allocator.create(CacheItem);
    errdefer allocator.destroy(item);
    item.* = try CacheItem.init(allocator, id, name, info);
    errdefer item.deinit();
    item.category = .large;
    try item.addLocationSized(path, size, 0, where, false);
    try items.append(allocator, item);
}

test "kind comes from the name" {
    try std.testing.expectEqualStrings("Virtual machine", kindOf("Ubuntu.vmdk"));
    try std.testing.expectEqualStrings("AI model", kindOf("llama-3.gguf"));
    try std.testing.expectEqualStrings("Disk image", kindOf("Xcode.dmg"));
    try std.testing.expectEqualStrings("Video", kindOf("holiday.MOV"));
    try std.testing.expectEqualStrings("Large file", kindOf("notes.txt"));
    try std.testing.expectEqualStrings("Large file", kindOf("noextension"));
}

test "only files past the threshold are offered, and their folder is named" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];

    try tmp.dir.createDirPath(io, "Downloads/Projects");
    const big = try allocator.alloc(u8, 2 << 20);
    defer allocator.free(big);
    @memset(big, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "Downloads/Projects/big.iso", .data = big });
    try tmp.dir.writeFile(io, .{ .sub_path = "Downloads/notes.txt", .data = "small" });

    var items = try scan(allocator, io, .{ .home = home, .min_bytes = 1 << 20 });
    defer {
        for (items.items) |item| {
            item.deinit();
            allocator.destroy(item);
        }
        items.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), items.items.len);
    const item = items.items[0];
    try std.testing.expectEqualStrings("big.iso", item.app_name);
    try std.testing.expectEqualStrings("Disk image", item.safety_info.headline);
    try std.testing.expectEqual(@as(u64, 2 << 20), item.sizeBytes());
    try std.testing.expectEqualStrings("Downloads/Projects", item.locations.items[0].folder_name);
    try std.testing.expectEqual(item_mod.Category.large, item.category);
}
