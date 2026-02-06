const std = @import("std");
const builtin = @import("builtin");
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;

/// Developer helper builtins: wip, code, pstorm
/// Note: bookmark remains in executor/mod.zig as it requires shell named_dirs state

/// Get C environment pointer (platform-specific)
fn getCEnviron() [*:null]const ?[*:0]const u8 {
    if (builtin.os.tag == .macos) {
        const NSGetEnviron = @extern(*const fn () callconv(.c) *[*:null]?[*:0]u8, .{ .name = "_NSGetEnviron" });
        return @ptrCast(NSGetEnviron().*);
    } else {
        const c_environ = @extern(*[*:null]?[*:0]u8, .{ .name = "environ" });
        return @ptrCast(c_environ.*);
    }
}

/// wip - Quick git add and commit with WIP message
pub fn wip(_: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    // Get custom message if provided
    var message: []const u8 = "WIP";
    if (command.args.len > 0) {
        message = command.args[0];
    }

    // Run git add .
    var add_child = std.process.spawn(std.Options.debug_io, .{
        .argv = &[_][]const u8{ "git", "add", "." },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch {
        try IO.eprint("den: wip: failed to run git add\n", .{});
        return 1;
    };

    const add_result = add_child.wait(std.Options.debug_io) catch {
        try IO.eprint("den: wip: git add failed\n", .{});
        return 1;
    };

    if (add_result.exited != 0) {
        try IO.eprint("den: wip: git add returned error\n", .{});
        return 1;
    }

    // Run git commit -m "message"
    var commit_child = std.process.spawn(std.Options.debug_io, .{
        .argv = &[_][]const u8{ "git", "commit", "-m", message },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch {
        try IO.eprint("den: wip: failed to run git commit\n", .{});
        return 1;
    };

    const commit_result = commit_child.wait(std.Options.debug_io) catch {
        try IO.eprint("den: wip: git commit failed\n", .{});
        return 1;
    };

    return @intCast(commit_result.exited);
}

/// code - Open file or directory in VS Code (macOS)
pub fn code(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (builtin.os.tag != .macos) {
        try IO.eprint("den: code: only supported on macOS\n", .{});
        return 1;
    }

    // Get path - use current directory if not specified
    const path = if (command.args.len > 0) command.args[0] else ".";

    // Execute: open -a "Visual Studio Code" <path>
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const argv = [_]?[*:0]const u8{
        "open",
        "-a",
        "Visual Studio Code",
        path_z,
        null,
    };

    const pid = try std.posix.fork();
    if (pid == 0) {
        _ = std.posix.execvpeZ("open", @ptrCast(&argv), getCEnviron()) catch {
            std.posix.exit(127);
        };
        unreachable;
    } else {
        const result = std.posix.waitpid(pid, 0);
        return @intCast(std.posix.W.EXITSTATUS(result.status));
    }
}

/// pstorm - Open file or directory in PhpStorm (macOS)
pub fn pstorm(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (builtin.os.tag != .macos) {
        try IO.eprint("den: pstorm: only supported on macOS\n", .{});
        return 1;
    }

    // Get path - use current directory if not specified
    const path = if (command.args.len > 0) command.args[0] else ".";

    // Execute: open -a "PhpStorm" <path>
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const argv = [_]?[*:0]const u8{
        "open",
        "-a",
        "PhpStorm",
        path_z,
        null,
    };

    const pid = try std.posix.fork();
    if (pid == 0) {
        _ = std.posix.execvpeZ("open", @ptrCast(&argv), getCEnviron()) catch {
            std.posix.exit(127);
        };
        unreachable;
    } else {
        const result = std.posix.waitpid(pid, 0);
        return @intCast(std.posix.W.EXITSTATUS(result.status));
    }
}
