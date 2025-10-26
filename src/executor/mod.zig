const std = @import("std");
const types = @import("../types/mod.zig");
const IO = @import("../utils/io.zig").IO;

pub const Executor = struct {
    allocator: std.mem.Allocator,
    environment: *std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, environment: *std.StringHashMap([]const u8)) Executor {
        return .{
            .allocator = allocator,
            .environment = environment,
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
                        // TODO: background should spawn and continue immediately
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

            // Execute single command
            last_exit_code = try self.executeCommand(&chain.commands[i]);
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
                    // TODO: Implement heredoc/herestring
                    try IO.eprint("den: heredoc/herestring not yet implemented\n", .{});
                },
                .fd_duplicate, .fd_close => {
                    // TODO: Implement fd duplication and closing
                    try IO.eprint("den: fd duplication/closing not yet implemented\n", .{});
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
        const builtins = [_][]const u8{ "cd", "pwd", "echo", "exit", "env", "export" };
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
};
