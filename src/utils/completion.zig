const std = @import("std");
const env_utils = @import("env.zig");

/// Tab completion utilities
pub const Completion = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Completion {
        return .{ .allocator = allocator };
    }

    /// Find command completions from PATH
    pub fn completeCommand(self: *Completion, prefix: []const u8) ![][]const u8 {
        var matches_buffer: [256][]const u8 = undefined;
        var match_count: usize = 0;

        // Get PATH environment variable
        const path = env_utils.getEnv("PATH") orelse return &[_][]const u8{};

        // Split PATH by ':'
        var path_iter = std.mem.splitScalar(u8, path, ':');
        while (path_iter.next()) |dir_path| {
            if (dir_path.len == 0) continue;

            // Open directory
            var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch continue;
            defer dir.close();

            // Iterate files in directory
            var iter = dir.iterate();
            while (iter.next() catch continue) |entry| {
                // Check if file starts with prefix
                if (entry.kind == .file and std.mem.startsWith(u8, entry.name, prefix)) {
                    // Check if executable
                    const stat = dir.statFile(entry.name) catch continue;
                    const is_executable = (stat.mode & 0o111) != 0;
                    
                    if (is_executable) {
                        if (match_count >= matches_buffer.len) break;
                        
                        // Check for duplicates
                        var is_dup = false;
                        for (matches_buffer[0..match_count]) |existing| {
                            if (std.mem.eql(u8, existing, entry.name)) {
                                is_dup = true;
                                break;
                            }
                        }
                        
                        if (!is_dup) {
                            matches_buffer[match_count] = try self.allocator.dupe(u8, entry.name);
                            match_count += 1;
                        }
                    }
                }
            }
        }

        // Sort matches
        self.sortMatches(matches_buffer[0..match_count]);

        // Allocate and return results
        const result = try self.allocator.alloc([]const u8, match_count);
        @memcpy(result, matches_buffer[0..match_count]);
        return result;
    }

    /// Find directory-only completions
    pub fn completeDirectory(self: *Completion, prefix: []const u8) ![][]const u8 {
        // First, try mid-word path expansion (e.g., /u/l/b -> /usr/local/bin)
        const expanded_prefix = try self.expandMidWordPath(prefix);
        const use_prefix = if (expanded_prefix) |exp| blk: {
            defer self.allocator.free(exp);
            break :blk try self.allocator.dupe(u8, exp);
        } else blk: {
            break :blk try self.allocator.dupe(u8, prefix);
        };
        defer self.allocator.free(use_prefix);

        var matches_buffer: [256][]const u8 = undefined;
        var match_count: usize = 0;

        // Parse directory and filename parts
        // If prefix ends with '/', we want to list contents of that directory
        const dir_path = if (use_prefix.len > 0 and use_prefix[use_prefix.len - 1] == '/') blk: {
            // Remove trailing slash for dirname
            const without_slash = use_prefix[0 .. use_prefix.len - 1];
            break :blk if (without_slash.len > 0) without_slash else ".";
        } else blk: {
            break :blk std.fs.path.dirname(use_prefix) orelse ".";
        };

        const file_prefix = if (use_prefix.len > 0 and use_prefix[use_prefix.len - 1] == '/') blk: {
            // If ends with slash, we're completing everything in that dir
            break :blk "";
        } else blk: {
            break :blk std.fs.path.basename(use_prefix);
        };

        // Safety check: ensure dir_path doesn't contain null bytes
        if (std.mem.indexOfScalar(u8, dir_path, 0) != null) {
            return &[_][]const u8{};
        }

        // Should we show hidden files?
        const show_hidden = file_prefix.len > 0 and file_prefix[0] == '.';

        // Open directory
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
            return &[_][]const u8{};
        };
        defer dir.close();

        // Iterate directory
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            // Only show directories
            if (entry.kind != .directory) continue;

            // Skip hidden files unless explicitly requested
            if (!show_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;

            if (std.mem.startsWith(u8, entry.name, file_prefix)) {
                if (match_count >= matches_buffer.len) break;

                // Build full path
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const full_path = if (std.mem.eql(u8, dir_path, ".")) blk: {
                    break :blk try std.fmt.bufPrint(&path_buf, "{s}", .{entry.name});
                } else blk: {
                    break :blk try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name });
                };

                // Add trailing slash for directories
                var slash_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
                const with_slash = try std.fmt.bufPrint(&slash_buf, "{s}/", .{full_path});

                matches_buffer[match_count] = try self.allocator.dupe(u8, with_slash);
                match_count += 1;
            }
        }

        // Sort matches
        self.sortMatches(matches_buffer[0..match_count]);

        // Allocate and return results
        const result = try self.allocator.alloc([]const u8, match_count);
        @memcpy(result, matches_buffer[0..match_count]);
        return result;
    }

    /// Find file/directory completions
    pub fn completeFile(self: *Completion, prefix: []const u8) ![][]const u8 {
        // First, try mid-word path expansion (e.g., /u/l/b -> /usr/local/bin)
        // This attempts to expand abbreviated path components
        const expanded_prefix = try self.expandMidWordPath(prefix);
        const use_prefix = if (expanded_prefix) |exp| blk: {
            // Use expanded path if we got one
            defer self.allocator.free(exp);
            break :blk try self.allocator.dupe(u8, exp);
        } else blk: {
            // Use original prefix if expansion failed or wasn't needed
            break :blk try self.allocator.dupe(u8, prefix);
        };
        defer self.allocator.free(use_prefix);

        // Now do regular file completion on the (possibly expanded) prefix
        var matches_buffer: [256][]const u8 = undefined;
        var match_count: usize = 0;

        // Parse directory and filename parts
        const dir_path = std.fs.path.dirname(use_prefix) orelse ".";
        const file_prefix = std.fs.path.basename(use_prefix);

        // Safety check: ensure dir_path doesn't contain null bytes
        if (std.mem.indexOfScalar(u8, dir_path, 0) != null) {
            return &[_][]const u8{};
        }

        // Should we show hidden files?
        const show_hidden = file_prefix.len > 0 and file_prefix[0] == '.';

        // Open directory
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
            return &[_][]const u8{};
        };
        defer dir.close();

        // Iterate directory
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            // Skip hidden files unless explicitly requested
            if (!show_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;

            if (std.mem.startsWith(u8, entry.name, file_prefix)) {
                if (match_count >= matches_buffer.len) break;

                // Build full path
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const full_path = if (std.mem.eql(u8, dir_path, ".")) blk: {
                    break :blk try std.fmt.bufPrint(&path_buf, "{s}", .{entry.name});
                } else blk: {
                    break :blk try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name });
                };

                // Add trailing slash for directories
                const with_slash = if (entry.kind == .directory) blk: {
                    var slash_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
                    break :blk try std.fmt.bufPrint(&slash_buf, "{s}/", .{full_path});
                } else full_path;

                matches_buffer[match_count] = try self.allocator.dupe(u8, with_slash);
                match_count += 1;
            }
        }

        // Sort matches
        self.sortMatches(matches_buffer[0..match_count]);

        // Allocate and return results
        const result = try self.allocator.alloc([]const u8, match_count);
        @memcpy(result, matches_buffer[0..match_count]);
        return result;
    }

    /// Regular file completion (without mid-word expansion)
    fn completeFileRegular(self: *Completion, prefix: []const u8) ![][]const u8 {
        var matches_buffer: [256][]const u8 = undefined;
        var match_count: usize = 0;

        // Parse directory and filename parts
        const dir_path = std.fs.path.dirname(prefix) orelse ".";
        const file_prefix = std.fs.path.basename(prefix);

        // Should we show hidden files?
        const show_hidden = file_prefix.len > 0 and file_prefix[0] == '.';

        // Open directory
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
            return &[_][]const u8{};
        };
        defer dir.close();

        // Iterate directory
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            // Skip hidden files unless explicitly requested
            if (!show_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;

            if (std.mem.startsWith(u8, entry.name, file_prefix)) {
                if (match_count >= matches_buffer.len) break;

                // Build full path
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const full_path = if (std.mem.eql(u8, dir_path, ".")) blk: {
                    break :blk try std.fmt.bufPrint(&path_buf, "{s}", .{entry.name});
                } else blk: {
                    break :blk try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name });
                };

                // Add trailing slash for directories
                const with_slash = if (entry.kind == .directory) blk: {
                    var slash_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
                    break :blk try std.fmt.bufPrint(&slash_buf, "{s}/", .{full_path});
                } else full_path;

                matches_buffer[match_count] = try self.allocator.dupe(u8, with_slash);
                match_count += 1;
            }
        }

        // Sort matches
        self.sortMatches(matches_buffer[0..match_count]);

        // Allocate and return results
        const result = try self.allocator.alloc([]const u8, match_count);
        @memcpy(result, matches_buffer[0..match_count]);
        return result;
    }

    /// Sort matches alphabetically
    fn sortMatches(self: *Completion, matches: [][]const u8) void {
        _ = self;
        if (matches.len <= 1) return;

        var i: usize = 0;
        while (i < matches.len - 1) : (i += 1) {
            var j: usize = 0;
            while (j < matches.len - 1 - i) : (j += 1) {
                if (std.mem.lessThan(u8, matches[j + 1], matches[j])) {
                    const temp = matches[j];
                    matches[j] = matches[j + 1];
                    matches[j + 1] = temp;
                }
            }
        }
    }

    /// Expand mid-word path components (zsh-style with multi-segment lookahead)
    /// Example: /u/l/b -> /usr/local/bin (even though 'l' is ambiguous, we look ahead to 'b')
    /// Returns the fully expanded path, or null if expansion fails
    pub fn expandMidWordPath(self: *Completion, path: []const u8) !?[]const u8 {
        // Skip if path doesn't look like it needs expansion
        if (path.len == 0) return null;

        // Check if this looks like a path that might need expansion
        const has_slash = std.mem.indexOfScalar(u8, path, '/') != null;
        if (!has_slash) return null;

        // Don't try to expand complete-looking paths
        if (std.mem.endsWith(u8, path, "/")) return null;

        // Parse into segments
        const is_absolute = path[0] == '/';
        const path_to_split = if (is_absolute) path[1..] else path;

        var segments_list: [32][]const u8 = undefined;
        var segment_count: usize = 0;

        var iter = std.mem.splitScalar(u8, path_to_split, '/');
        while (iter.next()) |seg| {
            if (seg.len > 0 and segment_count < segments_list.len) {
                segments_list[segment_count] = seg;
                segment_count += 1;
            }
        }

        if (segment_count == 0) return null;

        const segments = segments_list[0..segment_count];

        // Try to find a unique path through all segments using lookahead
        const start_dir = if (is_absolute) "/" else ".";
        if (try self.expandPathWithLookahead(start_dir, segments, 0)) |expanded| {
            // Check if we actually changed anything
            var test_buf: [std.fs.max_path_bytes]u8 = undefined;
            const reconstructed = if (is_absolute) blk: {
                var pos: usize = 0;
                test_buf[pos] = '/';
                pos += 1;
                for (segments, 0..) |seg, i| {
                    if (i > 0) {
                        test_buf[pos] = '/';
                        pos += 1;
                    }
                    @memcpy(test_buf[pos..pos + seg.len], seg);
                    pos += seg.len;
                }
                break :blk test_buf[0..pos];
            } else blk: {
                var pos: usize = 0;
                for (segments, 0..) |seg, i| {
                    if (i > 0) {
                        test_buf[pos] = '/';
                        pos += 1;
                    }
                    @memcpy(test_buf[pos..pos + seg.len], seg);
                    pos += seg.len;
                }
                break :blk test_buf[0..pos];
            };

            if (std.mem.eql(u8, expanded, reconstructed)) {
                self.allocator.free(expanded);
                return null;
            }

            return expanded;
        }

        return null;
    }

    /// Recursively expand path with lookahead (explores all possibilities)
    fn expandPathWithLookahead(self: *Completion, current_dir: []const u8, remaining_segments: []const []const u8, depth: usize) !?[]const u8 {
        if (remaining_segments.len == 0) {
            return try self.allocator.dupe(u8, current_dir);
        }

        // Prevent infinite recursion
        if (depth > 20) return null;

        const segment = remaining_segments[0];
        const rest = remaining_segments[1..];

        // Skip special directories
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) {
            var new_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
            const new_dir = if (std.mem.eql(u8, current_dir, "/"))
                try std.fmt.bufPrint(&new_dir_buf, "/{s}", .{segment})
            else if (std.mem.eql(u8, current_dir, "."))
                try std.fmt.bufPrint(&new_dir_buf, "{s}", .{segment})
            else
                try std.fmt.bufPrint(&new_dir_buf, "{s}/{s}", .{current_dir, segment});

            return try self.expandPathWithLookahead(new_dir, rest, depth + 1);
        }

        // Find all matching directories
        var matches: [64][]const u8 = undefined;
        var match_count: usize = 0;

        var dir = std.fs.cwd().openDir(current_dir, .{ .iterate = true }) catch return null;
        defer dir.close();

        var dir_iter = dir.iterate();
        while (dir_iter.next() catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (segment[0] != '.' and entry.name.len > 0 and entry.name[0] == '.') continue;

            if (std.mem.startsWith(u8, entry.name, segment)) {
                if (match_count >= matches.len) break;
                matches[match_count] = entry.name;
                match_count += 1;
            }
        }

        if (match_count == 0) return null;

        // If only one match, expand and continue
        if (match_count == 1) {
            var new_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
            const new_dir = if (std.mem.eql(u8, current_dir, "/"))
                try std.fmt.bufPrint(&new_dir_buf, "/{s}", .{matches[0]})
            else if (std.mem.eql(u8, current_dir, "."))
                try std.fmt.bufPrint(&new_dir_buf, "{s}", .{matches[0]})
            else
                try std.fmt.bufPrint(&new_dir_buf, "{s}/{s}", .{current_dir, matches[0]});

            return try self.expandPathWithLookahead(new_dir, rest, depth + 1);
        }

        // Multiple matches - try lookahead if we have more segments
        if (rest.len > 0) {
            var successful_path: ?[]const u8 = null;
            var success_count: usize = 0;

            for (matches[0..match_count]) |match| {
                var test_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
                const test_dir = if (std.mem.eql(u8, current_dir, "/"))
                    try std.fmt.bufPrint(&test_dir_buf, "/{s}", .{match})
                else if (std.mem.eql(u8, current_dir, "."))
                    try std.fmt.bufPrint(&test_dir_buf, "{s}", .{match})
                else
                    try std.fmt.bufPrint(&test_dir_buf, "{s}/{s}", .{current_dir, match});

                if (try self.expandPathWithLookahead(test_dir, rest, depth + 1)) |expanded_path| {
                    if (successful_path) |old_path| {
                        self.allocator.free(old_path);
                    }
                    successful_path = expanded_path;
                    success_count += 1;

                    if (success_count > 1) {
                        // Multiple valid paths, ambiguous
                        self.allocator.free(successful_path.?);
                        return null;
                    }
                }
            }

            return successful_path;
        }

        // Multiple matches and no lookahead - ambiguous
        return null;
    }

    /// Try to expand a single path segment
    /// Returns the expanded segment if unique, null otherwise
    fn expandSegment(self: *Completion, dir_path: []const u8, segment: []const u8) !?[]const u8 {
        // If segment is complete (doesn't look partial), return as-is
        if (segment.len == 0) return null;

        // Validate dir_path doesn't contain null bytes
        if (std.mem.indexOfScalar(u8, dir_path, 0) != null) {
            return null;
        }

        // Open directory
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
            return null;
        };
        defer dir.close();

        // Find entries that start with this segment
        var matches_buffer: [16][]const u8 = undefined;
        var match_count: usize = 0;

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            // Skip hidden files unless segment starts with '.'
            if (segment[0] != '.' and entry.name.len > 0 and entry.name[0] == '.') continue;

            if (std.mem.startsWith(u8, entry.name, segment)) {
                if (match_count >= matches_buffer.len) {
                    // Too many matches, ambiguous
                    return null;
                }
                matches_buffer[match_count] = entry.name;
                match_count += 1;
            }
        }

        // Only expand if exactly one match
        if (match_count == 1) {
            return try self.allocator.dupe(u8, matches_buffer[0]);
        }

        return null;
    }
};

test "completion init" {
    const allocator = std.testing.allocator;
    const comp = Completion.init(allocator);
    _ = comp;
}

test "mid-word path expansion - simple case" {
    const allocator = std.testing.allocator;
    var comp = Completion.init(allocator);

    // Test with common system paths
    // Note: This test assumes you're on a Unix-like system with /usr/local/bin
    const test_path = "/u/l/b";
    const expanded = try comp.expandMidWordPath(test_path);

    if (expanded) |path| {
        defer allocator.free(path);
        // Should expand to /usr/local/bin if it exists
        std.debug.print("\nExpanded '{s}' to '{s}'\n", .{test_path, path});
    }
}

test "mid-word path expansion - relative path" {
    const allocator = std.testing.allocator;
    var comp = Completion.init(allocator);

    // Create test directory structure
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create: testdir/subdir/file
    try tmp.dir.makeDir("testdir");
    try tmp.dir.makeDir("testdir/subdir");

    // Change to temp directory for testing
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.fs.cwd().realpath(".", &cwd_buf);
    const original_cwd_owned = try allocator.dupe(u8, original_cwd);
    defer allocator.free(original_cwd_owned);

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &tmp_path_buf);
    try std.fs.cwd().setAsCwd();
    try std.posix.chdir(tmp_path);
    defer std.posix.chdir(original_cwd_owned) catch {};

    // Test expansion of t/s (should expand to testdir/subdir)
    const test_path = "t/s";
    const expanded = try comp.expandMidWordPath(test_path);

    if (expanded) |path| {
        defer allocator.free(path);
        std.debug.print("\nExpanded '{s}' to '{s}'\n", .{test_path, path});
        try std.testing.expect(std.mem.indexOf(u8, path, "testdir") != null);
        try std.testing.expect(std.mem.indexOf(u8, path, "subdir") != null);
    }
}
