//! How each kind of item is removed, and how a command-line tool is updated.
//! Almost everything goes to the Trash; the few things only their own tool
//! can take away go through that tool, and are gone for good — which is why
//! the sheet says so before it happens.
const std = @import("std");
const item_mod = @import("item.zig");
const CacheItem = item_mod.CacheItem;
const Removal = item_mod.Removal;
const Update = item_mod.Update;
const exec = @import("exec.zig");
const trash_mod = @import("trash.zig");
const TrashManager = trash_mod.TrashManager;

pub const Outcome = enum { ok, failed };

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

/// Where Homebrew is, on Apple silicon or Intel. Only a hint: the callers ask
/// `brewPath` before offering anything Homebrew installed.
pub fn brewPath() ?[]const u8 {
    const candidates = [_][]const u8{ "/opt/homebrew/bin/brew", "/usr/local/bin/brew" };
    for (candidates) |path| {
        if (access(@ptrCast(path), 0) == 0) return path;
    }
    return null;
}

/// Remove one item, by its own rule. `trash` is used only for items that go
/// to the Trash; the tool-run removals ignore it.
pub fn remove(allocator: std.mem.Allocator, trash: *TrashManager, item: *CacheItem) Outcome {
    if (item.removal == .none) return .failed;
    if (item.removal == .trash) {
        for (item.locations.items) |loc| {
            // An app's bundle lives in /Applications and needs the app rule;
            // everything else follows the strict one.
            const dest = (if (loc.app_bundle) trash.moveAppToTrash(loc.path) else trash.moveToTrash(loc.path)) catch return .failed;
            allocator.free(dest);
        }
        return .ok;
    }

    const argv = command(allocator, item) orelse return .failed;
    defer freeCommand(allocator, argv);
    const answer = exec.runOk(allocator, argv) catch return .failed;
    defer allocator.free(answer.out);
    return if (answer.ok) .ok else .failed;
}

/// Update one command-line tool, through the manager that installed it. An
/// update replaces what is there; nothing is removed, and no Trash is
/// involved.
pub fn update(allocator: std.mem.Allocator, item: *CacheItem) Outcome {
    const argv = updateCommand(allocator, item) orelse return .failed;
    defer freeCommand(allocator, argv);
    const answer = exec.runOk(allocator, argv) catch return .failed;
    defer allocator.free(answer.out);
    return if (answer.ok) .ok else .failed;
}

/// The command that removes an item, or null when there is none. Every
/// string in the answer is the caller's: `freeCommand` gives it back.
pub fn command(allocator: std.mem.Allocator, item: *CacheItem) ?[]const []const u8 {
    const target = item.removal_target orelse return null;
    return switch (item.removal) {
        .simctl_runtime => argvOf(allocator, &.{ "/usr/bin/xcrun", "simctl", "runtime", "delete", target }),
        .simctl_device => argvOf(allocator, &.{ "/usr/bin/xcrun", "simctl", "delete", target }),
        .xcode_component => argvOf(allocator, &.{ "/usr/bin/xcodebuild", "-deleteComponent", target }),
        .brew_formula => argvOf(allocator, &.{ brewPath() orelse "/opt/homebrew/bin/brew", "uninstall", target }),
        .brew_cask => argvOf(allocator, &.{ brewPath() orelse "/opt/homebrew/bin/brew", "uninstall", "--cask", target }),
        .tm_snapshot => argvOf(allocator, &.{ "/usr/bin/tmutil", "deletelocalsnapshots", target }),
        .npm_global => managerArgvOf(allocator, "npm", &.{ "uninstall", "-g", target }),
        .pnpm_global => managerArgvOf(allocator, "pnpm", &.{ "remove", "-g", target }),
        .bun_global => managerArgvOf(allocator, "bun", &.{ "remove", "-g", target }),
        .pipx_venv => managerArgvOf(allocator, "pipx", &.{ "uninstall", target }),
        .cargo_install => managerArgvOf(allocator, "cargo", &.{ "uninstall", target }),
        .trash, .none => null,
    };
}

/// The command that updates a tool, or null when nothing can (a cache, a
/// downloaded program, or a tool whose manager is not on the machine).
pub fn updateCommand(allocator: std.mem.Allocator, item: *CacheItem) ?[]const []const u8 {
    const how = item.update orelse return null;
    const target = item.removal_target orelse return null;
    return switch (how) {
        .brew_upgrade => argvOf(allocator, &.{ brewPath() orelse "/opt/homebrew/bin/brew", "upgrade", target }),
        .npm_latest => at_latest: {
            const wanted = packageAtLatest(allocator, target) orelse break :at_latest null;
            defer allocator.free(wanted);
            break :at_latest managerArgvOf(allocator, "npm", &.{ "install", "-g", wanted });
        },
        .pnpm_latest => managerArgvOf(allocator, "pnpm", &.{ "update", "-g", "--latest", target }),
        .bun_latest => managerArgvOf(allocator, "bun", &.{ "update", "-g", "--latest", target }),
        .pipx_upgrade => managerArgvOf(allocator, "pipx", &.{ "upgrade", target }),
        .cargo_install => managerArgvOf(allocator, "cargo", &.{ "install", target }),
    };
}

/// `<name>@latest`: npm's way of asking for the newest version rather than
/// the newest one its range allows.
fn packageAtLatest(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const at = std.fmt.allocPrint(allocator, "{s}@latest", .{name}) catch return null;
    return at;
}

/// A command of literal strings and a manager's own binary: every string is
/// copied, so the answer stands on its own until it is freed.
fn argvOf(allocator: std.mem.Allocator, parts: []const []const u8) ?[]const []const u8 {
    const copy = allocator.alloc([]const u8, parts.len) catch return null;
    var made: usize = 0;
    for (parts, 0..) |part, i| {
        copy[i] = allocator.dupe(u8, part) catch {
            for (copy[0..made]) |made_part| allocator.free(made_part);
            allocator.free(copy);
            return null;
        };
        made += 1;
    }
    return copy;
}

/// The same, for a manager nanomon has to find first: `npm`, `pnpm`, `bun`,
/// `pipx` and `cargo` are not where a Dock-launched window looks.
fn managerArgvOf(allocator: std.mem.Allocator, tool: []const u8, rest: []const []const u8) ?[]const []const u8 {
    const path = toolPath(allocator, tool) orelse return null;
    defer allocator.free(path);
    const parts = allocator.alloc([]const u8, rest.len + 1) catch return null;
    defer allocator.free(parts);
    parts[0] = path;
    @memcpy(parts[1..], rest);
    return argvOf(allocator, parts);
}

/// Where a manager's own binary is, as the caller's to free.
pub fn toolPath(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    var scratch: [std.fs.max_path_bytes]u8 = undefined;
    const found = exec.which(name, &scratch) orelse return null;
    return allocator.dupe(u8, found) catch null;
}

/// Give back a command `command` or `updateCommand` built.
pub fn freeCommand(allocator: std.mem.Allocator, argv_slice: []const []const u8) void {
    for (argv_slice) |part| allocator.free(part);
    allocator.free(argv_slice);
}

test "every removable kind has a command, and none has one" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { removal: Removal, target: ?[]const u8, wants: bool }{
        .{ .removal = .trash, .target = null, .wants = false },
        .{ .removal = .none, .target = null, .wants = false },
        .{ .removal = .simctl_runtime, .target = "com.apple.CoreSimulator.SimRuntime.iOS-18-5", .wants = true },
        .{ .removal = .simctl_device, .target = "UDID", .wants = true },
        .{ .removal = .xcode_component, .target = "metalToolchain", .wants = true },
        .{ .removal = .brew_formula, .target = "jq", .wants = true },
        .{ .removal = .brew_cask, .target = "alacritty", .wants = true },
        .{ .removal = .tm_snapshot, .target = "2026-11-12-123456", .wants = true },
    };
    for (cases) |case| {
        var item = try CacheItem.init(allocator, "id", "name", @import("safety.zig").SafetyInfo.safe("h", "e"));
        defer item.deinit();
        try item.setRemoval(case.removal, case.target);
        const removal_argv = command(allocator, &item);
        if (case.wants) {
            const args = removal_argv orelse return error.NoCommand;
            defer freeCommand(allocator, args);
            try std.testing.expect(args.len >= 2);
            if (case.target) |target| try std.testing.expectEqualStrings(target, args[args.len - 1]);
        } else try std.testing.expect(removal_argv == null);
    }
}

test "a manager's tool is removed and updated by its own command" {
    const allocator = std.testing.allocator;
    // A manager nanomon has to find, and one it does not have to: the answer
    // is only there when the tool is on the machine, which the tests cannot
    // count on.
    const cases = [_]struct {
        removal: Removal,
        update: Update,
        target: []const u8,
        tool: []const u8,
        removes: []const []const u8,
        updates: []const []const u8,
    }{
        .{ .removal = .npm_global, .update = .npm_latest, .target = "wrangler", .tool = "npm", .removes = &.{ "uninstall", "-g" }, .updates = &.{ "install", "-g", "wrangler@latest" } },
        .{ .removal = .pnpm_global, .update = .pnpm_latest, .target = "serve", .tool = "pnpm", .removes = &.{ "remove", "-g" }, .updates = &.{ "update", "-g", "--latest" } },
        .{ .removal = .bun_global, .update = .bun_latest, .target = "9router", .tool = "bun", .removes = &.{ "remove", "-g" }, .updates = &.{ "update", "-g", "--latest" } },
        .{ .removal = .pipx_venv, .update = .pipx_upgrade, .target = "httpie", .tool = "pipx", .removes = &.{"uninstall"}, .updates = &.{"upgrade"} },
        .{ .removal = .cargo_install, .update = .cargo_install, .target = "bat", .tool = "cargo", .removes = &.{"uninstall"}, .updates = &.{"install"} },
    };
    for (cases) |case| {
        var item = try CacheItem.init(allocator, "id", case.target, @import("safety.zig").SafetyInfo.safe("h", "e"));
        defer item.deinit();
        try item.setRemoval(case.removal, case.target);
        try item.setUpdate(case.update, "1.0.0", "2.0.0");

        const removes = command(allocator, &item) orelse {
            // The manager is not installed: nothing to check.
            continue;
        };
        defer freeCommand(allocator, removes);
        try std.testing.expectEqual(case.removes.len + 2, removes.len);
        for (case.removes, 0..) |word, i| try std.testing.expectEqualStrings(word, removes[i + 1]);
        try std.testing.expectEqualStrings(case.target, removes[removes.len - 1]);
        try std.testing.expect(std.mem.endsWith(u8, removes[0], case.tool));

        const updates = updateCommand(allocator, &item) orelse return error.NoUpdateCommand;
        defer freeCommand(allocator, updates);
        for (case.updates, 0..) |word, i| try std.testing.expectEqualStrings(word, updates[i + 1]);
        try std.testing.expect(std.mem.endsWith(u8, updates[0], case.tool));
    }
}

test "an update aims at the version its manager offers" {
    const allocator = std.testing.allocator;
    var item = try CacheItem.init(allocator, "id", "wrangler", @import("safety.zig").SafetyInfo.safe("h", "e"));
    defer item.deinit();
    try item.setRemoval(.npm_global, "wrangler");
    try item.setUpdate(.npm_latest, "1.0.0", "2.0.0");
    // npm is asked for the newest, not for the newest its range allows.
    const argv_slice = updateCommand(allocator, &item) orelse return error.SkipZigTest;
    defer freeCommand(allocator, argv_slice);
    try std.testing.expectEqualStrings("wrangler@latest", argv_slice[argv_slice.len - 1]);

    // A tool nothing can update has no command, however it is removed.
    try item.setUpdate(null, "1.0.0", null);
    try std.testing.expect(updateCommand(allocator, &item) == null);
}
