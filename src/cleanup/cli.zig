//! The command-line tools the machine has, and the newer versions their own
//! managers offer.
//!
//! One row per tool, from whatever put it there: Homebrew's formulae, npm's,
//! pnpm's and bun's global packages, pipx's environments, cargo's binaries,
//! and the programs that were simply downloaded into a folder of the user's
//! own, which no manager knows about.
//!
//! Each manager is asked twice. First what it has installed, which is local
//! and quick; then its own `outdated`, which is the one part of a scan that
//! reaches the network. A manager that is not on the machine, or that will
//! not answer, leaves no rows behind and does not fail the pass.
//!
//! Nothing here removes anything: a row carries the command its manager would
//! run, and `remove.zig` runs it when the page asks.
const std = @import("std");
const builtin = @import("builtin");
const item_mod = @import("item.zig");
const CacheItem = item_mod.CacheItem;
const Removal = item_mod.Removal;
const Update = item_mod.Update;
const safety = @import("safety.zig");
const exec = @import("exec.zig");
const remove = @import("remove.zig");
const brew = @import("brew.zig");

pub const Options = struct {
    home: []const u8,
    /// Whether the managers may be asked at all. A test's own home sets this
    /// false, so a test never reads — or offers — the real machine's tools.
    machine: bool = true,
    /// How many tools one manager may contribute.
    max_per_manager: usize = 400,
    /// Where each manager's rows go the moment it has answered, so the page
    /// fills in manager by manager rather than at the end of the pass. The
    /// scanner measures them and hands them on; null keeps them here.
    batch: ?item_mod.Batch = null,
};

/// The folders that hold programs nobody manages, relative to the home
/// folder. The managers put their own commands here as symlinks, so only real
/// files are counted: what is left was downloaded.
const downloaded_dirs = [_][]const u8{ ".local/bin", "bin" };

/// What one manager says it has installed. Every string is allocated.
pub const Tool = struct {
    name: []const u8,
    version: ?[]const u8 = null,
    /// Where it lives, when the manager's answer says (a pipx environment).
    path: ?[]const u8 = null,
    /// The first command a crate installed, when that is all there is to go
    /// on (cargo names its binaries, not their folder).
    binary: ?[]const u8 = null,
};

/// Every tool on the machine, unmeasured: the scanner fills the sizes in.
pub fn scan(allocator: std.mem.Allocator, io: std.Io, opts: Options) !std.ArrayListUnmanaged(*CacheItem) {
    var items = std.ArrayListUnmanaged(*CacheItem).empty;
    errdefer discard(allocator, &items);
    // One manager at a time, each into a list of its own: what one manager
    // found is handed over before the next is asked.
    var batch: std.ArrayListUnmanaged(*CacheItem) = .empty;
    defer batch.deinit(allocator);
    if (opts.machine) {
        try addBrew(allocator, io, &batch, opts);
        try handOver(allocator, &batch, &items, opts);
        try addNpm(allocator, &batch, opts);
        try handOver(allocator, &batch, &items, opts);
        try addPnpm(allocator, &batch, opts);
        try handOver(allocator, &batch, &items, opts);
        try addBun(allocator, &batch, opts);
        try handOver(allocator, &batch, &items, opts);
        try addPipx(allocator, io, &batch, opts);
        try handOver(allocator, &batch, &items, opts);
        try addCargo(allocator, &batch, opts);
        try handOver(allocator, &batch, &items, opts);
    }
    // The downloaded ones are the user's own files, not the machine's: a scan
    // of a test's home looks at that home's folders.
    try addDownloaded(allocator, io, &batch, opts);
    try handOver(allocator, &batch, &items, opts);
    return items;
}

/// Hand one manager's rows over: to the scan's sink when it has one, or into
/// the list this pass returns.
fn handOver(allocator: std.mem.Allocator, batch: *std.ArrayListUnmanaged(*CacheItem), items: *std.ArrayListUnmanaged(*CacheItem), opts: Options) !void {
    defer batch.clearRetainingCapacity();
    if (opts.batch) |b| {
        b.give(b.ctx, .cli, batch);
        return;
    }
    try items.appendSlice(allocator, batch.items);
}

/// Homebrew's formulae, sized by their Cellar folder the way they always
/// were, now with the version and what `brew upgrade` would make of it.
fn addBrew(allocator: std.mem.Allocator, io: std.Io, items: *std.ArrayListUnmanaged(*CacheItem), opts: Options) !void {
    const brew_bin = remove.brewPath() orelse return;

    const listed = exec.runEnv(allocator, &.{ brew_bin, "list", "--formula", "--versions" }, &brew.env) catch return;
    defer allocator.free(listed);
    var tools = try parseBrewVersions(allocator, listed);
    defer freeTools(allocator, &tools);

    var outdated = std.StringHashMapUnmanaged([]const u8).empty;
    defer freeVersions(allocator, &outdated);
    if (exec.runEnv(allocator, &.{ brew_bin, "outdated", "--json=v2" }, &brew.env)) |answer| {
        defer allocator.free(answer);
        collectBrewVersions(allocator, answer, &outdated) catch {};
    } else |_| {}

    const cellar = try cellarOf(allocator, brew_bin);
    defer allocator.free(cellar);

    var added: usize = 0;
    for (tools.items) |tool| {
        if (added >= opts.max_per_manager) break;
        const path = try std.fs.path.join(allocator, &.{ cellar, tool.name });
        defer allocator.free(path);
        if (!isDir(io, path)) continue;
        try addTool(allocator, items, .{
            .name = tool.name,
            .path = path,
            .where = "Homebrew",
            .headline = "Homebrew tool",
            .manager = "Homebrew",
            .reinstall = "brew install",
            .removal = .brew_formula,
            .update = .brew_upgrade,
            .version = tool.version,
            .latest = outdated.get(tool.name),
        });
        added += 1;
    }
}

/// npm's global packages, sized by the folder each one lives in.
fn addNpm(allocator: std.mem.Allocator, items: *std.ArrayListUnmanaged(*CacheItem), opts: Options) !void {
    const npm = remove.toolPath(allocator, "npm") orelse return;
    defer allocator.free(npm);

    const listed = exec.run(allocator, &.{ npm, "ls", "-g", "--depth=0", "--json" }) catch return;
    defer allocator.free(listed);
    var tools = try parseNpmLs(allocator, listed);
    defer freeTools(allocator, &tools);
    if (tools.items.len == 0) return;

    const root_answer = exec.run(allocator, &.{ npm, "root", "-g" }) catch return;
    defer allocator.free(root_answer);
    const root = lastLine(root_answer);
    if (root.len == 0) return;

    var outdated = std.StringHashMapUnmanaged([]const u8).empty;
    defer freeVersions(allocator, &outdated);
    // npm exits non-zero when it finds one, which is not a failure here.
    if (exec.run(allocator, &.{ npm, "outdated", "-g", "--json" })) |answer| {
        defer allocator.free(answer);
        collectLatestVersions(allocator, answer, &outdated) catch {};
    } else |_| {}

    var added: usize = 0;
    for (tools.items) |tool| {
        if (added >= opts.max_per_manager) break;
        const path = try std.fs.path.join(allocator, &.{ root, tool.name });
        defer allocator.free(path);
        if (!exists(path)) continue;
        try addTool(allocator, items, .{
            .name = tool.name,
            .path = path,
            .where = "npm -g",
            .headline = "npm tool",
            .manager = "npm",
            .reinstall = "npm install -g",
            .removal = .npm_global,
            .update = .npm_latest,
            .version = tool.version,
            .latest = outdated.get(tool.name),
        });
        added += 1;
    }
}

/// pnpm's global packages. pnpm refuses every global question until its own
/// bin folder is on `PATH`, so the call carries one.
fn addPnpm(allocator: std.mem.Allocator, items: *std.ArrayListUnmanaged(*CacheItem), opts: Options) !void {
    const pnpm = remove.toolPath(allocator, "pnpm") orelse return;
    defer allocator.free(pnpm);
    const env = try pnpmEnv(allocator, opts.home);
    defer allocator.free(env);
    const envp = [_][]const u8{env};

    const listed = exec.runEnv(allocator, &.{ pnpm, "ls", "-g", "--depth", "0", "--json" }, &envp) catch return;
    defer allocator.free(listed);
    var tools = try parsePnpmLs(allocator, listed);
    defer freeTools(allocator, &tools);
    if (tools.items.len == 0) return;

    // pnpm names the folder each package is in; its own root is only a
    // fallback for an answer that did not.
    var root: []const u8 = "";
    var root_answer: ?[]u8 = null;
    defer if (root_answer) |answer| allocator.free(answer);
    for (tools.items) |tool| {
        if (tool.path != null) continue;
        root_answer = exec.runEnv(allocator, &.{ pnpm, "root", "-g" }, &envp) catch null;
        root = if (root_answer) |answer| lastLine(answer) else "";
        break;
    }

    var outdated = std.StringHashMapUnmanaged([]const u8).empty;
    defer freeVersions(allocator, &outdated);
    if (exec.runEnv(allocator, &.{ pnpm, "outdated", "-g", "--format", "json" }, &envp)) |answer| {
        defer allocator.free(answer);
        collectLatestVersions(allocator, answer, &outdated) catch {};
    } else |_| {}

    var added: usize = 0;
    for (tools.items) |tool| {
        if (added >= opts.max_per_manager) break;
        const path = if (tool.path) |given|
            try allocator.dupe(u8, given)
        else
            try std.fs.path.join(allocator, &.{ root, tool.name });
        defer allocator.free(path);
        if (!exists(path)) continue;
        try addTool(allocator, items, .{
            .name = tool.name,
            .path = path,
            .where = "pnpm -g",
            .headline = "pnpm tool",
            .manager = "pnpm",
            .reinstall = "pnpm add -g",
            .removal = .pnpm_global,
            .update = .pnpm_latest,
            .version = tool.version,
            .latest = outdated.get(tool.name),
        });
        added += 1;
    }
}

/// bun's global packages, from its own tree: the first line names the folder
/// they all live in.
fn addBun(allocator: std.mem.Allocator, items: *std.ArrayListUnmanaged(*CacheItem), opts: Options) !void {
    const bun = remove.toolPath(allocator, "bun") orelse return;
    defer allocator.free(bun);

    const listed = exec.run(allocator, &.{ bun, "pm", "ls", "-g" }) catch return;
    defer allocator.free(listed);
    var tools = try parseBunTree(allocator, listed);
    defer freeTools(allocator, &tools);
    if (tools.items.len == 0) return;
    const root = parseBunRoot(listed) orelse return;

    var outdated = std.StringHashMapUnmanaged([]const u8).empty;
    defer freeVersions(allocator, &outdated);
    if (exec.run(allocator, &.{ bun, "outdated", "-g" })) |answer| {
        defer allocator.free(answer);
        collectBunVersions(allocator, answer, &outdated) catch {};
    } else |_| {}

    var added: usize = 0;
    for (tools.items) |tool| {
        if (added >= opts.max_per_manager) break;
        const path = try std.fs.path.join(allocator, &.{ root, "node_modules", tool.name });
        defer allocator.free(path);
        if (!exists(path)) continue;
        try addTool(allocator, items, .{
            .name = tool.name,
            .path = path,
            .where = "bun -g",
            .headline = "bun tool",
            .manager = "bun",
            .reinstall = "bun add -g",
            .removal = .bun_global,
            .update = .bun_latest,
            .version = tool.version,
            .latest = outdated.get(tool.name),
        });
        added += 1;
    }
}

/// The tools pipx keeps in environments of their own — the way a Python
/// command-line program is meant to be installed. What plain `pip` writes
/// lands in Homebrew's or the system's own prefix, which nanomon never
/// touches.
fn addPipx(allocator: std.mem.Allocator, io: std.Io, items: *std.ArrayListUnmanaged(*CacheItem), opts: Options) !void {
    const pipx = remove.toolPath(allocator, "pipx") orelse return;
    defer allocator.free(pipx);

    const listed = exec.run(allocator, &.{ pipx, "list", "--json" }) catch return;
    defer allocator.free(listed);
    var tools = try parsePipxList(allocator, listed);
    defer freeTools(allocator, &tools);

    var added: usize = 0;
    for (tools.items) |tool| {
        if (added >= opts.max_per_manager) break;
        const path = tool.path orelse continue;
        if (!isDir(io, path)) continue;
        try addTool(allocator, items, .{
            .name = tool.name,
            .path = path,
            .where = "pipx",
            .headline = "pipx tool",
            .manager = "pipx",
            .reinstall = "pipx install",
            .removal = .pipx_venv,
            .update = .pipx_upgrade,
            .version = tool.version,
        });
        added += 1;
    }
}

/// The binaries `cargo install` put in `~/.cargo/bin`. Nothing local says
/// whether a crate is behind, so they are offered an update that installs the
/// newest version, and no version to go to until one is asked for.
fn addCargo(allocator: std.mem.Allocator, items: *std.ArrayListUnmanaged(*CacheItem), opts: Options) !void {
    const cargo = remove.toolPath(allocator, "cargo") orelse return;
    defer allocator.free(cargo);

    const listed = exec.run(allocator, &.{ cargo, "install", "--list" }) catch return;
    defer allocator.free(listed);
    var tools = try parseCargoList(allocator, listed);
    defer freeTools(allocator, &tools);

    const bin_dir = try std.fs.path.join(allocator, &.{ opts.home, ".cargo", "bin" });
    defer allocator.free(bin_dir);

    var added: usize = 0;
    for (tools.items) |tool| {
        if (added >= opts.max_per_manager) break;
        // The crate's first binary is the one to measure and name; a crate
        // that installs several (cargo-edit does) is still one row.
        const binary = tool.binary orelse tool.name;
        const path = try std.fs.path.join(allocator, &.{ bin_dir, binary });
        defer allocator.free(path);
        if (!exists(path)) continue;
        try addTool(allocator, items, .{
            .name = tool.name,
            .path = path,
            .where = "cargo",
            .headline = "cargo tool",
            .manager = "cargo",
            .reinstall = "cargo install",
            .removal = .cargo_install,
            .update = .cargo_install,
            .version = tool.version,
        });
        added += 1;
    }
}

/// The programs in the user's own bin folders that no manager owns: a real
/// file, executable, and not one of the symlinks a manager left there. They
/// are the `curl`-and-a-binary kind, and they go to the Trash, so offering
/// them costs nothing that cannot be put back.
fn addDownloaded(allocator: std.mem.Allocator, io: std.Io, items: *std.ArrayListUnmanaged(*CacheItem), opts: Options) !void {
    var added: usize = 0;
    for (downloaded_dirs) |relative| {
        const dir_path = try std.fs.path.join(allocator, &.{ opts.home, relative });
        defer allocator.free(dir_path);
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        const where = try std.fmt.allocPrint(allocator, "~/{s}", .{relative});
        defer allocator.free(where);
        const explanation = try std.fmt.allocPrint(allocator, "A program that was downloaded into ~/{s} rather than installed by a package manager. It moves to the Trash, so it can be put back.", .{relative});
        defer allocator.free(explanation);

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (added >= opts.max_per_manager) break;
            if (entry.kind != .file) continue;
            if (!isExecutable(dir, io, entry.name)) continue;
            const full = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            defer allocator.free(full);
            const id = try std.fmt.allocPrint(allocator, "cli:downloaded:{s}", .{full});
            defer allocator.free(id);
            try items.append(allocator, try CacheItem.create(allocator, .{
                .id = id,
                .name = entry.name,
                .info = .{
                    .level = .medium,
                    .headline = "Downloaded tool",
                    .explanation = explanation,
                    .recovery_steps = "Put it back from the Trash.",
                },
                .category = .cli,
                .path = full,
                .where = where,
                .removal = .trash,
            }));
            added += 1;
        }
    }
}

/// One tool a manager installed: Check First, because uninstalling it is
/// real and only its manager can undo it.
const ToolSpec = struct {
    name: []const u8,
    path: []const u8,
    where: []const u8,
    headline: []const u8,
    manager: []const u8,
    reinstall: []const u8,
    removal: Removal,
    update: Update,
    version: ?[]const u8 = null,
    latest: ?[]const u8 = null,
};

fn addTool(allocator: std.mem.Allocator, items: *std.ArrayListUnmanaged(*CacheItem), spec: ToolSpec) !void {
    const id = try std.fmt.allocPrint(allocator, "cli:{s}:{s}", .{ spec.where, spec.name });
    defer allocator.free(id);
    const explanation = try std.fmt.allocPrint(allocator, "Installed by {s}. Uninstalling goes through {s}, which removes it for good — it does not go to the Trash.", .{ spec.manager, spec.manager });
    defer allocator.free(explanation);
    const reinstall = try std.fmt.allocPrint(allocator, "{s} {s}", .{ spec.reinstall, spec.name });
    defer allocator.free(reinstall);
    try items.append(allocator, try CacheItem.create(allocator, .{
        .id = id,
        .name = spec.name,
        .info = .{
            .level = .medium,
            .headline = spec.headline,
            .explanation = explanation,
            .recovery_steps = reinstall,
            .reinstall_command = reinstall,
        },
        .category = .cli,
        .path = spec.path,
        .where = spec.where,
        .removal = spec.removal,
        .target = spec.name,
        .update = spec.update,
        .installed_version = spec.version,
        .latest_version = spec.latest,
    }));
}

// ---------------------------------------------------------------------------
// What each manager says. Every parser below is pure: the tests feed it what
// a real command printed.
// ---------------------------------------------------------------------------

/// `brew list --formula --versions`: a formula per line, its versions after
/// it (a formula can have more than one; the last is the one in use).
pub fn parseBrewVersions(allocator: std.mem.Allocator, text: []const u8) !std.ArrayListUnmanaged(Tool) {
    var tools = std.ArrayListUnmanaged(Tool).empty;
    errdefer freeTools(allocator, &tools);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        var words = std.mem.tokenizeAny(u8, trimmed, " \t");
        const name = words.next() orelse continue;
        var version: ?[]const u8 = null;
        while (words.next()) |word| version = word;
        try tools.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .version = if (version) |found| try allocator.dupe(u8, found) else null,
        });
    }
    return tools;
}

/// `npm ls -g --depth=0 --json`: a package per key under `dependencies`.
pub fn parseNpmLs(allocator: std.mem.Allocator, text: []const u8) !std.ArrayListUnmanaged(Tool) {
    var tools = std.ArrayListUnmanaged(Tool).empty;
    errdefer freeTools(allocator, &tools);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, exec.jsonSlice(text), .{}) catch return tools;
    defer parsed.deinit();
    const dependencies = switch (parsed.value) {
        .object => |object| object.get("dependencies") orelse return tools,
        else => return tools,
    };
    if (dependencies != .object) return tools;
    var it = dependencies.object.iterator();
    while (it.next()) |entry| {
        const version = stringField(entry.value_ptr.*, "version");
        try tools.append(allocator, .{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .version = if (version) |found| try allocator.dupe(u8, found) else null,
        });
    }
    return tools;
}

/// `pnpm ls -g --depth 0 --json`: an array of roots, each with the packages
/// installed under it.
pub fn parsePnpmLs(allocator: std.mem.Allocator, text: []const u8) !std.ArrayListUnmanaged(Tool) {
    var tools = std.ArrayListUnmanaged(Tool).empty;
    errdefer freeTools(allocator, &tools);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, exec.jsonSlice(text), .{}) catch return tools;
    defer parsed.deinit();
    const roots = switch (parsed.value) {
        .array => |array| array,
        else => return tools,
    };
    for (roots.items) |root| {
        const dependencies = switch (root) {
            .object => |object| object.get("dependencies") orelse continue,
            else => continue,
        };
        if (dependencies != .object) continue;
        var it = dependencies.object.iterator();
        while (it.next()) |entry| {
            const version = stringField(entry.value_ptr.*, "version");
            try tools.append(allocator, .{
                .name = try allocator.dupe(u8, entry.key_ptr.*),
                .version = if (version) |found| try allocator.dupe(u8, found) else null,
                // pnpm's global layout has a hash folder in it, so the path
                // it reports is the only way to the package.
                .path = if (stringField(entry.value_ptr.*, "path")) |found| try allocator.dupe(u8, found) else null,
            });
        }
    }
    return tools;
}

/// `bun pm ls -g`: a tree of `name@version`, the top level only.
pub fn parseBunTree(allocator: std.mem.Allocator, text: []const u8) !std.ArrayListUnmanaged(Tool) {
    var tools = std.ArrayListUnmanaged(Tool).empty;
    errdefer freeTools(allocator, &tools);
    // The tree's own glyphs, whose length in bytes is not the one they look
    // like they have.
    const branch = "├── ";
    const leaf = "└── ";
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const entry = if (std.mem.startsWith(u8, trimmed, branch))
            trimmed[branch.len..]
        else if (std.mem.startsWith(u8, trimmed, leaf))
            trimmed[leaf.len..]
        else
            continue;
        // A scoped name starts with '@', so the version is after the *last*
        // one; `qmd@github:tobi/qmd#63028fd` is a version too.
        const at = std.mem.lastIndexOfScalar(u8, entry, '@') orelse continue;
        if (at == 0 or at + 1 >= entry.len) continue;
        try tools.append(allocator, .{
            .name = try allocator.dupe(u8, entry[0..at]),
            .version = try allocator.dupe(u8, entry[at + 1 ..]),
        });
    }
    return tools;
}

/// The folder `bun pm ls -g` names on its first line: where its global
/// packages live.
pub fn parseBunRoot(text: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const at = std.mem.indexOf(u8, trimmed, " node_modules") orelse continue;
        const root = std.mem.trim(u8, trimmed[0..at], " \t");
        if (root.len > 0 and root[0] == '/') return root;
    }
    return null;
}

/// `cargo install --list`: a crate per stanza, its binaries indented under
/// it. The first binary is the one the row points at.
pub fn parseCargoList(allocator: std.mem.Allocator, text: []const u8) !std.ArrayListUnmanaged(Tool) {
    var tools = std.ArrayListUnmanaged(Tool).empty;
    errdefer freeTools(allocator, &tools);
    var waiting: ?usize = null;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) {
            if (waiting) |index| {
                const binary = std.mem.trim(u8, line, " \t\r");
                if (binary.len > 0) {
                    tools.items[index].binary = try allocator.dupe(u8, binary);
                    waiting = null;
                }
            }
            continue;
        }
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.endsWith(u8, trimmed, ":")) continue;
        const body = trimmed[0 .. trimmed.len - 1];
        const at = std.mem.lastIndexOfScalar(u8, body, ' ') orelse continue;
        const version = body[at + 1 ..];
        try tools.append(allocator, .{
            .name = try allocator.dupe(u8, body[0..at]),
            .version = try allocator.dupe(u8, if (std.mem.startsWith(u8, version, "v")) version[1..] else version),
        });
        waiting = tools.items.len - 1;
    }
    return tools;
}

/// `pipx list --json`: an environment per tool, with the package it holds and
/// where its commands were put.
pub fn parsePipxList(allocator: std.mem.Allocator, text: []const u8) !std.ArrayListUnmanaged(Tool) {
    var tools = std.ArrayListUnmanaged(Tool).empty;
    errdefer freeTools(allocator, &tools);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, exec.jsonSlice(text), .{}) catch return tools;
    defer parsed.deinit();
    const venvs = switch (parsed.value) {
        .object => |object| object.get("venvs") orelse return tools,
        else => return tools,
    };
    if (venvs != .object) return tools;
    var it = venvs.object.iterator();
    while (it.next()) |entry| {
        // The name pipx knows the tool by is the environment's; that is what
        // its own uninstall and upgrade commands take.
        const main = switch (entry.value_ptr.*) {
            .object => |object| blk: {
                const metadata = object.get("metadata") orelse break :blk null;
                if (metadata != .object) break :blk null;
                break :blk metadata.object.get("main_package");
            },
            else => null,
        } orelse continue;
        const version = stringField(main, "package_version");
        try tools.append(allocator, .{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .version = if (version) |found| try allocator.dupe(u8, found) else null,
            .path = pipxVenvPath(allocator, main),
        });
    }
    return tools;
}

/// The environment a pipx tool lives in, from where its first command was
/// put (`<venv>/bin/<command>`).
fn pipxVenvPath(allocator: std.mem.Allocator, main: std.json.Value) ?[]const u8 {
    const paths = switch (main) {
        .object => |object| object.get("app_paths") orelse return null,
        else => return null,
    };
    if (paths != .array or paths.array.items.len == 0) return null;
    const command = stringField(paths.array.items[0], "__Path__") orelse return null;
    const bin = std.fs.path.dirname(command) orelse return null;
    const venv = std.fs.path.dirname(bin) orelse return null;
    return allocator.dupe(u8, venv) catch null;
}

/// `brew outdated --json=v2`: the formulae, with the version brew would
/// install.
pub fn collectBrewVersions(allocator: std.mem.Allocator, text: []const u8, map: *std.StringHashMapUnmanaged([]const u8)) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, exec.jsonSlice(text), .{}) catch return;
    defer parsed.deinit();
    const formulae = switch (parsed.value) {
        .object => |object| object.get("formulae") orelse return,
        else => return,
    };
    if (formulae != .array) return;
    for (formulae.array.items) |entry| {
        const name = stringField(entry, "name") orelse continue;
        const latest = stringField(entry, "current_version") orelse continue;
        try remember(allocator, map, name, latest);
    }
}

/// npm's and pnpm's `outdated`, which answer with the same shape: a package
/// per key, `latest` inside.
pub fn collectLatestVersions(allocator: std.mem.Allocator, text: []const u8, map: *std.StringHashMapUnmanaged([]const u8)) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, exec.jsonSlice(text), .{}) catch return;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |found| found,
        else => return,
    };
    var it = object.iterator();
    while (it.next()) |entry| {
        const latest = stringField(entry.value_ptr.*, "latest") orelse continue;
        try remember(allocator, map, entry.key_ptr.*, latest);
    }
}

/// `bun outdated -g`: a table, its last column the newest version.
pub fn collectBunVersions(allocator: std.mem.Allocator, text: []const u8, map: *std.StringHashMapUnmanaged([]const u8)) !void {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOfScalar(u8, line, '|') == null) continue;
        var fields: [8][]const u8 = undefined;
        var count: usize = 0;
        var cells = std.mem.splitScalar(u8, line, '|');
        while (cells.next()) |cell| {
            if (count == fields.len) break;
            fields[count] = std.mem.trim(u8, cell, " \t\r");
            count += 1;
        }
        if (count < 6) continue;
        const name = fields[1];
        const latest = fields[4];
        // The header, and the rule under it.
        if (name.len == 0 or latest.len == 0) continue;
        if (std.mem.eql(u8, name, "Package") or std.mem.startsWith(u8, name, "-")) continue;
        try remember(allocator, map, name, latest);
    }
}

/// One name → newest version, without letting a second manager's answer
/// overwrite the first (they would agree anyway, but one map is enough).
fn remember(allocator: std.mem.Allocator, map: *std.StringHashMapUnmanaged([]const u8), name: []const u8, latest: []const u8) !void {
    if (map.contains(name)) return;
    const key = try allocator.dupe(u8, name);
    errdefer allocator.free(key);
    const value = try allocator.dupe(u8, latest);
    try map.put(allocator, key, value);
}

/// The last line of an answer that said anything. npm and pnpm write their
/// warnings to the same pipe as the path they were asked for, so the path is
/// the last thing they say, not the first.
fn lastLine(text: []const u8) []const u8 {
    var answer: []const u8 = "";
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) answer = trimmed;
    }
    return answer;
}

fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    const object = switch (value) {
        .object => |found| found,
        else => return null,
    };
    const field = object.get(key) orelse return null;
    return switch (field) {
        .string => |text| text,
        else => null,
    };
}

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// pnpm will not answer a global question while its own bin folder is off
/// `PATH`; the call carries a `PATH` that has it.
fn pnpmEnv(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
    const relative = if (builtin.os.tag == .macos) "Library/pnpm/bin" else ".local/share/pnpm/bin";
    const current = if (getenv("PATH")) |value| std.mem.span(value) else "";
    return std.fmt.allocPrint(allocator, "PATH={s}:{s}/{s}", .{ current, home, relative });
}

/// Homebrew's Cellar: the folder each formula keeps its files in.
fn cellarOf(allocator: std.mem.Allocator, brew_bin: []const u8) ![]u8 {
    const prefix = std.fs.path.dirname(std.fs.path.dirname(brew_bin) orelse "/opt/homebrew") orelse "/opt/homebrew";
    return std.fs.path.join(allocator, &.{ prefix, "Cellar" });
}

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

fn exists(path: []const u8) bool {
    const copy = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return false;
    defer std.heap.page_allocator.free(copy);
    @memcpy(copy, path);
    return access(copy.ptr, 0) == 0;
}

fn isDir(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

/// Whether a file may be run: the bit that tells a program from the LICENSE
/// and README that came with it.
fn isExecutable(dir: std.Io.Dir, io: std.Io, name: []const u8) bool {
    if (!std.Io.File.Permissions.has_executable_bit) return true;
    const stat = dir.statFile(io, name, .{}) catch return false;
    return stat.permissions.toMode() & 0o111 != 0;
}

fn freeTools(allocator: std.mem.Allocator, tools: *std.ArrayListUnmanaged(Tool)) void {
    for (tools.items) |tool| {
        allocator.free(tool.name);
        if (tool.version) |version| allocator.free(version);
        if (tool.path) |path| allocator.free(path);
        if (tool.binary) |binary| allocator.free(binary);
    }
    tools.deinit(allocator);
}

fn freeVersions(allocator: std.mem.Allocator, map: *std.StringHashMapUnmanaged([]const u8)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit(allocator);
}

fn discard(allocator: std.mem.Allocator, items: *std.ArrayListUnmanaged(*CacheItem)) void {
    for (items.items) |item| {
        item.deinit();
        allocator.destroy(item);
    }
    items.deinit(allocator);
}

test "Homebrew's list names a formula and its version" {
    const allocator = std.testing.allocator;
    var tools = try parseBrewVersions(allocator, "abseil 20260107.1\naichat 0.20.0 0.30.0\n\njq 1.7.1\n");
    defer freeTools(allocator, &tools);
    try std.testing.expectEqual(@as(usize, 3), tools.items.len);
    try std.testing.expectEqualStrings("abseil", tools.items[0].name);
    try std.testing.expectEqualStrings("20260107.1", tools.items[0].version.?);
    // Two versions installed: the last is the one in use.
    try std.testing.expectEqualStrings("0.30.0", tools.items[1].version.?);
    try std.testing.expectEqualStrings("1.7.1", tools.items[2].version.?);
}

test "npm's global list is read through its warning" {
    const allocator = std.testing.allocator;
    const answer =
        \\npm warn Unknown user config "home".
        \\{
        \\  "name": "lib",
        \\  "dependencies": {
        \\    "@anthropic-ai/claude-code": { "version": "2.1.76", "overridden": false },
        \\    "wrangler": { "version": "4.114.0" }
        \\  }
        \\}
    ;
    var tools = try parseNpmLs(allocator, answer);
    defer freeTools(allocator, &tools);
    try std.testing.expectEqual(@as(usize, 2), tools.items.len);
    try std.testing.expectEqualStrings("@anthropic-ai/claude-code", tools.items[0].name);
    try std.testing.expectEqualStrings("2.1.76", tools.items[0].version.?);
    try std.testing.expectEqualStrings("wrangler", tools.items[1].name);
}

test "pnpm's global list is an array of roots" {
    const allocator = std.testing.allocator;
    const answer =
        \\[
        \\  {
        \\    "path": "/Users/me/Library/pnpm/global/v11",
        \\    "dependencies": {
        \\      "pnpm": { "from": "pnpm", "version": "12.11.2", "path": "/Users/me/Library/pnpm/global/v11/10fc4-1a132c0334c/node_modules/pnpm" }
        \\    }
        \\  }
        \\]
    ;
    var tools = try parsePnpmLs(allocator, answer);
    defer freeTools(allocator, &tools);
    try std.testing.expectEqual(@as(usize, 1), tools.items.len);
    try std.testing.expectEqualStrings("pnpm", tools.items[0].name);
    try std.testing.expectEqualStrings("12.11.2", tools.items[0].version.?);
    // The folder it is really in, hash and all.
    try std.testing.expectEqualStrings("/Users/me/Library/pnpm/global/v11/10fc4-1a132c0334c/node_modules/pnpm", tools.items[0].path.?);
}

test "bun's tree names its folder and its packages" {
    const allocator = std.testing.allocator;
    const answer =
        \\
        \\/Users/me/.bun/install/global node_modules (2847 installed)
        \\├── 9router@0.5.81
        \\├── @anthropic-ai/claude-code@2.1.318
        \\├── qmd@github:tobi/qmd#63028fd
        \\└── wrangler@4.114.0
    ;
    try std.testing.expectEqualStrings("/Users/me/.bun/install/global", parseBunRoot(answer).?);
    var tools = try parseBunTree(allocator, answer);
    defer freeTools(allocator, &tools);
    try std.testing.expectEqual(@as(usize, 4), tools.items.len);
    try std.testing.expectEqualStrings("9router", tools.items[0].name);
    try std.testing.expectEqualStrings("0.5.81", tools.items[0].version.?);
    // A scoped name keeps its '@'; the version is after the last one.
    try std.testing.expectEqualStrings("@anthropic-ai/claude-code", tools.items[1].name);
    try std.testing.expectEqualStrings("2.1.318", tools.items[1].version.?);
    // A package from a repository, not a version number at all.
    try std.testing.expectEqualStrings("qmd", tools.items[2].name);
    try std.testing.expectEqualStrings("github:tobi/qmd#63028fd", tools.items[2].version.?);
    try std.testing.expectEqualStrings("wrangler", tools.items[3].name);
}

test "cargo's list gives a crate, its version and its first binary" {
    const allocator = std.testing.allocator;
    const answer =
        \\bat v0.18.3:
        \\    bat
        \\cargo-edit v0.8.0:
        \\    cargo-add
        \\    cargo-rm
        \\cargo-expand v1.0.13:
        \\    cargo-expand
    ;
    var tools = try parseCargoList(allocator, answer);
    defer freeTools(allocator, &tools);
    try std.testing.expectEqual(@as(usize, 3), tools.items.len);
    try std.testing.expectEqualStrings("bat", tools.items[0].name);
    try std.testing.expectEqualStrings("0.18.3", tools.items[0].version.?);
    try std.testing.expectEqualStrings("bat", tools.items[0].binary.?);
    // A crate whose name is none of its binaries: the first one is the row.
    try std.testing.expectEqualStrings("cargo-edit", tools.items[1].name);
    try std.testing.expectEqualStrings("cargo-add", tools.items[1].binary.?);
}

test "pipx's list gives the package and the environment it lives in" {
    const allocator = std.testing.allocator;
    const answer =
        \\{
        \\  "pipx_spec_version": "0.1",
        \\  "venvs": {
        \\    "omnara": {
        \\      "metadata": {
        \\        "main_package": {
        \\          "app_paths": [
        \\            { "__Path__": "/Users/me/.local/pipx/venvs/omnara/bin/omnara", "__type__": "Path" }
        \\          ],
        \\          "package": "omnara",
        \\          "package_version": "1.6.21",
        \\          "pinned": false
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ;
    var tools = try parsePipxList(allocator, answer);
    defer freeTools(allocator, &tools);
    try std.testing.expectEqual(@as(usize, 1), tools.items.len);
    try std.testing.expectEqualStrings("omnara", tools.items[0].name);
    try std.testing.expectEqualStrings("1.6.21", tools.items[0].version.?);
    try std.testing.expectEqualStrings("/Users/me/.local/pipx/venvs/omnara", tools.items[0].path.?);
}

test "each manager's outdated answer becomes a newest version" {
    const allocator = std.testing.allocator;
    var map = std.StringHashMapUnmanaged([]const u8).empty;
    defer freeVersions(allocator, &map);

    // brew: a list of formulae with the version it would install.
    try collectBrewVersions(allocator,
        \\{"formulae":[{"name":"jq","installed_versions":["1.7.1"],"current_version":"1.8.0"}],"casks":[]}
    , &map);
    try std.testing.expectEqualStrings("1.8.0", map.get("jq").?);

    // npm and pnpm: the same shape, an object per package.
    try collectLatestVersions(allocator,
        \\{"wrangler":{"current":"4.100.0","wanted":"4.114.0","latest":"4.114.0"}}
    , &map);
    try std.testing.expectEqualStrings("4.114.0", map.get("wrangler").?);
    // An entry npm could not ask about carries no version, and is left out.
    try collectLatestVersions(allocator,
        \\{"gone":{"error":{"code":"E404"}}}
    , &map);
    try std.testing.expect(map.get("gone") == null);

    // bun: a table, with a header and a rule to skip.
    try collectBunVersions(allocator,
        \\bun outdated v1.4.3 (c6da4a4d4)
        \\|---------------------------------------|-----------|-----------|-----------|
        \\| Package                               | Current   | Update    | Latest    |
        \\|---------------------------------------|-----------|-----------|-----------|
        \\| 9router                               | 0.5.81    | 0.5.116   | 0.5.116   |
        \\| @charmland/crush                      | 0.1.11    | 0.1.11    | 0.100.0   |
        \\|---------------------------------------|-----------|-----------|-----------|
    , &map);
    try std.testing.expectEqualStrings("0.5.116", map.get("9router").?);
    try std.testing.expectEqualStrings("0.100.0", map.get("@charmland/crush").?);
    try std.testing.expect(map.get("Package") == null);
}

test "the Cellar sits beside the brew that lives in it" {
    const allocator = std.testing.allocator;
    const arm = try cellarOf(allocator, "/opt/homebrew/bin/brew");
    defer allocator.free(arm);
    try std.testing.expectEqualStrings("/opt/homebrew/Cellar", arm);
    const intel = try cellarOf(allocator, "/usr/local/bin/brew");
    defer allocator.free(intel);
    try std.testing.expectEqualStrings("/usr/local/Cellar", intel);
}

test "the path a manager answers with is its last line, not its warning" {
    try std.testing.expectEqualStrings("/opt/homebrew/lib/node_modules", lastLine("npm warn Unknown user config \"home\".\n/opt/homebrew/lib/node_modules\n"));
    try std.testing.expectEqualStrings("/Users/me/Library/pnpm/global/v11", lastLine("/Users/me/Library/pnpm/global/v11\n"));
    try std.testing.expectEqualStrings("", lastLine("\n \n"));
}

test "a manager that is not there leaves no rows, and no failure" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];

    // A home of its own with nothing in it: the managers are not asked, and
    // there is nothing downloaded either.
    var items = try scan(allocator, io, .{ .home = home, .machine = false });
    defer discard(allocator, &items);
    try std.testing.expectEqual(@as(usize, 0), items.items.len);
}

test "a downloaded program is a row, and a manager's symlink is not" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];

    try tmp.dir.createDirPath(io, ".local/bin");
    // A program somebody downloaded, with the executable bit set.
    try tmp.dir.writeFile(io, .{
        .sub_path = ".local/bin/mytool",
        .data = "#!/bin/sh\necho hi\n",
        .flags = .{ .permissions = std.Io.File.Permissions.fromMode(0o755) },
    });
    // The LICENSE that came with it, which is not a program.
    try tmp.dir.writeFile(io, .{ .sub_path = ".local/bin/LICENSE", .data = "MIT\n" });
    // And a manager's own command, which is a symlink and belongs to it.
    try tmp.dir.symLink(io, "/opt/homebrew/bin/jq", ".local/bin/jq", .{});

    var items = try scan(allocator, io, .{ .home = home, .machine = false });
    defer discard(allocator, &items);
    try std.testing.expectEqual(@as(usize, 1), items.items.len);
    try std.testing.expectEqualStrings("mytool", items.items[0].app_name);
    try std.testing.expectEqual(item_mod.Category.cli, items.items[0].category);
    try std.testing.expectEqual(Removal.trash, items.items[0].removal);
    try std.testing.expect(items.items[0].update == null);
    try std.testing.expectEqualStrings("~/.local/bin", items.items[0].locations.items[0].folder_name);
}
