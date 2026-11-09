//! The Processes page's search: what a typed query asks for, and whether a
//! process answers it.
//!
//! - words show a process when any of them is in its name, path, user or
//!   pid: `chrome mail`, `"Google Chrome"`, `mai`;
//! - `-word` hides it: `-helper`;
//! - `user:root`, `cpu>10`, `mem>1GB` (and `<`, `>=`, `<=`) ask for more:
//!   every one of those holds too;
//! - `:3000` asks for a process listening on that port (ports.zig).
const std = @import("std");
const model = @import("model.zig");
const ports = @import("ports.zig");

/// The most words a query keeps, either way.
pub const max_words = 12;
/// The most words a query may be made of, quotes and all.
const max_tokens = 32;

/// A number to compare a process's by: above it (`>`, `>=`) or below.
pub const Compare = struct {
    value: f64,
    above: bool = true,
    strict: bool = true,
};

pub const Query = struct {
    /// Words any one of which shows the process.
    words: [max_words][]const u8 = @splat(""),
    nwords: usize = 0,
    /// Words any one of which hides it.
    not: [max_words][]const u8 = @splat(""),
    nnot: usize = 0,
    /// The user running it, its port, and its CPU and memory.
    user: ?[]const u8 = null,
    port: ?u16 = null,
    cpu: ?Compare = null,
    mem: ?Compare = null,

    pub fn empty(q: Query) bool {
        return q.nwords == 0 and q.nnot == 0 and q.user == null and q.port == null and q.cpu == null and q.mem == null;
    }

    fn word(q: *Query, w: []const u8) void {
        if (q.nwords < max_words) {
            q.words[q.nwords] = w;
            q.nwords += 1;
        }
    }

    fn hide(q: *Query, w: []const u8) void {
        if (q.nnot < max_words) {
            q.not[q.nnot] = w;
            q.nnot += 1;
        }
    }
};

const Token = struct { text: []const u8, quoted: bool = false };

/// Reads `text` as a query: its words point into it, so it must outlive the
/// query (the search field's buffer does).
pub fn parse(text: []const u8) Query {
    var toks: [max_tokens]Token = @splat(.{ .text = "" });
    const n = tokenize(text, &toks);
    var q: Query = .{};
    var t: usize = 0;
    while (t < n) : (t += 1) {
        const tok = toks[t];
        if (!tok.quoted and tok.text.len > 1) {
            if (tok.text[0] == '-') {
                q.hide(tok.text[1..]);
                continue;
            }
            if (std.ascii.startsWithIgnoreCase(tok.text, "user:")) {
                const rest = tok.text["user:".len..];
                if (rest.len > 0) q.user = rest else if (t + 1 < n) {
                    t += 1;
                    q.user = toks[t].text;
                }
                continue;
            }
            if (tok.text[0] == ':') {
                if (std.fmt.parseInt(u16, tok.text[1..], 10)) |port| {
                    q.port = port;
                    continue;
                } else |_| {}
            }
            if (ask(tok.text)) |a| {
                const o = operand(toks[0..n], t + 1, a.key, a.rest) orelse {
                    q.word(tok.text);
                    continue;
                };
                // The words it took are behind it now.
                t = o.next - 1;
                switch (a.key) {
                    .cpu => q.cpu = .{ .value = o.value, .above = o.above, .strict = o.strict },
                    .mem => q.mem = .{ .value = o.value, .above = o.above, .strict = o.strict },
                }
                continue;
            }
        }
        if (tok.text.len > 0) q.word(tok.text);
    }
    return q;
}

fn tokenize(text: []const u8, toks: *[max_tokens]Token) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (n < toks.len) {
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len) break;
        if (text[i] == '"') {
            const end = std.mem.indexOfScalarPos(u8, text, i + 1, '"') orelse text.len;
            toks[n] = .{ .text = text[i + 1 .. end], .quoted = true };
            n += 1;
            i = if (end < text.len) end + 1 else text.len;
            continue;
        }
        var j = i;
        while (j < text.len and !std.ascii.isWhitespace(text[j])) j += 1;
        toks[n] = .{ .text = text[i..j] };
        n += 1;
        i = j;
    }
    return n;
}

const Key = enum { cpu, mem };

/// What a word asks to compare: `cpu>` (`cpu > 10`, `cpu>10`), `mem>=`.
const Ask = struct { key: Key, rest: []const u8 };

fn ask(word: []const u8) ?Ask {
    // Longest first: `memory` before `mem`.
    const keys = [_]struct { []const u8, Key }{
        .{ "memory", .mem },
        .{ "cpu", .cpu },
        .{ "mem", .mem },
    };
    for (keys) |k| {
        if (!std.ascii.startsWithIgnoreCase(word, k[0])) continue;
        const rest = word[k[0].len..];
        // A word that only starts with a key (`cpufreq`) asks for nothing.
        if (rest.len > 0 and operator(rest) == null) continue;
        return .{ .key = k[1], .rest = rest };
    }
    return null;
}

/// A comparison's sign, and how long it is.
const Operator = struct { above: bool, strict: bool, len: usize };

fn operator(text: []const u8) ?Operator {
    if (std.mem.startsWith(u8, text, ">=")) return .{ .above = true, .strict = false, .len = 2 };
    if (std.mem.startsWith(u8, text, "<=")) return .{ .above = false, .strict = false, .len = 2 };
    if (std.mem.startsWith(u8, text, ">")) return .{ .above = true, .strict = true, .len = 1 };
    if (std.mem.startsWith(u8, text, "<")) return .{ .above = false, .strict = true, .len = 1 };
    return null;
}

/// The figure a key compares with: what follows it (`>10`, `> 10`, ` 10`),
/// in the same word or the words after, with a unit (`1 GB`) if it has one.
/// `next` is the first word it did not take.
const Operand = struct { value: f64, above: bool = true, strict: bool = true, next: usize };

fn operand(toks: []const Token, at: usize, key: Key, rest: []const u8) ?Operand {
    const n = toks.len;
    var above = true;
    var strict = true;
    var i = at;
    var text: []const u8 = rest;
    if (text.len == 0) {
        if (i >= n) return null;
        text = toks[i].text;
        i += 1;
    }
    if (operator(text)) |o| {
        above = o.above;
        strict = o.strict;
        text = text[o.len..];
        if (text.len == 0) {
            // `cpu > 10`: the figure is the word after.
            if (i >= n) return null;
            text = toks[i].text;
            i += 1;
        }
    }
    var k: usize = 0;
    while (k < text.len and (std.ascii.isDigit(text[k]) or text[k] == '.')) k += 1;
    if (k == 0) return null;
    const number = std.fmt.parseFloat(f64, text[0..k]) catch return null;
    const unit = text[k..];
    if (key == .cpu) {
        // A percent: `cpu>10`, `cpu> 12.5%`.
        if (unit.len > 0 and !std.mem.eql(u8, unit, "%")) return null;
        return .{ .value = number, .above = above, .strict = strict, .next = i };
    }
    if (unit.len > 0) return .{
        .value = withUnit(number, unit) orelse return null,
        .above = above,
        .strict = strict,
        .next = i,
    };
    // The unit may be the word after: `mem > 1 GB`; alone, a number is
    // megabytes, as the memory column shows them.
    if (i < n) if (withUnit(1, toks[i].text) != null) return .{
        .value = withUnit(number, toks[i].text).?,
        .above = above,
        .strict = strict,
        .next = i + 1,
    };
    return .{ .value = withUnit(number, "mb").?, .above = above, .strict = strict, .next = i };
}

/// `1 GB`, `512mb`, `1.5 GiB`; a number without a unit is megabytes.
fn withUnit(number: f64, unit: []const u8) ?f64 {
    const units = [_]struct { []const u8, f64 }{
        .{ "kib", 1 << 10 }, .{ "mib", 1 << 20 }, .{ "gib", 1 << 30 }, .{ "tib", 1 << 40 },
        .{ "kb", 1 << 10 },  .{ "mb", 1 << 20 },  .{ "gb", 1 << 30 },  .{ "tb", 1 << 40 },
        .{ "k", 1 << 10 },   .{ "m", 1 << 20 },   .{ "g", 1 << 30 },   .{ "t", 1 << 40 },
        .{ "b", 1 },
    };
    for (units) |u| if (std.ascii.eqlIgnoreCase(unit, u[0])) return number * u[1];
    if (std.ascii.eqlIgnoreCase(unit, "bytes")) return number;
    return null;
}

/// Whether `p` shows for `q`: any word in it, no hidden word in it, and its
/// user, port, CPU and memory as asked.
pub fn matches(p: model.Process, q: Query, listening: *const ports.Ports) bool {
    if (q.user) |u| if (!std.ascii.startsWithIgnoreCase(p.user, u)) return false;
    if (q.port) |port| if (!listening.listening(p.pid, port)) return false;
    if (q.cpu) |c| if (!holds(c, p.cpu)) return false;
    if (q.mem) |m| if (!holds(m, @floatFromInt(p.memory))) return false;
    for (q.not[0..q.nnot]) |w| if (inProcess(p, w)) return false;
    if (q.nwords == 0) return true;
    for (q.words[0..q.nwords]) |w| if (inProcess(p, w)) return true;
    return false;
}

/// Whether an app's `name` shows for `q`: the words, without a process's
/// own figures (the Apps page has none).
pub fn names(q: Query, name: []const u8) bool {
    for (q.not[0..q.nnot]) |w| if (contains(name, w)) return false;
    if (q.nwords == 0) return true;
    for (q.words[0..q.nwords]) |w| if (contains(name, w)) return true;
    return false;
}

fn holds(c: Compare, v: f64) bool {
    if (c.above) return if (c.strict) v > c.value else v >= c.value;
    return if (c.strict) v < c.value else v <= c.value;
}

fn inProcess(p: model.Process, w: []const u8) bool {
    if (contains(p.name, w) or contains(p.path, w) or contains(p.user, w)) return true;
    var buf: [16]u8 = undefined;
    const pid = std.fmt.bufPrint(&buf, "{d}", .{p.pid}) catch return false;
    return std.mem.startsWith(u8, pid, w);
}

fn contains(s: []const u8, w: []const u8) bool {
    if (w.len > s.len) return false;
    for (0..s.len - w.len + 1) |i| if (std.ascii.eqlIgnoreCase(s[i..][0..w.len], w)) return true;
    return false;
}

const P = model.Process;

fn proc(mem: u64) P {
    return .{ .pid = 990001, .ppid = 1, .uid = 501, .name = "Google Chrome Helper", .path = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome Helper", .user = "me", .cpu = 12.5, .memory = mem };
}

test "the words, quoted and hidden" {
    var q = parse("  ");
    try std.testing.expect(q.empty());
    q = parse("\"Google Chrome\" Notion");
    try std.testing.expectEqual(@as(usize, 2), q.nwords);
    try std.testing.expectEqualStrings("Google Chrome", q.words[0]);
    try std.testing.expectEqualStrings("Notion", q.words[1]);
    q = parse("chrome -helper");
    try std.testing.expectEqual(@as(usize, 1), q.nwords);
    try std.testing.expectEqual(@as(usize, 1), q.nnot);
    try std.testing.expectEqualStrings("helper", q.not[0]);
}

test "cpu, memory, user and port" {
    var q = parse("cpu>10");
    try std.testing.expectEqual(@as(f64, 10), q.cpu.?.value);
    try std.testing.expect(q.cpu.?.above and q.cpu.?.strict);
    q = parse("CPU > 10");
    try std.testing.expectEqual(@as(f64, 10), q.cpu.?.value);
    q = parse("cpu<=5%");
    try std.testing.expect(!q.cpu.?.above and !q.cpu.?.strict);
    try std.testing.expectEqual(@as(f64, 5), q.cpu.?.value);
    q = parse("mem > 1 GB");
    try std.testing.expectEqual(@as(f64, 1 << 30), q.mem.?.value);
    q = parse("mem>512mb");
    try std.testing.expectEqual(@as(f64, 512 << 20), q.mem.?.value);
    q = parse("memory>=2");
    try std.testing.expectEqual(@as(f64, 2 << 20), q.mem.?.value);
    q = parse("user:root");
    try std.testing.expectEqualStrings("root", q.user.?);
    q = parse("user: root");
    try std.testing.expectEqualStrings("root", q.user.?);
    q = parse(":3000");
    try std.testing.expectEqual(@as(u16, 3000), q.port.?);
    // Not an ask: a word that only starts with cpu.
    q = parse("cpufreq");
    try std.testing.expect(q.cpu == null and q.nwords == 1);
    // Malformed figure values: fallback to word treatment.
    q = parse("cpu>abc");
    try std.testing.expect(q.cpu == null and q.nwords == 1);
    q = parse("mem>xyz");
    try std.testing.expect(q.mem == null and q.nwords == 1);
    // Unknown units: fallback to word treatment.
    q = parse("mem>1X");
    try std.testing.expect(q.mem == null and q.nwords == 1);
    q = parse("cpu>10PB");
    try std.testing.expect(q.cpu == null and q.nwords == 1);
}

test "what shows" {
    var none: ports.Ports = .{};
    defer none.deinit(std.testing.allocator);
    const chrome = proc(900 << 20);
    try std.testing.expect(matches(chrome, parse("chrome"), &none));
    try std.testing.expect(matches(chrome, parse("CHROME"), &none));
    try std.testing.expect(matches(chrome, parse("helper"), &none));
    // The path it runs from.
    try std.testing.expect(matches(chrome, parse("Contents/MacOS"), &none));
    // Its pid's first digits.
    try std.testing.expect(matches(chrome, parse("990"), &none));
    // Any of the words.
    try std.testing.expect(matches(chrome, parse("safari chrome"), &none));
    try std.testing.expect(!matches(chrome, parse("safari mail"), &none));
    // Hidden words.
    try std.testing.expect(!matches(chrome, parse("-helper"), &none));
    try std.testing.expect(matches(chrome, parse("-safari"), &none));
    // Figures.
    try std.testing.expect(matches(chrome, parse("cpu>10"), &none));
    try std.testing.expect(!matches(chrome, parse("cpu>20"), &none));
    // The words around an ask are searched for like any other.
    try std.testing.expect(matches(chrome, parse("mem < 1 GB chrome"), &none));
    try std.testing.expect(!matches(chrome, parse("mem < 1 GB safari"), &none));
    try std.testing.expect(matches(chrome, parse("mem>800MB"), &none));
    try std.testing.expect(!matches(chrome, parse("mem>1GB"), &none));
    try std.testing.expect(matches(chrome, parse("user:me"), &none));
    try std.testing.expect(!matches(chrome, parse("user:root"), &none));
    // A port it does not listen on.
    try std.testing.expect(!matches(chrome, parse(":3000"), &none));
}

test "what shows of the ports" {
    const gpa = std.testing.allocator;
    var p: ports.Ports = .{};
    defer p.deinit(gpa);
    try p.by_pid.put(gpa, 990001, .{ .count = 1, .list = .{ 3000, 0, 0, 0, 0, 0, 0, 0 } });
    const chrome = proc(900 << 20);
    try std.testing.expect(matches(chrome, parse(":3000"), &p));
    try std.testing.expect(!matches(chrome, parse(":3001"), &p));
    try std.testing.expect(matches(chrome, parse(":3000 chrome"), &p));
}
