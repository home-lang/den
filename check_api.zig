const std = @import("std");
const builtin = @import("builtin");

pub fn main() void {
    std.debug.print("Zig version: {}\n", .{builtin.zig_version});
    std.debug.print("Try using std.posix or std.fs for I/O in Zig 0.15\n", .{});
}
