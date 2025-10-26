const std = @import("std");
const shell = @import("shell.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Den Shell v0.1.0\n", .{});

    // Parse command line arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.skip();

    // Initialize shell
    var den_shell = try shell.Shell.init(allocator);
    defer den_shell.deinit();

    // Start REPL or execute command
    try den_shell.run();
}

test {
    std.testing.refAllDecls(@This());
}
