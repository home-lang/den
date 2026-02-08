const std = @import("std");

/// Embedded standard library scripts
pub const stdlib_scripts = .{
    .{ "math", @embedFile("math.den") },
    .{ "iter", @embedFile("iter.den") },
    .{ "text", @embedFile("text.den") },
    .{ "fs", @embedFile("fs.den") },
    .{ "dt", @embedFile("dt.den") },
    .{ "assert", @embedFile("assert.den") },
    .{ "log", @embedFile("log.den") },
    .{ "bench", @embedFile("bench.den") },
};

/// Get a stdlib script by name
pub fn getScript(name: []const u8) ?[]const u8 {
    inline for (stdlib_scripts) |entry| {
        if (std.mem.eql(u8, name, entry[0])) {
            return entry[1];
        }
    }
    return null;
}

/// List all available stdlib module names
pub fn listModules() []const []const u8 {
    const names = comptime blk: {
        var result: [stdlib_scripts.len][]const u8 = undefined;
        for (stdlib_scripts, 0..) |entry, i| {
            result[i] = entry[0];
        }
        break :blk result;
    };
    return &names;
}
