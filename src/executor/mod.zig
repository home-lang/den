const std = @import("std");
const types = @import("../types/mod.zig");
const IO = @import("../utils/io.zig").IO;
const Expansion = @import("../utils/expansion.zig").Expansion;

// Forward declaration for Shell type
const Shell = @import("../shell.zig").Shell;

pub const Executor = struct {
    allocator: std.mem.Allocator,
    environment: *std.StringHashMap([]const u8),
    shell: ?*Shell, // Optional reference to shell for options

    pub fn init(allocator: std.mem.Allocator, environment: *std.StringHashMap([]const u8)) Executor {
        return .{
            .allocator = allocator,
            .environment = environment,
            .shell = null,
        };
    }

    pub fn initWithShell(allocator: std.mem.Allocator, environment: *std.StringHashMap([]const u8), shell: *Shell) Executor {
        return .{
            .allocator = allocator,
            .environment = environment,
            .shell = shell,
        };
    }

    pub fn executeChain(self: *Executor, chain: *types.CommandChain) !i32 {
        if (chain.commands.len == 0) return 0;

        // Single command - execute directly
        if (chain.commands.len == 1) {
            return try self.executeCommand(&chain.commands[0]);
        }

        // Multiple commands - handle operators
        var last_exit_code: i32 = 0;
        var i: usize = 0;

        while (i < chain.commands.len) {
            // Check if we should execute this command based on previous operator
            if (i > 0) {
                const prev_op = chain.operators[i - 1];
                switch (prev_op) {
                    .and_op => {
                        // && - only execute if previous succeeded
                        if (last_exit_code != 0) {
                            return last_exit_code;
                        }
                    },
                    .or_op => {
                        // || - only execute if previous failed
                        if (last_exit_code == 0) {
                            return last_exit_code;
                        }
                    },
                    .pipe => {
                        // Pipe handling - execute pipeline
                        const pipeline_start = i - 1;
                        var pipeline_end = i;

                        // Find the end of the pipeline
                        while (pipeline_end < chain.operators.len and
                               chain.operators[pipeline_end] == .pipe) {
                            pipeline_end += 1;
                        }

                        // Execute the pipeline
                        last_exit_code = try self.executePipeline(
                            chain.commands[pipeline_start..pipeline_end + 1]
                        );

                        // Skip to the end of the pipeline
                        i = pipeline_end + 1;
                        continue;
                    },
                    .semicolon, .background => {
                        // ; and & - always execute next command
                        // Background handling is implemented below in the execute logic
                    },
                }
            }

            // Check if this command starts a pipeline
            if (i < chain.operators.len and chain.operators[i] == .pipe) {
                const pipeline_start = i;
                var pipeline_end = i;

                // Find the end of the pipeline
                while (pipeline_end < chain.operators.len and
                       chain.operators[pipeline_end] == .pipe) {
                    pipeline_end += 1;
                }

                // Execute the pipeline
                last_exit_code = try self.executePipeline(
                    chain.commands[pipeline_start..pipeline_end + 1]
                );

                // Skip to the end of the pipeline
                i = pipeline_end + 1;
                continue;
            }

            // Check if this command should run in background
            const run_in_background = i < chain.operators.len and chain.operators[i] == .background;

            if (run_in_background) {
                // Execute command in background (don't wait for it)
                try self.executeCommandBackground(&chain.commands[i]);
                last_exit_code = 0; // Background commands always return 0
            } else {
                // Execute single command normally
                last_exit_code = try self.executeCommand(&chain.commands[i]);

                // Check for errexit option (set -e)
                if (self.shell) |shell| {
                    if (shell.option_errexit and last_exit_code != 0) {
                        // Exit on error if errexit is enabled
                        try IO.eprint("den: command failed with exit code {d} (errexit enabled)\n", .{last_exit_code});
                        if (shell.current_line > 0) {
                            try IO.eprint("den: line {d}\n", .{shell.current_line});
                        }
                        return last_exit_code;
                    }
                }
            }

            i += 1;
        }

        return last_exit_code;
    }

    fn executePipeline(self: *Executor, commands: []types.ParsedCommand) !i32 {
        if (commands.len == 0) return 0;
        if (commands.len == 1) return try self.executeCommand(&commands[0]);

        // Create pipes for communication
        var pipes_buffer: [16][2]std.posix.fd_t = undefined;
        const num_pipes = commands.len - 1;

        if (num_pipes > pipes_buffer.len) return error.TooManyPipes;

        // Create all pipes
        for (0..num_pipes) |i| {
            pipes_buffer[i] = try std.posix.pipe();
        }

        // Spawn all commands in the pipeline
        var pids_buffer: [17]std.posix.pid_t = undefined;

        for (commands, 0..) |*cmd, i| {
            const pid = try std.posix.fork();

            if (pid == 0) {
                // Child process

                // Set up stdin from previous pipe
                if (i > 0) {
                    try std.posix.dup2(pipes_buffer[i - 1][0], std.posix.STDIN_FILENO);
                }

                // Set up stdout to next pipe
                if (i < num_pipes) {
                    try std.posix.dup2(pipes_buffer[i][1], std.posix.STDOUT_FILENO);
                }

                // Close all pipe fds in child
                for (0..num_pipes) |j| {
                    std.posix.close(pipes_buffer[j][0]);
                    std.posix.close(pipes_buffer[j][1]);
                }

                // Execute the command
                if (self.isBuiltin(cmd.name)) {
                    const exit_code = self.executeBuiltin(cmd) catch 1;
                    std.posix.exit(@intCast(exit_code));
                } else {
                    _ = try self.executeExternalInChild(cmd);
                }
                unreachable;
            } else {
                // Parent - store pid
                pids_buffer[i] = pid;
            }
        }

        // Parent: close all pipes
        for (0..num_pipes) |i| {
            std.posix.close(pipes_buffer[i][0]);
            std.posix.close(pipes_buffer[i][1]);
        }

        // Wait for all children
        var last_status: i32 = 0;
        for (pids_buffer[0..commands.len]) |pid| {
            const result = std.posix.waitpid(pid, 0);
            last_status = @intCast(std.posix.W.EXITSTATUS(result.status));
        }

        return last_status;
    }

    fn executeExternalInChild(self: *Executor, command: *types.ParsedCommand) !void {
        // Apply redirections before exec
        try self.applyRedirections(command.redirections);

        // Build argv (command name + args)
        const argv_len = 1 + command.args.len;
        var argv = try self.allocator.alloc(?[*:0]const u8, argv_len + 1);
        defer self.allocator.free(argv);

        // Allocate command name as null-terminated string
        const cmd_z = try self.allocator.dupeZ(u8, command.name);
        defer self.allocator.free(cmd_z);
        argv[0] = cmd_z.ptr;

        // Allocate args as null-terminated strings
        var arg_zs = try self.allocator.alloc([:0]u8, command.args.len);
        defer {
            for (arg_zs) |arg_z| {
                self.allocator.free(arg_z);
            }
            self.allocator.free(arg_zs);
        }

        for (command.args, 0..) |arg, i| {
            arg_zs[i] = try self.allocator.dupeZ(u8, arg);
            argv[i + 1] = arg_zs[i].ptr;
        }
        argv[argv_len] = null;

        // Exec (no fork - we're already in child)
        _ = std.posix.execvpeZ(cmd_z.ptr, @ptrCast(argv.ptr), @ptrCast(std.os.environ.ptr)) catch {
            IO.eprint("den: {s}: command not found\n", .{command.name}) catch {};
            std.posix.exit(127);
        };
    }

    fn applyRedirections(self: *Executor, redirections: []types.Redirection) !void {
        for (redirections) |redir| {
            switch (redir.kind) {
                .output_truncate => {
                    // Open file for writing, truncate if exists
                    const path_z = try self.allocator.dupeZ(u8, redir.target);
                    defer self.allocator.free(path_z);

                    const fd = std.posix.open(
                        path_z,
                        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
                        0o644,
                    ) catch |err| {
                        try IO.eprint("den: {s}: {}\n", .{ redir.target, err });
                        std.posix.exit(1);
                    };

                    try std.posix.dup2(fd, @intCast(redir.fd));
                    std.posix.close(fd);
                },
                .output_append => {
                    // Open file for appending
                    const path_z = try self.allocator.dupeZ(u8, redir.target);
                    defer self.allocator.free(path_z);

                    const fd = std.posix.open(
                        path_z,
                        .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
                        0o644,
                    ) catch |err| {
                        try IO.eprint("den: {s}: {}\n", .{ redir.target, err });
                        std.posix.exit(1);
                    };

                    try std.posix.dup2(fd, @intCast(redir.fd));
                    std.posix.close(fd);
                },
                .input => {
                    // Open file for reading
                    const path_z = try self.allocator.dupeZ(u8, redir.target);
                    defer self.allocator.free(path_z);

                    const fd = std.posix.open(
                        path_z,
                        .{ .ACCMODE = .RDONLY },
                        0,
                    ) catch |err| {
                        try IO.eprint("den: {s}: {}\n", .{ redir.target, err });
                        std.posix.exit(1);
                    };

                    try std.posix.dup2(fd, std.posix.STDIN_FILENO);
                    std.posix.close(fd);
                },
                .heredoc, .herestring => {
                    // Create a pipe for the content
                    const pipe_fds = try std.posix.pipe();
                    const read_fd = pipe_fds[0];
                    const write_fd = pipe_fds[1];

                    // Write content to pipe
                    const content = blk: {
                        if (redir.kind == .herestring) {
                            // For herestring, expand variables and use the content
                            var expansion = Expansion.init(self.allocator, self.environment, 0);
                            const expanded = expansion.expand(redir.target) catch redir.target;
                            // Add newline for herestring
                            var buf: [4096]u8 = undefined;
                            const with_newline = std.fmt.bufPrint(&buf, "{s}\n", .{expanded}) catch redir.target;
                            if (expanded.ptr != redir.target.ptr) {
                                self.allocator.free(expanded);
                            }
                            break :blk try self.allocator.dupe(u8, with_newline);
                        } else {
                            // For heredoc, use the target as-is (it contains the content)
                            // Note: Full heredoc support requires parser changes
                            // This provides basic support for single-line heredocs
                            break :blk try self.allocator.dupe(u8, redir.target);
                        }
                    };
                    defer self.allocator.free(content);

                    // Fork to write content (avoid blocking)
                    const writer_pid = try std.posix.fork();
                    if (writer_pid == 0) {
                        // Child: write content and exit
                        std.posix.close(read_fd);
                        _ = std.posix.write(write_fd, content) catch {};
                        std.posix.close(write_fd);
                        std.posix.exit(0);
                    }

                    // Parent: close write end and dup read end to stdin
                    std.posix.close(write_fd);
                    try std.posix.dup2(read_fd, std.posix.STDIN_FILENO);
                    std.posix.close(read_fd);

                    // Wait for writer to finish
                    _ = std.posix.waitpid(writer_pid, 0);
                },
                .fd_duplicate => {
                    // Parse target as file descriptor number
                    // Format: N>&M or N<&M (duplicate fd M to fd N)
                    const target_fd = std.fmt.parseInt(u32, redir.target, 10) catch {
                        try IO.eprint("den: invalid file descriptor: {s}\n", .{redir.target});
                        return error.InvalidFd;
                    };

                    // Duplicate the target_fd to redir.fd
                    try std.posix.dup2(@intCast(target_fd), @intCast(redir.fd));
                },
                .fd_close => {
                    // Close the specified file descriptor
                    // Format: N>&- or N<&- (close fd N)
                    std.posix.close(@intCast(redir.fd));
                },
            }
        }
    }

    pub fn executeCommand(self: *Executor, command: *types.ParsedCommand) !i32 {
        // Check if it's a builtin
        if (self.isBuiltin(command.name)) {
            // If builtin has redirections, fork to avoid affecting parent shell
            if (command.redirections.len > 0) {
                const pid = try std.posix.fork();
                if (pid == 0) {
                    // Child - apply redirections and execute builtin
                    self.applyRedirections(command.redirections) catch {
                        std.posix.exit(1);
                    };
                    const exit_code = self.executeBuiltin(command) catch 1;
                    std.posix.exit(@intCast(exit_code));
                } else {
                    // Parent - wait for child
                    const result = std.posix.waitpid(pid, 0);
                    return @intCast(std.posix.W.EXITSTATUS(result.status));
                }
            }
            return try self.executeBuiltin(command);
        }

        // Execute external command
        return try self.executeExternal(command);
    }

    fn isBuiltin(self: *Executor, name: []const u8) bool {
        _ = self;
        const builtins = [_][]const u8{ "cd", "pwd", "echo", "exit", "env", "export", "set", "unset" };
        for (builtins) |builtin| {
            if (std.mem.eql(u8, name, builtin)) return true;
        }
        return false;
    }

    fn executeBuiltin(self: *Executor, command: *types.ParsedCommand) !i32 {
        if (std.mem.eql(u8, command.name, "echo")) {
            return try self.builtinEcho(command);
        } else if (std.mem.eql(u8, command.name, "pwd")) {
            return try self.builtinPwd();
        } else if (std.mem.eql(u8, command.name, "cd")) {
            return try self.builtinCd(command);
        } else if (std.mem.eql(u8, command.name, "env")) {
            return try self.builtinEnv();
        } else if (std.mem.eql(u8, command.name, "export")) {
            return try self.builtinExport(command);
        } else if (std.mem.eql(u8, command.name, "set")) {
            return try self.builtinSet(command);
        } else if (std.mem.eql(u8, command.name, "unset")) {
            return try self.builtinUnset(command);
        }

        try IO.eprint("den: builtin not implemented: {s}\n", .{command.name});
        return 1;
    }

    fn builtinEcho(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        for (command.args, 0..) |arg, i| {
            try IO.print("{s}", .{arg});
            if (i < command.args.len - 1) {
                try IO.print(" ", .{});
            }
        }
        try IO.print("\n", .{});
        return 0;
    }

    fn builtinPwd(self: *Executor) !i32 {
        _ = self;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = try std.posix.getcwd(&buf);
        try IO.print("{s}\n", .{cwd});
        return 0;
    }

    fn builtinCd(self: *Executor, command: *types.ParsedCommand) !i32 {
        const path = if (command.args.len > 0) command.args[0] else blk: {
            // Default to HOME
            if (self.environment.get("HOME")) |home| {
                break :blk home;
            }
            try IO.eprint("den: cd: HOME not set\n", .{});
            return 1;
        };

        std.posix.chdir(path) catch |err| {
            try IO.eprint("den: cd: {s}: {}\n", .{ path, err });
            return 1;
        };

        return 0;
    }

    fn builtinEnv(self: *Executor) !i32 {
        var iter = self.environment.iterator();
        while (iter.next()) |entry| {
            try IO.print("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        return 0;
    }

    fn builtinExport(self: *Executor, command: *types.ParsedCommand) !i32 {
        // export VAR=value or export VAR
        if (command.args.len == 0) {
            // No args - print all exported variables (same as env for now)
            return try self.builtinEnv();
        }

        for (command.args) |arg| {
            // Parse VAR=value format
            if (std.mem.indexOf(u8, arg, "=")) |eq_pos| {
                const var_name = arg[0..eq_pos];
                const var_value = arg[eq_pos + 1 ..];

                // Duplicate the value
                const value = try self.allocator.dupe(u8, var_value);

                // Get or put entry
                const gop = try self.environment.getOrPut(var_name);
                if (gop.found_existing) {
                    // Free old value and update
                    self.allocator.free(gop.value_ptr.*);
                    gop.value_ptr.* = value;
                } else {
                    // New key - duplicate it
                    const key = try self.allocator.dupe(u8, var_name);
                    gop.key_ptr.* = key;
                    gop.value_ptr.* = value;
                }
            } else {
                // Just variable name - export with empty value or existing value
                if (!self.environment.contains(arg)) {
                    const key = try self.allocator.dupe(u8, arg);
                    const value = try self.allocator.dupe(u8, "");
                    try self.environment.put(key, value);
                }
            }
        }

        return 0;
    }

    fn builtinSet(self: *Executor, command: *types.ParsedCommand) !i32 {
        if (command.args.len == 0) {
            // No args - print all variables
            return try self.builtinEnv();
        }

        for (command.args) |arg| {
            // Handle shell options (-e, -E, +e, +E, etc.)
            if (arg.len > 0 and (arg[0] == '-' or arg[0] == '+')) {
                const enable = arg[0] == '-';
                const option = arg[1..];

                if (self.shell) |shell| {
                    if (std.mem.eql(u8, option, "e")) {
                        shell.option_errexit = enable;
                        if (enable) {
                            try IO.print("errexit enabled (exit on error)\n", .{});
                        } else {
                            try IO.print("errexit disabled\n", .{});
                        }
                    } else if (std.mem.eql(u8, option, "E")) {
                        shell.option_errtrace = enable;
                        if (enable) {
                            try IO.print("errtrace enabled (ERR trap inheritance)\n", .{});
                        } else {
                            try IO.print("errtrace disabled\n", .{});
                        }
                    } else if (std.mem.eql(u8, option, "o")) {
                        // set -o option_name
                        if (command.args.len > 1) {
                            try IO.eprint("den: set: -o requires option name\n", .{});
                            return 1;
                        }
                    } else {
                        try IO.eprint("den: set: unknown option: {s}\n", .{arg});
                        return 1;
                    }
                } else {
                    try IO.eprint("den: set: shell options not available in this context\n", .{});
                    return 1;
                }
            } else if (std.mem.indexOf(u8, arg, "=")) |eq_pos| {
                // VAR=value assignment
                const var_name = arg[0..eq_pos];
                const var_value = arg[eq_pos + 1 ..];

                const value = try self.allocator.dupe(u8, var_value);

                // Get or put entry to avoid memory leak
                const gop = try self.environment.getOrPut(var_name);
                if (gop.found_existing) {
                    // Free old value and update
                    self.allocator.free(gop.value_ptr.*);
                    gop.value_ptr.* = value;
                } else {
                    // New key - duplicate it
                    const key = try self.allocator.dupe(u8, var_name);
                    gop.key_ptr.* = key;
                    gop.value_ptr.* = value;
                }
            } else {
                try IO.eprint("den: set: {s}: not a valid identifier\n", .{arg});
                return 1;
            }
        }

        return 0;
    }

    fn builtinUnset(self: *Executor, command: *types.ParsedCommand) !i32 {
        // unset VAR - remove variable from environment
        if (command.args.len == 0) {
            try IO.eprint("den: unset: not enough arguments\n", .{});
            return 1;
        }

        for (command.args) |var_name| {
            if (self.environment.fetchRemove(var_name)) |entry| {
                // Free the removed key and value
                self.allocator.free(entry.key);
                self.allocator.free(entry.value);
            }
        }

        return 0;
    }

    fn executeExternal(self: *Executor, command: *types.ParsedCommand) !i32 {
        // Build argv (command name + args)
        const argv_len = 1 + command.args.len;
        var argv = try self.allocator.alloc(?[*:0]const u8, argv_len + 1);
        defer self.allocator.free(argv);

        // Allocate command name as null-terminated string
        const cmd_z = try self.allocator.dupeZ(u8, command.name);
        defer self.allocator.free(cmd_z);
        argv[0] = cmd_z.ptr;

        // Allocate args as null-terminated strings
        var arg_zs = try self.allocator.alloc([:0]u8, command.args.len);
        defer {
            for (arg_zs) |arg_z| {
                self.allocator.free(arg_z);
            }
            self.allocator.free(arg_zs);
        }

        for (command.args, 0..) |arg, i| {
            arg_zs[i] = try self.allocator.dupeZ(u8, arg);
            argv[i + 1] = arg_zs[i].ptr;
        }
        argv[argv_len] = null;

        // Fork and exec
        const pid = try std.posix.fork();

        if (pid == 0) {
            // Child process - apply redirections before exec
            self.applyRedirections(command.redirections) catch {
                std.posix.exit(1);
            };

            _ = std.posix.execvpeZ(cmd_z.ptr, @ptrCast(argv.ptr), @ptrCast(std.os.environ.ptr)) catch {
                // If execvpe returns, it failed
                IO.eprint("den: {s}: command not found\n", .{command.name}) catch {};
                std.posix.exit(127);
            };
            unreachable;
        } else {
            // Parent process - wait for child
            const result = std.posix.waitpid(pid, 0);
            return @intCast(std.posix.W.EXITSTATUS(result.status));
        }
    }

    /// Execute command in background (don't wait for it to complete)
    fn executeCommandBackground(self: *Executor, command: *types.ParsedCommand) !void {
        // Check if it's a builtin - builtins can't run in background
        if (self.isBuiltin(command.name)) {
            try IO.eprint("den: cannot run builtin '{s}' in background\n", .{command.name});
            return error.BuiltinBackground;
        }

        // Build argv (command name + args)
        const argv_len = 1 + command.args.len;
        var argv = try self.allocator.alloc(?[*:0]const u8, argv_len + 1);
        defer self.allocator.free(argv);

        // Allocate command name as null-terminated string
        const cmd_z = try self.allocator.dupeZ(u8, command.name);
        defer self.allocator.free(cmd_z);
        argv[0] = cmd_z.ptr;

        // Allocate args as null-terminated strings
        var arg_zs = try self.allocator.alloc([:0]u8, command.args.len);
        defer {
            for (arg_zs) |arg_z| {
                self.allocator.free(arg_z);
            }
            self.allocator.free(arg_zs);
        }

        for (command.args, 0..) |arg, i| {
            arg_zs[i] = try self.allocator.dupeZ(u8, arg);
            argv[i + 1] = arg_zs[i].ptr;
        }
        argv[argv_len] = null;

        // Fork and exec
        const pid = try std.posix.fork();

        if (pid == 0) {
            // Child process - apply redirections before exec
            self.applyRedirections(command.redirections) catch {
                std.posix.exit(1);
            };

            _ = std.posix.execvpeZ(cmd_z.ptr, @ptrCast(argv.ptr), @ptrCast(std.os.environ.ptr)) catch {
                // If execvpe returns, it failed
                IO.eprint("den: {s}: command not found\n", .{command.name}) catch {};
                std.posix.exit(127);
            };
            unreachable;
        } else {
            // Parent process - DON'T wait, just print the PID
            try IO.print("[{d}]\n", .{pid});
        }
    }
};
