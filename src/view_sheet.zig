//! What opens over the window, as in Activity Monitor: the View menu
//! (which processes show), the search's suggestions, the inspector (a
//! double click, ⓘ or ⌘I), and the sheet asking before a process is quit
//! (ⓧ or ⌥⌘Q).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const model = @import("model.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const item_mod = @import("cleanup/item.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;

/// A click outside closes what is open.
fn scrim(c: *ui.Context, shade: f32) ui.Div {
    const s = ui.div(c).absolute().sizeFull().column().itemsCenter().bg(.{ .a = shade });
    return s;
}

pub fn menu(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (!a.menu) return;
    const s = scrim(c, 0);
    defer s.end();
    if (s.clicked()) a.menu = false;
    // Under its button.
    const m = ui.div(c).absolute().offset(a.menu_at[0], a.menu_at[1]).column().w(200).p(5).rounded(8).bg(k.control_on).border(k.separator).shadowLg();
    defer m.end();
    _ = m.interaction();
    for ([_]app_mod.Filter{ .all, .mine, .system }) |f| {
        ui.key(c, f.title());
        const item = ui.div(c).row().wFull().h(24).itemsCenter().gap(6).px(6).rounded(5).control();
        const it = item.interaction();
        if (it.hovered) c.node(item.index).style.background = k.selection;
        defer item.end();
        if (it.clicked) a.setFilter(f);
        const color = if (it.hovered) k.on_selection else k.text;
        const mark = ui.div(c).row().w(12).center();
        if (a.filter == f) ui.icon(c, "checkmark", .{ .size = 10, .weight = .bold, .color = color });
        mark.end();
        ui.text(c, f.title(), .{ .size = 13, .color = color });
    }
}

/// The width of the search's suggestions.
pub const suggest_w: f32 = 320;

/// The search's suggestions, under the field while it is empty and
/// focused (view_procs.search leaves where): what the search can be asked
/// for, each a click away. A hint fills the query in as its example shows.
pub fn suggest(c: *ui.Context, a: *App, k: theme.Colors) void {
    const at = a.suggest_at orelse return;
    const hints = [_]struct { fill: []const u8, says: []const u8 }{
        .{ .fill = "\"Safari\", Mail", .says = "A few at once" },
        .{ .fill = "cpu>10", .says = "Above 10% of a core" },
        .{ .fill = "mem>1GB", .says = "Using more than 1 GB" },
        .{ .fill = "user:root", .says = "Run by root" },
        .{ .fill = ":3000", .says = "Listening on port 3000" },
        .{ .fill = "-helper", .says = "Leave the helpers out" },
    };
    const box = ui.div(c).absolute().offset(at[0], at[1]).column().w(suggest_w).p(5).rounded(8).bg(k.control_on).border(k.separator).shadowLg();
    defer box.end();
    const it = box.interaction();
    for (hints) |h| {
        ui.key(c, h.fill);
        const item = ui.div(c).row().wFull().h(24).itemsCenter().gap(8).px(6).rounded(5).control();
        const row = item.interaction();
        if (row.hovered) c.node(item.index).style.background = k.selection;
        defer item.end();
        if (row.clicked) {
            a.query.set(h.fill);
            a.dirty = true;
            // The keys stay in the field, to carry on from the example.
            a.find_search = true;
        }
        const color = if (row.hovered) k.on_selection else k.text;
        ui.text(c, h.fill, .{ .size = 11.5, .mono = true, .color = color });
        ui.spacer(c);
        ui.text(c, h.says, .{ .size = 11, .color = if (row.hovered) k.on_selection else k.secondary });
    }
    // A press in the panel takes the focus from the field for the frame,
    // and the field hides the panel when it lets go: keep it, so the press
    // is still the panel's when it is released.
    if (c.input.pressed and it.hovered) c.focus = a.search_id;
}

/// The app's icon, large, if it has one.
fn bigIcon(c: *ui.Context, a: *App, p: model.Process, size: f32) void {
    const box = ui.div(c).row().w(size).h(size).center();
    defer box.end();
    if (a.icons.get(p.bundle)) |png| {
        _ = ui.image(c, .{ .key = p.bundle, .bytes = png, .max_width = size, .max_height = size, .radius = 0 });
    } else ui.icon(c, "terminal", .{ .size = size * 0.6, .color = c.theme.muted });
}

pub fn inspector(c: *ui.Context, a: *App, k: theme.Colors) void {
    const pid = a.inspect orelse return;
    const p = a.find(pid) orelse {
        a.inspect = null;
        return;
    };
    const s = scrim(c, 0.12);
    defer s.end();
    if (s.clicked()) a.inspect = null;
    const gap = ui.div(c).row().h(kit.header_h + 30);
    gap.end();
    const box = ui.div(c).column().w(440).gap(14).p(18).rounded(10).bg(k.page).border(k.separator).shadowLg();
    defer box.end();
    _ = box.interaction();
    {
        const h = ui.div(c).row().wFull().gap(12).itemsCenter();
        defer h.end();
        bigIcon(c, a, p, 32);
        ui.text(c, c.print("{s} ({d})", .{ p.name, p.pid }), .{ .size = 15, .weight = .semibold, .color = k.text });
    }
    var b: [32]u8 = undefined;
    const parent = if (a.find(p.ppid)) |pp| c.print("{s} ({d})", .{ pp.name, pp.pid }) else c.print("{d}", .{p.ppid});
    const known = p.known;
    const detail = p.detailed();
    const lines = [_]struct { []const u8, []const u8 }{
        .{ "Parent Process:", parent },
        .{ "User:", c.print("{s} ({d})", .{ p.user, p.uid }) },
        .{ "% CPU:", if (known) c.print("{d:.1}", .{p.cpu}) else "–" },
        .{ "CPU Time:", if (known) c.print("{s}", .{model.duration(&b, p.cpu_time_ns)}) else "–" },
        .{ "Threads:", if (detail and p.threads > 0) c.print("{d}", .{p.threads}) else "–" },
        .{ "Idle Wake Ups:", if (detail) c.print("{d}", .{p.wakeups}) else "–" },
        .{ "Memory:", if (known) c.print("{s}", .{model.bytes(&b, p.memory)}) else "–" },
        .{ "Bytes Read:", if (detail) c.print("{s}", .{model.bytes(&b, p.disk_read)}) else "–" },
        .{ "Bytes Written:", if (detail) c.print("{s}", .{model.bytes(&b, p.disk_written)}) else "–" },
    };
    {
        const grid = ui.div(c).column().wFull().gap(4).p(12).rounded(6).bg(k.card).border(k.separator);
        defer grid.end();
        for (lines) |l| {
            const r = ui.div(c).row().wFull().gap(10);
            defer r.end();
            const label = ui.div(c).row().w(130).justifyEnd();
            ui.text(c, l[0], .{ .size = 12, .color = k.secondary });
            label.end();
            ui.text(c, l[1], .{ .size = 12, .color = k.text });
        }
    }
    if (p.from_ps) ui.text(c, "Only part of this process can be read without administrator rights.", .{ .size = 11, .color = k.secondary, .wrap = true });
    const r = ui.div(c).row().wFull().gap(8);
    defer r.end();
    ui.spacer(c);
    if (ui.button(c, "Quit…", .{ .variant = .secondary, .size = 12.5 }).clicked) a.confirm = p.pid;
    if (ui.button(c, "Done", .{ .variant = .primary, .size = 12.5 }).clicked) a.inspect = null;
}

/// "Quit 3 processes?": their names, a word on the system's, and Force
/// Quit, Cancel, Quit.
pub fn confirmMarked(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (!a.confirm_marked) return;
    const sum = a.markedSummary();
    if (sum.count == 0) {
        a.confirm_marked = false;
        return;
    }
    const s = scrim(c, 0.18);
    defer s.end();
    if (s.clicked()) a.confirm_marked = false;
    const gap = ui.div(c).row().h(kit.header_h + 30);
    gap.end();
    const box = ui.div(c).column().w(440).gap(12).p(20).rounded(12).bg(k.page).border(k.border).shadowLg();
    defer box.end();
    _ = box.interaction();
    {
        const t = ui.div(c).row().gap(10).itemsCenter();
        defer t.end();
        kit.chip(c, "xmark.octagon", k.red, 28, false);
        ui.text(c, c.print("Quit {d} process{s}?", .{ sum.count, if (sum.count == 1) "" else "es" }), .{ .size = 15, .weight = .bold, .color = k.text });
    }
    {
        const list = ui.div(c).column().wFull().gap(2).p(10).rounded(8).bg(k.card).border(k.border);
        defer list.end();
        var shown: usize = 0;
        var b: [32]u8 = undefined;
        for (a.marked.keys()) |pid| if (a.find(pid)) |p| {
            if (shown == 7) break;
            shown += 1;
            ui.key(c, c.print("q-{d}", .{pid}));
            const r = ui.div(c).row().wFull().gap(8).itemsCenter().h(22);
            defer r.end();
            @import("view_memory.zig").procName(c, a, k, p, 220);
            ui.spacer(c);
            ui.text(c, c.print("{s}", .{model.bytes(&b, p.memory)}), .{ .size = 11, .mono = true, .color = k.secondary });
            if (p.uid != a.uid) ui.text(c, p.user, .{ .size = 11, .color = k.red });
        };
        if (sum.count > shown) ui.text(c, c.print("and {d} more", .{sum.count - shown}), .{ .size = 11.5, .color = k.secondary });
    }
    if (sum.system > 0) ui.text(c, c.print("{d} of them belong to another user or the system, and won't quit without administrator rights; they stay marked.", .{sum.system}), .{ .size = 11.5, .color = k.secondary, .wrap = true });
    ui.text(c, "Quit asks each to close; Force Quit ends them at once, and what they had not saved is lost.", .{ .size = 11.5, .color = k.secondary, .wrap = true });
    const r = ui.div(c).row().wFull().gap(8).pt(4);
    defer r.end();
    if (ui.button(c, "Force Quit", .{ .variant = .secondary, .size = 12.5 }).clicked) a.quitMarked(true);
    ui.spacer(c);
    if (ui.button(c, "Cancel", .{ .variant = .secondary, .size = 12.5 }).clicked) a.confirm_marked = false;
    if (ui.button(c, c.print("Quit {d}", .{sum.count}), .{ .variant = .primary, .size = 12.5 }).clicked) a.quitMarked(false);
}

/// "Are you sure you want to quit this process?": Force Quit, Cancel, Quit.
pub fn confirm(c: *ui.Context, a: *App, k: theme.Colors) void {
    const pid = a.confirm orelse return;
    const p = a.find(pid) orelse {
        a.confirm = null;
        return;
    };
    const s = scrim(c, 0.12);
    defer s.end();
    if (s.clicked()) a.confirm = null;
    const gap = ui.div(c).row().h(kit.header_h);
    gap.end();
    const box = ui.div(c).row().w(460).gap(16).p(20).rounded(10).bg(k.page).border(k.separator).shadowLg();
    defer box.end();
    _ = box.interaction();
    bigIcon(c, a, p, 48);
    // A width of its own: wrapping text is measured at it.
    const col = ui.div(c).column().w(460 - 2 * 20 - 48 - 16).gap(8);
    defer col.end();
    ui.text(c, "Are you sure you want to quit this process?", .{ .size = 13, .weight = .bold, .color = k.text, .wrap = true });
    ui.text(c, c.print("Do you really want to quit “{s}”? Force Quit ends it at once; what it had not saved is lost.", .{p.name}), .{ .size = 11.5, .color = k.text, .wrap = true });
    const r = ui.div(c).row().wFull().gap(8).pt(6);
    defer r.end();
    if (ui.button(c, "Force Quit", .{ .variant = .secondary, .size = 12.5 }).clicked) a.quit(pid, true);
    ui.spacer(c);
    if (ui.button(c, "Cancel", .{ .variant = .secondary, .size = 12.5 }).clicked) a.confirm = null;
    if (ui.button(c, "Quit", .{ .variant = .primary, .size = 12.5 }).clicked) a.quit(pid, false);
}

/// The Cleanup page's sheet: the items about to move to the Trash, what they
/// give back, and the promise that they can be put back.
pub fn cleanupConfirm(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (a.cleanup_confirm == .none) return;
    // An update takes only the tools a manager can bring up to date; a
    // removal takes everything ticked.
    const updating = a.cleanup_confirm == .update;
    const count = if (updating) a.cleanupSelectionUpdates() else a.cleanup_selected.count();
    if (count == 0) {
        a.cleanup_confirm = .none;
        return;
    }
    const verb = if (updating) "Update" else a.cleanupSelectionVerb();
    const s = scrim(c, 0.18);
    defer s.end();
    if (s.clicked()) a.cleanup_confirm = .none;
    const gap = ui.div(c).row().h(kit.header_h + 20);
    gap.end();
    const box = ui.div(c).column().w(460).gap(12).p(20).rounded(12).bg(k.page).border(k.border).shadowLg();
    defer box.end();
    _ = box.interaction();
    {
        const t = ui.div(c).row().gap(10).itemsCenter();
        defer t.end();
        kit.chip(c, if (updating) "arrow.down.circle" else "trash", if (updating) k.blue else k.orange, 28, false);
        const noun = if (a.cleanup_tab == .uninstall)
            (if (count == 1) "app" else "apps")
        else if (a.cleanup_tab == .cli)
            (if (count == 1) "tool" else "tools")
        else
            (if (count == 1) "item" else "items");
        const title = if (std.mem.eql(u8, verb, "Move to Trash"))
            c.print("Move {d} {s} to the Trash?", .{ count, noun })
        else
            c.print("{s} {d} {s}?", .{ verb, count, noun });
        ui.text(c, title, .{ .size = 15, .weight = .bold, .color = k.text });
    }
    {
        const list = ui.div(c).column().wFull().gap(2).p(10).rounded(8).bg(k.card).border(k.border);
        defer list.end();
        var shown: usize = 0;
        var it = a.cleanup_selected.iterator();
        while (it.next()) |entry| {
            const item = entry.key_ptr.*;
            // A tool with nothing newer is not part of an update.
            if (updating and item.update == null) continue;
            if (shown == 7) break;
            shown += 1;
            ui.key(c, item.primaryPath());
            const r = ui.div(c).row().wFull().gap(8).itemsCenter().h(20);
            defer r.end();
            @import("view_cleanup.zig").rowIcon(c, a, k, item, 16);
            ui.text(c, item.app_name, .{ .size = 12, .color = k.text });
            if (item.locations.items.len > 1) ui.text(c, c.print("+{d} files", .{item.locations.items.len - 1}), .{ .size = 11, .color = k.tertiary });
            ui.spacer(c);
            if (updating) {
                const installed = item.installed_version orelse "—";
                ui.text(c, c.print("{s} → {s}", .{ installed, item.latest_version orelse "newest" }), .{ .size = 11, .mono = true, .color = k.orange });
            } else {
                var buf: [32]u8 = undefined;
                ui.text(c, c.print("{s}{s}", .{ if (item.approx()) "≈ " else "", item.formatSize(&buf) }), .{ .size = 11, .mono = true, .color = k.secondary });
            }
        }
        if (count > shown) ui.text(c, c.print("and {d} more", .{count - shown}), .{ .size = 11.5, .color = k.secondary });
    }
    var buf: [32]u8 = undefined;
    var any_approx = false;
    var approx_it = a.cleanup_selected.iterator();
    while (approx_it.next()) |entry| {
        if (entry.key_ptr.*.approx()) {
            any_approx = true;
            break;
        }
    }
    const note = if (updating)
        // An update replaces what is there: nothing is removed, so nothing
        // has to be put back.
        "Each tool is updated by the manager that installed it — brew upgrade, npm, pnpm, bun, pipx or cargo — and the newest version it offers is installed. Nothing is removed."
    else if (!a.cleanupSelectionUndoable())
        // Not everything here can be put back: the tool that owns it removes
        // it for good, and the sheet says so before anything happens.
        c.print("{s}{s} is freed. Some of this is removed for good by its own tool — Homebrew, npm, pnpm, bun, pipx, cargo, a simulator, Time Machine or Xcode — and does not go to the Trash.", .{ if (any_approx) "≈ " else "", item_mod.formatBytes(a.cleanupSelectedBytes(), &buf) })
    else if (a.cleanup_tab == .uninstall)
        c.print("{s}{s} is freed, including what the app left in your Library. Everything moves to the Trash, so the app can be put back until you empty it.", .{ if (any_approx) "≈ " else "", item_mod.formatBytes(a.cleanupSelectedBytes(), &buf) })
    else
        c.print("{s}{s} comes back. Everything moves to the Trash, so you can put it back until you empty it.", .{ if (any_approx) "≈ " else "", item_mod.formatBytes(a.cleanupSelectedBytes(), &buf) });
    ui.text(c, note, .{ .size = 11.5, .color = k.secondary, .wrap = true });
    {
        const r = ui.div(c).row().wFull().gap(8).pt(4);
        defer r.end();
        ui.spacer(c);
        if (ui.button(c, "Cancel", .{ .variant = .secondary, .size = 12.5 }).clicked) a.cleanup_confirm = .none;
        const action = verb;
        if (ui.button(c, action, .{ .variant = .primary, .size = 12.5 }).clicked) {
            if (updating) a.cleanupUpdateSelected() else a.cleanupDeleteSelected();
        }
    }
}
