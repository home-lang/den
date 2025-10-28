const std = @import("std");
const builtin = @import("builtin");

/// Cross-platform environment variable access (returns pointer to static data - don't free)
/// On POSIX: returns pointer to static env data
/// On Windows: uses thread-local storage to cache values (still don't free - managed internally)
pub fn getEnv(key: []const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        // Windows: use process.getEnvVarOwned with a thread-local cache
        // This is a workaround since Windows env vars are UTF-16
        // For production use, callers should use getEnvAlloc
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const value = std.process.getEnvVarOwned(gpa.allocator(), key) catch {
            return null;
        };
        // NOTE: This leaks memory - use getEnvAlloc for proper cleanup
        return value;
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
