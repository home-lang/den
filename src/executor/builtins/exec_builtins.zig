const std = @import("std");
const builtin = @import("builtin");
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;
const BuiltinContext = @import("context.zig").BuiltinContext;
const utils = @import("../../utils.zig");
const c_exec = struct {
    extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
};

fn getenv(key: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(value)));
}

/// Execution builtins: eval, exec, command, builtin, coproc

/// eval - evaluate string as shell command
pub fn eval(ctx: *BuiltinContext, cmd: *types.ParsedCommand) !i32 {
    if (cmd.args.len == 0) {
        return 0;
    }

    // Concatenate all args into a single command string
    var eval_str = std.ArrayList(u8){};
    defer eval_str.deinit(ctx.allocator);

    for (cmd.args, 0..) |arg, i| {
        try eval_str.appendSlice(ctx.allocator, arg);
        if (i < cmd.args.len - 1) {
            try eval_str.append(ctx.allocator, ' ');
        }
    }

    // Execute the concatenated string directly as a command
    ctx.executeShellCommand(eval_str.items);

    return ctx.getShellExitCode();
}

/// exec - replace shell with command
pub fn exec(ctx: *BuiltinContext, cmd: *types.ParsedCommand) !i32 {
    if (cmd.args.len == 0) {
        // exec with no args - do nothing
        return 0;
    }

    const cmd_name = cmd.args[0];

    // Find the executable in PATH
    const path_var = getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    var path_iter = std.mem.splitScalar(u8, path_var, ':');

    var exe_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var exe_path: ?[]const u8 = null;

    // Check if cmd contains a slash (is a path)
    if (std.mem.indexOf(u8, cmd_name, "/") != null) {
        exe_path = cmd_name;
    } else {
        // Search in PATH
        while (path_iter.next()) |dir| {
            const full_path = std.fmt.bufPrint(&exe_path_buf, "{s}/{s}", .{ dir, cmd_name }) catch continue;
            std.Io.Dir.accessAbsolute(std.Options.debug_io,full_path, .{}) catch continue;
            exe_path = full_path;
            break;
        }
    }

    if (exe_path == null) {
        try IO.eprint("den: exec: {s}: command not found\n", .{cmd_name});
        return 127;
    }

    // Build argv for execve
    const argv_len = cmd.args.len + 1;
    var argv = try ctx.allocator.alloc(?[*:0]const u8, argv_len);
    defer ctx.allocator.free(argv);

    // Allocate cmd name and args as null-terminated strings
    var arg_zs = try ctx.allocator.alloc([:0]u8, cmd.args.len);
    defer {
        for (arg_zs) |arg_z| {
            ctx.allocator.free(arg_z);
        }
        ctx.allocator.free(arg_zs);
    }

    for (cmd.args, 0..) |arg, i| {
        arg_zs[i] = try ctx.allocator.dupeZ(u8, arg);
        argv[i] = arg_zs[i].ptr;
    }
    argv[cmd.args.len] = null;

    // Build envp from current environment
    const env_count = ctx.environment.count();

    // Allocate envp array (+1 for null terminator)
    const envp_len = env_count + 1;
    var envp = try ctx.allocator.alloc(?[*:0]const u8, envp_len);
    defer ctx.allocator.free(envp);

    // Allocate storage for the environment strings
    var env_strings = try ctx.allocator.alloc([:0]u8, env_count);
    defer {
        for (env_strings) |env_str| {
            ctx.allocator.free(env_str);
        }
        ctx.allocator.free(env_strings);
    }

    // Build the environment strings
    var env_iter = ctx.environment.iterator();
    var i: usize = 0;
    while (env_iter.next()) |entry| {
        const env_formatted = try std.fmt.allocPrint(ctx.allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
        defer ctx.allocator.free(env_formatted);
        env_strings[i] = try ctx.allocator.dupeZ(u8, env_formatted);
        envp[i] = env_strings[i].ptr;
        i += 1;
    }
    envp[env_count] = null;

    const exe_path_z = try ctx.allocator.dupeZ(u8, exe_path.?);
    defer ctx.allocator.free(exe_path_z);

    // Replace the current process with the new program
    _ = std.c.execve(exe_path_z.ptr, @ptrCast(argv.ptr), @ptrCast(envp.ptr));

    // If execve returns, it failed
    try IO.eprint("den: exec: execve failed\n", .{});
    return 126;
}

/// command - execute command bypassing functions/aliases
pub fn command(ctx: *BuiltinContext, cmd: *types.ParsedCommand) !i32 {
    // command [-pVv] command_name [args...]
    // -p: use default PATH
    // -V: verbose output (like type)
    // -v: short output (like which)

    if (cmd.args.len == 0) {
        try IO.eprint("den: command: missing argument\n", .{});
        return 1;
    }

    var verbose = false;
    var short_output = false;
    var use_default_path = false;
    var start_idx: usize = 0;

    // Parse flags
    for (cmd.args, 0..) |arg, i| {
        if (arg.len > 0 and arg[0] == '-') {
            for (arg[1..]) |c| {
                if (c == 'V') verbose = true else if (c == 'v') short_output = true else if (c == 'p') use_default_path = true else {
                    try IO.eprint("den: command: invalid option: -{c}\n", .{c});
                    return 1;
                }
            }
            start_idx = i + 1;
        } else {
            break;
        }
    }

    if (start_idx >= cmd.args.len) {
        try IO.eprint("den: command: missing command name\n", .{});
        return 1;
    }

    const cmd_name = cmd.args[start_idx];

    // -p flag: use default PATH instead of current PATH
    const default_path = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    var path_to_use: []const u8 = undefined;

    if (use_default_path) {
        path_to_use = default_path;
    } else {
        path_to_use = getenv("PATH") orelse default_path;
    }

    if (verbose or short_output) {
        // Act like type/which
        if (ctx.isBuiltin(cmd_name)) {
            if (verbose) {
                try IO.print("{s} is a shell builtin\n", .{cmd_name});
            } else {
                try IO.print("{s}\n", .{cmd_name});
            }
            return 0;
        }

        // Check PATH (or default PATH if -p)
        var path_list = utils.env.PathList.parse(ctx.allocator, path_to_use) catch {
            return 1;
        };
        defer path_list.deinit();

        if (try path_list.findExecutable(ctx.allocator, cmd_name)) |exec_path| {
            defer ctx.allocator.free(exec_path);
            try IO.print("{s}\n", .{exec_path});
            return 0;
        }

        return 1;
    }

    // Execute the command, skipping builtins
    var new_cmd = types.ParsedCommand{
        .name = cmd_name,
        .args = if (start_idx + 1 < cmd.args.len) cmd.args[start_idx + 1 ..] else &[_][]const u8{},
        .redirections = cmd.redirections,
    };

    return try ctx.executeExternalCmd(&new_cmd);
}

/// builtin - execute a shell builtin directly
pub fn builtinCmd(ctx: *BuiltinContext, cmd: *types.ParsedCommand) !i32 {
    // The 'builtin' command is used to bypass shell functions and aliases
    // and execute a builtin directly.
    if (cmd.args.len == 0) {
        try IO.eprint("den: builtin: missing argument\n", .{});
        return 1;
    }

    const builtin_name = cmd.args[0];
    if (!ctx.isBuiltin(builtin_name)) {
        try IO.eprint("den: builtin: {s}: not a shell builtin\n", .{builtin_name});
        return 1;
    }

    // Execute the builtin, bypassing alias/function resolution
    var new_cmd = types.ParsedCommand{
        .name = builtin_name,
        .args = if (cmd.args.len > 1) cmd.args[1..] else &[_][]const u8{},
        .redirections = cmd.redirections,
    };

    return try ctx.executeBuiltinCmd(&new_cmd);
}

/// coproc - run a command as a coprocess with bidirectional pipes
/// Usage: coproc [NAME] command [args...]
/// Sets NAME_0 (read fd), NAME_1 (write fd), NAME_PID
pub fn coproc(ctx: *BuiltinContext, cmd: *types.ParsedCommand) !i32 {
    if (cmd.args.len == 0) {
        try IO.eprint("coproc: command required\n", .{});
        return 1;
    }

    // Parse optional name and command
    var name: []const u8 = "COPROC";
    var cmd_start: usize = 0;

    // Check if first arg looks like a name (all caps, alphanumeric)
    if (cmd.args.len > 1) {
        const first = cmd.args[0];
        var is_name = true;
        for (first) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') {
                is_name = false;
                break;
            }
        }
        // If it looks like a valid name and there's a command after it
        if (is_name and std.ascii.isUpper(first[0])) {
            name = first;
            cmd_start = 1;
        }
    }

    if (cmd_start >= cmd.args.len) {
        try IO.eprint("coproc: command required after name\n", .{});
        return 1;
    }

    // Create pipes for bidirectional communication
    // pipe_to_coproc: parent writes to [1], coproc reads from [0]
    // pipe_from_coproc: coproc writes to [1], parent reads from [0]
    var pipe_to_coproc: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_to_coproc) != 0) {
        try IO.eprint("coproc: failed to create pipe\n", .{});
        return 1;
    }
    var pipe_from_coproc: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_from_coproc) != 0) {
        std.posix.close(pipe_to_coproc[0]);
        std.posix.close(pipe_to_coproc[1]);
        try IO.eprint("coproc: failed to create pipe\n", .{});
        return 1;
    }

    // Fork to create coprocess
    const fork_ret = std.c.fork();
    if (fork_ret < 0) {
        std.posix.close(pipe_to_coproc[0]);
        std.posix.close(pipe_to_coproc[1]);
        std.posix.close(pipe_from_coproc[0]);
        std.posix.close(pipe_from_coproc[1]);
        try IO.eprint("coproc: failed to fork\n", .{});
        return 1;
    }
    const pid: std.posix.pid_t = @intCast(fork_ret);

    if (pid == 0) {
        // Child process (coprocess)
        // Close parent's ends
        std.posix.close(pipe_to_coproc[1]);
        std.posix.close(pipe_from_coproc[0]);

        // Redirect stdin from pipe_to_coproc[0]
        if (std.c.dup2(pipe_to_coproc[0], std.posix.STDIN_FILENO) < 0) std.process.exit(1);
        std.posix.close(pipe_to_coproc[0]);

        // Redirect stdout to pipe_from_coproc[1]
        if (std.c.dup2(pipe_from_coproc[1], std.posix.STDOUT_FILENO) < 0) std.process.exit(1);
        std.posix.close(pipe_from_coproc[1]);

        // Execute the command
        const cmd_name = cmd.args[cmd_start];

        // Convert command name to null-terminated
        const cmd_z = std.posix.toPosixPath(cmd_name) catch {
            std.process.exit(127);
        };

        // Build argv - allocate on stack
        var argv_storage: [64][std.Io.Dir.max_path_bytes:0]u8 = undefined;
        var argv: [64:null]?[*:0]const u8 = undefined;
        var argv_idx: usize = 0;

        for (cmd.args[cmd_start..]) |arg| {
            if (argv_idx >= 63) break;
            const arg_z = std.posix.toPosixPath(arg) catch {
                std.process.exit(127);
            };
            @memcpy(argv_storage[argv_idx][0..arg_z.len], arg_z[0..arg_z.len]);
            argv_storage[argv_idx][arg_z.len] = 0;
            argv[argv_idx] = &argv_storage[argv_idx];
            argv_idx += 1;
        }
        argv[argv_idx] = null;

        // Execute
        _ = c_exec.execvp(&cmd_z, @ptrCast(argv[0..argv_idx :null]));

        // If exec failed
        std.process.exit(127);
    }

    // Parent process
    // Close child's ends
    std.posix.close(pipe_to_coproc[0]);
    std.posix.close(pipe_from_coproc[1]);

    // Set up variables:
    // NAME_0 = fd for reading from coproc (pipe_from_coproc[0])
    // NAME_1 = fd for writing to coproc (pipe_to_coproc[1])
    // NAME_PID = pid of coprocess

    // Set NAME_PID
    var pid_name_buf: [128]u8 = undefined;
    const pid_name = std.fmt.bufPrint(&pid_name_buf, "{s}_PID", .{name}) catch {
        try IO.eprint("coproc: name too long\n", .{});
        return 1;
    };
    var pid_val_buf: [32]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_val_buf, "{d}", .{pid}) catch "0";

    // Duplicate strings for the hash map
    const pid_name_dup = ctx.allocator.dupe(u8, pid_name) catch {
        return 1;
    };
    const pid_str_dup = ctx.allocator.dupe(u8, pid_str) catch {
        ctx.allocator.free(pid_name_dup);
        return 1;
    };
    ctx.environment.put(pid_name_dup, pid_str_dup) catch {};

    // For array-like access, we store as NAME_0 and NAME_1
    // (full array support is a separate feature)
    var read_fd_name_buf: [128]u8 = undefined;
    const read_fd_name = std.fmt.bufPrint(&read_fd_name_buf, "{s}_0", .{name}) catch name;
    var fd_buf: [32]u8 = undefined;
    const read_fd_str = std.fmt.bufPrint(&fd_buf, "{d}", .{pipe_from_coproc[0]}) catch "0";

    const read_name_dup = ctx.allocator.dupe(u8, read_fd_name) catch {
        return 1;
    };
    const read_str_dup = ctx.allocator.dupe(u8, read_fd_str) catch {
        ctx.allocator.free(read_name_dup);
        return 1;
    };
    ctx.environment.put(read_name_dup, read_str_dup) catch {};

    var write_fd_name_buf: [128]u8 = undefined;
    const write_fd_name = std.fmt.bufPrint(&write_fd_name_buf, "{s}_1", .{name}) catch name;
    var fd_buf2: [32]u8 = undefined;
    const write_fd_str = std.fmt.bufPrint(&fd_buf2, "{d}", .{pipe_to_coproc[1]}) catch "0";

    const write_name_dup = ctx.allocator.dupe(u8, write_fd_name) catch {
        return 1;
    };
    const write_str_dup = ctx.allocator.dupe(u8, write_fd_str) catch {
        ctx.allocator.free(write_name_dup);
        return 1;
    };
    ctx.environment.put(write_name_dup, write_str_dup) catch {};

    // Store coproc info in shell for later cleanup
    ctx.setCoprocState(pid, pipe_from_coproc[0], pipe_to_coproc[1]) catch {};

    try IO.print("[coproc] {d}\n", .{pid});
    return 0;
}

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
