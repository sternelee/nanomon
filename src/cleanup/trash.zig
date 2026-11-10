//! Trash operations for safe file deletion.
//! Moves files to macOS Trash or Linux equivalent.

const std = @import("std");
const builtin = @import("builtin");

const builtin_os = builtin.os.tag;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// Error types for trash operations
pub const TrashError = error{
    TrashNotFound,
    FileNotFound,
    AccessDenied,
    InvalidPath,
    NotImplemented,
} || std.fs.File.WriteError;

/// Trash manager for safe file deletion
pub const TrashManager = struct {
    allocator: std.mem.Allocator,
    trash_path: []const u8,
    io: std.Io,

    /// Initialize trash manager
    pub fn init(allocator: std.mem.Allocator, io: std.Io) !TrashManager {
        const trash_path = try getTrashPath(allocator);
        return .{
            .allocator = allocator,
            .trash_path = trash_path,
            .io = io,
        };
    }

    pub fn deinit(self: *TrashManager) void {
        self.allocator.free(self.trash_path);
    }

    /// Move a file or directory to trash
    pub fn moveToTrash(self: *TrashManager, path: []const u8) !void {
        // TODO: implement proper file move for Zig 0.17
        // For now, just log that we would move to trash
        _ = self;
        _ = path;
        return error.NotImplemented;
    }

    /// Generate a unique filename in trash (add suffix if exists)
    fn generateUniqueTrashName(self: *TrashManager, basename: []const u8) ![]const u8 {
        // For now, just return basename without checking existence
        // TODO: implement proper uniqueness check for Zig 0.17
        return self.allocator.dupe(u8, basename);
    }

    /// Write .trashinfo file (Linux freedesktop.org standard)
    fn writeTrashInfo(self: *TrashManager, trash_name: []const u8, original_path: []const u8) !void {
        const info_path = try std.fs.path.join(self.allocator, &.{ self.trash_path, "info", trash_name ++ ".trashinfo" });
        defer self.allocator.free(info_path);

        const info_file = try std.fs.createFileAbsolute(info_path, .{});
        defer info_file.close();

        const writer = info_file.writer();
        try writer.print("[Trash Info]\n", .{});
        try writer.print("Path={s}\n", .{original_path});
        try writer.print("DeletionDate={s}\n", .{self.getISO8601Date()});
    }

    /// Get current date in ISO 8601 format
    fn getISO8601Date(_: *TrashManager) []const u8 {
        return "2024-01-01T00:00:00"; // TODO: implement proper date formatting
    }
};

/// Get the path to the user's trash directory
fn getTrashPath(allocator: std.mem.Allocator) ![]const u8 {
    if (comptime builtin_os == .macos) {
        // macOS: ~/.Trash
        const home = getenv("HOME") orelse return error.TrashNotFound;
        return std.fs.path.join(allocator, &.{ std.mem.span(home), ".Trash" });
    } else if (comptime builtin_os == .linux) {
        // Linux: XDG_DATA_HOME/Trash or ~/.local/share/Trash
        const xdg_data = getenv("XDG_DATA_HOME");
        if (xdg_data) |xdg| {
            return std.fs.path.join(allocator, &.{ std.mem.span(xdg), "Trash" });
        }
        const home = getenv("HOME") orelse return error.TrashNotFound;
        return std.fs.path.join(allocator, &.{ std.mem.span(home), ".local", "share", "Trash" });
    } else {
        return error.TrashNotFound;
    }
}

test "TrashManager init" {
    var manager = try TrashManager.init(std.testing.allocator, std.Io.Threaded.global_single_threaded.io());
    defer manager.deinit();

    try std.testing.expect(manager.trash_path.len > 0);
}
