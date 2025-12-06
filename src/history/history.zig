const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");

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
        const file = std.fs.cwd().openFile(history_file_path, .{}) catch |err| {
            if (err == error.FileNotFound) return; // File doesn't exist yet
            return err;
        };
        defer file.close();

        // Read entire file
        const max_size = 1024 * 1024; // 1MB max
        const file_size = try file.getEndPos();
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
        const file = try std.fs.cwd().createFile(history_file_path, .{});
        defer file.close();

        for (history) |maybe_entry| {
            if (maybe_entry) |entry| {
                _ = try file.writeAll(entry);
                _ = try file.write("\n");
            }
        }
    }

    /// Append a single command to the history file.
    pub fn appendToFile(history_file_path: []const u8, command: []const u8) !void {
        const file = try std.fs.cwd().openFile(history_file_path, .{ .mode = .write_only });
        defer file.close();

        // Seek to end of file
        try file.seekFromEnd(0);

        // Append the command
        _ = try file.writeAll(command);
        _ = try file.write("\n");
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
};
