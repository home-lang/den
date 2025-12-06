const std = @import("std");

/// Configuration file watching utilities.
///
/// Provides functions for monitoring configuration file changes
/// to support hot-reload functionality.

/// Get modification time of a file.
///
/// Parameters:
/// - `path`: Optional path to the file. Returns 0 if null.
///
/// Returns the file modification time in nanoseconds, or 0 if:
/// - path is null
/// - file doesn't exist
/// - stat operation fails
pub fn getFileMtime(path: ?[]const u8) i128 {
    const config_path = path orelse return 0;
    const file = std.fs.cwd().openFile(config_path, .{}) catch return 0;
    defer file.close();
    const stat = file.stat() catch return 0;
    return stat.mtime.nanoseconds;
}

/// Alias for getFileMtime for config-specific usage.
pub const getConfigMtime = getFileMtime;

/// Check if a file has been modified since a given timestamp.
///
/// Parameters:
/// - `path`: Path to the file to check.
/// - `last_mtime`: The last known modification time.
///
/// Returns true if the file has been modified.
pub fn hasFileChanged(path: ?[]const u8, last_mtime: i128) bool {
    const current_mtime = getFileMtime(path);
    if (current_mtime == 0) return false;
    return current_mtime != last_mtime;
}

/// File watcher that tracks modification times.
pub const FileWatcher = struct {
    path: ?[]const u8,
    last_mtime: i128,

    /// Initialize a file watcher.
    pub fn init(path: ?[]const u8) FileWatcher {
        return FileWatcher{
            .path = path,
            .last_mtime = getFileMtime(path),
        };
    }

    /// Check if the file has changed since the last check.
    /// Updates the internal timestamp if changed.
    pub fn checkChanged(self: *FileWatcher) bool {
        const current_mtime = getFileMtime(self.path);
        if (current_mtime == 0) return false;

        if (current_mtime != self.last_mtime) {
            self.last_mtime = current_mtime;
            return true;
        }
        return false;
    }

    /// Update the path being watched.
    pub fn setPath(self: *FileWatcher, path: ?[]const u8) void {
        self.path = path;
        self.last_mtime = getFileMtime(path);
    }
};

// ========================================
// Tests
// ========================================

test "getFileMtime returns 0 for null path" {
    try std.testing.expectEqual(@as(i128, 0), getFileMtime(null));
}

test "getFileMtime returns 0 for nonexistent file" {
    try std.testing.expectEqual(@as(i128, 0), getFileMtime("/nonexistent/path/to/file.txt"));
}

test "FileWatcher init" {
    var watcher = FileWatcher.init(null);
    try std.testing.expectEqual(@as(i128, 0), watcher.last_mtime);
    try std.testing.expect(!watcher.checkChanged());
}
