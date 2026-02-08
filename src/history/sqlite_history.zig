const std = @import("std");
const posix = std.posix;

/// Structured history entry with rich metadata.
/// Each entry captures command text, timing, exit status, working directory,
/// and session information for analytics and advanced search.
pub const HistoryEntry = struct {
    command: []const u8,
    timestamp: i64,
    duration_ms: i64,
    exit_code: i32,
    cwd: []const u8,
    session_id: []const u8,

    /// Free all owned string fields.
    pub fn deinit(self: *const HistoryEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
        allocator.free(self.cwd);
        allocator.free(self.session_id);
    }
};

/// A single entry in the "most used commands" ranking.
pub const MostUsedCommand = struct {
    command: []const u8,
    count: usize,
};

/// Aggregate statistics computed from the structured history.
pub const HistoryStats = struct {
    total_entries: usize,
    unique_commands: usize,
    sessions: usize,
    avg_duration_ms: i64,
    most_used: [10]MostUsedCommand,
    most_used_count: usize,

    pub fn deinit(self: *const HistoryStats, allocator: std.mem.Allocator) void {
        for (self.most_used[0..self.most_used_count]) |entry| {
            allocator.free(entry.command);
        }
    }
};

/// File-backed structured history stored as newline-delimited JSON (.jsonl).
///
/// Provides the same benefits as an SQLite-backed history: per-session tracking,
/// timestamps, working directory recording, substring search, and analytics,
/// without requiring a native SQLite dependency.
pub const StructuredHistory = struct {
    allocator: std.mem.Allocator,
    file_path: []const u8,
    session_id: []const u8,
    entries: std.ArrayList(HistoryEntry),
    max_entries: usize,

    /// Create a new StructuredHistory.
    /// `file_path` and `session_id` must outlive the returned struct (or be
    /// heap-allocated and freed after `deinit`).
    pub fn init(allocator: std.mem.Allocator, file_path: []const u8, session_id: []const u8) StructuredHistory {
        return .{
            .allocator = allocator,
            .file_path = file_path,
            .session_id = session_id,
            .entries = std.ArrayList(HistoryEntry).empty,
            .max_entries = 50000,
        };
    }

    /// Release all resources held by this history instance.
    pub fn deinit(self: *StructuredHistory) void {
        for (self.entries.items) |entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
    }

    /// Record a new command, persist it to disk immediately.
    pub fn addEntry(
        self: *StructuredHistory,
        command: []const u8,
        exit_code: i32,
        cwd: []const u8,
        duration_ms: i64,
    ) !void {
        if (command.len == 0) return;

        const timestamp = getTimestamp();

        const entry = HistoryEntry{
            .command = try self.allocator.dupe(u8, command),
            .timestamp = timestamp,
            .duration_ms = duration_ms,
            .exit_code = exit_code,
            .cwd = try self.allocator.dupe(u8, cwd),
            .session_id = try self.allocator.dupe(u8, self.session_id),
        };

        try self.entries.append(self.allocator, entry);

        // Persist by appending one JSON line to the file.
        self.appendEntryToFile(entry) catch |err| {
            // Best-effort persistence; log but do not propagate.
            _ = err;
        };
    }

    /// Load all entries from the .jsonl file into memory.
    pub fn load(self: *StructuredHistory) !void {
        const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, self.file_path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close(std.Options.debug_io);

        const max_size: usize = 10 * 1024 * 1024; // 10 MB cap
        const file_size = (try file.stat(std.Options.debug_io)).size;
        const read_size: usize = @min(file_size, max_size);
        const buffer = try self.allocator.alloc(u8, read_size);
        defer self.allocator.free(buffer);

        var total_read: usize = 0;
        while (total_read < read_size) {
            const bytes_read = try posix.read(file.handle, buffer[total_read..]);
            if (bytes_read == 0) break;
            total_read += bytes_read;
        }
        const content = buffer[0..total_read];

        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;

            if (entryFromJson(self.allocator, trimmed)) |entry| {
                try self.entries.append(self.allocator, entry);
            } else |_| {
                // Skip malformed lines silently.
            }
        }
    }

    /// Return entries whose command text contains `pattern`.
    pub fn search(self: *StructuredHistory, allocator: std.mem.Allocator, pattern: []const u8) ![]const HistoryEntry {
        var results = std.ArrayList(HistoryEntry).empty;
        errdefer results.deinit(allocator);

        for (self.entries.items) |entry| {
            if (std.mem.indexOf(u8, entry.command, pattern) != null) {
                try results.append(allocator, entry);
            }
        }
        return results.toOwnedSlice(allocator);
    }

    /// Return entries that belong to the given session.
    pub fn searchBySession(self: *StructuredHistory, allocator: std.mem.Allocator, sid: []const u8) ![]const HistoryEntry {
        var results = std.ArrayList(HistoryEntry).empty;
        errdefer results.deinit(allocator);

        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.session_id, sid)) {
                try results.append(allocator, entry);
            }
        }
        return results.toOwnedSlice(allocator);
    }

    /// Return the last `n` entries (or fewer if the history is smaller).
    pub fn getRecent(self: *StructuredHistory, n: usize) []const HistoryEntry {
        const items = self.entries.items;
        if (n >= items.len) return items;
        return items[items.len - n ..];
    }

    /// Compute aggregate statistics from the in-memory entries.
    pub fn getStats(self: *StructuredHistory, allocator: std.mem.Allocator) !HistoryStats {
        var command_counts: std.StringHashMapUnmanaged(usize) = .empty;
        defer command_counts.deinit(allocator);

        var session_set: std.StringHashMapUnmanaged(void) = .empty;
        defer session_set.deinit(allocator);

        var total_duration: i64 = 0;
        var duration_count: usize = 0;

        for (self.entries.items) |entry| {
            // Count commands
            const gop = try command_counts.getOrPut(allocator, entry.command);
            if (gop.found_existing) {
                gop.value_ptr.* += 1;
            } else {
                gop.value_ptr.* = 1;
            }

            // Track sessions
            const sgop = try session_set.getOrPut(allocator, entry.session_id);
            _ = sgop;

            // Accumulate durations
            if (entry.duration_ms > 0) {
                total_duration += entry.duration_ms;
                duration_count += 1;
            }
        }

        // Build the top-10 most-used commands.
        var most_used: [10]MostUsedCommand = undefined;
        var most_used_count: usize = 0;

        var cmd_iter = command_counts.iterator();
        while (cmd_iter.next()) |kv| {
            const cmd = kv.key_ptr.*;
            const cnt = kv.value_ptr.*;

            if (most_used_count < 10) {
                most_used[most_used_count] = .{
                    .command = try allocator.dupe(u8, cmd),
                    .count = cnt,
                };
                most_used_count += 1;
                // Bubble-sort the new entry into position.
                sortMostUsed(most_used[0..most_used_count]);
            } else if (cnt > most_used[most_used_count - 1].count) {
                allocator.free(most_used[most_used_count - 1].command);
                most_used[most_used_count - 1] = .{
                    .command = try allocator.dupe(u8, cmd),
                    .count = cnt,
                };
                sortMostUsed(most_used[0..most_used_count]);
            }
        }

        // Zero-fill any unused slots.
        for (most_used[most_used_count..10]) |*slot| {
            slot.* = .{ .command = &[_]u8{}, .count = 0 };
        }

        const avg_dur: i64 = if (duration_count > 0) @divTrunc(total_duration, @as(i64, @intCast(duration_count))) else 0;

        return HistoryStats{
            .total_entries = self.entries.items.len,
            .unique_commands = command_counts.count(),
            .sessions = session_set.count(),
            .avg_duration_ms = avg_dur,
            .most_used = most_used,
            .most_used_count = most_used_count,
        };
    }

    /// Trim history to `max_entries` and rewrite the backing file.
    pub fn compact(self: *StructuredHistory) !void {
        if (self.entries.items.len <= self.max_entries) return;

        // Free oldest entries that exceed the cap.
        const to_remove = self.entries.items.len - self.max_entries;
        for (self.entries.items[0..to_remove]) |entry| {
            entry.deinit(self.allocator);
        }

        // Shift remaining entries to the front.
        const remaining = self.entries.items[to_remove..];
        std.mem.copyForwards(HistoryEntry, self.entries.items[0..remaining.len], remaining);
        self.entries.shrinkRetainingCapacity(remaining.len);

        // Rewrite the file with the surviving entries.
        try self.rewriteFile();
    }

    /// Remove all history entries and truncate the backing file.
    pub fn clear(self: *StructuredHistory) !void {
        for (self.entries.items) |entry| {
            entry.deinit(self.allocator);
        }
        self.entries.clearRetainingCapacity();

        // Truncate the file by creating it anew.
        const file = std.Io.Dir.cwd().createFile(std.Options.debug_io, self.file_path, .{}) catch return;
        file.close(std.Options.debug_io);
    }

    // ------------------------------------------------------------------
    // JSON serialization helpers (public so callers can use them directly)
    // ------------------------------------------------------------------

    /// Serialize a single HistoryEntry to a one-line JSON string.
    pub fn entryToJson(allocator: std.mem.Allocator, entry: HistoryEntry) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);

        try buf.appendSlice(allocator, "{\"command\":\"");
        try appendJsonEscaped(allocator, &buf, entry.command);
        try buf.appendSlice(allocator, "\",\"timestamp\":");
        try appendInt(allocator, &buf, entry.timestamp);
        try buf.appendSlice(allocator, ",\"duration_ms\":");
        try appendInt(allocator, &buf, entry.duration_ms);
        try buf.appendSlice(allocator, ",\"exit_code\":");
        try appendI32(allocator, &buf, entry.exit_code);
        try buf.appendSlice(allocator, ",\"cwd\":\"");
        try appendJsonEscaped(allocator, &buf, entry.cwd);
        try buf.appendSlice(allocator, "\",\"session_id\":\"");
        try appendJsonEscaped(allocator, &buf, entry.session_id);
        try buf.appendSlice(allocator, "\"}");

        return buf.toOwnedSlice(allocator);
    }

    /// Parse a single JSON line back into a HistoryEntry.
    /// Returns `null` (via error) when the line cannot be parsed.
    pub fn entryFromJson(allocator: std.mem.Allocator, json_line: []const u8) !HistoryEntry {
        const parsed = std.json.parseFromSlice(JsonEntry, allocator, json_line, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return error.InvalidJson;

        const v = parsed.value;

        // Duplicate strings so they outlive the parsed arena.
        const command = try allocator.dupe(u8, v.command);
        errdefer allocator.free(command);
        const cwd = try allocator.dupe(u8, v.cwd);
        errdefer allocator.free(cwd);
        const sid = try allocator.dupe(u8, v.session_id);
        errdefer allocator.free(sid);

        // Free the JSON parser's arena now that we have our own copies.
        parsed.deinit();

        return HistoryEntry{
            .command = command,
            .timestamp = v.timestamp,
            .duration_ms = v.duration_ms,
            .exit_code = v.exit_code,
            .cwd = cwd,
            .session_id = sid,
        };
    }

    // ------------------------------------------------------------------
    // Private helpers
    // ------------------------------------------------------------------

    /// JSON-compatible struct that mirrors HistoryEntry for `std.json.parseFromSlice`.
    const JsonEntry = struct {
        command: []const u8 = "",
        timestamp: i64 = 0,
        duration_ms: i64 = 0,
        exit_code: i32 = 0,
        cwd: []const u8 = "",
        session_id: []const u8 = "",
    };

    fn appendEntryToFile(self: *StructuredHistory, entry: HistoryEntry) !void {
        const json_line = try entryToJson(self.allocator, entry);
        defer self.allocator.free(json_line);

        const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, self.file_path, .{ .mode = .write_only }) catch blk: {
            // File may not exist yet; create it.
            break :blk try std.Io.Dir.cwd().createFile(std.Options.debug_io, self.file_path, .{});
        };
        defer file.close(std.Options.debug_io);

        // Seek to end.
        _ = std.c.lseek(file.handle, 0, std.c.SEEK.END);

        try file.writeStreamingAll(std.Options.debug_io, json_line);
        try file.writeStreamingAll(std.Options.debug_io, "\n");
    }

    fn rewriteFile(self: *StructuredHistory) !void {
        const file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, self.file_path, .{});
        defer file.close(std.Options.debug_io);

        for (self.entries.items) |entry| {
            const json_line = try entryToJson(self.allocator, entry);
            defer self.allocator.free(json_line);
            try file.writeStreamingAll(std.Options.debug_io, json_line);
            try file.writeStreamingAll(std.Options.debug_io, "\n");
        }
    }

    fn sortMostUsed(slice: []MostUsedCommand) void {
        // Simple insertion sort (at most 10 elements).
        var i: usize = 1;
        while (i < slice.len) : (i += 1) {
            const key = slice[i];
            var j: usize = i;
            while (j > 0 and slice[j - 1].count < key.count) {
                slice[j] = slice[j - 1];
                j -= 1;
            }
            slice[j] = key;
        }
    }

    /// Append a JSON-escaped version of `str` to `buf`.
    fn appendJsonEscaped(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), str: []const u8) !void {
        for (str) |c| {
            switch (c) {
                '"' => try buf.appendSlice(allocator, "\\\""),
                '\\' => try buf.appendSlice(allocator, "\\\\"),
                '\n' => try buf.appendSlice(allocator, "\\n"),
                '\r' => try buf.appendSlice(allocator, "\\r"),
                '\t' => try buf.appendSlice(allocator, "\\t"),
                else => {
                    if (c < 0x20) {
                        // Control characters as \\uXXXX.
                        var hex_buf: [6]u8 = undefined;
                        const hex = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{c}) catch continue;
                        try buf.appendSlice(allocator, hex);
                    } else {
                        try buf.append(allocator, c);
                    }
                },
            }
        }
    }

    /// Append the decimal representation of an i64.
    fn appendInt(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: i64) !void {
        var num_buf: [24]u8 = undefined;
        const formatted = std.fmt.bufPrint(&num_buf, "{d}", .{value}) catch return;
        try buf.appendSlice(allocator, formatted);
    }

    /// Append the decimal representation of an i32.
    fn appendI32(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: i32) !void {
        var num_buf: [16]u8 = undefined;
        const formatted = std.fmt.bufPrint(&num_buf, "{d}", .{value}) catch return;
        try buf.appendSlice(allocator, formatted);
    }

    /// Return the current UNIX epoch timestamp in seconds.
    fn getTimestamp() i64 {
        if (std.time.Instant.now()) |instant| {
            return @intCast(instant.timestamp.sec);
        } else |_| {
            return 0;
        }
    }
};

// =========================================================================
// Tests
// =========================================================================

test "entryToJson and entryFromJson round-trip" {
    const allocator = std.testing.allocator;

    const original = HistoryEntry{
        .command = "ls -la",
        .timestamp = 1700000000,
        .duration_ms = 42,
        .exit_code = 0,
        .cwd = "/home/user",
        .session_id = "abc-123",
    };

    const json_line = try StructuredHistory.entryToJson(allocator, original);
    defer allocator.free(json_line);

    // Verify it is valid JSON containing expected fields.
    try std.testing.expect(std.mem.indexOf(u8, json_line, "\"command\":\"ls -la\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_line, "\"timestamp\":1700000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_line, "\"exit_code\":0") != null);

    // Parse it back.
    const parsed = try StructuredHistory.entryFromJson(allocator, json_line);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("ls -la", parsed.command);
    try std.testing.expectEqual(@as(i64, 1700000000), parsed.timestamp);
    try std.testing.expectEqual(@as(i64, 42), parsed.duration_ms);
    try std.testing.expectEqual(@as(i32, 0), parsed.exit_code);
    try std.testing.expectEqualStrings("/home/user", parsed.cwd);
    try std.testing.expectEqualStrings("abc-123", parsed.session_id);
}

test "entryToJson escapes special characters" {
    const allocator = std.testing.allocator;

    const entry = HistoryEntry{
        .command = "echo \"hello\nworld\"",
        .timestamp = 0,
        .duration_ms = 0,
        .exit_code = 0,
        .cwd = "/tmp",
        .session_id = "s1",
    };

    const json_line = try StructuredHistory.entryToJson(allocator, entry);
    defer allocator.free(json_line);

    // The double-quotes and newline inside the command must be escaped.
    try std.testing.expect(std.mem.indexOf(u8, json_line, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_line, "\\n") != null);

    // Verify it round-trips.
    const parsed = try StructuredHistory.entryFromJson(allocator, json_line);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("echo \"hello\nworld\"", parsed.command);
}

test "entryFromJson rejects garbage" {
    const allocator = std.testing.allocator;
    const result = StructuredHistory.entryFromJson(allocator, "not json at all");
    try std.testing.expectError(error.InvalidJson, result);
}

test "StructuredHistory init and deinit" {
    const allocator = std.testing.allocator;

    var history = StructuredHistory.init(allocator, "/tmp/den_test_history.jsonl", "test-session-1");
    defer history.deinit();

    try std.testing.expectEqual(@as(usize, 50000), history.max_entries);
    try std.testing.expectEqual(@as(usize, 0), history.entries.items.len);
    try std.testing.expectEqualStrings("test-session-1", history.session_id);
}

test "getRecent returns correct slice" {
    const allocator = std.testing.allocator;

    var history = StructuredHistory.init(allocator, "/dev/null", "sess");
    defer history.deinit();

    // Manually add entries (bypassing file I/O).
    for (0..5) |i| {
        try history.entries.append(allocator, .{
            .command = try allocator.dupe(u8, "cmd"),
            .timestamp = @intCast(i),
            .duration_ms = 0,
            .exit_code = 0,
            .cwd = try allocator.dupe(u8, "/"),
            .session_id = try allocator.dupe(u8, "sess"),
        });
    }

    const recent3 = history.getRecent(3);
    try std.testing.expectEqual(@as(usize, 3), recent3.len);
    try std.testing.expectEqual(@as(i64, 2), recent3[0].timestamp);
    try std.testing.expectEqual(@as(i64, 4), recent3[2].timestamp);

    // Requesting more than available returns all.
    const recent100 = history.getRecent(100);
    try std.testing.expectEqual(@as(usize, 5), recent100.len);
}

test "search finds matching entries" {
    const allocator = std.testing.allocator;

    var history = StructuredHistory.init(allocator, "/dev/null", "sess");
    defer history.deinit();

    const commands = [_][]const u8{ "git status", "ls -la", "git commit -m fix", "echo hello" };
    for (commands) |cmd| {
        try history.entries.append(allocator, .{
            .command = try allocator.dupe(u8, cmd),
            .timestamp = 0,
            .duration_ms = 0,
            .exit_code = 0,
            .cwd = try allocator.dupe(u8, "/"),
            .session_id = try allocator.dupe(u8, "sess"),
        });
    }

    const git_results = try history.search(allocator, "git");
    defer allocator.free(git_results);
    try std.testing.expectEqual(@as(usize, 2), git_results.len);

    const echo_results = try history.search(allocator, "echo");
    defer allocator.free(echo_results);
    try std.testing.expectEqual(@as(usize, 1), echo_results.len);

    const none_results = try history.search(allocator, "python");
    defer allocator.free(none_results);
    try std.testing.expectEqual(@as(usize, 0), none_results.len);
}

test "searchBySession filters correctly" {
    const allocator = std.testing.allocator;

    var history = StructuredHistory.init(allocator, "/dev/null", "sess-a");
    defer history.deinit();

    const sessions = [_][]const u8{ "sess-a", "sess-b", "sess-a", "sess-b", "sess-a" };
    for (sessions, 0..) |sid, i| {
        try history.entries.append(allocator, .{
            .command = try std.fmt.allocPrint(allocator, "cmd{d}", .{i}),
            .timestamp = 0,
            .duration_ms = 0,
            .exit_code = 0,
            .cwd = try allocator.dupe(u8, "/"),
            .session_id = try allocator.dupe(u8, sid),
        });
    }

    const a_results = try history.searchBySession(allocator, "sess-a");
    defer allocator.free(a_results);
    try std.testing.expectEqual(@as(usize, 3), a_results.len);

    const b_results = try history.searchBySession(allocator, "sess-b");
    defer allocator.free(b_results);
    try std.testing.expectEqual(@as(usize, 2), b_results.len);
}

test "getStats computes correct analytics" {
    const allocator = std.testing.allocator;

    var history = StructuredHistory.init(allocator, "/dev/null", "sess");
    defer history.deinit();

    // Add some entries with varying commands, sessions, and durations.
    const test_data = [_]struct { cmd: []const u8, sid: []const u8, dur: i64 }{
        .{ .cmd = "ls", .sid = "s1", .dur = 10 },
        .{ .cmd = "ls", .sid = "s1", .dur = 20 },
        .{ .cmd = "pwd", .sid = "s2", .dur = 5 },
        .{ .cmd = "ls", .sid = "s2", .dur = 15 },
        .{ .cmd = "echo hi", .sid = "s3", .dur = 0 },
    };

    for (test_data) |td| {
        try history.entries.append(allocator, .{
            .command = try allocator.dupe(u8, td.cmd),
            .timestamp = 0,
            .duration_ms = td.dur,
            .exit_code = 0,
            .cwd = try allocator.dupe(u8, "/"),
            .session_id = try allocator.dupe(u8, td.sid),
        });
    }

    var stats = try history.getStats(allocator);
    defer stats.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), stats.total_entries);
    try std.testing.expectEqual(@as(usize, 3), stats.unique_commands);
    try std.testing.expectEqual(@as(usize, 3), stats.sessions);

    // avg of 10,20,5,15 = 50/4 = 12  (echo has dur=0, excluded)
    try std.testing.expectEqual(@as(i64, 12), stats.avg_duration_ms);

    // Most used should be "ls" with count 3.
    try std.testing.expect(stats.most_used_count > 0);
    try std.testing.expectEqualStrings("ls", stats.most_used[0].command);
    try std.testing.expectEqual(@as(usize, 3), stats.most_used[0].count);
}
