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
            // Only show directories
            if (entry.kind != .directory) continue;

            // Skip hidden files unless explicitly requested
            if (!show_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;

            if (std.mem.startsWith(u8, entry.name, file_prefix)) {
                if (match_count >= matches_buffer.len) break;

                // Build full path with trailing slash
                var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
                const full_path = if (std.mem.eql(u8, dir_path, ".")) blk: {
                    break :blk try std.fmt.bufPrint(&path_buf, "{s}/", .{entry.name});
                } else blk: {
                    break :blk try std.fmt.bufPrint(&path_buf, "{s}/{s}/", .{ dir_path, entry.name });
                };

                matches_buffer[match_count] = try self.allocator.dupe(u8, full_path);
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
};

test "completion init" {
    const allocator = std.testing.allocator;
    const comp = Completion.init(allocator);
    _ = comp;
}
