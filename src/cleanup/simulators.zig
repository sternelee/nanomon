//! Simulator runtimes and devices, through `xcrun simctl`. Deleting one is
//! for good — a runtime comes back only by downloading it again — so every
//! row is Check First, and a simulator that is running is never offered.
const std = @import("std");
const item_mod = @import("item.zig");
const CacheItem = item_mod.CacheItem;
const safety = @import("safety.zig");
const exec = @import("exec.zig");
const measure = @import("measure.zig");

pub const Options = struct {
    max_items: usize = 80,
    max_runtimes: usize = 30,
    max_files: usize = measure.default_max_files,
};

pub fn scan(allocator: std.mem.Allocator, io: std.Io, opts: Options) !std.ArrayListUnmanaged(*CacheItem) {
    var items = std.ArrayListUnmanaged(*CacheItem).empty;
    errdefer discard(allocator, &items);
    if (comptime @import("builtin").os.tag != .macos) return items;

    const runtimes = runJSON(allocator, &.{ "/usr/bin/xcrun", "simctl", "list", "runtimes", "--json" });
    defer if (runtimes) |parsed| parsed.deinit();
    const devices = runJSON(allocator, &.{ "/usr/bin/xcrun", "simctl", "list", "devices", "--json" });
    defer if (devices) |parsed| parsed.deinit();
    if (runtimes == null and devices == null) return items;

    // A runtime with a running simulator stays: deleting it would stop one.
    var busy = std.StringHashMapUnmanaged(void).empty;
    defer busy.deinit(allocator);
    if (devices) |parsed| try noteBusy(allocator, parsed.value, &busy);

    if (runtimes) |parsed| {
        const list = parsed.value.object.get("runtimes") orelse std.json.Value{ .null = {} };
        var count: usize = 0;
        for (list.array.items) |entry| {
            if (count >= opts.max_runtimes or items.items.len >= opts.max_items) break;
            const object = entry.object;
            const identifier = stringOf(object.get("identifier")) orelse continue;
            if (busy.contains(identifier)) continue;
            const bundle = stringOf(object.get("bundlePath")) orelse continue;
            const name = stringOf(object.get("name")) orelse "Simulator";
            const version = stringOf(object.get("version")) orelse "";

            const size = measure.measureAt(allocator, io, bundle, opts.max_files);
            if (size.bytes == 0) continue; // nothing on disk to reclaim
            const label = try std.fmt.allocPrint(allocator, "{s} runtime", .{name});
            defer allocator.free(label);
            const id = try std.fmt.allocPrint(allocator, "simulator:{s}", .{identifier});
            defer allocator.free(id);

            const info = safety.SafetyInfo.checkFirst(
                if (version.len > 0) "Simulator runtime" else "Simulator runtime",
                "An iOS, watchOS, tvOS or visionOS runtime the Simulator runs. Deleting it frees the whole runtime; Xcode downloads it again the next time a project needs it.",
                "Xcode downloads the runtime again from Settings › Components, or with `xcodebuild -downloadPlatform`.",
            );
            try items.append(allocator, try CacheItem.create(allocator, .{
                .id = id,
                .name = label,
                .info = info,
                .category = .simulator,
                .path = bundle,
                .where = "CoreSimulator",
                .size = size.bytes,
                .sized = true,
                .removal = .simctl_runtime,
                .target = identifier,
            }));
            count += 1;
        }
    }

    if (devices) |parsed| try addDevices(allocator, parsed.value, &items, opts);
    return items;
}

fn addDevices(allocator: std.mem.Allocator, root: std.json.Value, items: *std.ArrayListUnmanaged(*CacheItem), opts: Options) !void {
    const groups = root.object.get("devices") orelse return;
    var found: std.ArrayListUnmanaged(Device) = .empty;
    defer {
        for (found.items) |d| allocator.free(d.runtime);
        found.deinit(allocator);
    }
    var it = groups.object.iterator();
    while (it.next()) |group| {
        const runtime = shortRuntime(allocator, group.key_ptr.*) catch continue;
        for (group.value_ptr.array.items) |entry| {
            const object = entry.object;
            const state = stringOf(object.get("state")) orelse "";
            if (std.mem.eql(u8, state, "Booted")) continue;
            const name = stringOf(object.get("name")) orelse continue;
            const udid = stringOf(object.get("udid")) orelse continue;
            const path = stringOf(object.get("dataPath")) orelse continue;
            const size: u64 = switch (object.get("dataPathSize") orelse std.json.Value{ .null = {} }) {
                .integer => |v| @intCast(@max(0, v)),
                .float => |v| @intFromFloat(@max(0, v)),
                else => 0,
            };
            try found.append(allocator, .{
                .name = name,
                .udid = udid,
                .path = path,
                .runtime = try allocator.dupe(u8, runtime),
                .size = size,
            });
        }
        allocator.free(runtime);
    }
    // The biggest first, so a cap keeps what is worth reclaiming.
    std.sort.pdq(Device, found.items, {}, struct {
        fn less(_: void, a: Device, b: Device) bool {
            return a.size > b.size;
        }
    }.less);

    for (found.items) |device| {
        if (items.items.len >= opts.max_items) break;
        const label = try std.fmt.allocPrint(allocator, "{s} ({s})", .{ device.name, device.runtime });
        defer allocator.free(label);
        const id = try std.fmt.allocPrint(allocator, "simulator-device:{s}", .{device.udid});
        defer allocator.free(id);
        const info = safety.SafetyInfo.checkFirst(
            "Simulator",
            "A simulator's own disk, with the apps and data you put on it. Deleting it frees the whole device; Xcode makes a new one in a moment.",
            "Create the device again in Xcode's Devices window, or with `xcrun simctl create`.",
        );
        try items.append(allocator, try CacheItem.create(allocator, .{
            .id = id,
            .name = label,
            .info = info,
            .category = .simulator,
            .path = device.path,
            .where = device.runtime,
            .size = device.size,
            .sized = device.size > 0,
            .removal = .simctl_device,
            .target = device.udid,
        }));
    }
}

const Device = struct {
    name: []const u8,
    udid: []const u8,
    path: []const u8,
    runtime: []const u8,
    size: u64,
};

/// "com.apple.CoreSimulator.SimRuntime.iOS-26-5" → "iOS 26.5".
fn shortRuntime(allocator: std.mem.Allocator, identifier: []const u8) ![]u8 {
    const tail = std.mem.lastIndexOfScalar(u8, identifier, '.') orelse return allocator.dupe(u8, identifier);
    const rest = identifier[tail + 1 ..];
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (rest, 0..) |ch, i| {
        if (ch == '-') {
            // "iOS-26-5": the first dash separates the platform from its
            // version, the ones after it separate the version's parts.
            const next_is_digit = i + 1 < rest.len and std.ascii.isDigit(rest[i + 1]);
            if (next_is_digit and i > 0 and std.ascii.isDigit(rest[i - 1])) {
                try out.append(allocator, '.');
                continue;
            }
            if (next_is_digit and i > 0 and std.ascii.isAlphabetic(rest[i - 1])) {
                try out.append(allocator, ' ');
                continue;
            }
        }
        try out.append(allocator, ch);
    }
    return out.toOwnedSlice(allocator);
}

/// The runtimes that have a running simulator, so they are left alone.
fn noteBusy(allocator: std.mem.Allocator, root: std.json.Value, busy: *std.StringHashMapUnmanaged(void)) !void {
    const groups = root.object.get("devices") orelse return;
    var it = groups.object.iterator();
    while (it.next()) |group| {
        for (group.value_ptr.array.items) |entry| {
            const state = stringOf(entry.object.get("state")) orelse continue;
            if (std.mem.eql(u8, state, "Booted")) try busy.put(allocator, group.key_ptr.*, {});
        }
    }
}

fn stringOf(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn runJSON(allocator: std.mem.Allocator, argv: []const []const u8) ?std.json.Parsed(std.json.Value) {
    const out = exec.run(allocator, argv) catch return null;
    defer allocator.free(out);
    if (out.len == 0) return null;
    return std.json.parseFromSlice(std.json.Value, allocator, exec.jsonSlice(out), .{}) catch null;
}

fn discard(allocator: std.mem.Allocator, items: *std.ArrayListUnmanaged(*CacheItem)) void {
    for (items.items) |item| {
        item.deinit();
        allocator.destroy(item);
    }
    items.deinit(allocator);
}

test "a runtime identifier reads as a name" {
    const allocator = std.testing.allocator;
    const ios = try shortRuntime(allocator, "com.apple.CoreSimulator.SimRuntime.iOS-26-5");
    defer allocator.free(ios);
    try std.testing.expectEqualStrings("iOS 26.5", ios);
    const watch = try shortRuntime(allocator, "com.apple.CoreSimulator.SimRuntime.watchOS-11-2");
    defer allocator.free(watch);
    try std.testing.expectEqualStrings("watchOS 11.2", watch);
    const odd = try shortRuntime(allocator, "com.apple.CoreSimulator.SimRuntime.iOS-18-5");
    defer allocator.free(odd);
    try std.testing.expectEqualStrings("iOS 18.5", odd);
}

test "no simulators on a machine without the tools" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    // An empty PATH-like home: the callers only get rows when simctl answers.
    var items = try scan(allocator, std.testing.io, .{});
    defer discard(allocator, &items);
    for (items.items) |item| {
        try std.testing.expectEqual(item_mod.Category.simulator, item.category);
        try std.testing.expect(item.removal != .trash);
        try std.testing.expect(item.removal_target != null);
    }
}
