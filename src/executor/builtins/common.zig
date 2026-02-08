/// Shared utilities for builtin commands.
/// Eliminates duplication of common helpers across builtin files.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const IO = @import("../../utils/io.zig").IO;

/// C exec functions for fork/exec patterns.
pub const c_exec = struct {
    pub extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
};

/// Read all available data from stdin into a heap-allocated string.
/// Caller owns the returned slice and must free it with `allocator.free()`.
pub fn readAllStdin(allocator: std.mem.Allocator) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(posix.STDIN_FILENO, &buf) catch |err| {
            if (err == error.WouldBlock) break;
            return err;
        };
        if (n == 0) break;
        try result.appendSlice(allocator, buf[0..n]);
    }
    return try result.toOwnedSlice(allocator);
}

/// Get a C environment variable as a Zig slice.
pub fn getenv(key: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(value)));
}

/// Get the C environ pointer (platform-specific).
pub fn getCEnviron() [*:null]const ?[*:0]const u8 {
    if (builtin.os.tag == .macos) {
        const NSGetEnviron = @extern(*const fn () callconv(.c) *[*:null]?[*:0]u8, .{ .name = "_NSGetEnviron" });
        return @ptrCast(NSGetEnviron().*);
    } else {
        const c_environ = @extern(*[*:null]?[*:0]u8, .{ .name = "environ" });
        return @ptrCast(c_environ.*);
    }
}

/// Print a number, formatting whole numbers without decimal places.
pub fn printNumber(n: f64) !void {
    if (n == @floor(n) and @abs(n) < 1e15) {
        try IO.print("{d}\n", .{@as(i64, @intFromFloat(n))});
    } else {
        try IO.print("{d}\n", .{n});
    }
}
