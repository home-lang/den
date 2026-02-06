const std = @import("std");
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;
const BuiltinContext = @import("context.zig").BuiltinContext;

fn getenv(key: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(value)));
}

fn getEnvOwned(allocator: std.mem.Allocator, key: [*:0]const u8) ?[]u8 {
    const value = getenv(key) orelse return null;
    return allocator.dupe(u8, value) catch null;
}

/// Directory stack builtins: pushd, popd, dirs

pub fn pushd(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    const shell_ref = ctx.getShell() catch {
        try IO.eprint("den: pushd: shell context not available\n", .{});
        return 1;
    };

    // Get current directory
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = std.Io.Dir.cwd().realPathFile(std.Options.debug_io, ".", &cwd_buf) catch |err| {
        try IO.eprint("den: pushd: cannot get current directory: {}\n", .{err});
        return 1;
    };
    const cwd = cwd_buf[0..cwd_len];

    if (command.args.len == 0) {
        // pushd with no args: swap top two dirs
        if (shell_ref.dir_stack_count == 0) {
            try IO.eprint("den: pushd: directory stack empty\n", .{});
            return 1;
        }

        const top_dir = shell_ref.dir_stack[shell_ref.dir_stack_count - 1] orelse {
            try IO.eprint("den: pushd: directory stack corrupted\n", .{});
            return 1;
        };

        {
            var chdir_buf: [std.fs.max_path_bytes]u8 = undefined;
            @memcpy(chdir_buf[0..top_dir.len], top_dir);
            chdir_buf[top_dir.len] = 0;
            if (std.c.chdir(chdir_buf[0..top_dir.len :0]) != 0) {
                try IO.eprint("den: pushd: {s}: cannot change directory\n", .{top_dir});
                return 1;
            }
        }

        ctx.allocator.free(shell_ref.dir_stack[shell_ref.dir_stack_count - 1].?);
        shell_ref.dir_stack[shell_ref.dir_stack_count - 1] = try ctx.allocator.dupe(u8, cwd);

        return 0;
    }

    const arg = command.args[0];

    // Check for +N or -N rotation
    if (arg.len > 0 and (arg[0] == '+' or arg[0] == '-')) {
        const n = std.fmt.parseInt(usize, arg[1..], 10) catch {
            try IO.eprint("den: pushd: {s}: invalid number\n", .{arg});
            return 1;
        };

        const total_size = shell_ref.dir_stack_count + 1;
        if (n >= total_size) {
            try IO.eprint("den: pushd: {s}: directory stack index out of range\n", .{arg});
            return 1;
        }

        const index = if (arg[0] == '+') n else total_size - n;
        if (index == 0) {
            return 0;
        }

        const stack_idx = shell_ref.dir_stack_count - index;
        const target_dir = shell_ref.dir_stack[stack_idx] orelse {
            try IO.eprint("den: pushd: directory stack corrupted\n", .{});
            return 1;
        };

        {
            var chdir_buf: [std.fs.max_path_bytes]u8 = undefined;
            @memcpy(chdir_buf[0..target_dir.len], target_dir);
            chdir_buf[target_dir.len] = 0;
            if (std.c.chdir(chdir_buf[0..target_dir.len :0]) != 0) {
                try IO.eprint("den: pushd: {s}: cannot change directory\n", .{target_dir});
                return 1;
            }
        }

        ctx.allocator.free(shell_ref.dir_stack[stack_idx].?);
        shell_ref.dir_stack[stack_idx] = try ctx.allocator.dupe(u8, cwd);

        return 0;
    }

    // pushd <dir>: push current dir and cd to new dir
    const new_dir = arg;

    {
        var chdir_buf: [std.fs.max_path_bytes]u8 = undefined;
        @memcpy(chdir_buf[0..new_dir.len], new_dir);
        chdir_buf[new_dir.len] = 0;
        if (std.c.chdir(chdir_buf[0..new_dir.len :0]) != 0) {
            try IO.eprint("den: pushd: {s}: cannot change directory\n", .{new_dir});
            return 1;
        }
    }

    if (shell_ref.dir_stack_count >= shell_ref.dir_stack.len) {
        try IO.eprint("den: pushd: directory stack full\n", .{});
        return 1;
    }

    shell_ref.dir_stack[shell_ref.dir_stack_count] = try ctx.allocator.dupe(u8, cwd);
    shell_ref.dir_stack_count += 1;

    return 0;
}

pub fn popd(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    const shell_ref = ctx.getShell() catch {
        try IO.eprint("den: popd: shell context not available\n", .{});
        return 1;
    };

    if (shell_ref.dir_stack_count == 0) {
        try IO.eprint("den: popd: directory stack empty\n", .{});
        return 1;
    }

    // Check for +N/-N argument
    if (command.args.len > 0) {
        const arg = command.args[0];
        if (arg.len > 0 and (arg[0] == '+' or arg[0] == '-')) {
            const n = std.fmt.parseInt(usize, arg[1..], 10) catch {
                try IO.eprint("den: popd: {s}: invalid number\n", .{arg});
                return 1;
            };

            const total_size = shell_ref.dir_stack_count + 1;
            if (n >= total_size) {
                try IO.eprint("den: popd: {s}: directory stack index out of range\n", .{arg});
                return 1;
            }

            const index = if (arg[0] == '+') n else total_size - n;
            if (index == 0) {
                try IO.eprint("den: popd: cannot remove current directory\n", .{});
                return 1;
            }

            const stack_idx = shell_ref.dir_stack_count - index;
            ctx.allocator.free(shell_ref.dir_stack[stack_idx].?);

            // Shift entries down
            var i = stack_idx;
            while (i < shell_ref.dir_stack_count - 1) : (i += 1) {
                shell_ref.dir_stack[i] = shell_ref.dir_stack[i + 1];
            }
            shell_ref.dir_stack[shell_ref.dir_stack_count - 1] = null;
            shell_ref.dir_stack_count -= 1;

            return 0;
        }
    }

    // Default: pop top and cd to it
    shell_ref.dir_stack_count -= 1;
    const dir = shell_ref.dir_stack[shell_ref.dir_stack_count] orelse {
        try IO.eprint("den: popd: directory stack corrupted\n", .{});
        return 1;
    };
    defer ctx.allocator.free(dir);

    {
        var chdir_buf: [std.fs.max_path_bytes]u8 = undefined;
        @memcpy(chdir_buf[0..dir.len], dir);
        chdir_buf[dir.len] = 0;
        if (std.c.chdir(chdir_buf[0..dir.len :0]) != 0) {
            try IO.eprint("den: popd: {s}: cannot change directory\n", .{dir});
            shell_ref.dir_stack_count += 1;
            return 1;
        }
    }

    shell_ref.dir_stack[shell_ref.dir_stack_count] = null;

    return 0;
}

pub fn dirs(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    const shell_ref = ctx.getShell() catch {
        try IO.eprint("den: dirs: shell context not available\n", .{});
        return 1;
    };

    var clear_stack = false;
    var full_paths = false;
    var one_per_line = false;
    var verbose = false;

    for (command.args) |arg| {
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

    if (clear_stack) {
        var i: usize = 0;
        while (i < shell_ref.dir_stack_count) : (i += 1) {
            if (shell_ref.dir_stack[i]) |dir| {
                ctx.allocator.free(dir);
                shell_ref.dir_stack[i] = null;
            }
        }
        shell_ref.dir_stack_count = 0;
        return 0;
    }

    // Get current directory
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = std.Io.Dir.cwd().realPathFile(std.Options.debug_io, ".", &cwd_buf) catch |err| {
        try IO.eprint("den: dirs: cannot get current directory: {}\n", .{err});
        return 1;
    };
    const cwd = cwd_buf[0..cwd_len];

    // Get home for tilde substitution
    const home = getEnvOwned(ctx.allocator, "HOME");
    defer if (home) |h| ctx.allocator.free(h);

    const printPath = struct {
        fn print(path: []const u8, use_full: bool, home_dir: ?[]const u8) void {
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
    }.print;

    var index: usize = 0;

    if (verbose) {
        IO.print(" {d}  ", .{index}) catch {};
    }
    printPath(cwd, full_paths, home);

    index += 1;

    if (shell_ref.dir_stack_count > 0) {
        var i: usize = shell_ref.dir_stack_count;
        while (i > 0) {
            i -= 1;
            if (shell_ref.dir_stack[i]) |dir| {
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

    return 0;
}
