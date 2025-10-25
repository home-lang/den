const std = @import("std");

pub const Shell = struct {
    allocator: std.mem.Allocator,
    running: bool,

    pub fn init(allocator: std.mem.Allocator) !Shell {
        return Shell{
            .allocator = allocator,
            .running = false,
        };
    }

    pub fn deinit(self: *Shell) void {
        _ = self;
    }

    pub fn run(self: *Shell) !void {
        self.running = true;
        const stdout = std.io.getStdOut().writer();

        try stdout.print("Den shell initialized!\n", .{});
        try stdout.print("Type 'exit' to quit.\n\n", .{});

        while (self.running) {
            try stdout.print("den> ", .{});

            // Read input
            const stdin = std.io.getStdIn().reader();
            var buffer: [1024]u8 = undefined;

            if (try stdin.readUntilDelimiterOrEof(&buffer, '\n')) |line| {
                const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

                if (trimmed.len == 0) continue;

                if (std.mem.eql(u8, trimmed, "exit")) {
                    self.running = false;
                    try stdout.print("Goodbye!\n", .{});
                    break;
                }

                try stdout.print("Command: {s}\n", .{trimmed});
            } else {
                // EOF (Ctrl+D)
                self.running = false;
                try stdout.print("\nGoodbye!\n", .{});
            }
        }
    }
};

test "shell initialization" {
    const allocator = std.testing.allocator;
    var sh = try Shell.init(allocator);
    defer sh.deinit();

    try std.testing.expect(!sh.running);
}
