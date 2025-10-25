const std = @import("std");
const types = @import("types/mod.zig");

pub const Shell = struct {
    allocator: std.mem.Allocator,
    running: bool,
    config: types.DenConfig,
    environment: std.StringHashMap([]const u8),
    aliases: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) !Shell {
        const config = types.DenConfig{};

        return Shell{
            .allocator = allocator,
            .running = false,
            .config = config,
            .environment = std.StringHashMap([]const u8).init(allocator),
            .aliases = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Shell) void {
        self.environment.deinit();
        self.aliases.deinit();
    }

    pub fn run(self: *Shell) !void {
        _ = self;

        std.debug.print("Den shell initialized!\n", .{});
        std.debug.print("Basic REPL coming soon...\n", .{});
        std.debug.print("For now, see ROADMAP.md for implementation plan.\n", .{});

        // TODO: Implement full REPL with stdin/stdout handling for Zig 0.15
        // The std.io API changed significantly in Zig 0.15
        // Will need to use posix APIs or update to newer patterns
    }
};

test "shell initialization" {
    const allocator = std.testing.allocator;
    var sh = try Shell.init(allocator);
    defer sh.deinit();

    try std.testing.expect(!sh.running);
}
