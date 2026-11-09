//! The ports processes listen on (TCP), from `lsof`: asked every few
//! samples without waiting for it: its output is read as it comes
//! (`nanoui.fdwatch`) and the last complete answer is kept.
//!
//! lsof shows the sockets this user may see, as ps shows the processes it
//! may see: the other users' are the root's. Elsewhere than macOS the
//! ports are not read yet, and no process listens on one.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");

extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn posix_spawn(pid: *c_int, path: [*:0]const u8, actions: ?*const anyopaque, attr: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn posix_spawn_file_actions_init(a: *?*anyopaque) c_int;
extern "c" fn posix_spawn_file_actions_destroy(a: *?*anyopaque) c_int;
extern "c" fn posix_spawn_file_actions_adddup2(a: *?*anyopaque, fd: c_int, newfd: c_int) c_int;
extern "c" fn posix_spawn_file_actions_addclose(a: *?*anyopaque, fd: c_int) c_int;

/// Whether the ports can be read here: macOS's lsof knows the pids.
pub const supported = builtin.os.tag == .macos;

/// Samples between two asks: lsof is slower than ps, and ports change less.
const every = 15;

/// The most ports kept for one process (a browser may listen on more).
pub const max_ports = 8;

pub const Notify = struct { ctx: *anyopaque, func: *const fn (*anyopaque) void };

/// The ports one process listens on.
pub const Entry = struct {
    count: u8 = 0,
    list: [max_ports]u16 = @splat(0),

    pub fn add(e: *Entry, port: u16) void {
        for (e.list[0..e.count]) |p| if (p == port) return;
        if (e.count == max_ports) return;
        e.list[e.count] = port;
        e.count += 1;
    }

    pub fn has(e: Entry, port: u16) bool {
        for (e.list[0..e.count]) |p| if (p == port) return true;
        return false;
    }
};

pub const Ports = struct {
    by_pid: std.AutoHashMapUnmanaged(i32, Entry) = .empty,
    /// The ask in flight.
    pid: c_int = 0,
    fd: c_int = -1,
    watch: ?nanoui.fdwatch.Watch = null,
    out: std.ArrayList(u8) = .empty,
    gpa: ?std.mem.Allocator = null,
    /// Told when an answer has come.
    notify: ?Notify = null,

    pub fn deinit(p: *Ports, gpa: std.mem.Allocator) void {
        p.stop();
        p.by_pid.deinit(gpa);
        p.out.deinit(gpa);
    }

    /// Whether process `pid` listens on `port`.
    pub fn listening(p: *const Ports, pid: i32, port: u16) bool {
        const e = p.by_pid.get(pid) orelse return false;
        return e.has(port);
    }

    /// Asks lsof again on every `every`th sample, if no ask is in flight.
    pub fn refresh(p: *Ports, gpa: std.mem.Allocator, n: usize) void {
        if (comptime !supported) return;
        if (p.fd >= 0 or n % every != 0) return;
        p.gpa = gpa;
        var fds: [2]c_int = undefined;
        if (pipe(&fds) != 0) return;
        var fa: ?*anyopaque = null;
        _ = posix_spawn_file_actions_init(&fa);
        defer _ = posix_spawn_file_actions_destroy(&fa);
        _ = posix_spawn_file_actions_adddup2(&fa, fds[1], 1);
        _ = posix_spawn_file_actions_addclose(&fa, fds[0]);
        const argv = [_:null]?[*:0]const u8{ "/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn" };
        const envp = [_:null]?[*:0]const u8{"LC_ALL=C"};
        var pid: c_int = 0;
        const rc = posix_spawn(&pid, "/usr/sbin/lsof", @ptrCast(&fa), null, &argv, &envp);
        _ = close(fds[1]);
        if (rc != 0) {
            _ = close(fds[0]);
            return;
        }
        p.pid = pid;
        p.fd = fds[0];
        _ = fcntl(p.fd, 4, @as(c_int, 0x4)); // O_NONBLOCK
        p.out.clearRetainingCapacity();
        p.watch = nanoui.fdwatch.readable(p.fd, p, onReadable) catch {
            p.stop();
            return;
        };
    }

    fn onReadable(ctx: ?*anyopaque) callconv(.c) void {
        const p: *Ports = @ptrCast(@alignCast(ctx));
        const gpa = p.gpa orelse return;
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            const n = read(p.fd, &buf, buf.len);
            if (n > 0) {
                p.out.appendSlice(gpa, buf[0..@intCast(n)]) catch {};
                continue;
            }
            if (n == 0) {
                // The end: what it said replaces what it said before.
                p.by_pid.clearRetainingCapacity();
                parse(gpa, &p.by_pid, p.out.items);
                p.stop();
                if (p.notify) |tell| tell.func(tell.ctx);
            }
            return;
        }
    }

    fn stop(p: *Ports) void {
        if (p.watch) |w| w.cancel();
        p.watch = null;
        if (p.fd >= 0) _ = close(p.fd);
        p.fd = -1;
        if (p.pid > 0) {
            var status: c_int = 0;
            _ = waitpid(p.pid, &status, 0);
        }
        p.pid = 0;
    }
};

/// `lsof -Fpn` lines: `p<pid>` starts a process's, `n*:3000`,
/// `n127.0.0.1:8080` and `n[::1]:443` are its listening sockets, whose
/// port follows the last ':'.
pub fn parse(gpa: std.mem.Allocator, out: *std.AutoHashMapUnmanaged(i32, Entry), text: []const u8) void {
    var pid: i32 = 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len < 2) continue;
        switch (line[0]) {
            'p' => pid = std.fmt.parseInt(i32, line[1..], 10) catch 0,
            'n' => {
                if (pid == 0) continue;
                const colon = std.mem.lastIndexOfScalar(u8, line, ':') orelse continue;
                const port = std.fmt.parseInt(u16, line[colon + 1 ..], 10) catch continue;
                const gop = out.getOrPut(gpa, pid) catch return;
                if (!gop.found_existing) gop.value_ptr.* = .{};
                gop.value_ptr.add(port);
            },
            else => {},
        }
    }
}

test "what lsof says" {
    const gpa = std.testing.allocator;
    var m: std.AutoHashMapUnmanaged(i32, Entry) = .empty;
    defer m.deinit(gpa);
    parse(gpa, &m, "p648\nf11\nn*:7000\nf12\nn*:7000\nf13\nn127.0.0.1:44950\np924\nf9\nn[::1]:443\nbad\n");
    try std.testing.expect(m.get(648).?.has(7000));
    try std.testing.expect(m.get(648).?.has(44950));
    try std.testing.expect(!m.get(648).?.has(3000));
    try std.testing.expectEqual(@as(u8, 2), m.get(648).?.count);
    try std.testing.expect(m.get(924).?.has(443));
}
