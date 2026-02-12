//! Directory Stack Builtins
//!
//! This module implements the directory stack builtins:
//! - pushd: Push directory onto stack and cd
//! - popd: Pop directory from stack and cd
//! - dirs: Show directory stack

const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");

// Forward declaration for Shell type
const Shell = @import("../shell.zig").Shell;

fn getenv(key: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(value)));
}

fn getEnvOwned(allocator: std.mem.Allocator, key: [*:0]const u8) ?[]u8 {
    const value = getenv(key) orelse return null;
    return allocator.dupe(u8, value) catch null;
}

/// Update PWD and OLDPWD environment variables after a directory change.
/// old_cwd is the directory before the change.
fn updatePwdEnv(shell: *Shell, old_cwd: []const u8) void {
    // Set OLDPWD to the previous directory
    const gop_old = shell.environment.getOrPut("OLDPWD") catch return;
    if (gop_old.found_existing) {
        shell.allocator.free(gop_old.value_ptr.*);
        gop_old.value_ptr.* = shell.allocator.dupe(u8, old_cwd) catch return;
    } else {
        gop_old.key_ptr.* = shell.allocator.dupe(u8, "OLDPWD") catch return;
        gop_old.value_ptr.* = shell.allocator.dupe(u8, old_cwd) catch return;
    }

    // Set PWD to the new current directory
    var new_cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (std.c.getcwd(&new_cwd_buf, new_cwd_buf.len)) |result| {
        const new_cwd = std.mem.sliceTo(@as([*:0]u8, @ptrCast(result)), 0);
        const gop_pwd = shell.environment.getOrPut("PWD") catch return;
        if (gop_pwd.found_existing) {
            shell.allocator.free(gop_pwd.value_ptr.*);
            gop_pwd.value_ptr.* = shell.allocator.dupe(u8, new_cwd) catch return;
        } else {
            gop_pwd.key_ptr.* = shell.allocator.dupe(u8, "PWD") catch return;
            gop_pwd.value_ptr.* = shell.allocator.dupe(u8, new_cwd) catch return;
        }
    }
}

/// Builtin: pushd - push directory onto stack and cd
/// Supports: pushd (swap), pushd dir, pushd +N/-N (rotate)
pub fn builtinPushd(shell: *Shell, cmd: *types.ParsedCommand) !void {
    // Restricted mode: pushd is not allowed (changes directory)
    if (shell.option_restricted) {
        try IO.eprint("den: pushd: restricted\n", .{});
        shell.last_exit_code = 1;
        return;
    }

    if (cmd.args.len == 0) {
        // pushd with no args: swap top two directories
        if (shell.dir_stack_count < 1) {
            try IO.eprint("den: pushd: directory stack empty\n", .{});
            shell.last_exit_code = 1;
            return;
        }

        // Get current directory
        var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cwd_result = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.Unexpected;
        const cwd = std.mem.sliceTo(@as([*:0]u8, @ptrCast(cwd_result)), 0);
        const cwd_copy = try shell.allocator.dupe(u8, cwd);

        // Pop top of stack and cd to it
        const top_dir = shell.dir_stack[shell.dir_stack_count - 1].?;
        {
            var chdir_buf: [std.fs.max_path_bytes]u8 = undefined;
            @memcpy(chdir_buf[0..top_dir.len], top_dir);
            chdir_buf[top_dir.len] = 0;
            if (std.c.chdir(chdir_buf[0..top_dir.len :0]) != 0) {
                try IO.eprint("den: pushd: {s}: cannot change directory\n", .{top_dir});
                shell.allocator.free(cwd_copy);
                shell.last_exit_code = 1;
                return;
            }
        }

        // Update PWD/OLDPWD environment variables
        updatePwdEnv(shell, cwd);

        // Push old cwd onto stack
        shell.dir_stack[shell.dir_stack_count - 1] = cwd_copy;
        try printDirStack(shell);
        shell.last_exit_code = 0;
    } else {
        const arg = cmd.args[0];

        // Check for +N or -N rotation
        if (arg.len > 0 and (arg[0] == '+' or arg[0] == '-')) {
            const n = std.fmt.parseInt(usize, arg[1..], 10) catch {
                try IO.eprint("den: pushd: {s}: invalid number\n", .{arg});
                shell.last_exit_code = 1;
                return;
            };

            // Total stack size is dir_stack_count + 1 (including cwd)
            const total_size = shell.dir_stack_count + 1;
            if (n >= total_size) {
                try IO.eprint("den: pushd: {s}: directory stack index out of range\n", .{arg});
                shell.last_exit_code = 1;
                return;
            }

            // Calculate index: +N counts from left, -N from right
            const index = if (arg[0] == '+') n else total_size - n;
            if (index >= total_size) {
                try IO.eprint("den: pushd: {s}: directory stack index out of range\n", .{arg});
                shell.last_exit_code = 1;
                return;
            }
            if (index == 0) {
                // Already at current directory, nothing to do
                try printDirStack(shell);
                shell.last_exit_code = 0;
                return;
            }

            // Rotate stack: bring index to top
            try rotateDirStack(shell, index);
            try printDirStack(shell);
            shell.last_exit_code = 0;
        } else {
            const target_dir = arg;

            // Get current directory before changing
            var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const cwd_result = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.Unexpected;
            const cwd = std.mem.sliceTo(@as([*:0]u8, @ptrCast(cwd_result)), 0);

            // Try to change to target directory
            {
                var chdir_buf: [std.fs.max_path_bytes]u8 = undefined;
                @memcpy(chdir_buf[0..target_dir.len], target_dir);
                chdir_buf[target_dir.len] = 0;
                if (std.c.chdir(chdir_buf[0..target_dir.len :0]) != 0) {
                    try IO.eprint("den: pushd: {s}: cannot change directory\n", .{target_dir});
                    shell.last_exit_code = 1;
                    return;
                }
            }

            // Update PWD/OLDPWD environment variables
            updatePwdEnv(shell, cwd);

            // Push old cwd onto stack
            if (shell.dir_stack_count >= shell.dir_stack.len) {
                try IO.eprint("den: pushd: directory stack full\n", .{});
                shell.last_exit_code = 1;
                return;
            }

            shell.dir_stack[shell.dir_stack_count] = try shell.allocator.dupe(u8, cwd);
            shell.dir_stack_count += 1;
            try printDirStack(shell);
            shell.last_exit_code = 0;
        }
    }
}

/// Helper to rotate directory stack - brings index to top by rotating
pub fn rotateDirStack(shell: *Shell, index: usize) !void {
    if (index == 0 or index > shell.dir_stack_count) return;

    // Get current directory
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_result = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.Unexpected;
    const cwd = std.mem.sliceTo(@as([*:0]u8, @ptrCast(cwd_result)), 0);
    const cwd_copy = try shell.allocator.dupe(u8, cwd);

    // Build full stack: [cwd, stack[count-1], stack[count-2], ..., stack[0]]
    const stack_idx = shell.dir_stack_count - index;
    const target_dir = shell.dir_stack[stack_idx].?;

    // Change to target directory
    {
        var chdir_buf: [std.fs.max_path_bytes]u8 = undefined;
        @memcpy(chdir_buf[0..target_dir.len], target_dir);
        chdir_buf[target_dir.len] = 0;
        if (std.c.chdir(chdir_buf[0..target_dir.len :0]) != 0) {
            try IO.eprint("den: pushd: {s}: cannot change directory\n", .{target_dir});
            shell.allocator.free(cwd_copy);
            return error.Unexpected;
        }
    }

    // Update PWD/OLDPWD environment variables
    updatePwdEnv(shell, cwd);

    // Rotate the stack
    shell.allocator.free(shell.dir_stack[stack_idx].?);
    shell.dir_stack[stack_idx] = null;

    // Shift elements down to fill gap
    var i = stack_idx;
    while (i + 1 < shell.dir_stack_count) : (i += 1) {
        shell.dir_stack[i] = shell.dir_stack[i + 1];
    }
    shell.dir_stack[shell.dir_stack_count - 1] = null;

    // Add cwd at the correct position
    i = shell.dir_stack_count - 1;
    while (i > stack_idx) : (i -= 1) {
        shell.dir_stack[i] = shell.dir_stack[i - 1];
    }
    shell.dir_stack[stack_idx] = cwd_copy;
}

/// Helper to print directory stack
pub fn printDirStack(shell: *Shell) !void {
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_result = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.Unexpected;
    const cwd = std.mem.sliceTo(@as([*:0]u8, @ptrCast(cwd_result)), 0);
    try IO.print("{s}", .{cwd});

    if (shell.dir_stack_count > 0) {
        var i: usize = shell.dir_stack_count;
        while (i > 0) {
            i -= 1;
            if (shell.dir_stack[i]) |dir| {
                try IO.print(" {s}", .{dir});
            }
        }
    }
    try IO.print("\n", .{});
}

/// Builtin: popd - pop directory from stack and cd
/// Supports: popd, popd +N/-N (remove specific entry)
pub fn builtinPopd(shell: *Shell, cmd: *types.ParsedCommand) !void {
    // Restricted mode: popd is not allowed (changes directory)
    if (shell.option_restricted) {
        try IO.eprint("den: popd: restricted\n", .{});
        shell.last_exit_code = 1;
        return;
    }

    if (shell.dir_stack_count == 0) {
        try IO.eprint("den: popd: directory stack empty\n", .{});
        shell.last_exit_code = 1;
        return;
    }

    // Check for +N or -N to remove specific entry
    if (cmd.args.len > 0) {
        const arg = cmd.args[0];
        if (arg.len > 0 and (arg[0] == '+' or arg[0] == '-')) {
            const n = std.fmt.parseInt(usize, arg[1..], 10) catch {
                try IO.eprint("den: popd: {s}: invalid number\n", .{arg});
                shell.last_exit_code = 1;
                return;
            };

            const total_size = shell.dir_stack_count + 1;
            if (n >= total_size) {
                try IO.eprint("den: popd: {s}: directory stack index out of range\n", .{arg});
                shell.last_exit_code = 1;
                return;
            }

            const index = if (arg[0] == '+') n else total_size - n;

            if (index >= total_size) {
                try IO.eprint("den: popd: {s}: directory stack index out of range\n", .{arg});
                shell.last_exit_code = 1;
                return;
            }

            if (index == 0) {
                // Remove current directory - same as normal popd
                shell.dir_stack_count -= 1;
                const dir = shell.dir_stack[shell.dir_stack_count].?;
                defer shell.allocator.free(dir);
                shell.dir_stack[shell.dir_stack_count] = null;

                // Get current directory before changing
                var popd_cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const popd_cwd_result = std.c.getcwd(&popd_cwd_buf, popd_cwd_buf.len);
                const popd_old_cwd = if (popd_cwd_result) |r| std.mem.sliceTo(@as([*:0]u8, @ptrCast(r)), 0) else "";

                {
                    var chdir_buf: [std.fs.max_path_bytes]u8 = undefined;
                    @memcpy(chdir_buf[0..dir.len], dir);
                    chdir_buf[dir.len] = 0;
                    if (std.c.chdir(chdir_buf[0..dir.len :0]) != 0) {
                        try IO.eprint("den: popd: {s}: cannot change directory\n", .{dir});
                        shell.last_exit_code = 1;
                        return;
                    }
                }

                // Update PWD/OLDPWD environment variables
                updatePwdEnv(shell, popd_old_cwd);
            } else {
                // Remove entry at index (without changing directory)
                const stack_idx = shell.dir_stack_count - index;
                shell.allocator.free(shell.dir_stack[stack_idx].?);

                // Shift elements down to fill gap
                var i = stack_idx;
                while (i + 1 < shell.dir_stack_count) : (i += 1) {
                    shell.dir_stack[i] = shell.dir_stack[i + 1];
                }
                shell.dir_stack[shell.dir_stack_count - 1] = null;
                shell.dir_stack_count -= 1;
            }

            try printDirStack(shell);
            shell.last_exit_code = 0;
            return;
        }
    }

    // Default: pop top directory from stack and cd to it
    shell.dir_stack_count -= 1;
    const dir = shell.dir_stack[shell.dir_stack_count].?;
    defer shell.allocator.free(dir);
    shell.dir_stack[shell.dir_stack_count] = null;

    // Get current directory before changing
    var popd_def_cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const popd_def_cwd_result = std.c.getcwd(&popd_def_cwd_buf, popd_def_cwd_buf.len);
    const popd_def_old_cwd = if (popd_def_cwd_result) |r| std.mem.sliceTo(@as([*:0]u8, @ptrCast(r)), 0) else "";

    {
        var chdir_buf: [std.fs.max_path_bytes]u8 = undefined;
        @memcpy(chdir_buf[0..dir.len], dir);
        chdir_buf[dir.len] = 0;
        if (std.c.chdir(chdir_buf[0..dir.len :0]) != 0) {
            try IO.eprint("den: popd: {s}: cannot change directory\n", .{dir});
            shell.last_exit_code = 1;
            return;
        }
    }

    // Update PWD/OLDPWD environment variables
    updatePwdEnv(shell, popd_def_old_cwd);

    try printDirStack(shell);
    shell.last_exit_code = 0;
}

/// Builtin: dirs - show directory stack
/// Supports: -c (clear), -l (long/full paths), -p (one per line), -v (verbose with indices)
pub fn builtinDirs(shell: *Shell, cmd: *types.ParsedCommand) !void {
    var clear_stack = false;
    var full_paths = false;
    var one_per_line = false;
    var verbose = false;

    // Parse flags
    for (cmd.args) |arg| {
        if (arg.len > 0 and arg[0] == '-') {
            for (arg[1..]) |c| {
                switch (c) {
                    'c' => clear_stack = true,
                    'l' => full_paths = true,
                    'p' => one_per_line = true,
                    'v' => {
                        verbose = true;
                        one_per_line = true;
                    },
                    else => {},
                }
            }
        }
    }

    // Handle -c: clear directory stack
    if (clear_stack) {
        var i: usize = 0;
        while (i < shell.dir_stack_count) : (i += 1) {
            if (shell.dir_stack[i]) |dir| {
                shell.allocator.free(dir);
                shell.dir_stack[i] = null;
            }
        }
        shell.dir_stack_count = 0;
        shell.last_exit_code = 0;
        return;
    }

    // Get current directory
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_result = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.Unexpected;
    const cwd = std.mem.sliceTo(@as([*:0]u8, @ptrCast(cwd_result)), 0);

    // Get home directory for tilde substitution
    const home = getEnvOwned(shell.allocator, "HOME");
    defer if (home) |h| shell.allocator.free(h);

    // Output directory stack
    var index: usize = 0;

    if (verbose) {
        IO.print(" {d}  ", .{index}) catch {};
    }
    printPath(cwd, full_paths, home);

    index += 1;

    // Show stack from top to bottom
    if (shell.dir_stack_count > 0) {
        var i: usize = shell.dir_stack_count;
        while (i > 0) {
            i -= 1;
            if (shell.dir_stack[i]) |dir| {
                if (one_per_line) {
                    IO.print("\n", .{}) catch {};
                    if (verbose) {
                        IO.print(" {d}  ", .{index}) catch {};
                    }
                } else {
                    IO.print(" ", .{}) catch {};
                }
                printPath(dir, full_paths, home);
                index += 1;
            }
        }
    }

    IO.print("\n", .{}) catch {};
    shell.last_exit_code = 0;
}

/// Helper to format path (with optional tilde substitution)
fn printPath(path: []const u8, use_full: bool, home_dir: ?[]const u8) void {
    if (!use_full) {
        if (home_dir) |h| {
            if (std.mem.startsWith(u8, path, h)) {
                IO.print("~{s}", .{path[h.len..]}) catch {};
                return;
            }
        }
    }
    IO.print("{s}", .{path}) catch {};
}
