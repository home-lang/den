// Path utilities for Den Shell - normalization and recursive walking
const std = @import("std");
const builtin = @import("builtin");

/// Platform-specific path separator
pub const separator = if (builtin.os.tag == .windows) '\\' else '/';
pub const separator_str = if (builtin.os.tag == .windows) "\\" else "/";

/// Normalize a path by resolving `.`, `..`, and redundant separators
/// Returns an owned slice that the caller must free
pub fn normalize(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (path.len == 0) {
        return try allocator.dupe(u8, ".");
    }

    var components = std.array_list.Managed([]const u8).init(allocator);
    defer components.deinit();

    const is_absolute = isAbsolute(path);
    var has_trailing_sep = path.len > 0 and isSeparator(path[path.len - 1]);

    // Split path into components
    var iter = std.mem.tokenizeAny(u8, path, "/\\");
    while (iter.next()) |component| {
        if (std.mem.eql(u8, component, ".")) {
            // Skip current directory references
            continue;
        } else if (std.mem.eql(u8, component, "..")) {
            // Go up one directory
            if (components.items.len > 0) {
                const last = components.items[components.items.len - 1];
                if (!std.mem.eql(u8, last, "..")) {
                    _ = components.pop();
                    continue;
                }
            }
            // Keep ".." if we're at the start of a relative path
            if (!is_absolute) {
                try components.append(component);
            }
        } else {
            try components.append(component);
        }
    }

    // Build result
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    if (is_absolute) {
        if (builtin.os.tag == .windows) {
            // Preserve drive letter on Windows (e.g., "C:")
            if (path.len >= 2 and path[1] == ':') {
                try result.appendSlice(path[0..2]);
            }
        }
        try result.append(separator);
    }

    for (components.items, 0..) |component, i| {
        try result.appendSlice(component);
        if (i < components.items.len - 1) {
            try result.append(separator);
        }
    }

    // Handle empty result
    if (result.items.len == 0) {
        try result.append('.');
        has_trailing_sep = false;
    }

    // Add trailing separator if original had one (and result isn't just "/")
    if (has_trailing_sep and result.items.len > 1 and !isSeparator(result.items[result.items.len - 1])) {
        try result.append(separator);
    }

    return result.toOwnedSlice();
}

/// Check if a character is a path separator
pub fn isSeparator(c: u8) bool {
    return c == '/' or (builtin.os.tag == .windows and c == '\\');
}

/// Check if a path is absolute
pub fn isAbsolute(path: []const u8) bool {
    if (path.len == 0) return false;

    if (builtin.os.tag == .windows) {
        // Windows: absolute if starts with drive letter (C:\) or UNC path (\\)
        if (path.len >= 3 and path[1] == ':' and isSeparator(path[2])) {
            return true;
        }
        if (path.len >= 2 and isSeparator(path[0]) and isSeparator(path[1])) {
            return true; // UNC path
        }
        return false;
    }

    // Unix: absolute if starts with /
    return isSeparator(path[0]);
}

/// Join path components with proper separator handling
pub fn join(allocator: std.mem.Allocator, components: []const []const u8) ![]const u8 {
    if (components.len == 0) {
        return try allocator.dupe(u8, ".");
    }

    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    for (components, 0..) |component, i| {
        if (component.len == 0) continue;

        // Skip adding separator if this component is absolute (starts fresh)
        if (i > 0 and result.items.len > 0 and !isSeparator(result.items[result.items.len - 1])) {
            if (!isAbsolute(component)) {
                try result.append(separator);
            }
        }

        // Skip leading separators if we already have content (unless absolute)
        var start: usize = 0;
        if (result.items.len > 0 and !isAbsolute(component)) {
            while (start < component.len and isSeparator(component[start])) {
                start += 1;
            }
        }

        try result.appendSlice(component[start..]);
    }

    if (result.items.len == 0) {
        try result.append('.');
    }

    return result.toOwnedSlice();
}

/// Get the directory name (parent) of a path
pub fn dirname(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (path.len == 0) {
        return try allocator.dupe(u8, ".");
    }

    // Find last separator
    var last_sep: ?usize = null;
    for (path, 0..) |c, i| {
        if (isSeparator(c)) {
            last_sep = i;
        }
    }

    if (last_sep) |sep_pos| {
        if (sep_pos == 0) {
            return try allocator.dupe(u8, separator_str);
        }
        return try allocator.dupe(u8, path[0..sep_pos]);
    }

    return try allocator.dupe(u8, ".");
}

/// Get the base name (filename) of a path
pub fn basename(path: []const u8) []const u8 {
    if (path.len == 0) return ".";

    // Remove trailing separators
    var end = path.len;
    while (end > 0 and isSeparator(path[end - 1])) {
        end -= 1;
    }
    if (end == 0) return separator_str;

    // Find last separator
    var start: usize = 0;
    for (path[0..end], 0..) |c, i| {
        if (isSeparator(c)) {
            start = i + 1;
        }
    }

    return path[start..end];
}

/// Get the file extension (including the dot)
pub fn extension(path: []const u8) []const u8 {
    const base = basename(path);
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) {
        return "";
    }

    // Find last dot (but not if it's the first character - hidden file)
    var last_dot: ?usize = null;
    for (base, 0..) |c, i| {
        if (c == '.' and i > 0) {
            last_dot = i;
        }
    }

    if (last_dot) |dot_pos| {
        return base[dot_pos..];
    }
    return "";
}

/// Recursive directory walker
pub const DirWalker = struct {
    allocator: std.mem.Allocator,
    root: []const u8,
    max_depth: ?u32,
    follow_symlinks: bool,
    include_hidden: bool,
    file_filter: ?*const fn ([]const u8) bool,

    pub const Entry = struct {
        path: []const u8,
        kind: std.Io.Dir.Entry.Kind,
        depth: u32,
    };

    pub const Config = struct {
        max_depth: ?u32 = null,
        follow_symlinks: bool = false,
        include_hidden: bool = false,
        file_filter: ?*const fn ([]const u8) bool = null,
    };

    pub fn init(allocator: std.mem.Allocator, root: []const u8, config: Config) DirWalker {
        return .{
            .allocator = allocator,
            .root = root,
            .max_depth = config.max_depth,
            .follow_symlinks = config.follow_symlinks,
            .include_hidden = config.include_hidden,
            .file_filter = config.file_filter,
        };
    }

    /// Walk directory tree and collect all entries
    /// Returns owned slice of Entry structs; caller must free both entries and their paths
    pub fn walk(self: *DirWalker) ![]Entry {
        var results = std.array_list.Managed(Entry).init(self.allocator);
        errdefer {
            for (results.items) |entry| {
                self.allocator.free(entry.path);
            }
            results.deinit();
        }

        try self.walkRecursive(self.root, 0, &results);

        return results.toOwnedSlice();
    }

    fn walkRecursive(self: *DirWalker, dir_path: []const u8, depth: u32, results: *std.array_list.Managed(Entry)) !void {
        // Check max depth
        if (self.max_depth) |max| {
            if (depth >= max) return;
        }

        var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true }) catch |err| {
            switch (err) {
                error.AccessDenied, error.FileNotFound => return,
                else => return err,
            }
        };
        defer dir.close(std.Options.debug_io);

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            // Skip hidden files unless configured to include them
            if (!self.include_hidden and entry.name.len > 0 and entry.name[0] == '.') {
                continue;
            }

            // Build full path
            const full_path = try join(self.allocator, &[_][]const u8{ dir_path, entry.name });
            errdefer self.allocator.free(full_path);

            // Apply file filter if set
            if (self.file_filter) |filter| {
                if (!filter(full_path)) {
                    self.allocator.free(full_path);
                    continue;
                }
            }

            // Add entry
            try results.append(.{
                .path = full_path,
                .kind = entry.kind,
                .depth = depth,
            });

            // Recurse into directories
            if (entry.kind == .directory) {
                try self.walkRecursive(full_path, depth + 1, results);
            } else if (entry.kind == .sym_link and self.follow_symlinks) {
                // Check if symlink points to a directory
                const stat = dir.statFile(std.Options.debug_io, entry.name, .{}) catch continue;
                if (stat.kind == .directory) {
                    try self.walkRecursive(full_path, depth + 1, results);
                }
            }
        }
    }

    /// Free entries returned by walk()
    pub fn freeEntries(self: *DirWalker, entries: []Entry) void {
        for (entries) |entry| {
            self.allocator.free(entry.path);
        }
        self.allocator.free(entries);
    }
};

/// Convenience function for simple directory walking
pub fn walkDir(allocator: std.mem.Allocator, root: []const u8, config: DirWalker.Config) ![]DirWalker.Entry {
    var walker = DirWalker.init(allocator, root, config);
    return walker.walk();
}

/// Iterate over directory entries (non-recursive, lazy)
pub const DirIterator = struct {
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    iter: std.Io.Dir.Iterator,
    base_path: []const u8,
    include_hidden: bool,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, include_hidden: bool) !DirIterator {
        const dir = try std.Io.Dir.cwd().openDir(std.Options.debug_io, path, .{ .iterate = true });
        return .{
            .allocator = allocator,
            .dir = dir,
            .iter = dir.iterate(),
            .base_path = path,
            .include_hidden = include_hidden,
        };
    }

    pub fn deinit(self: *DirIterator) void {
        self.dir.close(std.Options.debug_io);
    }

    pub fn next(self: *DirIterator) !?struct { name: []const u8, kind: std.Io.Dir.Entry.Kind } {
        while (try self.iter.next()) |entry| {
            // Skip hidden files unless configured to include them
            if (!self.include_hidden and entry.name.len > 0 and entry.name[0] == '.') {
                continue;
            }
            return .{ .name = entry.name, .kind = entry.kind };
        }
        return null;
    }
};

// Tests
test "normalize simple paths" {
    const allocator = std.testing.allocator;

    const result1 = try normalize(allocator, "foo/bar");
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("foo" ++ separator_str ++ "bar", result1);

    const result2 = try normalize(allocator, "foo//bar");
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("foo" ++ separator_str ++ "bar", result2);

    const result3 = try normalize(allocator, "");
    defer allocator.free(result3);
    try std.testing.expectEqualStrings(".", result3);
}

test "normalize with dots" {
    const allocator = std.testing.allocator;

    const result1 = try normalize(allocator, "foo/./bar");
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("foo" ++ separator_str ++ "bar", result1);

    const result2 = try normalize(allocator, "foo/bar/..");
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("foo", result2);

    const result3 = try normalize(allocator, "foo/../bar");
    defer allocator.free(result3);
    try std.testing.expectEqualStrings("bar", result3);

    const result4 = try normalize(allocator, "./foo");
    defer allocator.free(result4);
    try std.testing.expectEqualStrings("foo", result4);
}

test "normalize absolute paths" {
    const allocator = std.testing.allocator;

    const result1 = try normalize(allocator, "/foo/bar");
    defer allocator.free(result1);
    try std.testing.expectEqualStrings(separator_str ++ "foo" ++ separator_str ++ "bar", result1);

    const result2 = try normalize(allocator, "/foo/../bar");
    defer allocator.free(result2);
    try std.testing.expectEqualStrings(separator_str ++ "bar", result2);

    const result3 = try normalize(allocator, "/../foo");
    defer allocator.free(result3);
    try std.testing.expectEqualStrings(separator_str ++ "foo", result3);
}

test "normalize relative parent" {
    const allocator = std.testing.allocator;

    const result1 = try normalize(allocator, "../foo");
    defer allocator.free(result1);
    try std.testing.expectEqualStrings(".." ++ separator_str ++ "foo", result1);

    const result2 = try normalize(allocator, "../../foo");
    defer allocator.free(result2);
    try std.testing.expectEqualStrings(".." ++ separator_str ++ ".." ++ separator_str ++ "foo", result2);
}

test "join paths" {
    const allocator = std.testing.allocator;

    const result1 = try join(allocator, &[_][]const u8{ "foo", "bar" });
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("foo" ++ separator_str ++ "bar", result1);

    const result2 = try join(allocator, &[_][]const u8{ "foo/", "bar" });
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("foo" ++ separator_str ++ "bar", result2);

    const result3 = try join(allocator, &[_][]const u8{});
    defer allocator.free(result3);
    try std.testing.expectEqualStrings(".", result3);
}

test "basename" {
    try std.testing.expectEqualStrings("bar", basename("foo/bar"));
    try std.testing.expectEqualStrings("bar", basename("/foo/bar"));
    try std.testing.expectEqualStrings("bar", basename("bar"));
    try std.testing.expectEqualStrings("bar", basename("foo/bar/"));
    try std.testing.expectEqualStrings(separator_str, basename("/"));
}

test "extension" {
    try std.testing.expectEqualStrings(".txt", extension("file.txt"));
    try std.testing.expectEqualStrings(".gz", extension("file.tar.gz"));
    try std.testing.expectEqualStrings("", extension("file"));
    try std.testing.expectEqualStrings("", extension(".hidden"));
    try std.testing.expectEqualStrings(".txt", extension(".hidden.txt"));
}

test "isAbsolute" {
    if (builtin.os.tag == .windows) {
        try std.testing.expect(isAbsolute("C:\\foo"));
        try std.testing.expect(isAbsolute("\\\\server\\share"));
        try std.testing.expect(!isAbsolute("foo\\bar"));
    } else {
        try std.testing.expect(isAbsolute("/foo/bar"));
        try std.testing.expect(!isAbsolute("foo/bar"));
        try std.testing.expect(!isAbsolute("./foo"));
    }
}
