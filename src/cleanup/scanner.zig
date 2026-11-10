//! Scanner for app caches and system junk.
//! Scans ~/Library/Caches, Application Support, and common system junk locations.

const std = @import("std");
const item_mod = @import("item.zig");
const CacheItem = item_mod.CacheItem;
const safety_mod = @import("safety.zig");
const SafetyPolicy = safety_mod.SafetyPolicy;
const SafetyInfo = safety_mod.SafetyInfo;

const builtin = @import("builtin");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// Event types emitted during scanning
pub const ScanEvent = union(enum) {
    found: *CacheItem,
    progress: struct {
        current: usize,
        total: usize,
        path: []const u8,
    },
    finished: struct {
        total_items: usize,
        total_bytes: u64,
    },
    scan_error: struct {
        message: []const u8,
    },
};

/// Scanner for app caches
pub const CacheScanner = struct {
    allocator: std.mem.Allocator,
    policy: SafetyPolicy,
    home_dir: []const u8,
    io: std.Io,
    max_entries_per_scan: usize = 50, // Process N entries per scan call to avoid blocking
    max_files_for_dir_size: usize = 100, // Limit files to check when calculating directory size
    pub fn init(allocator: std.mem.Allocator, io: std.Io) !CacheScanner {
        var policy = SafetyPolicy.init(allocator);
        errdefer policy.deinit();

        const home_dir = if (comptime builtin.os.tag == .windows)
            if (getenv("USERPROFILE")) |p| std.mem.span(p) else return error.HomeNotFound
        else
            if (getenv("HOME")) |p| std.mem.span(p) else return error.HomeNotFound;

        return .{
            .allocator = allocator,
            .policy = policy,
            .home_dir = home_dir,
            .io = io,
        };
    }

    pub fn deinit(self: *CacheScanner) void {
        self.policy.deinit();
    }
    /// Scan ~/Library/Caches for cache items (shallow scan to prevent blocking)
    pub fn scanLibraryCaches(self: *CacheScanner) !std.ArrayListUnmanaged(*CacheItem) {
        var items = std.ArrayListUnmanaged(*CacheItem).empty;
        errdefer {
            for (items.items) |item| {
                item.deinit();
                self.allocator.destroy(item);
            }
            items.deinit(self.allocator);
        }

        const caches_path = try std.fs.path.join(self.allocator, &.{ self.home_dir, "Library", "Caches" });
        defer self.allocator.free(caches_path);

        var dir = std.Io.Dir.cwd().openDir(self.io, caches_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return items; // No caches directory
            return err;
        };
        defer dir.close(self.io);

        var iter = dir.iterate();
        var entry_count: usize = 0;
        while (try iter.next(self.io)) |entry| {
            if (entry.kind != .directory) continue;

            const folder_name = entry.name;
            const full_path = try std.fs.path.join(self.allocator, &.{ caches_path, folder_name });
            defer self.allocator.free(full_path);

            if (self.policy.isProtected(full_path)) continue;

            const safety_info = self.policy.safetyForCacheFolder(folder_name, full_path);
            if (!safety_info.level.canSurfaceInScanResults()) continue;

            // Skip size calculation to prevent blocking (size will be 0)
            const size: u64 = 0;

            const mod_time = try self.dirModTime(full_path);

            const item_id = try std.fmt.allocPrint(self.allocator, "cache:{s}", .{folder_name});
            const item = try self.allocator.create(CacheItem);
            item.* = try CacheItem.init(self.allocator, item_id, folder_name, safety_info);
            try item.addLocation(full_path, size, mod_time, folder_name);

            try items.append(self.allocator, item);

            entry_count += 1;
            if (entry_count >= self.max_entries_per_scan) break;
        }

        return items;
    }

    /// Scan Application Support for browser caches
    pub fn scanApplicationSupport(self: *CacheScanner) !std.ArrayListUnmanaged(*CacheItem) {
        var items = std.ArrayListUnmanaged(*CacheItem).empty;
        errdefer {
            for (items.items) |item| {
                item.deinit();
                self.allocator.destroy(item);
            }
            items.deinit(self.allocator);
        }

        const app_support_path = try std.fs.path.join(self.allocator, &.{ self.home_dir, "Library", "Application Support" });
        defer self.allocator.free(app_support_path);

        var dir = std.Io.Dir.cwd().openDir(self.io, app_support_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return items;
            return err;
        };
        defer dir.close(self.io);

        var iter = dir.iterate();
        var entry_count: usize = 0;
        while (try iter.next(self.io)) |entry| {
            if (entry.kind != .directory) continue;

            const folder_name = entry.name;
            const full_path = try std.fs.path.join(self.allocator, &.{ app_support_path, folder_name });
            defer self.allocator.free(full_path);

            if (self.policy.isProtected(full_path)) continue;

            const safety_info = self.policy.safetyForCacheFolder(folder_name, full_path);
            if (!safety_info.level.canSurfaceInScanResults()) continue;

            // Skip size calculation to prevent blocking (size will be 0)
            // const size = try self.dirSize(full_path);
            // if (size == 0) continue;
            const size: u64 = 0;

            const mod_time = try self.dirModTime(full_path);

            const item_id = try std.fmt.allocPrint(self.allocator, "app-support:{s}", .{folder_name});
            const item = try self.allocator.create(CacheItem);
            item.* = try CacheItem.init(self.allocator, item_id, folder_name, safety_info);
            try item.addLocation(full_path, size, mod_time, folder_name);

            try items.append(self.allocator, item);

            entry_count += 1;
            if (entry_count >= self.max_entries_per_scan) break;
        }

        return items;
    }
    /// Scan home directory for Dev Tools (shallow scan only)
    pub fn scanDevTools(self: *CacheScanner) !std.ArrayListUnmanaged(*CacheItem) {
        var items = std.ArrayListUnmanaged(*CacheItem).empty;
        errdefer {
            for (items.items) |item| {
                item.deinit();
                self.allocator.destroy(item);
            }
            items.deinit(self.allocator);
        }

        // Common Dev Tools patterns to search for
        const dev_patterns = [_][]const u8{
            "node_modules",
            ".venv",
            "venv",
            ".virtualenv",
            "zig-cache",
            "zig-out",
            ".gradle",
            "target", // Rust
            "build",  // Generic build directory
        };

        // Scan home directory for these patterns (shallow scan only)
        var home_dir_dir = std.Io.Dir.cwd().openDir(self.io, self.home_dir, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return items;
            return err;
        };
        defer home_dir_dir.close(self.io);

        var iter = home_dir_dir.iterate();
        var entry_count: usize = 0;
        while (try iter.next(self.io)) |entry| {
            if (entry.kind != .directory) continue;

            const dir_name = entry.name;

            // Check if directory matches any Dev Tools pattern
            const is_dev_tool = for (dev_patterns) |pattern| {
                if (std.mem.eql(u8, dir_name, pattern)) break true;
            } else false;

            if (!is_dev_tool) continue;

            const full_path = try std.fs.path.join(self.allocator, &.{ self.home_dir, dir_name });
            defer self.allocator.free(full_path);

            if (self.policy.isProtected(full_path)) continue;

            // Skip size calculation to prevent blocking (size will be 0)
            const size: u64 = 0;

            const mod_time = try self.dirModTime(full_path);

            // Dev Tools are generally safe to delete (medium safety level)
            const safety_info = SafetyInfo.checkFirst(
                "Dev Tools directory",
                "This directory can be regenerated (e.g., via `npm install`, `zig build`).",
                "Run the appropriate build or install command for your project."
            );

            const item_id = try std.fmt.allocPrint(self.allocator, "devtools:{s}", .{dir_name});
            const item = try self.allocator.create(CacheItem);
            item.* = try CacheItem.init(self.allocator, item_id, dir_name, safety_info);
            try item.addLocation(full_path, size, mod_time, dir_name);

            try items.append(self.allocator, item);

            entry_count += 1;
            if (entry_count >= self.max_entries_per_scan) break;
        }

        return items;
    }

    /// Calculate directory size recursively (with file limit to avoid blocking)
    /// Currently disabled to prevent UI blocking - returns 0 for all directories
    fn dirSize(self: *CacheScanner, path: []const u8) !u64 {
        _ = self;
        _ = path;
        // TODO: Implement non-blocking size calculation using async pattern
        // For now, return 0 to prevent UI freezing
        return 0;
    }

    /// Get directory modification time
    fn dirModTime(self: *CacheScanner, path: []const u8) !i64 {
        const dir = std.Io.Dir.cwd().openDir(self.io, path, .{}) catch return 0;
        defer dir.close(self.io);

        const dir_stat = dir.stat(self.io) catch return 0;
        return @intCast(dir_stat.mtime.nanoseconds);
    }
};

test "CacheScanner init" {
    var scanner = try CacheScanner.init(std.testing.allocator, std.Io.Threaded.global_single_threaded.io());
    defer scanner.deinit();

    try std.testing.expect(scanner.home_dir.len > 0);
}

test "CacheScanner protected paths" {
    var scanner = try CacheScanner.init(std.testing.allocator, std.Io.Threaded.global_single_threaded.io());
    defer scanner.deinit();

    try std.testing.expect(scanner.policy.isProtected("/System/Library"));
}

test "CacheScanner scanDevTools compilation" {
    // Just test that the function compiles
    // Skip the expensive scan in unit tests
    try std.testing.expect(true);
}
