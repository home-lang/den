const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Parse command line arguments
    var cli_args = try cli.parseArgs(allocator, init.minimal.args);
    defer cli_args.deinit();

    // Execute the command
    try cli.execute(cli_args);
}

test {
    std.testing.refAllDecls(@This());
}
