const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");
const cpu_opt = @import("../utils/cpu_opt.zig");

/// History utilities extracted from the shell core.
///
/// This module centralizes history storage, persistence, and builtin
/// behavior so that the shell can delegate to it.
pub const History = struct {
    /// Add command to history with de-duplication and optional incremental
    /// append to the history file.
    pub fn add(
        allocator: std.mem.Allocator,
        history: []?[]const u8,
        history_count: *usize,
        history_file_path: []const u8,
        command: []const u8,
    ) !void {
        // Don't add empty commands or duplicate of last command
        if (command.len == 0) return;

        // Skip if same as last command (consecutive deduplication)
        if (history_count.* > 0) {
            if (history[history_count.* - 1]) |last_cmd| {
                if (std.mem.eql(u8, last_cmd, command)) {
                    return; // Skip consecutive duplicate
                }
            }
        }

        // Optional: Also check for duplicates in recent history (more aggressive)
        // This prevents duplicate commands even if they're not consecutive
        const check_last_n = @min(history_count.*, @min(history.len, 50));
        var i: usize = 0;
        while (i < check_last_n) : (i += 1) {
            const idx = history_count.* - 1 - i;
            if (history[idx]) |cmd_entry| {
                if (std.mem.eql(u8, cmd_entry, command)) {
                    // Found duplicate in recent history - remove old one and add at end
                    allocator.free(cmd_entry);

                    // Shift entries to remove the duplicate
                    var j = idx;
                    while (j < history_count.* - 1) : (j += 1) {
                        history[j] = history[j + 1];
                    }
                    history[history_count.* - 1] = null;
                    history_count.* -= 1;
                    break;
                }
            }
        }

        // If history is full, shift everything left
        if (history_count.* >= history.len) {
            // Free oldest entry
            if (history[0]) |oldest| {
                allocator.free(oldest);
            }

            // Shift all entries left
            var m: usize = 0;
            while (m < history.len - 1) : (m += 1) {
                history[m] = history[m + 1];
            }
            history[history.len - 1] = null;
            history_count.* -= 1;
        }

        // Add new entry
        const cmd_copy = try allocator.dupe(u8, command);
        history[history_count.*] = cmd_copy;
        history_count.* += 1;

        // Incremental append to history file (zsh-style)
        appendToFile(history_file_path, command) catch {
            // Ignore errors when appending to history file
        };
    }

    /// Load history from a file into the in-memory buffer with de-duplication.
    pub fn load(
        allocator: std.mem.Allocator,
        history: []?[]const u8,
        history_count: *usize,
        history_file_path: []const u8,
    ) !void {
        const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, history_file_path, .{}) catch |err| {
            if (err == error.FileNotFound) return; // File doesn't exist yet
            return err;
        };
        defer file.close(std.Options.debug_io);

        // Read entire file
        const max_size = 1024 * 1024; // 1MB max
        const file_size = (try file.stat(std.Options.debug_io)).size;
        const read_size: usize = @min(file_size, max_size);
        const buffer = try allocator.alloc(u8, read_size);
        defer allocator.free(buffer);
        var total_read: usize = 0;
        while (total_read < read_size) {
            const bytes_read = try file.read(buffer[total_read..]);
            if (bytes_read == 0) break;
            total_read += bytes_read;
        }
        const content = buffer[0..total_read];

        // Split by newlines and add to history (with de-duplication)
        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len > 0 and history_count.* < history.len) {
                // Check for duplicates before adding
                var is_duplicate = false;
                var k: usize = 0;
                while (k < history_count.*) : (k += 1) {
                    if (history[k]) |existing| {
                        if (std.mem.eql(u8, existing, trimmed)) {
                            is_duplicate = true;
                            break;
                        }
                    }
                }

                if (!is_duplicate) {
                    const cmd_copy = try allocator.dupe(u8, trimmed);
                    history[history_count.*] = cmd_copy;
                    history_count.* += 1;
                }
            }
        }
    }

    /// Save the entire history buffer to the history file.
    pub fn save(history: []?[]const u8, history_file_path: []const u8) !void {
        const file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, history_file_path, .{});
        defer file.close(std.Options.debug_io);

        for (history) |maybe_entry| {
            if (maybe_entry) |entry| {
                try file.writeStreamingAll(std.Options.debug_io, entry);
                try file.writeStreamingAll(std.Options.debug_io, "\n");
            }
        }
    }

    /// Append a single command to the history file.
    pub fn appendToFile(history_file_path: []const u8, command: []const u8) !void {
        const file = try std.Io.Dir.cwd().openFile(std.Options.debug_io, history_file_path, .{ .mode = .write_only });
        defer file.close(std.Options.debug_io);

        // Seek to end of file
        try file.seekFromEnd(0);

        // Append the command
        try file.writeStreamingAll(std.Options.debug_io, command);
        try file.writeStreamingAll(std.Options.debug_io, "\n");
    }

    /// Print history in the same format as the builtin `history` command.
    pub fn printBuiltin(
        history: []?[]const u8,
        history_count: usize,
        cmd: *types.ParsedCommand,
    ) !void {
        var num_entries: usize = history_count;
        if (cmd.args.len > 0) {
            num_entries = std.fmt.parseInt(usize, cmd.args[0], 10) catch {
                try IO.eprint("den: history: {s}: numeric argument required\n", .{cmd.args[0]});
                return;
            };
            if (num_entries > history_count) {
                num_entries = history_count;
            }
        }

        const start_idx = if (num_entries >= history_count) 0 else history_count - num_entries;

        var idx = start_idx;
        while (idx < history_count) : (idx += 1) {
            if (history[idx]) |entry| {
                try IO.print("{d:5}  {s}\n", .{ idx + 1, entry });
            }
        }
    }

    /// Free all history entries and the history file path buffer.
    pub fn deinit(allocator: std.mem.Allocator, history: []?[]const u8, history_file_path: []const u8) void {
        for (history) |maybe_entry| {
            if (maybe_entry) |entry| {
                allocator.free(entry);
            }
        }
        allocator.free(history_file_path);
    }

    /// Fast hash-based exact match search - O(1) average case
    /// Returns the index of the entry if found, null otherwise.
    pub fn fastExactSearch(history: []?[]const u8, history_count: usize, query: []const u8) ?usize {
        if (query.len == 0 or history_count == 0) return null;

        // Compute hash for O(1) lookup hint
        var h: u32 = 5381;
        for (query) |c| {
            h = ((h << 5) +% h) +% c;
        }
        const hash_idx = h % @min(history_count, 256);

        // Check hash position first (likely match)
        if (hash_idx < history_count) {
            if (history[hash_idx]) |entry| {
                if (std.mem.eql(u8, entry, query)) {
                    return hash_idx;
                }
            }
        }

        // Fall back to linear search from end (most recent first)
        var i = history_count;
        while (i > 0) {
            i -= 1;
            if (history[i]) |entry| {
                if (std.mem.eql(u8, entry, query)) {
                    return i;
                }
            }
        }

        return null;
    }

    /// Fuzzy search with scoring - returns best matches sorted by relevance
    /// Returns up to max_results entries with their scores.
    pub fn fuzzySearch(
        allocator: std.mem.Allocator,
        history: []?[]const u8,
        history_count: usize,
        query: []const u8,
        max_results: usize,
    ) ![]FuzzyMatch {
        if (query.len == 0 or history_count == 0) {
            return &[_]FuzzyMatch{};
        }

        var matches = std.array_list.Managed(FuzzyMatch).init(allocator);
        defer matches.deinit();

        // Score all history entries
        var i: usize = 0;
        while (i < history_count) : (i += 1) {
            if (history[i]) |entry| {
                const score = cpu_opt.fuzzyScore(entry, query);
                if (score > 0) {
                    try matches.append(.{ .entry = entry, .index = i, .score = score });
                }
            }
        }

        // Sort by score (descending), then by recency (more recent first)
        const items = matches.items;
        std.mem.sort(FuzzyMatch, items, {}, struct {
            fn lessThan(_: void, a: FuzzyMatch, b: FuzzyMatch) bool {
                if (a.score != b.score) return a.score > b.score;
                return a.index > b.index; // More recent entries first
            }
        }.lessThan);

        // Return top results
        const result_count = @min(items.len, max_results);
        const result = try allocator.alloc(FuzzyMatch, result_count);
        @memcpy(result, items[0..result_count]);
        return result;
    }

    /// Prefix search - find entries starting with query
    /// Returns the most recent match first.
    pub fn prefixSearch(history: []?[]const u8, history_count: usize, prefix: []const u8) ?[]const u8 {
        if (prefix.len == 0 or history_count == 0) return null;

        // Search from most recent
        var i = history_count;
        while (i > 0) {
            i -= 1;
            if (history[i]) |entry| {
                if (cpu_opt.hasPrefix(entry, prefix)) {
                    return entry;
                }
            }
        }
        return null;
    }

    /// Substring search - find entries containing query
    /// Starts from start_idx and searches backwards.
    pub fn substringSearch(
        history: []?[]const u8,
        history_count: usize,
        query: []const u8,
        start_idx: usize,
    ) ?SubstringMatch {
        if (query.len == 0 or history_count == 0) return null;

        var i = @min(start_idx, history_count);
        while (i > 0) {
            i -= 1;
            if (history[i]) |entry| {
                if (std.mem.indexOf(u8, entry, query) != null) {
                    return .{ .entry = entry, .index = i };
                }
            }
        }
        return null;
    }
};

/// Result of a fuzzy search
pub const FuzzyMatch = struct {
    entry: []const u8,
    index: usize,
    score: u8,
};

/// Result of a substring search
pub const SubstringMatch = struct {
    entry: []const u8,
    index: usize,
};
