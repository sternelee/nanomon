//! Running a short-lived command and reading its answer, for the few things
//! only a tool knows (an app bundle's identifier). Blocking on purpose: the
//! Cleanup scan runs on a worker thread, never on the UI's.
const std = @import("std");
const builtin = @import("builtin");

const posix = builtin.os.tag != .windows;

extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn posix_spawn(pid: *c_int, path: [*:0]const u8, actions: ?*const anyopaque, attr: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn posix_spawn_file_actions_init(a: *?*anyopaque) c_int;
extern "c" fn posix_spawn_file_actions_destroy(a: *?*anyopaque) c_int;
extern "c" fn posix_spawn_file_actions_adddup2(a: *?*anyopaque, fd: c_int, newfd: c_int) c_int;
extern "c" fn posix_spawn_file_actions_addclose(a: *?*anyopaque, fd: c_int) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// The most of a command's answer nanomon keeps. Generous enough for the JSON
/// tools answer with (a list of casks is a few hundred kilobytes), small
/// enough that a runaway command cannot fill memory.
const max_output = 8 * 1024 * 1024;

pub const Answer = struct {
    /// What the command wrote to standard output (the caller frees it).
    out: []u8,
    /// Whether it exited zero.
    ok: bool,
};

/// Run `argv[0]` and return its standard output (the caller frees it). An
/// empty slice means the command could not be run or said nothing.
pub fn run(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    return runEnv(allocator, argv, &.{});
}

/// The same, with environment entries of the caller's own (`KEY=VALUE`),
/// which replace the ones nanomon hands every child. `brew` is told not to
/// update itself (that alone can take ten seconds), and `pnpm` is told where
/// its own binaries are, or it refuses to answer at all.
pub fn runEnv(allocator: std.mem.Allocator, argv: []const []const u8, extra_env: []const []const u8) ![]u8 {
    return (try runOkEnv(allocator, argv, extra_env)).out;
}

/// Run `argv[0]`, and say whether it worked as well as what it said. The
/// removals that go through a tool (simctl, xcodebuild, brew, tmutil) are
/// judged by the exit status, not by the output.
pub fn runOk(allocator: std.mem.Allocator, argv: []const []const u8) !Answer {
    return runOkEnv(allocator, argv, &.{});
}

/// The same, with environment entries of the caller's own.
pub fn runOkEnv(allocator: std.mem.Allocator, argv: []const []const u8, extra_env: []const []const u8) !Answer {
    if (!posix or argv.len == 0) return .{ .out = try allocator.alloc(u8, 0), .ok = false };

    // posix_spawn wants null-terminated strings; they live for the call only.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const args = try arena.allocator().alloc(?[*:0]const u8, argv.len + 1);
    for (argv, 0..) |arg, i| {
        const z = try arena.allocator().allocSentinel(u8, arg.len, 0);
        @memcpy(z, arg);
        args[i] = z.ptr;
    }
    args[argv.len] = null;

    var fds: [2]c_int = undefined;
    if (pipe(&fds) != 0) return .{ .out = try allocator.alloc(u8, 0), .ok = false };
    var fa: ?*anyopaque = null;
    _ = posix_spawn_file_actions_init(&fa);
    defer _ = posix_spawn_file_actions_destroy(&fa);
    _ = posix_spawn_file_actions_adddup2(&fa, fds[1], 1);
    // The error text comes along: it is how a caller learns what a tool
    // refused to do ("Refusing to load cask … from untrusted tap …").
    _ = posix_spawn_file_actions_adddup2(&fa, fds[1], 2);
    _ = posix_spawn_file_actions_addclose(&fa, fds[0]);

    var envp = try childEnv(arena.allocator(), extra_env);

    var pid: c_int = 0;
    const rc = posix_spawn(&pid, args[0].?, @ptrCast(&fa), null, @ptrCast(args.ptr), &envp);
    _ = close(fds[1]);
    if (rc != 0) {
        _ = close(fds[0]);
        return .{ .out = try allocator.alloc(u8, 0), .ok = false };
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = read(fds[0], &buf, buf.len);
        if (n <= 0) break;
        // Past the cap the rest is read and dropped rather than left in the
        // pipe: a child blocked writing into a full pipe would never exit,
        // and `waitpid` below would wait for it for ever.
        const room = max_output - out.items.len;
        if (room > 0) try out.appendSlice(allocator, buf[0..@min(@as(usize, @intCast(n)), room)]);
    }
    _ = close(fds[0]);
    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);
    // waitpid's status: the low byte is the signal, the next is the exit code.
    const exited_zero = (status & 0x7f) == 0 and ((status >> 8) & 0xff) == 0;
    return .{ .out = try out.toOwnedSlice(allocator), .ok = exited_zero };
}

/// The environment a tool needs to work: `brew`, `xcrun` and `tmutil` all
/// look for `$HOME`, and brew will not run at all without it.
fn childEnv(arena: std.mem.Allocator, extra: []const []const u8) !Env {
    var env: Env = undefined;
    var n: usize = 0;
    const names = [_][]const u8{ "HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "SHELL" };
    for (names) |name| {
        if (n == env.len - 1) break;
        // The caller's entry, when it has one, is the one that counts: a
        // child with two PATHs is not a child with a choice.
        if (replaced(name, extra)) continue;
        const key = try arena.allocSentinel(u8, name.len, 0);
        @memcpy(key, name);
        const value = getenv(key.ptr) orelse continue;
        const text = try std.fmt.allocPrint(arena, "{s}={s}", .{ name, std.mem.span(value) });
        const line = try arena.allocSentinel(u8, text.len, 0);
        @memcpy(line, text);
        env[n] = line.ptr;
        n += 1;
    }
    for (extra) |entry| {
        if (n == env.len - 1) break;
        const line = try arena.allocSentinel(u8, entry.len, 0);
        @memcpy(line, entry);
        env[n] = line.ptr;
        n += 1;
    }
    env[n] = null;
    return env;
}

/// Whether the caller's own environment carries this name.
fn replaced(name: []const u8, extra: []const []const u8) bool {
    for (extra) |entry| {
        if (entry.len > name.len and entry[name.len] == '=' and std.mem.eql(u8, entry[0..name.len], name)) return true;
    }
    return false;
}

/// Room for the environment nanomon hands a tool.
const Env = [16:null]?[*:0]const u8;

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

/// Where a tool that has no fixed home is looked for, after `$PATH`.
const tool_dirs = [_][]const u8{ "/opt/homebrew/bin", "/usr/local/bin", "/opt/homebrew/sbin" };

/// The same, relative to the home folder: cargo's, bun's, pipx's, and the
/// user's own bin folders. A window opened from the Dock has none of these
/// on its `PATH`.
const home_tool_dirs = [_][]const u8{ ".cargo/bin", ".bun/bin", ".local/bin", "bin", "Library/pnpm/bin" };

/// Find an executable by name, or null. `scratch` holds the path being
/// tried; the answer points into it, and is valid until the next call.
pub fn which(name: []const u8, scratch: []u8) ?[]const u8 {
    if (!posix) return null;
    if (getenv("PATH")) |path| {
        var it = std.mem.tokenizeScalar(u8, std.mem.span(path), ':');
        while (it.next()) |dir| {
            if (executableIn(dir, name, scratch)) |found| return found;
        }
    }
    for (tool_dirs) |dir| {
        if (executableIn(dir, name, scratch)) |found| return found;
    }
    const home = if (getenv("HOME")) |value| std.mem.span(value) else return null;
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    for (home_tool_dirs) |relative| {
        const dir = std.fmt.bufPrint(&dir_buffer, "{s}/{s}", .{ home, relative }) catch continue;
        if (executableIn(dir, name, scratch)) |found| return found;
    }
    return null;
}

/// `<dir>/<name>`, when it is there and may be run.
fn executableIn(dir: []const u8, name: []const u8, scratch: []u8) ?[]const u8 {
    const path = std.fmt.bufPrint(scratch, "{s}/{s}", .{ dir, name }) catch return null;
    const z = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return null;
    defer std.heap.page_allocator.free(z);
    @memcpy(z, path);
    // X_OK: executable by this process.
    if (access(z.ptr, 1) != 0) return null;
    return path;
}

/// The JSON in what a command said, without the warnings around it. Tools
/// write "Warning: …" to the same pipe, and a parser will not take the lot.
/// An answer can be an object (`brew info`) or an array (`pnpm ls -g`), so
/// the closer that matches the opener is the one looked for.
pub fn jsonSlice(out: []const u8) []const u8 {
    const brace = std.mem.indexOfScalar(u8, out, '{');
    const bracket = std.mem.indexOfScalar(u8, out, '[');
    const braces = (brace orelse out.len) <= (bracket orelse out.len);
    const open = (if (braces) brace else bracket) orelse return out;
    const shut = (if (braces) std.mem.lastIndexOfScalar(u8, out, '}') else std.mem.lastIndexOfScalar(u8, out, ']')) orelse return out;
    if (shut <= open) return out;
    return out[open .. shut + 1];
}

test "a command's answer comes back, and a missing one does not fail" {
    if (!posix) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const out = try run(allocator, &.{ "/bin/echo", "hello" });
    defer allocator.free(out);
    try std.testing.expectEqualStrings("hello\n", out);

    const nothing = try run(allocator, &.{"/bin/echo"});
    defer allocator.free(nothing);
    try std.testing.expectEqualStrings("\n", nothing);

    const missing = try run(allocator, &.{"/nope/not/here"});
    defer allocator.free(missing);
    try std.testing.expectEqual(@as(usize, 0), missing.len);

    // The exit status is what the removals are judged by.
    const good = try runOk(allocator, &.{ "/bin/echo", "hi" });
    defer allocator.free(good.out);
    try std.testing.expect(good.ok);
    const bad = try runOk(allocator, &.{ "/bin/ls", "/nope/not/here" });
    defer allocator.free(bad.out);
    try std.testing.expect(!bad.ok);
}

test "the JSON is found among the warnings" {
    try std.testing.expectEqualStrings("{\"a\":1}", jsonSlice("Warning: something\n{\"a\":1}\n"));
    try std.testing.expectEqualStrings("{}", jsonSlice("{}"));
    // An array answer, and an object with an array inside it.
    try std.testing.expectEqualStrings("[{\"a\":1}]", jsonSlice("warn\n[{\"a\":1}]\n"));
    try std.testing.expectEqualStrings("{\"a\":[1,2]}", jsonSlice("{\"a\":[1,2]}"));
    try std.testing.expectEqualStrings("no json here", jsonSlice("no json here"));
}
