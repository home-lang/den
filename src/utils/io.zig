const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

/// I/O utilities for Zig 0.15
pub const IO = struct {
    /// Write string to stdout (cross-platform)
    pub fn print(comptime fmt: []const u8, args: anytype) !void {
        // Use File API directly to write to stdout
        const stdout_file = std.fs.File{ .handle = if (builtin.os.tag == .windows)
            std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch return
        else
            posix.STDOUT_FILENO
        };

        // Format the string
        var buf: [4096]u8 = undefined;
        const formatted = try std.fmt.bufPrint(&buf, fmt, args);
        try stdout_file.writeAll(formatted);
    }

    /// Write string to stderr (cross-platform)
    pub fn eprint(comptime fmt: []const u8, args: anytype) !void {
        // Use File API directly to write to stderr
        const stderr_file = std.fs.File{ .handle = if (builtin.os.tag == .windows)
            std.os.windows.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) catch return
        else
            posix.STDERR_FILENO
        };

        // Format the string
        var buf: [4096]u8 = undefined;
        const formatted = try std.fmt.bufPrint(&buf, fmt, args);
        try stderr_file.writeAll(formatted);
    }

    /// Read a line from stdin (blocking)
    /// Returns null on EOF
    /// Caller owns returned memory
    pub fn readLine(allocator: std.mem.Allocator) !?[]u8 {
        var buffer: [4096]u8 = undefined;
        var pos: usize = 0;

        if (builtin.os.tag == .windows) {
            // Use Windows stdin handle with read loop (similar to POSIX path)
            const handle = std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) orelse return error.NoStdIn;
            const stdin = std.fs.File{ .handle = handle };

            while (pos < buffer.len) {
                var char_buf: [1]u8 = undefined;

                const bytes_read = stdin.read(&char_buf) catch {
                    if (pos == 0) return null;
                    return try allocator.dupe(u8, buffer[0..pos]);
                };

                if (bytes_read == 0) {
                    // EOF
                    if (pos == 0) return null;
                    return try allocator.dupe(u8, buffer[0..pos]);
                }

                const char = char_buf[0];

                if (char == '\n') {
                    return try allocator.dupe(u8, buffer[0..pos]);
                }

                buffer[pos] = char;
                pos += 1;
            }

            return try allocator.dupe(u8, buffer[0..pos]);
        }

        // Unix-like systems: use posix.read
        while (pos < buffer.len) {
            var char_buf: [1]u8 = undefined;

            const bytes_read = posix.read(posix.STDIN_FILENO, &char_buf) catch |err| {
                if (err == error.EOF or err == error.Unexpected) {
                    if (pos == 0) return null;
                    return try allocator.dupe(u8, buffer[0..pos]);
                }
                return err;
            };

            if (bytes_read == 0) {
                // EOF
                if (pos == 0) return null;
                return try allocator.dupe(u8, buffer[0..pos]);
            }

            const char = char_buf[0];

            if (char == '\n') {
                return try allocator.dupe(u8, buffer[0..pos]);
            }

            buffer[pos] = char;
            pos += 1;
        }

        // Line too long, return what we have
        return try allocator.dupe(u8, buffer[0..pos]);
    }

    /// Read exactly N bytes from stdin
    pub fn readBytes(buffer: []u8) !usize {
        if (builtin.os.tag == .windows) {
            var stdin = std.io.getStdIn();
            const reader = stdin.reader();
            return try reader.read(buffer);
        }
        return try posix.read(posix.STDIN_FILENO, buffer);
    }

    /// Write bytes to stdout
    pub fn writeBytes(bytes: []const u8) !void {
        if (builtin.os.tag == .windows) {
            var stdout = std.io.getStdOut();
            const writer = stdout.writer();
            try writer.writeAll(bytes);
        } else {
            _ = try posix.write(posix.STDOUT_FILENO, bytes);
        }
    }

    /// Flush stdout (no-op on Unix, as writes are unbuffered)
    pub fn flush() void {
        // POSIX write() is unbuffered, so no flush needed
    }
};

test "IO.print" {
    try IO.print("test: {s}\n", .{"hello"});
}
