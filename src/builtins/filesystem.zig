const std = @import("std");
const types = @import("../types/mod.zig");
const IO = @import("../utils/io.zig").IO;
const BuiltinContext = @import("context.zig").BuiltinContext;
const BuiltinResult = @import("context.zig").BuiltinResult;

/// Builtin: basename - extract filename from path
pub fn basename(ctx: *BuiltinContext, cmd: *types.ParsedCommand) !BuiltinResult {
    _ = ctx;

    if (cmd.args.len == 0) {
        try IO.eprint("den: basename: missing operand\n", .{});
        return BuiltinResult{ .exit_code = 1 };
    }

    const path = cmd.args[0];
    const base = std.fs.path.basename(path);

    // Handle optional suffix removal
    if (cmd.args.len > 1) {
        const suffix = cmd.args[1];
        if (std.mem.endsWith(u8, base, suffix)) {
            const trimmed = base[0 .. base.len - suffix.len];
            try IO.print("{s}\n", .{trimmed});
        } else {
            try IO.print("{s}\n", .{base});
        }
    } else {
        try IO.print("{s}\n", .{base});
    }

    return BuiltinResult{ .exit_code = 0 };
}

/// Builtin: dirname - extract directory from path
pub fn dirname(ctx: *BuiltinContext, cmd: *types.ParsedCommand) !BuiltinResult {
    _ = ctx;

    if (cmd.args.len == 0) {
        try IO.eprint("den: dirname: missing operand\n", .{});
        return BuiltinResult{ .exit_code = 1 };
    }

    const path = cmd.args[0];
    const dir = std.fs.path.dirname(path) orelse ".";
    try IO.print("{s}\n", .{dir});

    return BuiltinResult{ .exit_code = 0 };
}

/// Builtin: realpath - resolve absolute path
pub fn realpath(ctx: *BuiltinContext, cmd: *types.ParsedCommand) !BuiltinResult {
    _ = ctx;

    if (cmd.args.len == 0) {
        try IO.eprint("den: realpath: missing operand\n", .{});
        return BuiltinResult{ .exit_code = 1 };
    }

    const path = cmd.args[0];
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real = std.Io.Dir.cwd().realpath(path, &buf) catch |err| {
        try IO.eprint("den: realpath: {s}: {}\n", .{ path, err });
        return BuiltinResult{ .exit_code = 1 };
    };

    try IO.print("{s}\n", .{real});
    return BuiltinResult{ .exit_code = 0 };
}

/// Builtin: pwd - print working directory
pub fn pwd(ctx: *BuiltinContext, cmd: *types.ParsedCommand) !BuiltinResult {
    _ = cmd;

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = std.Io.Dir.cwd().realpath(".", &buf) catch |err| {
        try IO.eprint("den: pwd: {}\n", .{err});
        return BuiltinResult{ .exit_code = 1 };
    };

    try IO.print("{s}\n", .{cwd});

    // Also update PWD environment variable
    try ctx.setEnv("PWD", cwd);

    return BuiltinResult{ .exit_code = 0 };
}

// Tests
test "basename extracts filename" {
    const path1 = "/usr/bin/bash";
    const base1 = std.fs.path.basename(path1);
    try std.testing.expectEqualStrings("bash", base1);

    const path2 = "script.sh";
    const base2 = std.fs.path.basename(path2);
    try std.testing.expectEqualStrings("script.sh", base2);
}

test "dirname extracts directory" {
    const path1 = "/usr/bin/bash";
    const dir1 = std.fs.path.dirname(path1) orelse ".";
    try std.testing.expectEqualStrings("/usr/bin", dir1);

    const path2 = "script.sh";
    const dir2 = std.fs.path.dirname(path2) orelse ".";
    try std.testing.expectEqualStrings(".", dir2);
}
