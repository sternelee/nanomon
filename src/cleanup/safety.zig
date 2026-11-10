//! Safety levels and policies for cleanup items.
//! Items are classified by safety level before being shown to the user.
//! Unknown items never surface in the UI as a safety net.

const std = @import("std");

/// The classification a scanned item can carry.
pub const SafetyLevel = enum {
    /// Safe to Clean: known cache or rebuildable artifact
    safe,
    /// Check First: may be safe, but could cause inconvenience
    medium,
    /// Not Sure: the resolver could not identify this
    /// Unknown items never surface in scan results
    unknown,

    /// The only classifications permitted to surface in scan results.
    /// Anything else is dropped at the assembly boundary as a safety net.
    pub fn canSurfaceInScanResults(self: SafetyLevel) bool {
        return self == .safe or self == .medium;
    }

    /// Display name for the safety level
    pub fn displayName(self: SafetyLevel) []const u8 {
        return switch (self) {
            .safe => "Safe to Clean",
            .medium => "Check First",
            .unknown => "Not Sure",
        };
    }

    /// Sort order for filtering
    pub fn sortOrder(self: SafetyLevel) u8 {
        return switch (self) {
            .safe => 0,
            .medium => 1,
            .unknown => 2,
        };
    }
};

/// Safety information for a cleanup item.
pub const SafetyInfo = struct {
    level: SafetyLevel,
    headline: []const u8,
    explanation: []const u8,
    recovery_steps: []const u8,
    reinstall_command: ?[]const u8 = null,

    /// Create a safe safety info
    pub fn safe(headline: []const u8, explanation: []const u8) SafetyInfo {
        return .{
            .level = .safe,
            .headline = headline,
            .explanation = explanation,
            .recovery_steps = "The app will rebuild this cache automatically.",
            .reinstall_command = null,
        };
    }

    /// Create a check-first safety info
    pub fn checkFirst(headline: []const u8, explanation: []const u8, recovery: []const u8) SafetyInfo {
        return .{
            .level = .medium,
            .headline = headline,
            .explanation = explanation,
            .recovery_steps = recovery,
            .reinstall_command = null,
        };
    }

    /// Create an unknown safety info (should not surface)
    pub fn unknown(_: []const u8) SafetyInfo {
        return .{
            .level = .unknown,
            .headline = "Unknown",
            .explanation = "This folder's purpose is not recognized.",
            .recovery_steps = "Review the folder's contents before deletion.",
            .reinstall_command = null,
        };
    }
};

/// Safety policy for determining what can be cleaned.
/// All deletions must go through this policy.
pub const SafetyPolicy = struct {
    allocator: std.mem.Allocator,

    /// Paths that are protected and should never be scanned
    protected_paths: std.StringArrayHashMapUnmanaged(void),

    /// Known safe cache paths (folder names)
    safe_cache_folders: std.StringArrayHashMapUnmanaged(SafetyInfo),

    pub fn init(allocator: std.mem.Allocator) SafetyPolicy {
        var policy = SafetyPolicy{
            .allocator = allocator,
            .protected_paths = .empty,
            .safe_cache_folders = .empty,
        };
        policy.initDefaultProtectedPaths();
        policy.initDefaultSafeCaches();
        return policy;
    }

    pub fn deinit(self: *SafetyPolicy) void {
        self.protected_paths.deinit(self.allocator);
        self.safe_cache_folders.deinit(self.allocator);
    }

    /// Initialize the default protected paths that should never be scanned
    fn initDefaultProtectedPaths(self: *SafetyPolicy) void {
        // System-protected locations
        const protected = [_][]const u8{
            "/System",
            "/Library",
            "/usr",
            "/bin",
            "/sbin",
            "/etc",
            "/var",
        };

        for (protected) |path| {
            self.protected_paths.put(self.allocator, path, {}) catch {};
        }
    }

    /// Initialize known safe cache folders
    fn initDefaultSafeCaches(self: *SafetyPolicy) void {
        // Common browser cache folders
        const safe_caches = [_]struct { []const u8, []const u8, []const u8 }{
            .{ "com.google.Chrome", "Chrome browser cache", "Safe to delete; Chrome rebuilds it automatically." },
            .{ "com.apple.Safari", "Safari browser cache", "Safe to delete; Safari rebuilds it automatically." },
            .{ "com.mozilla.firefox", "Firefox browser cache", "Safe to delete; Firefox rebuilds it automatically." },
            .{ "com.microsoft.VSCode", "VS Code cache", "Safe to delete; VS Code rebuilds it automatically." },
            .{ "com.jetbrains.intellij", "JetBrains IDE cache", "Safe to delete; the IDE rebuilds it automatically." },
        };

        for (safe_caches) |item| {
            const info = SafetyInfo.safe(item[1], item[2]);
            self.safe_cache_folders.put(self.allocator, item[0], info) catch {};
        }
    }

    /// Check if a path is protected (should never be scanned)
    pub fn isProtected(self: *const SafetyPolicy, path: []const u8) bool {
        // Check if path starts with any protected prefix
        var iter = self.protected_paths.iterator();
        while (iter.next()) |entry| {
            if (std.mem.startsWith(u8, path, entry.key_ptr.*)) {
                return true;
            }
        }
        return false;
    }

    /// Determine safety level for a cache folder
    pub fn safetyForCacheFolder(self: *const SafetyPolicy, folder_name: []const u8, path: []const u8) SafetyInfo {
        // Check if it's a known safe cache
        if (self.safe_cache_folders.get(folder_name)) |info| {
            return info;
        }

        // Unknown folder - return unknown (won't surface)
        return SafetyInfo.unknown(path);
    }

    /// Check if an item can be offered for cleanup
    pub fn isOfferedForCleanup(self: *const SafetyPolicy, path: []const u8) bool {
        if (self.isProtected(path)) return false;
        return true;
    }
};

test "SafetyLevel display names" {
    try std.testing.expectEqualStrings("Safe to Clean", SafetyLevel.safe.displayName());
    try std.testing.expectEqualStrings("Check First", SafetyLevel.medium.displayName());
    try std.testing.expectEqualStrings("Not Sure", SafetyLevel.unknown.displayName());
}

test "SafetyLevel can surface" {
    try std.testing.expect(SafetyLevel.safe.canSurfaceInScanResults());
    try std.testing.expect(SafetyLevel.medium.canSurfaceInScanResults());
    try std.testing.expect(!SafetyLevel.unknown.canSurfaceInScanResults());
}

test "SafetyLevel sort order" {
    try std.testing.expect(@as(u8, 0) == SafetyLevel.safe.sortOrder());
    try std.testing.expect(@as(u8, 1) == SafetyLevel.medium.sortOrder());
    try std.testing.expect(@as(u8, 2) == SafetyLevel.unknown.sortOrder());
}

test "SafetyPolicy protected paths" {
    var policy = SafetyPolicy.init(std.testing.allocator);
    defer policy.deinit();

    try std.testing.expect(policy.isProtected("/System/Library"));
    try std.testing.expect(policy.isProtected("/usr/local"));
    try std.testing.expect(!policy.isProtected("/Users/test/Library/Caches"));
}

test "SafetyPolicy safe caches" {
    var policy = SafetyPolicy.init(std.testing.allocator);
    defer policy.deinit();

    const info = policy.safetyForCacheFolder("com.google.Chrome", "/path/to/cache");
    try std.testing.expectEqual(SafetyLevel.safe, info.level);
    try std.testing.expectEqualStrings("Chrome browser cache", info.headline);
}

test "SafetyPolicy unknown folder" {
    var policy = SafetyPolicy.init(std.testing.allocator);
    defer policy.deinit();

    const info = policy.safetyForCacheFolder("unknown.app", "/path/to/unknown");
    try std.testing.expectEqual(SafetyLevel.unknown, info.level);
}
