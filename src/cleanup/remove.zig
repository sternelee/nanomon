//! How each kind of item is removed. Almost everything goes to the Trash;
//! the few things only their own tool can take away go through that tool, and
//! are gone for good — which is why the sheet says so before it happens.
const std = @import("std");
const item_mod = @import("item.zig");
const CacheItem = item_mod.CacheItem;
const Removal = item_mod.Removal;
const exec = @import("exec.zig");
const trash_mod = @import("trash.zig");
const TrashManager = trash_mod.TrashManager;

pub const Outcome = enum { removed, failed };

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
        return .removed;
    }

    const argv = command(allocator, item) orelse return .failed;
    defer allocator.free(argv);
    const answer = exec.runOk(allocator, argv) catch return .failed;
    defer allocator.free(answer.out);
    return if (answer.ok) .removed else .failed;
}

/// The command that removes an item, or null when there is none. The returned
/// slice is the caller's to free; the strings inside it are not.
pub fn command(allocator: std.mem.Allocator, item: *CacheItem) ?[]const []const u8 {
    const target = item.removal_target orelse return null;
    const args: []const []const u8 = switch (item.removal) {
        .simctl_runtime => &.{ "/usr/bin/xcrun", "simctl", "runtime", "delete", target },
        .simctl_device => &.{ "/usr/bin/xcrun", "simctl", "delete", target },
        .xcode_component => &.{ "/usr/bin/xcodebuild", "-deleteComponent", target },
        .brew_formula => &.{ brewPath() orelse "/opt/homebrew/bin/brew", "uninstall", target },
        .brew_cask => &.{ brewPath() orelse "/opt/homebrew/bin/brew", "uninstall", "--cask", target },
        .tm_snapshot => &.{ "/usr/bin/tmutil", "deletelocalsnapshots", target },
        .trash, .none => return null,
    };
    const copy = allocator.alloc([]const u8, args.len) catch return null;
    @memcpy(copy, args);
    return copy;
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
        const argv = command(allocator, &item);
        if (case.wants) {
            const args = argv orelse return error.NoCommand;
            defer allocator.free(args);
            try std.testing.expect(args.len >= 2);
            if (case.target) |target| try std.testing.expectEqualStrings(target, args[args.len - 1]);
        } else try std.testing.expect(argv == null);
    }
}
