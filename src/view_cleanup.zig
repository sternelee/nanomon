//! The Cleanup page (⌘9): what the scan found, biggest first, with the
//! safety of each row in plain sight. Rows tick with a click (the header's
//! box ticks all of them, or clears them), the header sorts, and the ticked
//! rows move to the Trash together once the sheet is answered.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const CleanupFilter = app_mod.CleanupFilter;
const CleanupSort = app_mod.CleanupSort;
const CleanupTab = app_mod.CleanupTab;
const item_mod = @import("cleanup/item.zig");
const CacheItem = item_mod.CacheItem;
const safety_mod = @import("cleanup/safety.zig");
const SafetyLevel = safety_mod.SafetyLevel;

const row_h = 26;
const header_h = 26;

/// What a column shows. The row draws them in the order the header names
/// them, so the two can never drift apart.
const Field = enum { name, kind, where, version, size, safety };

const Column = struct {
    field: Field,
    title: []const u8,
    width: ?f32 = null,
    right: bool = false,
    sort: ?CleanupSort = null,
};

const columns = [_]Column{
    .{ .field = .name, .title = "Name", .sort = .name },
    .{ .field = .kind, .title = "Kind", .width = 96 },
    .{ .field = .where, .title = "Where", .width = 150 },
    .{ .field = .size, .title = "Size", .width = 90, .right = true, .sort = .size },
    .{ .field = .safety, .title = "Safety", .width = 76, .sort = .safety },
};

/// The CLI Tools page adds a column: what is installed, and what its own
/// manager would install instead. Its Kind and Where sort too, because that
/// is how a list of several hundred tools is read: by what they are, and by
/// the manager that owns them.
const columns_cli = [_]Column{
    .{ .field = .name, .title = "Name", .sort = .name },
    .{ .field = .kind, .title = "Kind", .width = 120, .sort = .kind },
    .{ .field = .where, .title = "Where", .width = 80, .sort = .where },
    .{ .field = .version, .title = "Version", .width = 150 },
    .{ .field = .size, .title = "Size", .width = 78, .right = true, .sort = .size },
    .{ .field = .safety, .title = "Safety", .width = 76, .sort = .safety },
};

/// The columns the page in hand shows.
fn currentColumns(a: *App) []const Column {
    return if (a.cleanup_tab == .cli) &columns_cli else &columns;
}

fn cell(c: *ui.Context, col: Column, h: f32) ui.Div {
    var d = ui.div(c).row().h(h).itemsCenter().px(10).clip();
    d = if (col.width) |w| d.w(w) else d.grow().w(0);
    if (col.right) d = d.justifyEnd();
    return d;
}

fn divider(c: *ui.Context, k: theme.Colors) void {
    _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .{ .px = 14 }, .background = k.separator }, .none, null);
}

fn safetyColor(level: SafetyLevel, k: theme.Colors) ui.Color {
    return switch (level) {
        .safe => k.green,
        .medium => k.orange,
        .unknown => k.gray,
    };
}

/// What the Kind column says: a file's kind is what it is (a disk image, a
/// virtual machine), everything else is where it came from.
fn kindLabel(item: *CacheItem) []const u8 {
    return item.kind();
}

/// The symbol a row carries when it is not an app: one per kind of thing.
pub fn kindIcon(category: item_mod.Category) []const u8 {
    return switch (category) {
        .cache => "internaldrive",
        .junk => "doc.text",
        .dev => "chevron.left.forwardslash.chevron.right",
        .cli => "terminal",
        .project => "folder",
        .large => "doc",
        .app => "app.badge",
        .simulator => "cube",
        .xcode => "wrench.and.screwdriver",
        .other => "folder",
    };
}

/// A row's icon at the left of its name: an app's own icon when it is one
/// (and macOS will give it), a symbol for its kind otherwise.
pub fn rowIcon(c: *ui.Context, a: *App, k: theme.Colors, item: *CacheItem, size: f32) void {
    const box = ui.div(c).row().w(size).h(size).center();
    defer box.end();
    if (item.category == .app) {
        const bundle = item.primaryPath();
        if (a.icons.get(bundle)) |png| {
            _ = ui.image(c, .{ .key = bundle, .bytes = png, .max_width = size, .max_height = size, .radius = 0 });
            return;
        }
    }
    ui.icon(c, kindIcon(item.category), .{ .size = size * 0.72, .color = kit.tabColor(item.category.tab(), k) });
}

/// The tick at a row's start: the accent when ticked, an outline when not.
fn tick(c: *ui.Context, k: theme.Colors, on: bool) void {
    const box = ui.div(c).row().w(13).h(13).center().rounded(3);
    const styled = if (on) box.bg(k.accent) else box.border(k.border);
    defer styled.end();
    if (on) ui.icon(c, "checkmark", .{ .size = 8, .weight = .bold, .color = k.on_picked });
}

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    // The first time the page is opened it looks around on its own, the way
    // purge does; Scan asks again.
    if (a.cleanup_auto and !a.cleanup_scanning and !a.cleanup_scanned) a.startCleanupScan();
    // The disk map's rows are the Overview page's; there is no tab for them.
    if (a.cleanup_tab == .overview) a.cleanupSetTab(.caches);
    const root = ui.div(c).column().wFull().grow().hFull();
    defer root.end();
    head(c, a, k);
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.separator }, .none, null);
    columnsHeader(c, a, k);
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.separator }, .none, null);
    list(c, a, k);
    footer(c, a, k);
}

fn head(c: *ui.Context, a: *App, k: theme.Colors) void {
    var b: [32]u8 = undefined;
    const totals = a.cleanupTabTotals(a.cleanup_tab);
    const sub = if (a.cleanup_scanning)
        if (a.cleanupProgress() == 0)
            a.cleanup_tab.subtitle()
        else
            c.print("Scanning… {d} of {d} done", .{ a.cleanupProgress(), app_mod.cleanup_pass_count })
    else if (totals.count == 0)
        a.cleanup_tab.subtitle()
    else if (a.cleanup_visible.items.len != totals.count)
        c.print("{d} of {d} shown · {s}{s}", .{ a.cleanup_visible.items.len, totals.count, if (a.cleanupApprox()) "≈ " else "", item_mod.formatBytes(a.cleanupVisibleBytes(), &b) })
    else
        c.print("{d} found · {s}{s}", .{ totals.count, if (a.cleanupApprox()) "≈ " else "", item_mod.formatBytes(totals.bytes, &b) });
    const h = kit.header(c, k, a.cleanup_tab.title(), sub);
    defer h.end();
    if (totals.count > 0) {
        const filters = [_]CleanupFilter{ .all, .safe, .check };
        var names: [filters.len][]const u8 = undefined;
        for (filters, 0..) |f, i| names[i] = f.title();
        if (kit.segmented(c, k, &names, @backingInt(a.cleanup_filter))) |i| {
            a.cleanupSetFilter(filters[i]);
            if (a.window) |w| w.redraw();
        }
    }
    scanButton(c, a, k, .primary, 12);
}

/// A button's look, named as nanoui names it (its own `ButtonVariant` is not
/// one of the ui module's exports).
const Variant = @FieldType(ui.ButtonOptions, "variant");

/// Scan, with its arrow turning while the scan runs: a `ui.button` draws its
/// own icon, and there is no reaching it to set an angle, so while the button
/// is disabled anyway it is drawn here instead — the same box, with the
/// arrow's angle read from the frame clock.
fn scanButton(c: *ui.Context, a: *App, k: theme.Colors, variant: Variant, size: f32) void {
    const scanning = a.cleanup_scanning;
    const label = if (scanning) "Scanning…" else "Scan";
    if (!scanning and !a.cleanup_removing) {
        if (ui.button(c, label, .{ .variant = variant, .size = size, .icon = "arrow.clockwise" }).clicked) a.startCleanupScan();
        return;
    }
    const fg: ui.Color = switch (variant) {
        .primary, .danger => k.on_picked,
        else => k.text,
    };
    var d = ui.div(c).row().itemsCenter().justifyCenter().gap(size * 0.4).px(size).py(size * 0.5).rounded(8).opacity(0.45);
    d = switch (variant) {
        .primary => d.bg(k.accent),
        .danger => d.bg(k.red),
        .secondary => d.bg(k.control_on).border(k.border).shadow(.{ .color = .{ .a = 0.14 }, .blur = 2, .y = 1 }),
        .ghost => d,
    };
    defer d.end();
    // One turn a second, clockwise; nothing else here turns.
    const angle: f32 = if (scanning) @floatCast(@mod(c.time, 1.0) * std.math.tau) else 0;
    ui.icon(c, "arrow.clockwise", .{ .size = size, .weight = .medium, .color = fg, .rotation = angle });
    ui.text(c, label, .{ .size = size, .weight = .medium, .color = fg });
    // A frame in a sixtieth: the arrow has moved by the next one.
    if (scanning) c.frameIn(1.0 / 60.0);
}

fn columnsHeader(c: *ui.Context, a: *App, k: theme.Colors) void {
    const h = ui.div(c).row().wFull().h(header_h).itemsCenter();
    defer h.end();
    {
        const box = ui.div(c).row().w(30).center().control();
        defer box.end();
        if (box.clicked() and a.cleanup_visible.items.len > 0) {
            a.cleanupToggleAll();
            if (a.window) |w| w.redraw();
        }
        tick(c, k, a.cleanupAllSelected());
    }
    for (currentColumns(a), 0..) |col, i| {
        if (i > 0) divider(c, k);
        var d = cell(c, col, header_h).gap(4);
        if (col.sort) |sort| {
            d = d.control().hover(k.hover);
            if (d.clicked()) {
                a.cleanupSortBy(sort);
                if (a.window) |w| w.redraw();
            }
        }
        defer d.end();
        const on = if (col.sort) |sort| a.cleanup_sort == sort else false;
        ui.text(c, col.title, .{ .size = 11.5, .weight = if (on) .semibold else .regular, .color = if (on) k.text else k.secondary });
        if (on) ui.icon(c, if (a.cleanup_ascending) "chevron.up" else "chevron.down", .{ .size = 8, .weight = .bold, .color = k.secondary });
    }
}

fn list(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (a.cleanup_visible.items.len == 0) {
        const empty = ui.div(c).column().wFull().grow().center().gap(8);
        defer empty.end();
        if (a.cleanup_scanning) {
            ui.text(c, "Scanning…", .{ .size = 13, .color = k.text });
            ui.text(c, a.cleanup_tab.subtitle(), .{ .size = 11.5, .color = k.tertiary });
        } else if (a.cleanup_scan_failed.load(.acquire)) {
            ui.text(c, "The scan could not start", .{ .size = 13, .color = k.text });
            ui.text(c, "Try again in a moment", .{ .size = 11.5, .color = k.tertiary });
        } else if (a.cleanupTabTotals(a.cleanup_tab).count == 0) {
            const words = switch (a.cleanup_tab) {
                .overview => .{ "Nothing measured yet", "Press Scan to see where the space went" },
                .caches => .{ "Nothing to clean here", "Caches, logs and system junk show up here" },
                .dev => .{ "No build folders found", "Tool caches and project build folders show up here" },
                .cli => .{ "No command-line tools found", "What Homebrew, npm, pnpm, bun, pipx and cargo installed shows up here" },
                .large => .{ "No large files found", "Files over 100 MB in your folders show up here" },
                .uninstall => .{ "No apps found", "The apps in Applications show up here" },
            };
            ui.text(c, words[0], .{ .size = 13, .color = k.text });
            ui.text(c, words[1], .{ .size = 11.5, .color = k.tertiary });
        } else {
            ui.text(c, "Nothing here", .{ .size = 13, .color = k.text });
            ui.text(c, "No items match this filter", .{ .size = 11.5, .color = k.tertiary });
        }
        return;
    }
    var rows = ui.list(c, .{ .count = a.cleanup_visible.items.len, .row_height = row_h });
    while (rows.next()) |i| row(c, a, k, a.cleanup_visible.items[i], i);
    rows.end();
}

fn row(c: *ui.Context, a: *App, k: theme.Colors, item: *CacheItem, i: usize) void {
    const on = a.cleanupIsSelected(item);
    var r = ui.div(c).row().wFull().h(row_h).itemsCenter().control();
    if (i % 2 == 1) r = r.bg(k.stripe);
    if (on) r = r.bg(k.marked);
    r = r.hover(k.hover);
    defer r.end();
    const it = r.interaction();
    if (it.clicked) {
        a.cleanupToggle(item);
        if (a.window) |w| w.redraw();
    }

    {
        const box = ui.div(c).row().w(30).center();
        defer box.end();
        tick(c, k, on);
    }
    for (currentColumns(a), 0..) |col, at| {
        if (at > 0) divider(c, k);
        rowCell(c, a, k, col, item);
    }
}

/// One cell of a row, in the column the header named.
fn rowCell(c: *ui.Context, a: *App, k: theme.Colors, col: Column, item: *CacheItem) void {
    switch (col.field) {
        .name => {
            const name_cell = cell(c, col, row_h).gap(7);
            defer name_cell.end();
            rowIcon(c, a, k, item, 16);
            ui.text(c, item.app_name, .{ .size = 12.5, .color = k.text });
            // An app is more than its bundle: say how much more is coming with it.
            if (item.locations.items.len > 1) {
                ui.text(c, c.print("+{d}", .{item.locations.items.len - 1}), .{ .size = 10.5, .color = k.tertiary });
            }
            if (item.safety_info.reinstall_command != null) ui.icon(c, "chevron.left.forwardslash.chevron.right", .{ .size = 9, .color = k.tertiary });
        },
        .kind => {
            const kind_cell = cell(c, col, row_h);
            defer kind_cell.end();
            ui.text(c, kindLabel(item), .{ .size = 11.5, .color = k.secondary });
        },
        .where => {
            const where_cell = cell(c, col, row_h);
            defer where_cell.end();
            ui.text(c, item.where(), .{ .size = 11.5, .color = k.tertiary });
        },
        .version => {
            const version_cell = cell(c, col, row_h).gap(5);
            defer version_cell.end();
            if (item.installed_version) |installed| {
                ui.text(c, installed, .{ .size = 11.5, .mono = true, .color = if (item.outdated()) k.secondary else k.tertiary });
                // Behind: the version its own update command would install.
                if (item.latest_version) |latest| {
                    ui.icon(c, "arrow.right", .{ .size = 8, .weight = .bold, .color = k.orange });
                    ui.text(c, latest, .{ .size = 11.5, .mono = true, .color = k.orange });
                }
            } else {
                ui.text(c, "—", .{ .size = 11.5, .mono = true, .color = k.tertiary });
            }
        },
        .size => {
            const size_cell = cell(c, col, row_h);
            defer size_cell.end();
            var buf: [32]u8 = undefined;
            if (!item.measured) {
                ui.text(c, "—", .{ .size = 11.5, .mono = true, .color = k.tertiary });
            } else ui.text(c, c.print("{s}{s}", .{ if (item.approx()) "≈ " else "", item.formatSize(&buf) }), .{ .size = 11.5, .mono = true, .color = k.text });
        },
        .safety => {
            const safety_cell = cell(c, col, row_h).gap(5);
            defer safety_cell.end();
            const color = safetyColor(item.safety_info.level, k);
            _ = c.leaf(.{ .width = .{ .px = 6 }, .height = .{ .px = 6 }, .radius = 3, .background = color }, .none, null);
            ui.text(c, item.safety_info.level.shortName(), .{ .size = 11.5, .color = color });
        },
    }
}

fn footer(c: *ui.Context, a: *App, k: theme.Colors) void {
    const count = a.cleanup_selected.count();
    const notice = a.cleanup_notice;
    if (count == 0 and notice == null) return;
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.separator }, .none, null);
    const bar = ui.div(c).column().wFull().gap(6).p(12).bg(k.card);
    defer bar.end();
    if (count > 0) {
        {
            const r = ui.div(c).row().wFull().itemsCenter().gap(10);
            defer r.end();
            var buf: [32]u8 = undefined;
            _ = c.leaf(.{ .width = .{ .px = 8 }, .height = .{ .px = 8 }, .radius = 2, .background = k.accent }, .none, null);
            ui.text(c, c.print("{d} ticked", .{count}), .{ .size = 12.5, .weight = .semibold, .color = k.text });
            ui.text(c, c.print("{s}", .{item_mod.formatBytes(a.cleanupSelectedBytes(), &buf)}), .{ .size = 11.5, .mono = true, .color = k.secondary });
            ui.spacer(c);
            if (ui.button(c, "Clear", .{ .variant = .ghost, .size = 12, .disabled = a.cleanup_removing }).clicked) {
                a.cleanup_selected.clearRetainingCapacity();
                if (a.window) |w| w.redraw();
            }
            // A tool its manager can bring up to date gets a second action:
            // an update replaces what is there, it removes nothing.
            const updates = a.cleanupSelectionUpdates();
            if (updates > 0) {
                const label = if (a.cleanup_updating) "Updating…" else c.print("Update {d}…", .{updates});
                if (ui.button(c, label, .{ .variant = .secondary, .size = 12, .icon = "arrow.down.circle", .disabled = a.cleanup_removing }).clicked) {
                    a.cleanup_confirm = .update;
                    if (a.window) |w| w.redraw();
                }
            }
            const label = if (a.cleanup_removing and !a.cleanup_updating) "Removing…" else c.print("{s}…", .{a.cleanupSelectionVerb()});
            if (ui.button(c, label, .{ .variant = .primary, .size = 12, .icon = "trash", .disabled = a.cleanup_removing }).clicked) {
                a.cleanup_confirm = .remove;
                if (a.window) |w| w.redraw();
            }
        }
        if (count == 1) {
            var it = a.cleanup_selected.iterator();
            if (it.next()) |entry| explain(c, k, entry.key_ptr.*);
        }
    }
    if (notice) |text| {
        const r = ui.div(c).row().wFull().itemsCenter().gap(8);
        defer r.end();
        ui.icon(c, if (a.cleanup_notice_error) "exclamationmark.triangle.fill" else "checkmark.circle.fill", .{
            .size = 13,
            .color = if (a.cleanup_notice_error) k.orange else k.green,
        });
        ui.text(c, text, .{ .size = 12, .color = k.text });
        ui.spacer(c);
        if (ui.button(c, "Dismiss", .{ .variant = .ghost, .size = 12 }).clicked) {
            a.clearCleanupNotice();
            if (a.window) |w| w.redraw();
        }
    }
}

/// One ticked row's plain-language story: what it is, and what brings it back.
fn explain(c: *ui.Context, k: theme.Colors, item: *CacheItem) void {
    const lines = ui.div(c).column().wFull().gap(2);
    defer lines.end();
    ui.text(c, c.print("{s} — {s}", .{ item.safety_info.headline, item.safety_info.explanation }), .{ .size = 11.5, .color = k.secondary, .wrap = true });
    if (item.safety_info.reinstall_command) |cmd| {
        ui.text(c, cmd, .{ .size = 11, .mono = true, .color = k.tertiary });
    } else {
        ui.text(c, item.safety_info.recovery_steps, .{ .size = 11, .color = k.tertiary, .wrap = true });
    }
}

/// Where the space went, as the Overview page shows it beside the machine's
/// tiles: the disk's own figures, what each Cleanup tab found, and the user's
/// own folders. A Cleanup row opens that tab; nothing here moves a file.
pub fn space(c: *ui.Context, a: *App, k: theme.Colors) void {
    var b0: [32]u8 = undefined;
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    const card = kit.card(c, k);
    defer card.end();
    {
        const t = kit.title(c, "internaldrive", "Space", k.orange);
        defer t.end();
        if (a.cleanup_volume) |disk| {
            ui.text(c, c.print("Used {s} of {s} · {s} free", .{
                item_mod.formatBytes(disk.used, &b0),
                item_mod.formatBytes(disk.total, &b1),
                item_mod.formatBytes(disk.free, &b2),
            }), .{ .size = 11, .mono = true, .color = k.secondary });
        } else if (a.cleanup_scanning) {
            ui.text(c, "Measuring…", .{ .size = 11, .color = k.secondary });
        }
        scanButton(c, a, k, .secondary, 11.5);
    }
    if (a.cleanup_volume) |disk| {
        kit.bar(c, k, @as(f32, @floatFromInt(disk.used)) / @as(f32, @floatFromInt(@max(1, disk.total))), k.accent);
    }
    {
        const halves = ui.div(c).row().wFull().gap(24).itemsStart();
        defer halves.end();
        // Left: what Cleanup found, one row per tab, each a click away.
        {
            const col = ui.div(c).column().grow().w(0).gap(3);
            defer col.end();
            ui.text(c, "What Cleanup found", .{ .size = 11, .weight = .semibold, .color = k.tertiary });
            const tabs = [_]CleanupTab{ .caches, .dev, .cli, .large, .uninstall };
            for (tabs) |tab| {
                const totals = a.cleanupTabTotals(tab);
                ui.key(c, c.print("space-{s}", .{tab.title()}));
                const line = ui.div(c).row().wFull().h(20).itemsCenter().gap(8).px(4).rounded(5).hover(k.hover).control();
                defer line.end();
                if (line.clicked()) {
                    a.page = .cleanup;
                    a.cleanupSetTab(tab);
                }
                kit.chip(c, tab.icon(), kit.tabColor(tab, k), 18, false);
                ui.text(c, tab.title(), .{ .size = 12, .color = k.text });
                ui.spacer(c);
                if (totals.count == 0) {
                    ui.text(c, "—", .{ .size = 11.5, .mono = true, .color = k.tertiary });
                } else {
                    ui.text(c, c.print("{d} · {s}", .{ totals.count, item_mod.formatBytes(totals.bytes, &b0) }), .{ .size = 11.5, .mono = true, .color = k.secondary });
                }
                ui.icon(c, "chevron.right", .{ .size = 9, .weight = .semibold, .color = k.tertiary });
            }
        }
        // Right: the user's own folders, as the disk map measured them.
        {
            const col = ui.div(c).column().grow().w(0).gap(3);
            defer col.end();
            ui.text(c, "Your folders", .{ .size = 11, .weight = .semibold, .color = k.tertiary });
            var most: u64 = 1;
            for (a.cleanup_items.items) |item| {
                if (item.category == .other) most = @max(most, item.sizeBytes());
            }
            var shown: usize = 0;
            for (a.cleanup_items.items) |item| {
                if (item.category != .other) continue;
                shown += 1;
                const line = ui.div(c).row().wFull().h(20).itemsCenter().gap(8);
                defer line.end();
                ui.text(c, item.app_name, .{ .size = 12, .color = k.text });
                ui.spacer(c);
                const bar_box = ui.div(c).row().w(90);
                defer bar_box.end();
                kit.bar(c, k, @as(f32, @floatFromInt(item.sizeBytes())) / @as(f32, @floatFromInt(most)), k.blue);
                ui.text(c, c.print("{s}{s}", .{ if (item.approx()) "≈ " else "", item.formatSize(&b1) }), .{ .size = 11.5, .mono = true, .color = k.secondary });
            }
            if (shown == 0) ui.text(c, if (a.cleanup_scanning) "Measuring…" else "Nothing measured yet", .{ .size = 11.5, .color = k.tertiary });
        }
    }
    ui.text(c, "Nothing here moves a file: the Cleanup pages do that, and this only says where the space went.", .{ .size = 11, .color = k.tertiary });
}
