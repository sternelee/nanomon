//! Moving what Cleanup removes to the Trash: macOS's `~/.Trash`, or the
//! freedesktop.org trash on Linux. Nothing here ever deletes for good; the
//! user empties the Trash themselves, so anything removed can be put back.
//!
//! Every move runs the path past the safety catalog first, so a mistake in a
//! scan rule still cannot delete a protected or denied folder.
const std = @import("std");
const builtin = @import("builtin");
const safety = @import("safety.zig");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// Moves files and folders to the Trash, giving each a name that does not
/// collide with what is already there.
pub const TrashManager = struct {
    allocator: std.mem.Allocator,
    /// macOS: `~/.Trash`. Linux: the freedesktop trash root.
    root: []const u8,
    /// Where the files themselves go. On Linux that is `<root>/files`.
    files: []const u8,
    io: std.Io,

    /// The user's trash, from `$HOME` (and `$XDG_DATA_HOME` on Linux).
    pub fn init(allocator: std.mem.Allocator, io: std.Io) !TrashManager {
        const home = getenv("HOME") orelse return error.HomeNotFound;
        if (comptime builtin.os.tag == .linux) {
            if (getenv("XDG_DATA_HOME")) |xdg| {
                const root = try std.fs.path.join(allocator, &.{ std.mem.span(xdg), "Trash" });
                return initRoot(allocator, io, root);
            }
        }
        return initAt(allocator, io, std.mem.span(home));
    }

    /// The trash inside a given home folder: the tests' way in. It always
    /// follows `home`, even when `$XDG_DATA_HOME` points elsewhere, so a test
    /// can never reach the real trash.
    pub fn initAt(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !TrashManager {
        const root = if (comptime builtin.os.tag == .linux)
            try std.fs.path.join(allocator, &.{ home, ".local", "share", "Trash" })
        else
            try std.fs.path.join(allocator, &.{ home, ".Trash" });
        return initRoot(allocator, io, root);
    }

    fn initRoot(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !TrashManager {
        errdefer allocator.free(root);

        const files = if (comptime builtin.os.tag == .linux)
            try std.fs.path.join(allocator, &.{ root, "files" })
        else
            try allocator.dupe(u8, root);

        return .{ .allocator = allocator, .root = root, .files = files, .io = io };
    }

    pub fn deinit(self: *TrashManager) void {
        self.allocator.free(self.root);
        self.allocator.free(self.files);
    }

    /// Whether this platform has a Trash to move things to.
    pub fn supported() bool {
        return comptime builtin.os.tag == .macos or builtin.os.tag == .linux;
    }

    /// Move a file or folder to the Trash, returning where it landed (the
    /// caller owns the returned string). Fails rather than deleting anything
    /// if the move cannot be done.
    pub fn moveToTrash(self: *TrashManager, path: []const u8) ![]const u8 {
        return self.move(path, false);
    }

    /// Move an app bundle. Bundles live in `/Applications`, which the strict
    /// rule protects, so this checks instead that the path really is a bundle
    /// in a folder apps live in.
    pub fn moveAppToTrash(self: *TrashManager, path: []const u8) ![]const u8 {
        if (!isAppBundlePath(path)) return error.RefusedPath;
        return self.move(path, true);
    }

    fn move(self: *TrashManager, path: []const u8, app_bundle: bool) ![]const u8 {
        if (!supported()) return error.TrashUnsupported;
        const base = std.fs.path.basename(path);
        if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return error.InvalidPath;
        // Defense in depth: a scan rule can only propose what the catalog allows.
        if (safety.isDeniedName(base)) return error.RefusedPath;
        if (!app_bundle and safety.isProtectedPath(path)) return error.RefusedPath;

        try self.ensureDirs();

        const name = try self.uniqueName(base);
        defer self.allocator.free(name);
        const dest = try std.fs.path.join(self.allocator, &.{ self.files, name });
        errdefer self.allocator.free(dest);

        if (comptime builtin.os.tag == .linux) try self.writeTrashInfo(name, path);
        std.Io.Dir.renameAbsolute(path, dest, self.io) catch |err| {
            // The .trashinfo is written first so the Trash shows the original
            // location; if the move itself fails, it must not be left behind.
            if (comptime builtin.os.tag == .linux) self.removeTrashInfo(name);
            return err;
        };
        return dest;
    }

    /// Whether a path is already in this trash (nothing to do, then).
    pub fn holds(self: *const TrashManager, path: []const u8) bool {
        return std.mem.startsWith(u8, path, self.files);
    }

    fn ensureDirs(self: *TrashManager) !void {
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(self.io, self.files);
        if (comptime builtin.os.tag == .linux) {
            const info = try std.fs.path.join(self.allocator, &.{ self.root, "info" });
            defer self.allocator.free(info);
            try cwd.createDirPath(self.io, info);
        }
    }

    /// `name`, or `name 2`, `name 3`… until one is free in the Trash.
    fn uniqueName(self: *TrashManager, base: []const u8) ![]const u8 {
        const cwd = std.Io.Dir.cwd();
        var attempt: usize = 0;
        while (attempt < 1000) : (attempt += 1) {
            const candidate = if (attempt == 0)
                try self.allocator.dupe(u8, base)
            else
                try self.numbered(base, attempt + 1);
            const candidate_path = try std.fs.path.join(self.allocator, &.{ self.files, candidate });
            defer self.allocator.free(candidate_path);
            _ = cwd.statFile(self.io, candidate_path, .{}) catch |err| switch (err) {
                error.FileNotFound => return candidate,
                else => {
                    self.allocator.free(candidate);
                    return err;
                },
            };
            self.allocator.free(candidate);
        }
        return error.TooManyCollisions;
    }

    /// `report.pdf` → `report 2.pdf`; a name with no extension gains the
    /// number at the end.
    fn numbered(self: *TrashManager, base: []const u8, n: usize) ![]const u8 {
        if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
            if (dot > 0) return std.fmt.allocPrint(self.allocator, "{s} {d}{s}", .{ base[0..dot], n, base[dot..] });
        }
        return std.fmt.allocPrint(self.allocator, "{s} {d}", .{ base, n });
    }

    /// The freedesktop.org `.trashinfo` beside the file: where it came from,
    /// and when it was removed.
    fn writeTrashInfo(self: *TrashManager, name: []const u8, original: []const u8) !void {
        const encoded = try percentEncode(self.allocator, original);
        defer self.allocator.free(encoded);
        const date = try self.nowISO8601();
        defer self.allocator.free(date);
        const body = try std.fmt.allocPrint(self.allocator, "[Trash Info]\nPath={s}\nDeletionDate={s}\n", .{ encoded, date });
        defer self.allocator.free(body);
        const info = try std.fs.path.join(self.allocator, &.{ self.root, "info", name });
        defer self.allocator.free(info);
        const info_path = try std.fmt.allocPrint(self.allocator, "{s}.trashinfo", .{info});
        defer self.allocator.free(info_path);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = info_path, .data = body });
    }

    fn removeTrashInfo(self: *TrashManager, name: []const u8) void {
        const info = std.fs.path.join(self.allocator, &.{ self.root, "info", name }) catch return;
        defer self.allocator.free(info);
        const info_path = std.fmt.allocPrint(self.allocator, "{s}.trashinfo", .{info}) catch return;
        defer self.allocator.free(info_path);
        std.Io.Dir.cwd().deleteFile(self.io, info_path) catch {};
    }

    /// `2026-11-12T14:35:09`, as the freedesktop spec asks for.
    fn nowISO8601(self: *TrashManager) ![]const u8 {
        const ns = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        const secs: u64 = @intCast(@divTrunc(ns, std.time.ns_per_s));
        const day = std.time.epoch.EpochSeconds{ .secs = secs };
        const year_day = day.getEpochDay().calculateYearDay();
        const date = year_day.calculateMonthDay();
        const time = day.getDaySeconds();
        return std.fmt.allocPrint(self.allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
            year_day.year,
            date.month.numeric(),
            date.day_index + 1,
            time.getHoursIntoDay(),
            time.getMinutesIntoHour(),
            time.getSecondsIntoMinute(),
        });
    }
};

/// Whether a path is an app bundle in a folder apps live in.
fn isAppBundlePath(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    if (!std.mem.endsWith(u8, path, ".app")) return false;
    const parent = std.fs.path.dirname(path) orelse return false;
    if (std.mem.eql(u8, parent, "/Applications")) return true;
    // `~/Applications`, and nowhere else that merely ends in "Applications".
    const home = if (getenv("HOME")) |h| std.mem.span(h) else return false;
    if (home.len == 0 or std.mem.eql(u8, home, "/")) return false;
    if (parent.len != home.len + "/Applications".len) return false;
    return std.mem.startsWith(u8, parent, home) and std.mem.eql(u8, parent[home.len..], "/Applications");
}

/// Percent-encode a path the way `.trashinfo` expects: everything but the
/// unreserved characters and `/`.
fn percentEncode(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (path) |ch| {
        const plain = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~' or ch == '/';
        if (plain) {
            try out.append(allocator, ch);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[ch >> 4]);
            try out.append(allocator, hex[ch & 0xf]);
        }
    }
    return out.toOwnedSlice(allocator);
}

test "percent encoding keeps the path readable" {
    const allocator = std.testing.allocator;
    const encoded = try percentEncode(allocator, "/Users/me/Library/Caches/Some App/cache");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("/Users/me/Library/Caches/Some%20App/cache", encoded);
}

test "a folder and a file move to the trash and can be put back" {
    if (!TrashManager.supported()) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home_len = try tmp.dir.realPath(io, &home_buf);
    const home = home_buf[0..home_len];

    // A file and a folder to remove.
    try tmp.dir.writeFile(io, .{ .sub_path = "old.log", .data = "log lines" });
    try tmp.dir.createDirPath(io, "DerivedData");

    var trash = try TrashManager.initAt(allocator, io, home);
    defer trash.deinit();

    const file_path = try std.fs.path.join(allocator, &.{ home, "old.log" });
    defer allocator.free(file_path);
    const dir_path = try std.fs.path.join(allocator, &.{ home, "DerivedData" });
    defer allocator.free(dir_path);

    const moved_file = try trash.moveToTrash(file_path);
    defer allocator.free(moved_file);
    const moved_dir = try trash.moveToTrash(dir_path);
    defer allocator.free(moved_dir);

    // Gone from where they were…
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, file_path, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, dir_path, .{}));
    // …and in the trash.
    _ = try std.Io.Dir.cwd().statFile(io, moved_file, .{});
    _ = try std.Io.Dir.cwd().statFile(io, moved_dir, .{});
    try std.testing.expect(std.mem.endsWith(u8, moved_file, "old.log"));
    try std.testing.expect(trash.holds(moved_file));
}

test "a second file of the same name does not overwrite the first" {
    if (!TrashManager.supported()) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home_len = try tmp.dir.realPath(io, &home_buf);
    const home = home_buf[0..home_len];

    try tmp.dir.createDirPath(io, "a");
    try tmp.dir.createDirPath(io, "b");
    try tmp.dir.writeFile(io, .{ .sub_path = "a/report.pdf", .data = "one" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b/report.pdf", .data = "two" });

    var trash = try TrashManager.initAt(allocator, io, home);
    defer trash.deinit();

    const first = try std.fs.path.join(allocator, &.{ home, "a", "report.pdf" });
    defer allocator.free(first);
    const second = try std.fs.path.join(allocator, &.{ home, "b", "report.pdf" });
    defer allocator.free(second);

    const moved_first = try trash.moveToTrash(first);
    defer allocator.free(moved_first);
    const moved_second = try trash.moveToTrash(second);
    defer allocator.free(moved_second);

    try std.testing.expect(!std.mem.eql(u8, moved_first, moved_second));
    try std.testing.expect(std.mem.endsWith(u8, moved_first, "report.pdf"));
    try std.testing.expect(std.mem.endsWith(u8, moved_second, "report 2.pdf"));
}

test "the trash refuses a protected path" {
    if (!TrashManager.supported()) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home_len = try tmp.dir.realPath(io, &home_buf);

    var trash = try TrashManager.initAt(allocator, io, home_buf[0..home_len]);
    defer trash.deinit();

    try std.testing.expectError(error.RefusedPath, trash.moveToTrash("/Library/Caches/com.apple.akd"));
    try std.testing.expectError(error.RefusedPath, trash.moveToTrash("/Users/me/Library/Caches/com.apple.finder"));
}
