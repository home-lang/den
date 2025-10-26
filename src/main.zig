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

    // Skip program name (argv[0])
    const program_name = args.next() orelse "den";

    // Collect remaining arguments into a fixed buffer
    var argv_buffer: [64][]const u8 = undefined;
    var argv_count: usize = 0;

    while (args.next()) |arg| {
        if (argv_count >= argv_buffer.len) break;
        argv_buffer[argv_count] = arg;
        argv_count += 1;
    }

    const argv = argv_buffer[0..argv_count];

    // Initialize shell
    var den_shell = try shell.Shell.init(allocator);
    defer den_shell.deinit();

    // If script file provided, execute it; otherwise start REPL
    if (argv.len > 0) {
        // First arg is script file, rest are positional parameters
        const script_file = argv[0];
        const script_args = if (argv.len > 1) argv[1..] else &[_][]const u8{};
        try den_shell.runScript(script_file, program_name, script_args);
    } else {
        // Start interactive REPL
        try den_shell.run();
    }
}

test {
    std.testing.refAllDecls(@This());
}
