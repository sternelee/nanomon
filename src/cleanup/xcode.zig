//! Xcode's optional components: the ones Xcode downloads on demand and can
//! drop again, like the Metal toolchain. Removing one is for good, but Xcode
//! fetches it again the next time a project needs it.
const std = @import("std");
const item_mod = @import("item.zig");
const CacheItem = item_mod.CacheItem;
const safety = @import("safety.zig");
const exec = @import("exec.zig");
const measure = @import("measure.zig");

/// The component types `xcodebuild -showComponent` knows. Only the ones that
/// really are installed become rows.
pub const components = [_][]const u8{"metalToolchain"};

pub const Options = struct {
    max_files: usize = measure.default_max_files,
};

pub fn scan(allocator: std.mem.Allocator, io: std.Io, opts: Options) !std.ArrayListUnmanaged(*CacheItem) {
    var items = std.ArrayListUnmanaged(*CacheItem).empty;
    errdefer discard(allocator, &items);
    if (comptime @import("builtin").os.tag != .macos) return items;

    for (components) |component| {
        const out = exec.run(allocator, &.{ "/usr/bin/xcodebuild", "-showComponent", component, "-json" }) catch continue;
        defer allocator.free(out);
        if (out.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, exec.jsonSlice(out), .{}) catch continue;
        defer parsed.deinit();
        const status = switch (parsed.value.object.get("status") orelse std.json.Value{ .null = {} }) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, status, "installed")) continue;

        // Where it lives, if Xcode says; otherwise the usual place. Only the
        // path we build ourselves may be freed — the other points into the
        // answer's own arena.
        var built: ?[]u8 = null;
        const path = pathIn(parsed.value) orelse blk: {
            built = try std.fmt.allocPrint(allocator, "/Library/Developer/Toolchains/{s}.xctoolchain", .{component});
            break :blk built.?;
        };
        defer if (built) |mine| allocator.free(mine);
        const size = measure.measureAt(allocator, io, path, opts.max_files);

        const label = try std.fmt.allocPrint(allocator, "{s} component", .{component});
        defer allocator.free(label);
        const id = try std.fmt.allocPrint(allocator, "xcode:{s}", .{component});
        defer allocator.free(id);
        const info = safety.SafetyInfo.checkFirst(
            "Xcode component",
            "An optional piece of Xcode. Removing it frees its space; Xcode downloads it again the next time a project needs it.",
            "Run `xcodebuild -downloadComponent <name>` to fetch it again.",
        );
        try items.append(allocator, try CacheItem.create(allocator, .{
            .id = id,
            .name = label,
            .info = info,
            .category = .xcode,
            .path = path,
            .where = "Xcode",
            .size = size.bytes,
            // Xcode says it is installed but does not always say where: the
            // row shows either way, with a dash when the size is unknowable.
            .sized = size.bytes > 0,
            .unknown_size = size.bytes == 0,
            .removal = .xcode_component,
            .target = component,
        }));
    }
    return items;
}

/// The first string in the component's answer that looks like a path.
fn pathIn(value: std.json.Value) ?[]const u8 {
    switch (value) {
        .string => |s| return if (std.mem.startsWith(u8, s, "/")) s else null,
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| if (pathIn(entry.value_ptr.*)) |found| return found;
        },
        .array => |array| {
            for (array.items) |entry| if (pathIn(entry)) |found| return found;
        },
        else => {},
    }
    return null;
}

fn discard(allocator: std.mem.Allocator, items: *std.ArrayListUnmanaged(*CacheItem)) void {
    for (items.items) |item| {
        item.deinit();
        allocator.destroy(item);
    }
    items.deinit(allocator);
}

test "a path is found in the component's answer" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"status\":\"installed\",\"path\":\"/Library/Developer/Toolchains/x.xctoolchain\",\"nested\":{\"other\":1}}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("/Library/Developer/Toolchains/x.xctoolchain", pathIn(parsed.value).?);
    const none = try std.json.parseFromSlice(std.json.Value, allocator, "{\"status\":\"uninstalled\",\"buildVersion\":\"27B47\"}", .{});
    defer none.deinit();
    try std.testing.expect(pathIn(none.value) == null);
}

test "only installed components become rows" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var items = try scan(allocator, std.testing.io, .{});
    defer discard(allocator, &items);
    for (items.items) |item| {
        try std.testing.expectEqual(item_mod.Category.xcode, item.category);
        try std.testing.expectEqualStrings("metalToolchain", item.removal_target.?);
    }
}
