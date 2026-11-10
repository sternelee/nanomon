//! Cache item model for cleanup results.

const std = @import("std");
const safety_mod = @import("safety.zig");
const SafetyInfo = safety_mod.SafetyInfo;
const SafetyLevel = safety_mod.SafetyLevel;

/// A single location within a cache item (multiple locations can be merged)
pub const CacheLocation = struct {
    path: []const u8,
    size_bytes: u64,
    last_modified: i64, // Unix timestamp
    folder_name: []const u8,
};

/// A cache item that can be cleaned.
pub const CacheItem = struct {
    /// Unique identifier for this item
    id: []const u8,
    /// Canonical definition key (for explanations)
    definition_key: ?[]const u8,
    /// Locations that make up this item (multiple paths merged)
    locations: std.ArrayListUnmanaged(CacheLocation),
    /// App/folder name
    app_name: []const u8,
    /// Whether this item is selected for cleanup
    selected: bool,
    /// Safety information
    safety_info: SafetyInfo,

    allocator: std.mem.Allocator,

    /// Total size across all locations
    pub fn sizeBytes(self: *const CacheItem) u64 {
        var total: u64 = 0;
        for (self.locations.items) |loc| {
            total += loc.size_bytes;
        }
        return total;
    }

    /// Most recent last modified time
    pub fn lastModified(self: *const CacheItem) i64 {
        var latest: i64 = 0;
        for (self.locations.items) |loc| {
            if (loc.last_modified > latest) latest = loc.last_modified;
        }
        return latest;
    }

    /// Primary path (first location)
    pub fn primaryPath(self: *const CacheItem) []const u8 {
        if (self.locations.items.len == 0) return "";
        return self.locations.items[0].path;
    }

    /// Format size as human-readable string
    pub fn formatSize(self: *const CacheItem, buffer: []u8) []const u8 {
        const size = self.sizeBytes();
        return formatBytes(size, buffer);
    }

    /// Initialize a new cache item
    pub fn init(allocator: std.mem.Allocator, id: []const u8, app_name: []const u8, safety_info: SafetyInfo) !CacheItem {
        return .{
            .id = try allocator.dupe(u8, id),
            .definition_key = null,
            .locations = .empty,
            .app_name = try allocator.dupe(u8, app_name),
            .selected = false,
            .safety_info = safety_info,
            .allocator = allocator,
        };
    }

    /// Add a location to this item
    pub fn addLocation(self: *CacheItem, path: []const u8, size_bytes: u64, last_modified: i64, folder_name: []const u8) !void {
        const loc = CacheLocation{
            .path = try self.allocator.dupe(u8, path),
            .size_bytes = size_bytes,
            .last_modified = last_modified,
            .folder_name = try self.allocator.dupe(u8, folder_name),
        };
        try self.locations.append(self.allocator, loc);
    }

    /// Deallocate resources
    pub fn deinit(self: *CacheItem) void {
        for (self.locations.items) |*loc| {
            self.allocator.free(loc.path);
            self.allocator.free(loc.folder_name);
        }
        self.locations.deinit(self.allocator);
        if (self.definition_key) |key| {
            self.allocator.free(key);
        }
        self.allocator.free(self.id);
        self.allocator.free(self.app_name);
    }
};

/// Format bytes as human-readable string (e.g., "1.2 GB")
pub fn formatBytes(bytes: u64, buffer: []u8) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value: f64 = @floatFromInt(bytes);
    var unit_index: usize = 0;

    while (value >= 1024 and unit_index < units.len - 1) {
        value /= 1024;
        unit_index += 1;
    }

    if (unit_index == 0) {
        return std.fmt.bufPrint(buffer, "{d} {s}", .{ @as(u64, @intFromFloat(value)), units[unit_index] }) catch "Unknown";
    } else {
        return std.fmt.bufPrint(buffer, "{d:.1} {s}", .{ value, units[unit_index] }) catch "Unknown";
    }
}

test "formatBytes" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", formatBytes(0, &buffer));
    try std.testing.expectEqualStrings("512 B", formatBytes(512, &buffer));
    try std.testing.expectEqualStrings("1.0 KB", formatBytes(1024, &buffer));
    try std.testing.expectEqualStrings("1.5 MB", formatBytes(1572864, &buffer));
    try std.testing.expectEqualStrings("1.0 GB", formatBytes(1073741824, &buffer));
}

test "CacheItem size calculation" {
    var item = try CacheItem.init(std.testing.allocator, "test-id", "TestApp", SafetyInfo.safe("Test", "Test cache"));
    defer item.deinit();

    try item.addLocation("/path1", 1024, 1000, "folder1");
    try item.addLocation("/path2", 2048, 2000, "folder2");

    try std.testing.expectEqual(@as(u64, 3072), item.sizeBytes());
}

test "CacheItem last modified" {
    var item = try CacheItem.init(std.testing.allocator, "test-id", "TestApp", SafetyInfo.safe("Test", "Test cache"));
    defer item.deinit();

    try item.addLocation("/path1", 1024, 1000, "folder1");
    try item.addLocation("/path2", 2048, 2000, "folder2");

    try std.testing.expectEqual(@as(i64, 2000), item.lastModified());
}
