const std = @import("std");
const cli = @import("cli.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    var cli_args = try cli.parseArgs(allocator);
    defer cli_args.deinit();

    // Execute the command
    try cli.execute(cli_args);
}

test {
    std.testing.refAllDecls(@This());
}
