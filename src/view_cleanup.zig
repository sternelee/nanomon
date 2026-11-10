//! The Cleanup page: scan and delete app caches and system junk.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;

const cleanup_mod = @import("cleanup/scanner.zig");
const CacheScanner = cleanup_mod.CacheScanner;
const item_mod = @import("cleanup/item.zig");
const CacheItem = item_mod.CacheItem;
const safety_mod = @import("cleanup/safety.zig");
const SafetyLevel = safety_mod.SafetyLevel;
const trash_mod = @import("cleanup/trash.zig");
const TrashManager = trash_mod.TrashManager;

const row_h = 30;

const Column = struct { title: []const u8, width: ?f32 = null };

const columns = [_]Column{
    .{ .title = "Name", .width = null },
    .{ .title = "Location", .width = 180 },
    .{ .title = "Size", .width = 90 },
    .{ .title = "Safety", .width = 80 },
};

fn cell(c: *ui.Context, col: Column, h: f32) ui.Div {
    var d = ui.div(c).row().h(h).itemsCenter().px(10).clip();
    d = if (col.width) |w| d.w(w).justifyEnd() else d.grow().w(0);
    return d;
}

fn safetyColor(level: SafetyLevel, k: theme.Colors) ui.Color {
    return switch (level) {
        .safe => k.green,
        .medium => k.orange,
        .unknown => k.gray,
    };
}

fn safetyLabel(level: SafetyLevel) []const u8 {
    return switch (level) {
        .safe => "Safe",
        .medium => "Review",
        .unknown => "Unknown",
    };
}

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    {
        const h = kit.header(c, k, "Cleanup", "Scan and delete app caches");
        defer h.end();
        // Scan button temporarily disabled
        // const scan = ui.div(c).row().h(28).itemsCenter().gap(8).control();
        // defer scan.end();
        // if (scan.clicked()) {
        //     a.cleanup_scanning = true;
        //     a.cleanup_scan_phase = 0;
        // }
        // ui.text(c, "Scan", .{ .size = 12.5, .weight = .medium, .color = k.text });
    }
    {
        const h = ui.div(c).row().wFull().h(28).itemsCenter().px(10);
        defer h.end();
        for (columns, 0..) |col, i| {
            if (i > 0) _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .{ .px = 14 }, .background = k.separator }, .none, null);
            ui.key(c, col.title);
            const d = cell(c, col, 28).gap(4);
            defer d.end();
            ui.text(c, col.title, .{ .size = 11.5, .weight = .semibold, .color = k.secondary });
        }
    }
    // Scan phase temporarily disabled
    // if (a.cleanup_scanning) {
    //     var scanner = CacheScanner.init(a.sampler.gpa, a.sampler.io) catch {
    //         a.cleanup_scanning = false;
    //         return;
    //     };
    //     defer scanner.deinit();
    //
    //     switch (a.cleanup_scan_phase) {
    //         0 => {
    //             // Phase 0: Scan Library Caches
    //             if (scanner.scanLibraryCaches()) |items| {
    //                 a.cleanup_items.appendSlice(a.sampler.gpa, items.items) catch {};
    //             } else |_| {}
    //             a.cleanup_scan_phase = 1;
    //             if (a.window) |w| w.redraw();
    //         },
    //         1 => {
    //             // Phase 1: Scan Application Support
    //             if (scanner.scanApplicationSupport()) |items| {
    //                 a.cleanup_items.appendSlice(a.sampler.gpa, items.items) catch {};
    //             } else |_| {}
    //             a.cleanup_scan_phase = 2;
    //             if (a.window) |w| w.redraw();
    //         },
    //         2 => {
    //             // Phase 2: Scan Dev Tools
    //             if (scanner.scanDevTools()) |items| {
    //                 a.cleanup_items.appendSlice(a.sampler.gpa, items.items) catch {};
    //             } else |_| {}
    //             a.cleanup_scan_phase = 3;
    //             a.cleanup_scanning = false;
    //             if (a.window) |w| w.redraw();
    //         },
    //         3 => {
    //             // Done
    //             a.cleanup_scanning = false;
    //         },
    //         else => {
    //             // Invalid phase, reset
    //             a.cleanup_scanning = false;
    //             a.cleanup_scan_phase = 0;
    //         },
    //     }
    // }
    // Render items
    if (a.cleanup_items.items.len == 0) {
        const empty = ui.div(c).column().wFull().grow().center().gap(10);
        defer empty.end();
        ui.text(c, "Scan functionality temporarily disabled", .{ .size = 13, .color = k.secondary });
        ui.text(c, "UI blocking issue - using async pattern required", .{ .size = 11.5, .color = k.tertiary });
    } else {
        for (a.cleanup_items.items, 0..) |item, i| {
            const row = ui.div(c).row().wFull().h(row_h).itemsCenter();
            defer row.end();

            // Checkbox for selection
            const selected = a.cleanup_selected.get(i) != null;
            const checkbox = ui.div(c).w(20).h(20).center().control();
            defer checkbox.end();
            if (checkbox.clicked()) {
                if (selected) {
                    _ = a.cleanup_selected.swapRemove(i);
                } else {
                    a.cleanup_selected.put(a.sampler.gpa, i, {}) catch {};
                }
                if (a.window) |w| w.redraw();
            }
            if (selected) {
                _ = c.leaf(.{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .background = k.accent }, .none, null);
            } else {
                _ = c.leaf(.{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .background = k.border }, .none, null);
            }

            // Name
            _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .{ .px = 14 }, .background = k.separator }, .none, null);
            const name_cell = cell(c, columns[0], row_h);
            defer name_cell.end();
            ui.text(c, item.app_name, .{ .size = 12.5, .color = k.text });

            // Location
            _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .{ .px = 14 }, .background = k.separator }, .none, null);
            // Size
            _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .{ .px = 14 }, .background = k.separator }, .none, null);
            const size_cell = cell(c, columns[2], row_h);
            defer size_cell.end();
            var size_buf: [32]u8 = undefined;
            ui.text(c, item.formatSize(&size_buf), .{ .size = 11.5, .color = k.secondary });

            // Safety
            _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .{ .px = 14 }, .background = k.separator }, .none, null);
            const safety_cell = cell(c, columns[3], row_h);
            defer safety_cell.end();
            const safety_color = safetyColor(item.safety_info.level, k);
            _ = c.leaf(.{ .width = .{ .px = 6 }, .height = .{ .px = 6 }, .background = safety_color }, .none, null);
            ui.text(c, safetyLabel(item.safety_info.level), .{ .size = 11.5, .color = safety_color });
        }
    }

    // Delete button (at bottom)
    if (a.cleanup_selected.count() > 0) {
        const footer = ui.div(c).row().wFull().h(44).itemsCenter().px(10).gap(10);
        defer footer.end();
        const delete = ui.div(c).row().h(28).itemsCenter().px(12).rounded(6).control();
        defer delete.end();
        if (delete.clicked()) {
            a.cleanup_confirm = true;
            if (a.window) |w| w.redraw();
        }
        ui.text(c, "Delete Selected", .{ .size = 12.5, .weight = .medium, .color = k.text });
        var count_buf: [32]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d} items", .{a.cleanup_selected.count()}) catch "0 items";
        ui.text(c, count_str, .{ .size = 11.5, .color = k.secondary });
    }

    // Confirmation sheet
    if (a.cleanup_confirm) {
        const sheet = ui.div(c).column().w(300).center().gap(12).rounded(12);
        defer sheet.end();
        ui.text(c, "Delete Selected Items?", .{ .size = 14, .weight = .semibold, .color = k.text });
        ui.text(c, "Items will be moved to Trash.", .{ .size = 12, .color = k.secondary });
        const buttons = ui.div(c).row().wFull().gap(8);
        defer buttons.end();
        const cancel = ui.div(c).row().h(28).itemsCenter().px(12).rounded(6).control();
        defer cancel.end();
        if (cancel.clicked()) {
            a.cleanup_confirm = false;
            if (a.window) |w| w.redraw();
        }
        ui.text(c, "Cancel", .{ .size = 12.5, .weight = .medium, .color = k.text });
        const confirm = ui.div(c).row().h(28).itemsCenter().px(12).rounded(6).control();
        defer confirm.end();
        if (confirm.clicked()) {
            // Delete selected items
            var trash = TrashManager.init(a.sampler.gpa, a.sampler.io) catch return;
            defer trash.deinit();

            var it = a.cleanup_selected.iterator();
            while (it.next()) |entry| {
                const idx = entry.key_ptr.*;
                if (idx < a.cleanup_items.items.len) {
                    const item = a.cleanup_items.items[idx];
                    for (item.locations.items) |loc| {
                        trash.moveToTrash(loc.path) catch {};
                    }
                }
            }

            // Clear selected items from list
            var keep: usize = 0;
            for (a.cleanup_items.items, 0..) |item, i| {
                if (a.cleanup_selected.get(i) == null) {
                    a.cleanup_items.items[keep] = item;
                    keep += 1;
                } else {
                    item.deinit();
                    a.sampler.gpa.destroy(item);
                }
            }
            a.cleanup_items.shrinkRetainingCapacity(keep);
            a.cleanup_selected.clearRetainingCapacity();
            a.cleanup_confirm = false;
            if (a.window) |w| w.redraw();
        }
        ui.text(c, "Delete", .{ .size = 12.5, .weight = .medium, .color = k.text });
    }
}
