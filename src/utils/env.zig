const std = @import("std");
const builtin = @import("builtin");

/// Windows environment variable cache to avoid memory leaks
/// Uses a simple LRU-style cache with fixed size
const WindowsEnvCache = struct {
    const CACHE_SIZE = 32;
    const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    entries: [CACHE_SIZE]?Entry = [_]?Entry{null} ** CACHE_SIZE,
    allocator: std.heap.GeneralPurposeAllocator(.{}) = .{},
    next_slot: usize = 0,

    fn get(self: *WindowsEnvCache, key: []const u8) ?[]const u8 {
        // First check if we already have this key cached
        for (self.entries) |entry_opt| {
            if (entry_opt) |entry| {
                if (std.mem.eql(u8, entry.key, key)) {
                    return entry.value;
                }
            }
        }

        // Not cached, fetch from OS
        const value = std.process.getEnvVarOwned(self.allocator.allocator(), key) catch {
            return null;
        };
        const key_copy = self.allocator.allocator().dupe(u8, key) catch {
            self.allocator.allocator().free(value);
            return null;
        };

        // Free old entry if slot is occupied
        if (self.entries[self.next_slot]) |old_entry| {
            self.allocator.allocator().free(old_entry.key);
            self.allocator.allocator().free(old_entry.value);
        }

        // Store in cache
        self.entries[self.next_slot] = Entry{
            .key = key_copy,
            .value = value,
        };
        self.next_slot = (self.next_slot + 1) % CACHE_SIZE;

        return value;
    }
};

/// Thread-local cache for Windows environment variables
threadlocal var windows_env_cache: WindowsEnvCache = .{};

/// Cross-platform environment variable access (returns pointer to static data - don't free)
/// On POSIX: returns pointer to static env data
/// On Windows: uses thread-local storage to cache values (still don't free - managed internally)
pub fn getEnv(key: []const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        // Windows: use thread-local cache to avoid memory leaks
        // The cache manages its own memory and reuses slots
        return windows_env_cache.get(key);
    }
    // On POSIX systems
    return std.posix.getenv(key);
}

/// Get environment variable with fallback to std.process (cross-platform, allocates)
/// Caller owns returned memory
pub fn getEnvAlloc(allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
    return std.process.getEnvVarOwned(allocator, key) catch |err| {
        if (err == error.EnvironmentVariableNotFound) {
            return null;
        }
        return err;
    };
}

/// Platform information
pub const Platform = enum {
    linux,
    macos,
    windows,
    freebsd,
    openbsd,
    netbsd,
    dragonfly,
    solaris,
    illumos,
    haiku,
    unknown,

    /// Get the current platform
    pub fn current() Platform {
        return switch (builtin.os.tag) {
            .linux => .linux,
            .macos => .macos,
            .windows => .windows,
            .freebsd => .freebsd,
            .openbsd => .openbsd,
            .netbsd => .netbsd,
            .dragonfly => .dragonfly,
            .solaris => .solaris,
            .illumos => .illumos,
            .haiku => .haiku,
            else => .unknown,
        };
    }

    /// Get platform name as string
    pub fn name(self: Platform) []const u8 {
        return switch (self) {
            .linux => "Linux",
            .macos => "macOS",
            .windows => "Windows",
            .freebsd => "FreeBSD",
            .openbsd => "OpenBSD",
            .netbsd => "NetBSD",
            .dragonfly => "DragonFly BSD",
            .solaris => "Solaris",
            .illumos => "illumos",
            .haiku => "Haiku",
            .unknown => "Unknown",
        };
    }

    /// Check if platform is Unix-like
    pub fn isUnix(self: Platform) bool {
        return switch (self) {
            .linux, .macos, .freebsd, .openbsd, .netbsd, .dragonfly, .solaris, .illumos => true,
            .windows, .haiku, .unknown => false,
        };
    }

    /// Check if platform is BSD
    pub fn isBSD(self: Platform) bool {
        return switch (self) {
            .freebsd, .openbsd, .netbsd, .dragonfly, .macos => true,
            else => false,
        };
    }
};

/// Architecture information
pub const Architecture = enum {
    x86_64,
    aarch64,
    arm,
    x86,
    riscv64,
    powerpc64,
    powerpc,
    mips64,
    mips,
    sparc64,
    unknown,

    /// Get the current architecture
    pub fn current() Architecture {
        return switch (builtin.cpu.arch) {
            .x86_64 => .x86_64,
            .aarch64 => .aarch64,
            .arm => .arm,
            .x86 => .x86,
            .riscv64 => .riscv64,
            .powerpc64 => .powerpc64,
            .powerpc => .powerpc,
            .mips64 => .mips64,
            .mips => .mips,
            .sparc64 => .sparc64,
            else => .unknown,
        };
    }

    /// Get architecture name as string
    pub fn name(self: Architecture) []const u8 {
        return switch (self) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            .arm => "arm",
            .x86 => "x86",
            .riscv64 => "riscv64",
            .powerpc64 => "powerpc64",
            .powerpc => "powerpc",
            .mips64 => "mips64",
            .mips => "mips",
            .sparc64 => "sparc64",
            .unknown => "unknown",
        };
    }

    /// Get bit width
    pub fn bits(self: Architecture) u8 {
        return switch (self) {
            .x86_64, .aarch64, .riscv64, .powerpc64, .mips64, .sparc64 => 64,
            .arm, .x86, .powerpc, .mips => 32,
            .unknown => 0,
        };
    }
};

/// System information
pub const SystemInfo = struct {
    platform: Platform,
    architecture: Architecture,

    pub fn current() SystemInfo {
        return .{
            .platform = Platform.current(),
            .architecture = Architecture.current(),
        };
    }

    /// Format as "platform-architecture" (e.g., "Linux-x86_64")
    pub fn format(
        self: SystemInfo,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s}-{s}", .{ self.platform.name(), self.architecture.name() });
    }
};

/// PATH environment variable utilities
pub const PathList = struct {
    allocator: std.mem.Allocator,
    paths: std.ArrayList([]const u8),

    /// Parse PATH environment variable
    pub fn fromEnv(allocator: std.mem.Allocator) !PathList {
        const path_str = std.posix.getenv("PATH") orelse return PathList{
            .allocator = allocator,
            .paths = std.ArrayList([]const u8){},
        };

        return try parse(allocator, path_str);
    }

    /// Parse PATH string
    pub fn parse(allocator: std.mem.Allocator, path_str: []const u8) !PathList {
        var paths = std.ArrayList([]const u8){};
        errdefer paths.deinit(allocator);

        const separator = if (builtin.os.tag == .windows) ';' else ':';
        var iter = std.mem.splitScalar(u8, path_str, separator);

        while (iter.next()) |path| {
            if (path.len > 0) {
                const owned = try allocator.dupe(u8, path);
                try paths.append(allocator, owned);
            }
        }

        return .{
            .allocator = allocator,
            .paths = paths,
        };
    }

    pub fn deinit(self: *PathList) void {
        for (self.paths.items) |path| {
            self.allocator.free(path);
        }
        self.paths.deinit(self.allocator);
    }

    /// Get number of paths
    pub fn count(self: *const PathList) usize {
        return self.paths.items.len;
    }

    /// Get path at index
    pub fn get(self: *const PathList, index: usize) ?[]const u8 {
        if (index >= self.paths.items.len) return null;
        return self.paths.items[index];
    }

    /// Check if a path exists in the list
    pub fn contains(self: *const PathList, path: []const u8) bool {
        for (self.paths.items) |p| {
            if (std.mem.eql(u8, p, path)) return true;
        }
        return false;
    }

    /// Windows executable extensions (checked in order)
    const windows_exe_extensions = [_][]const u8{ ".exe", ".com", ".bat", ".cmd", ".ps1" };

    /// Find executable in PATH
    pub fn findExecutable(self: *const PathList, allocator: std.mem.Allocator, name: []const u8) !?[]const u8 {
        for (self.paths.items) |path_dir| {
            if (builtin.os.tag == .windows) {
                // On Windows, check for executable extensions
                // First, try the name as-is (might already have extension)
                if (try self.checkWindowsExecutable(allocator, path_dir, name)) |result| {
                    return result;
                }

                // If no extension, try common executable extensions
                if (std.mem.indexOfScalar(u8, name, '.') == null) {
                    for (windows_exe_extensions) |ext| {
                        var name_with_ext_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const name_with_ext = std.fmt.bufPrint(&name_with_ext_buf, "{s}{s}", .{ name, ext }) catch continue;
                        if (try self.checkWindowsExecutable(allocator, path_dir, name_with_ext)) |result| {
                            return result;
                        }
                    }
                }
            } else {
                // On Unix, check if executable via mode bits
                const full_path = try std.fs.path.join(allocator, &[_][]const u8{ path_dir, name });
                defer allocator.free(full_path);

                // Check if file exists and is accessible
                std.fs.accessAbsolute(full_path, .{}) catch continue;

                const file = std.fs.openFileAbsolute(full_path, .{}) catch continue;
                defer file.close();

                const stat = file.stat() catch continue;
                if (stat.mode & 0o111 == 0) continue; // Not executable

                return try allocator.dupe(u8, full_path);
            }
        }

        return null;
    }

    /// Find all executables with given name in PATH (for `which -a`)
    pub fn findAllExecutables(self: *const PathList, allocator: std.mem.Allocator, name: []const u8) ![][]const u8 {
        var results = std.ArrayList([]const u8).empty;
        errdefer {
            for (results.items) |item| allocator.free(item);
            results.deinit(allocator);
        }

        for (self.paths.items) |path_dir| {
            if (builtin.os.tag == .windows) {
                // On Windows, check for executable extensions
                if (try self.checkWindowsExecutable(allocator, path_dir, name)) |result| {
                    try results.append(allocator, result);
                }
                // If no extension, try common executable extensions
                if (std.mem.indexOfScalar(u8, name, '.') == null) {
                    for (windows_exe_extensions) |ext| {
                        var name_with_ext_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const name_with_ext = std.fmt.bufPrint(&name_with_ext_buf, "{s}{s}", .{ name, ext }) catch continue;
                        if (try self.checkWindowsExecutable(allocator, path_dir, name_with_ext)) |result| {
                            try results.append(allocator, result);
                        }
                    }
                }
            } else {
                // On Unix, check if executable via mode bits
                const full_path = try std.fs.path.join(allocator, &[_][]const u8{ path_dir, name });

                // Check if file exists and is accessible
                std.fs.accessAbsolute(full_path, .{}) catch {
                    allocator.free(full_path);
                    continue;
                };

                const file = std.fs.openFileAbsolute(full_path, .{}) catch {
                    allocator.free(full_path);
                    continue;
                };
                defer file.close();

                const stat = file.stat() catch {
                    allocator.free(full_path);
                    continue;
                };

                if (stat.mode & 0o111 == 0) {
                    allocator.free(full_path);
                    continue;
                }

                try results.append(allocator, full_path);
            }
        }

        return results.toOwnedSlice(allocator);
    }

    /// Check if a file exists and is an executable on Windows
    fn checkWindowsExecutable(self: *const PathList, allocator: std.mem.Allocator, path_dir: []const u8, name: []const u8) !?[]const u8 {
        _ = self;
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ path_dir, name });
        errdefer allocator.free(full_path);

        // Check if file exists
        std.fs.accessAbsolute(full_path, .{}) catch {
            allocator.free(full_path);
            return null;
        };

        // Verify it has a valid executable extension
        const has_valid_ext = blk: {
            for (windows_exe_extensions) |ext| {
                if (std.ascii.endsWithIgnoreCase(full_path, ext)) {
                    break :blk true;
                }
            }
            break :blk false;
        };

        if (has_valid_ext) {
            return full_path;
        }

        allocator.free(full_path);
        return null;
    }

    /// Convert back to PATH string
    pub fn toString(self: *const PathList, allocator: std.mem.Allocator) ![]const u8 {
        if (self.paths.items.len == 0) return try allocator.dupe(u8, "");

        const separator = if (builtin.os.tag == .windows) ";" else ":";
        var result = std.ArrayList(u8){};
        errdefer result.deinit(allocator);

        for (self.paths.items, 0..) |path, i| {
            try result.appendSlice(allocator, path);
            if (i < self.paths.items.len - 1) {
                try result.appendSlice(allocator, separator);
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Add path to the list
    pub fn add(self: *PathList, path: []const u8) !void {
        const owned = try self.allocator.dupe(u8, path);
        try self.paths.append(self.allocator, owned);
    }

    /// Remove path at index
    pub fn remove(self: *PathList, index: usize) void {
        if (index >= self.paths.items.len) return;
        const path = self.paths.orderedRemove(index);
        self.allocator.free(path);
    }

    /// Clear all paths
    pub fn clear(self: *PathList) void {
        for (self.paths.items) |path| {
            self.allocator.free(path);
        }
        self.paths.clearRetainingCapacity();
    }
};

/// Get PATH separator for the current platform
pub fn pathSeparator() u8 {
    return if (builtin.os.tag == .windows) ';' else ':';
}

/// Get directory separator for the current platform
pub fn dirSeparator() u8 {
    return if (builtin.os.tag == .windows) '\\' else '/';
}
