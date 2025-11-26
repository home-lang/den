const std = @import("std");
const builtin = @import("builtin");

/// Platform-specific path separator
const path_sep = if (builtin.os.tag == .windows) '\\' else '/';
const path_sep_str = if (builtin.os.tag == .windows) "\\" else "/";

/// Glob pattern matching and expansion
pub const Glob = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Glob {
        return .{ .allocator = allocator };
    }

    /// Expand glob pattern into list of matching files
    /// Returns allocated array of file paths
    pub fn expand(self: *Glob, pattern: []const u8, cwd: []const u8) ![][]const u8 {
        // Check if pattern contains glob characters
        if (!self.hasGlobChars(pattern)) {
            // No glob characters - return pattern as-is
            const result = try self.allocator.alloc([]const u8, 1);
            result[0] = try self.allocator.dupe(u8, pattern);
            return result;
        }

        // Simple implementation: expand basic wildcards in current directory
        var matches_buffer: [256][]const u8 = undefined;
        var match_count: usize = 0;

        // Open directory
        const dir_path = std.fs.path.dirname(pattern) orelse cwd;
        const base_pattern = std.fs.path.basename(pattern);

        // Parse extended glob features
        const parsed = self.parseExtendedGlob(base_pattern);

        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            // Can't open directory - return pattern as-is
            if (err == error.FileNotFound or err == error.AccessDenied) {
                const result = try self.allocator.alloc([]const u8, 1);
                result[0] = try self.allocator.dupe(u8, pattern);
                return result;
            }
            return err;
        };
        defer dir.close();

        // Iterate directory and match pattern
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            // Match base pattern
            if (!self.matchPattern(parsed.base, entry.name)) {
                continue;
            }

            // Check exclusion pattern
            if (parsed.exclusion) |exclusion| {
                if (self.matchPattern(exclusion, entry.name)) {
                    continue; // Excluded
                }
            }

            // Check file type qualifier
            if (parsed.qualifier) |qualifier| {
                if (!self.matchesQualifier(dir, entry.name, qualifier)) {
                    continue;
                }
            }

            // Match found
            if (match_count >= matches_buffer.len) {
                break; // Too many matches
            }

            // Build full path using platform-specific separator
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_path = if (std.mem.eql(u8, dir_path, ".")) blk: {
                break :blk try std.fmt.bufPrint(&path_buf, "{s}", .{entry.name});
            } else blk: {
                break :blk try std.fmt.bufPrint(&path_buf, "{s}" ++ path_sep_str ++ "{s}", .{ dir_path, entry.name });
            };

            matches_buffer[match_count] = try self.allocator.dupe(u8, full_path);
            match_count += 1;
        }

        // If no matches, return pattern as-is (bash behavior)
        if (match_count == 0) {
            const result = try self.allocator.alloc([]const u8, 1);
            result[0] = try self.allocator.dupe(u8, pattern);
            return result;
        }

        // Sort matches (alphabetically)
        self.sortMatches(matches_buffer[0..match_count]);

        // Allocate and return results
        const result = try self.allocator.alloc([]const u8, match_count);
        @memcpy(result, matches_buffer[0..match_count]);
        return result;
    }

    /// Check if string contains glob characters
    fn hasGlobChars(self: *Glob, pattern: []const u8) bool {
        _ = self;
        for (pattern) |char| {
            if (char == '*' or char == '?' or char == '[' or char == '~' or char == '(' or char == '|') {
                return true;
            }
        }
        return false;
    }

    /// Parse extended glob pattern into base pattern, exclusions, and qualifiers
    /// Returns: .{ base_pattern, exclusion_pattern, file_qualifier }
    fn parseExtendedGlob(self: *Glob, pattern: []const u8) struct {
        base: []const u8,
        exclusion: ?[]const u8,
        qualifier: ?u8,
    } {
        _ = self;

        // Check for exclusion pattern: *.txt~*.log
        if (std.mem.indexOfScalar(u8, pattern, '~')) |tilde_pos| {
            const base = pattern[0..tilde_pos];
            const exclusion = pattern[tilde_pos + 1..];

            // Check for qualifier after exclusion
            if (std.mem.lastIndexOfScalar(u8, exclusion, '(')) |qual_pos| {
                if (qual_pos + 2 < exclusion.len and exclusion[qual_pos + 2] == ')') {
                    // Check if it's a qualifier (single char, no |)
                    const inside = exclusion[qual_pos + 1 .. qual_pos + 2];
                    if (inside[0] == '.' or inside[0] == '@' or inside[0] == '/' or inside[0] == '*') {
                        return .{
                            .base = base,
                            .exclusion = exclusion[0..qual_pos],
                            .qualifier = exclusion[qual_pos + 1],
                        };
                    }
                }
            }

            return .{
                .base = base,
                .exclusion = exclusion,
                .qualifier = null,
            };
        }

        // Check for qualifier: *.txt(.)
        // Qualifier is at the END and contains a single special char
        if (std.mem.lastIndexOfScalar(u8, pattern, '(')) |qual_pos| {
            if (qual_pos + 2 < pattern.len and pattern[qual_pos + 2] == ')' and qual_pos + 3 == pattern.len) {
                // Check if it's a qualifier (single char, no |)
                const inside = pattern[qual_pos + 1];
                if (inside == '.' or inside == '@' or inside == '/' or inside == '*') {
                    return .{
                        .base = pattern[0..qual_pos],
                        .exclusion = null,
                        .qualifier = inside,
                    };
                }
            }
        }

        return .{
            .base = pattern,
            .exclusion = null,
            .qualifier = null,
        };
    }

    /// Check if file matches the qualifier
    /// . = regular file, @ = symlink, / = directory, * = executable
    fn matchesQualifier(self: *Glob, dir: std.fs.Dir, name: []const u8, qualifier: u8) bool {
        _ = self;

        const stat = dir.statFile(name) catch return false;

        return switch (qualifier) {
            '.' => stat.kind == .file,
            '@' => stat.kind == .sym_link,
            '/' => stat.kind == .directory,
            '*' => blk: {
                // Check if executable (Unix permissions)
                if (stat.kind != .file) break :blk false;
                // On Unix, check execute bits
                break :blk (stat.mode & 0o111) != 0;
            },
            else => true, // Unknown qualifier - match everything
        };
    }

    /// Match a single filename against a glob pattern
    /// Supports: * (any chars), ? (single char), [abc] (char class), (a|b) (alternation)
    fn matchPattern(self: *Glob, pattern: []const u8, name: []const u8) bool {
        _ = self;
        // Check for alternation pattern: *.(sh|zsh)
        if (std.mem.indexOfScalar(u8, pattern, '(')) |paren_pos| {
            if (std.mem.indexOfScalar(u8, pattern[paren_pos..], ')')) |close_offset| {
                const close_pos = paren_pos + close_offset;
                const prefix = pattern[0..paren_pos];
                const suffix = if (close_pos + 1 < pattern.len) pattern[close_pos + 1..] else "";
                const alternatives = pattern[paren_pos + 1..close_pos];

                // Split alternatives by |
                var iter = std.mem.splitScalar(u8, alternatives, '|');
                while (iter.next()) |alt| {
                    // Build pattern: prefix + alt + suffix
                    var buf: [std.fs.max_path_bytes]u8 = undefined;
                    const full_pattern = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ prefix, alt, suffix }) catch continue;
                    if (matchPatternImpl(full_pattern, name, 0, 0)) {
                        return true;
                    }
                }
                return false;
            }
        }

        return matchPatternImpl(pattern, name, 0, 0);
    }

    fn matchPatternImpl(pattern: []const u8, name: []const u8, p_idx: usize, n_idx: usize) bool {
        // End of pattern
        if (p_idx >= pattern.len) {
            return n_idx >= name.len;
        }

        // End of name but not pattern
        if (n_idx >= name.len) {
            // Only valid if rest of pattern is all *
            for (pattern[p_idx..]) |char| {
                if (char != '*') return false;
            }
            return true;
        }

        const p_char = pattern[p_idx];

        switch (p_char) {
            '*' => {
                // Try matching zero or more characters
                // First try zero chars (skip the *)
                if (matchPatternImpl(pattern, name, p_idx + 1, n_idx)) {
                    return true;
                }
                // Try matching one or more chars
                return matchPatternImpl(pattern, name, p_idx, n_idx + 1);
            },
            '?' => {
                // Match any single character
                return matchPatternImpl(pattern, name, p_idx + 1, n_idx + 1);
            },
            '[' => {
                // Character class - simplified implementation
                // Find closing bracket
                var end: usize = p_idx + 1;
                while (end < pattern.len and pattern[end] != ']') {
                    end += 1;
                }
                if (end >= pattern.len) {
                    // No closing bracket - treat [ as literal
                    if (name[n_idx] == '[') {
                        return matchPatternImpl(pattern, name, p_idx + 1, n_idx + 1);
                    }
                    return false;
                }

                const char_class = pattern[p_idx + 1 .. end];
                const n_char = name[n_idx];

                // Check if char is in class
                var matched = false;
                for (char_class) |c| {
                    if (c == n_char) {
                        matched = true;
                        break;
                    }
                }

                if (!matched) return false;
                return matchPatternImpl(pattern, name, end + 1, n_idx + 1);
            },
            else => {
                // Literal character match
                if (p_char != name[n_idx]) {
                    return false;
                }
                return matchPatternImpl(pattern, name, p_idx + 1, n_idx + 1);
            },
        }
    }

    /// Simple bubble sort for alphabetical ordering
    fn sortMatches(self: *Glob, matches: [][]const u8) void {
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
};

test "glob pattern matching" {
    const allocator = std.testing.allocator;
    var glob = Glob.init(allocator);

    try std.testing.expect(glob.matchPattern("*.txt", "file.txt"));
    try std.testing.expect(glob.matchPattern("*.txt", "test.txt"));
    try std.testing.expect(!glob.matchPattern("*.txt", "file.rs"));

    try std.testing.expect(glob.matchPattern("test?.txt", "test1.txt"));
    try std.testing.expect(glob.matchPattern("test?.txt", "testa.txt"));
    try std.testing.expect(!glob.matchPattern("test?.txt", "test12.txt"));

    try std.testing.expect(glob.matchPattern("file[123].txt", "file1.txt"));
    try std.testing.expect(glob.matchPattern("file[123].txt", "file2.txt"));
    try std.testing.expect(!glob.matchPattern("file[123].txt", "file4.txt"));
}

test "glob has glob chars" {
    const allocator = std.testing.allocator;
    var glob = Glob.init(allocator);

    try std.testing.expect(glob.hasGlobChars("*.txt"));
    try std.testing.expect(glob.hasGlobChars("test?.rs"));
    try std.testing.expect(glob.hasGlobChars("file[123].txt"));
    try std.testing.expect(!glob.hasGlobChars("regular.txt"));
}
