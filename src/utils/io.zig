const std = @import("std");
const posix = std.posix;

/// I/O utilities for Zig 0.15
pub const IO = struct {
    /// Standard file descriptors
    pub const stdin_fd = posix.STDIN_FILENO;
    pub const stdout_fd = posix.STDOUT_FILENO;
    pub const stderr_fd = posix.STDERR_FILENO;

    /// Write string to stdout
    pub fn print(comptime fmt: []const u8, args: anytype) !void {
        var buf: [4096]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, fmt, args);
        _ = try posix.write(stdout_fd, msg);
    }

    /// Write string to stderr
    pub fn eprint(comptime fmt: []const u8, args: anytype) !void {
        var buf: [4096]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, fmt, args);
        _ = try posix.write(stderr_fd, msg);
    }

    /// Read a line from stdin (blocking)
    /// Returns null on EOF
    /// Caller owns returned memory
    pub fn readLine(allocator: std.mem.Allocator) !?[]u8 {
        var buffer: [4096]u8 = undefined;
        var pos: usize = 0;

        while (pos < buffer.len) {
            var char_buf: [1]u8 = undefined;

            const bytes_read = posix.read(stdin_fd, &char_buf) catch |err| {
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
        return try posix.read(stdin_fd, buffer);
    }

    /// Write bytes to stdout
    pub fn writeBytes(bytes: []const u8) !void {
        _ = try posix.write(stdout_fd, bytes);
    }

    /// Flush stdout (no-op on Unix, as writes are unbuffered)
    pub fn flush() void {
        // POSIX write() is unbuffered, so no flush needed
    }
};

test "IO.print" {
    try IO.print("test: {s}\n", .{"hello"});
}
