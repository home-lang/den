const std = @import("std");
const types = @import("../types/mod.zig");
const IO = @import("../utils/io.zig").IO;
const Expansion = @import("../utils/expansion.zig").Expansion;
const builtin = @import("builtin");

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

        if (builtin.os.tag == .windows) {
            return try self.executePipelineWindows(commands);
        }
        return try self.executePipelinePosix(commands);
    }

    fn executePipelineWindows(self: *Executor, commands: []types.ParsedCommand) !i32 {
        // Windows implementation using std.process.Child with pipes
        const num_pipes = commands.len - 1;
        if (num_pipes > 16) return error.TooManyPipes;

        // Spawn all commands as Child processes with pipe behavior
        var children_buffer: [17]std.process.Child = undefined;
        var argv_lists: [17]std.ArrayList([]const u8) = undefined;

        // Initialize argv lists
        for (0..commands.len) |i| {
            argv_lists[i] = .{};
        }
        defer {
            for (0..commands.len) |i| {
                argv_lists[i].deinit(self.allocator);
            }
        }

        // Build argv and spawn children
        for (commands, 0..) |*cmd, i| {
            // Build argv list
            try argv_lists[i].append(self.allocator, cmd.name);
            for (cmd.args) |arg| {
                try argv_lists[i].append(self.allocator, arg);
            }

            children_buffer[i] = std.process.Child.init(argv_lists[i].items, self.allocator);

            // Set up stdin from previous command's stdout pipe
            if (i > 0) {
                children_buffer[i].stdin_behavior = .Pipe;
                // After spawning previous child, we'll connect the pipes
            } else {
                children_buffer[i].stdin_behavior = .Inherit;
            }

            // Set up stdout to pipe to next command
            if (i < num_pipes) {
                children_buffer[i].stdout_behavior = .Pipe;
            } else {
                children_buffer[i].stdout_behavior = .Inherit;
            }

            children_buffer[i].stderr_behavior = .Inherit;

            // Handle explicit redirections
            for (cmd.redirections) |redir| {
                switch (redir.kind) {
                    .output_truncate, .output_append => {
                        const file = try std.fs.cwd().createFile(redir.target, .{
                            .truncate = (redir.kind == .output_truncate),
                        });
                        if (redir.fd == 1) {
                            children_buffer[i].stdout_behavior = .Ignore;
                            children_buffer[i].stdout = file;
                        } else if (redir.fd == 2) {
                            children_buffer[i].stderr_behavior = .Ignore;
                            children_buffer[i].stderr = file;
                        }
                    },
                    .input => {
                        const file = try std.fs.cwd().openFile(redir.target, .{});
                        children_buffer[i].stdin_behavior = .Ignore;
                        children_buffer[i].stdin = file;
                    },
                    .fd_duplicate => {
                        // Handle 2>&1 (stderr to stdout)
                        if (redir.fd == 2 and std.mem.eql(u8, redir.target, "1")) {
                            children_buffer[i].stderr_behavior = .Inherit; // Will inherit stdout's destination
                        }
                    },
                    else => {},
                }
            }

            try children_buffer[i].spawn();

            // Connect pipes between processes
            if (i > 0 and children_buffer[i - 1].stdout != null) {
                children_buffer[i].stdin = children_buffer[i - 1].stdout.?;
            }
        }

        // Wait for all children
        var last_status: i32 = 0;
        for (0..commands.len) |i| {
            const term = try children_buffer[i].wait();
            last_status = switch (term) {
                .Exited => |code| code,
                else => 1,
            };
        }

        return last_status;
    }

    fn executePipelinePosix(self: *Executor, commands: []types.ParsedCommand) !i32 {
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
            // If builtin has redirections, handle appropriately per OS
            if (command.redirections.len > 0) {
                if (builtin.os.tag == .windows) {
                    // Windows: save/restore stdout/stderr instead of fork
                    return try self.executeBuiltinWithRedirectionsWindows(command);
                }

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
        const builtins = [_][]const u8{
            "cd", "pwd", "echo", "exit", "env", "export", "set", "unset",
            "true", "false", "test", "[", "alias", "unalias", "which",
            "type", "help", "read", "printf", "source", ".", "history",
            "pushd", "popd", "dirs", "eval", "exec", "command", "builtin",
            "jobs", "fg", "bg", "wait", "disown", "kill", "trap", "times",
            "umask", "getopts", "clear", "time", "hash", "yes", "reload"
        };
        for (builtins) |builtin_name| {
            if (std.mem.eql(u8, name, builtin_name)) return true;
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
        } else if (std.mem.eql(u8, command.name, "true")) {
            return try self.builtinTrue();
        } else if (std.mem.eql(u8, command.name, "false")) {
            return try self.builtinFalse();
        } else if (std.mem.eql(u8, command.name, "test") or std.mem.eql(u8, command.name, "[")) {
            return try self.builtinTest(command);
        } else if (std.mem.eql(u8, command.name, "which")) {
            return try self.builtinWhich(command);
        } else if (std.mem.eql(u8, command.name, "type")) {
            return try self.builtinType(command);
        } else if (std.mem.eql(u8, command.name, "help")) {
            return try self.builtinHelp(command);
        } else if (std.mem.eql(u8, command.name, "alias")) {
            return try self.builtinAlias(command);
        } else if (std.mem.eql(u8, command.name, "unalias")) {
            return try self.builtinUnalias(command);
        } else if (std.mem.eql(u8, command.name, "read")) {
            return try self.builtinRead(command);
        } else if (std.mem.eql(u8, command.name, "printf")) {
            return try self.builtinPrintf(command);
        } else if (std.mem.eql(u8, command.name, "source") or std.mem.eql(u8, command.name, ".")) {
            return try self.builtinSource(command);
        } else if (std.mem.eql(u8, command.name, "history")) {
            return try self.builtinHistory(command);
        } else if (std.mem.eql(u8, command.name, "pushd")) {
            return try self.builtinPushd(command);
        } else if (std.mem.eql(u8, command.name, "popd")) {
            return try self.builtinPopd(command);
        } else if (std.mem.eql(u8, command.name, "dirs")) {
            return try self.builtinDirs(command);
        } else if (std.mem.eql(u8, command.name, "eval")) {
            return try self.builtinEval(command);
        } else if (std.mem.eql(u8, command.name, "exec")) {
            return try self.builtinExec(command);
        } else if (std.mem.eql(u8, command.name, "command")) {
            return try self.builtinCommand(command);
        } else if (std.mem.eql(u8, command.name, "builtin")) {
            return try self.builtinBuiltin(command);
        } else if (std.mem.eql(u8, command.name, "jobs")) {
            return try self.builtinJobs(command);
        } else if (std.mem.eql(u8, command.name, "fg")) {
            return try self.builtinFg(command);
        } else if (std.mem.eql(u8, command.name, "bg")) {
            return try self.builtinBg(command);
        } else if (std.mem.eql(u8, command.name, "wait")) {
            return try self.builtinWait(command);
        } else if (std.mem.eql(u8, command.name, "disown")) {
            return try self.builtinDisown(command);
        } else if (std.mem.eql(u8, command.name, "kill")) {
            return try self.builtinKill(command);
        } else if (std.mem.eql(u8, command.name, "trap")) {
            return try self.builtinTrap(command);
        } else if (std.mem.eql(u8, command.name, "times")) {
            return try self.builtinTimes(command);
        } else if (std.mem.eql(u8, command.name, "umask")) {
            return try self.builtinUmask(command);
        } else if (std.mem.eql(u8, command.name, "getopts")) {
            return try self.builtinGetopts(command);
        } else if (std.mem.eql(u8, command.name, "clear")) {
            return try self.builtinClear(command);
        } else if (std.mem.eql(u8, command.name, "time")) {
            return try self.builtinTime(command);
        } else if (std.mem.eql(u8, command.name, "hash")) {
            return try self.builtinHash(command);
        } else if (std.mem.eql(u8, command.name, "yes")) {
            return try self.builtinYes(command);
        } else if (std.mem.eql(u8, command.name, "reload")) {
            return try self.builtinReload(command);
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

    fn builtinTrue(self: *Executor) !i32 {
        _ = self;
        return 0;
    }

    fn builtinFalse(self: *Executor) !i32 {
        _ = self;
        return 1;
    }

    fn builtinTest(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;

        // Handle both 'test' and '[' syntax
        const args = if (std.mem.eql(u8, command.name, "[")) blk: {
            // For '[', last arg should be ']'
            if (command.args.len > 0 and std.mem.eql(u8, command.args[command.args.len - 1], "]")) {
                break :blk command.args[0..command.args.len - 1];
            }
            try IO.eprint("den: [: missing ']'\n", .{});
            return 2;
        } else command.args;

        if (args.len == 0) return 1; // Empty test is false

        // Single argument - test if non-empty string
        if (args.len == 1) {
            return if (args[0].len > 0) 0 else 1;
        }

        // Two arguments - unary operators
        if (args.len == 2) {
            const op = args[0];
            const arg = args[1];

            if (std.mem.eql(u8, op, "-z")) {
                // True if string is empty
                return if (arg.len == 0) 0 else 1;
            } else if (std.mem.eql(u8, op, "-n")) {
                // True if string is non-empty
                return if (arg.len > 0) 0 else 1;
            } else if (std.mem.eql(u8, op, "-f")) {
                // True if file exists and is regular file
                const file = std.fs.cwd().openFile(arg, .{}) catch return 1;
                defer file.close();
                const stat = file.stat() catch return 1;
                return if (stat.kind == .file) 0 else 1;
            } else if (std.mem.eql(u8, op, "-d")) {
                // True if file exists and is directory
                var dir = std.fs.cwd().openDir(arg, .{}) catch return 1;
                dir.close();
                return 0;
            } else if (std.mem.eql(u8, op, "-e")) {
                // True if file exists
                std.fs.cwd().access(arg, .{}) catch return 1;
                return 0;
            } else if (std.mem.eql(u8, op, "-r")) {
                // True if file exists and is readable
                const file = std.fs.cwd().openFile(arg, .{}) catch return 1;
                file.close();
                return 0;
            } else if (std.mem.eql(u8, op, "-w")) {
                // True if file exists and is writable
                const file = std.fs.cwd().openFile(arg, .{ .mode = .write_only }) catch return 1;
                file.close();
                return 0;
            } else if (std.mem.eql(u8, op, "-x")) {
                // True if file exists and is executable
                if (builtin.os.tag == .windows) {
                    // On Windows, check if file exists
                    std.fs.cwd().access(arg, .{}) catch return 1;
                    return 0;
                }
                const file = std.fs.cwd().openFile(arg, .{}) catch return 1;
                defer file.close();
                const stat = file.stat() catch return 1;
                return if (stat.mode & 0o111 != 0) 0 else 1;
            }
        }

        // Three arguments - binary operators
        if (args.len == 3) {
            const left = args[0];
            const op = args[1];
            const right = args[2];

            if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) {
                // String equality
                return if (std.mem.eql(u8, left, right)) 0 else 1;
            } else if (std.mem.eql(u8, op, "!=")) {
                // String inequality
                return if (!std.mem.eql(u8, left, right)) 0 else 1;
            } else if (std.mem.eql(u8, op, "-eq")) {
                // Numeric equality
                const left_num = std.fmt.parseInt(i64, left, 10) catch return 2;
                const right_num = std.fmt.parseInt(i64, right, 10) catch return 2;
                return if (left_num == right_num) 0 else 1;
            } else if (std.mem.eql(u8, op, "-ne")) {
                // Numeric inequality
                const left_num = std.fmt.parseInt(i64, left, 10) catch return 2;
                const right_num = std.fmt.parseInt(i64, right, 10) catch return 2;
                return if (left_num != right_num) 0 else 1;
            } else if (std.mem.eql(u8, op, "-lt")) {
                // Numeric less than
                const left_num = std.fmt.parseInt(i64, left, 10) catch return 2;
                const right_num = std.fmt.parseInt(i64, right, 10) catch return 2;
                return if (left_num < right_num) 0 else 1;
            } else if (std.mem.eql(u8, op, "-le")) {
                // Numeric less than or equal
                const left_num = std.fmt.parseInt(i64, left, 10) catch return 2;
                const right_num = std.fmt.parseInt(i64, right, 10) catch return 2;
                return if (left_num <= right_num) 0 else 1;
            } else if (std.mem.eql(u8, op, "-gt")) {
                // Numeric greater than
                const left_num = std.fmt.parseInt(i64, left, 10) catch return 2;
                const right_num = std.fmt.parseInt(i64, right, 10) catch return 2;
                return if (left_num > right_num) 0 else 1;
            } else if (std.mem.eql(u8, op, "-ge")) {
                // Numeric greater than or equal
                const left_num = std.fmt.parseInt(i64, left, 10) catch return 2;
                const right_num = std.fmt.parseInt(i64, right, 10) catch return 2;
                return if (left_num >= right_num) 0 else 1;
            }
        }

        try IO.eprint("den: test: unsupported expression\n", .{});
        return 2;
    }

    fn builtinWhich(self: *Executor, command: *types.ParsedCommand) !i32 {
        if (command.args.len == 0) {
            try IO.eprint("den: which: missing argument\n", .{});
            return 1;
        }

        const utils = @import("../utils.zig");
        var found_all = true;

        for (command.args) |cmd_name| {
            // Check if it's a builtin
            if (self.isBuiltin(cmd_name)) {
                try IO.print("{s}: shell builtin command\n", .{cmd_name});
                continue;
            }

            // Parse PATH and find executable
            var path_list = utils.env.PathList.fromEnv(self.allocator) catch {
                try IO.eprint("den: which: failed to parse PATH\n", .{});
                return 1;
            };
            defer path_list.deinit();

            if (try path_list.findExecutable(self.allocator, cmd_name)) |exec_path| {
                defer self.allocator.free(exec_path);
                try IO.print("{s}\n", .{exec_path});
            } else {
                found_all = false;
            }
        }

        return if (found_all) 0 else 1;
    }

    fn builtinType(self: *Executor, command: *types.ParsedCommand) !i32 {
        if (command.args.len == 0) {
            try IO.eprint("den: type: missing argument\n", .{});
            return 1;
        }

        const utils = @import("../utils.zig");
        var found_all = true;

        for (command.args) |cmd_name| {
            // Check if it's a builtin
            if (self.isBuiltin(cmd_name)) {
                try IO.print("{s} is a shell builtin\n", .{cmd_name});
                continue;
            }

            // Check if it's in PATH
            var path_list = utils.env.PathList.fromEnv(self.allocator) catch {
                try IO.eprint("den: type: failed to parse PATH\n", .{});
                return 1;
            };
            defer path_list.deinit();

            if (try path_list.findExecutable(self.allocator, cmd_name)) |exec_path| {
                defer self.allocator.free(exec_path);
                try IO.print("{s} is {s}\n", .{ cmd_name, exec_path });
            } else {
                try IO.print("den: type: {s}: not found\n", .{cmd_name});
                found_all = false;
            }
        }

        return if (found_all) 0 else 1;
    }

    fn builtinHelp(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        _ = command;

        try IO.print("Den Shell - Built-in Commands:\n\n", .{});
        try IO.print("Core:\n", .{});
        try IO.print("  cd [dir]          Change directory\n", .{});
        try IO.print("  pwd               Print working directory\n", .{});
        try IO.print("  echo [args...]    Print arguments\n", .{});
        try IO.print("  exit [n]          Exit shell with status n\n", .{});
        try IO.print("  env               Print environment variables\n", .{});
        try IO.print("  export VAR=val    Export environment variable\n", .{});
        try IO.print("  set [opts]        Set shell options or variables\n", .{});
        try IO.print("  unset VAR         Unset environment variable\n", .{});
        try IO.print("\nControl:\n", .{});
        try IO.print("  true              Return success (0)\n", .{});
        try IO.print("  false             Return failure (1)\n", .{});
        try IO.print("  test / [          Evaluate conditional expression\n", .{});
        try IO.print("  eval CMD          Evaluate and execute command string\n", .{});
        try IO.print("  exec CMD          Replace shell with command\n", .{});
        try IO.print("\nInformation:\n", .{});
        try IO.print("  which CMD         Locate a command\n", .{});
        try IO.print("  type CMD          Display command type\n", .{});
        try IO.print("  command [-pVv]    Run command with options\n", .{});
        try IO.print("  builtin CMD       Run builtin command\n", .{});
        try IO.print("  help              Display this help message\n", .{});
        try IO.print("  hash              Command hash table\n", .{});
        try IO.print("\nI/O:\n", .{});
        try IO.print("  read VAR          Read line into variable\n", .{});
        try IO.print("  printf fmt [args] Formatted print\n", .{});
        try IO.print("  clear             Clear the screen\n", .{});
        try IO.print("\nJob Control:\n", .{});
        try IO.print("  jobs              List active jobs\n", .{});
        try IO.print("  fg [job]          Foreground a job\n", .{});
        try IO.print("  bg [job]          Background a job\n", .{});
        try IO.print("  wait [pid]        Wait for process completion\n", .{});
        try IO.print("  disown [job]      Remove job from table\n", .{});
        try IO.print("  kill [-sig] pid   Send signal to process\n", .{});
        try IO.print("\nDirectory Stack:\n", .{});
        try IO.print("  pushd [dir]       Push directory onto stack\n", .{});
        try IO.print("  popd              Pop directory from stack\n", .{});
        try IO.print("  dirs              Display directory stack\n", .{});
        try IO.print("\nAdvanced:\n", .{});
        try IO.print("  alias [name=val]  Create or display aliases\n", .{});
        try IO.print("  unalias name      Remove alias\n", .{});
        try IO.print("  source / . file   Execute commands from file\n", .{});
        try IO.print("  history           Display command history\n", .{});
        try IO.print("  time CMD          Time command execution\n", .{});
        try IO.print("  times             Print process times\n", .{});
        try IO.print("  trap              Set signal handlers\n", .{});
        try IO.print("  umask [mask]      Set file creation mask\n", .{});
        try IO.print("  getopts           Parse command options\n", .{});
        try IO.print("\nUtility:\n", .{});
        try IO.print("  yes [str]         Repeatedly output string\n", .{});
        try IO.print("  reload            Reload shell configuration\n", .{});

        return 0;
    }

    fn builtinAlias(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        if (command.args.len == 0) {
            // TODO: Display all aliases when we have alias storage
            try IO.print("den: alias: alias storage not yet implemented\n", .{});
            return 0;
        }

        // TODO: Implement alias storage and expansion
        try IO.print("den: alias: not yet fully implemented\n", .{});
        return 1;
    }

    fn builtinUnalias(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        if (command.args.len == 0) {
            try IO.eprint("den: unalias: missing argument\n", .{});
            return 1;
        }

        // TODO: Implement alias storage and removal
        try IO.print("den: unalias: not yet fully implemented\n", .{});
        return 1;
    }

    fn builtinRead(self: *Executor, command: *types.ParsedCommand) !i32 {
        if (command.args.len == 0) {
            try IO.eprint("den: read: missing variable name\n", .{});
            return 1;
        }

        const var_name = command.args[0];

        // Read a line from stdin using IO utility
        const line_opt = try IO.readLine(self.allocator);
        if (line_opt) |line| {
            defer self.allocator.free(line);

            // Store in environment (dupe again since we're freeing line)
            const value = try self.allocator.dupe(u8, line);
            const gop = try self.environment.getOrPut(var_name);
            if (gop.found_existing) {
                self.allocator.free(gop.value_ptr.*);
                gop.value_ptr.* = value;
            } else {
                const key = try self.allocator.dupe(u8, var_name);
                gop.key_ptr.* = key;
                gop.value_ptr.* = value;
            }
        } else {
            // EOF - set to empty string
            const value = try self.allocator.dupe(u8, "");
            const gop = try self.environment.getOrPut(var_name);
            if (gop.found_existing) {
                self.allocator.free(gop.value_ptr.*);
                gop.value_ptr.* = value;
            } else {
                const key = try self.allocator.dupe(u8, var_name);
                gop.key_ptr.* = key;
                gop.value_ptr.* = value;
            }
        }

        return 0;
    }

    fn builtinPrintf(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        if (command.args.len == 0) {
            try IO.eprint("den: printf: missing format string\n", .{});
            return 1;
        }

        const format = command.args[0];
        var arg_idx: usize = 1;
        var i: usize = 0;

        while (i < format.len) {
            if (format[i] == '%' and i + 1 < format.len) {
                const spec = format[i + 1];
                if (spec == 's') {
                    // String format
                    if (arg_idx < command.args.len) {
                        try IO.print("{s}", .{command.args[arg_idx]});
                        arg_idx += 1;
                    }
                    i += 2;
                } else if (spec == 'd' or spec == 'i') {
                    // Integer format
                    if (arg_idx < command.args.len) {
                        const num = std.fmt.parseInt(i64, command.args[arg_idx], 10) catch 0;
                        try IO.print("{d}", .{num});
                        arg_idx += 1;
                    }
                    i += 2;
                } else if (spec == '%') {
                    // Escaped %
                    try IO.print("%", .{});
                    i += 2;
                } else if (spec == 'n') {
                    // Newline
                    try IO.print("\n", .{});
                    i += 2;
                } else {
                    // Unknown format, just print it
                    try IO.print("{c}", .{format[i]});
                    i += 1;
                }
            } else if (format[i] == '\\' and i + 1 < format.len) {
                const esc = format[i + 1];
                if (esc == 'n') {
                    try IO.print("\n", .{});
                    i += 2;
                } else if (esc == 't') {
                    try IO.print("\t", .{});
                    i += 2;
                } else if (esc == '\\') {
                    try IO.print("\\", .{});
                    i += 2;
                } else {
                    try IO.print("{c}", .{format[i]});
                    i += 1;
                }
            } else {
                try IO.print("{c}", .{format[i]});
                i += 1;
            }
        }

        return 0;
    }

    fn builtinSource(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        if (command.args.len == 0) {
            try IO.eprint("den: source: missing filename\n", .{});
            return 1;
        }

        // TODO: Implement script execution from file
        try IO.print("den: source: not yet fully implemented\n", .{});
        return 1;
    }

    fn builtinHistory(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        _ = command;

        // TODO: Implement history display when we have history storage
        try IO.print("den: history: not yet fully implemented\n", .{});
        return 0;
    }

    fn builtinPushd(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        _ = command;

        // TODO: Implement directory stack when we have it in Shell
        try IO.print("den: pushd: not yet fully implemented\n", .{});
        return 1;
    }

    fn builtinPopd(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        _ = command;

        // TODO: Implement directory stack when we have it in Shell
        try IO.print("den: popd: not yet fully implemented\n", .{});
        return 1;
    }

    fn builtinDirs(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        _ = command;

        // TODO: Implement directory stack when we have it in Shell
        try IO.print("den: dirs: not yet fully implemented\n", .{});
        return 0;
    }

    fn builtinEval(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        if (command.args.len == 0) {
            return 0;
        }

        // TODO: Implement eval - needs parser integration to parse and execute the concatenated args
        try IO.print("den: eval: not yet fully implemented\n", .{});
        return 1;
    }

    fn builtinExec(self: *Executor, command: *types.ParsedCommand) !i32 {
        if (command.args.len == 0) {
            // exec with no args - do nothing
            return 0;
        }

        // exec replaces the current shell process with the command
        // For now, just execute the command - actual exec would replace process
        // TODO: Use std.posix.execve to actually replace the process
        var new_cmd = types.ParsedCommand{
            .name = command.args[0],
            .args = if (command.args.len > 1) command.args[1..] else &[_][]const u8{},
            .redirections = command.redirections,
        };

        // For now, just run the command and return its exit code
        // In a real implementation, this would never return
        return try self.executeExternal(&new_cmd);
    }

    fn builtinCommand(self: *Executor, command: *types.ParsedCommand) !i32 {
        // command [-pVv] command_name [args...]
        // -p: use default PATH
        // -V: verbose output (like type)
        // -v: short output (like which)

        if (command.args.len == 0) {
            try IO.eprint("den: command: missing argument\n", .{});
            return 1;
        }

        var verbose = false;
        var short_output = false;
        var use_default_path = false;
        var start_idx: usize = 0;

        // Parse flags
        for (command.args, 0..) |arg, i| {
            if (arg.len > 0 and arg[0] == '-') {
                for (arg[1..]) |c| {
                    if (c == 'V') verbose = true
                    else if (c == 'v') short_output = true
                    else if (c == 'p') use_default_path = true
                    else {
                        try IO.eprint("den: command: invalid option: -{c}\n", .{c});
                        return 1;
                    }
                }
                start_idx = i + 1;
            } else {
                break;
            }
        }

        if (start_idx >= command.args.len) {
            try IO.eprint("den: command: missing command name\n", .{});
            return 1;
        }

        const cmd_name = command.args[start_idx];

        // TODO: implement -p flag (use default PATH)
        if (use_default_path) {
            // Not yet implemented
        }

        if (verbose or short_output) {
            // Act like type/which
            if (self.isBuiltin(cmd_name)) {
                if (verbose) {
                    try IO.print("{s} is a shell builtin\n", .{cmd_name});
                } else {
                    try IO.print("{s}\n", .{cmd_name});
                }
                return 0;
            }

            // Check PATH
            const utils = @import("../utils.zig");
            var path_list = utils.env.PathList.fromEnv(self.allocator) catch {
                return 1;
            };
            defer path_list.deinit();

            if (try path_list.findExecutable(self.allocator, cmd_name)) |exec_path| {
                defer self.allocator.free(exec_path);
                try IO.print("{s}\n", .{exec_path});
                return 0;
            }

            return 1;
        }

        // Execute the command, skipping builtins
        var new_cmd = types.ParsedCommand{
            .name = cmd_name,
            .args = if (start_idx + 1 < command.args.len) command.args[start_idx + 1..] else &[_][]const u8{},
            .redirections = command.redirections,
        };

        return try self.executeExternal(&new_cmd);
    }

    fn builtinBuiltin(self: *Executor, command: *types.ParsedCommand) !i32 {
        // The 'builtin' command is used to bypass shell functions and aliases
        // and execute a builtin directly. Since we don't have functions or aliases yet,
        // this is effectively a no-op. Just validate the builtin name exists.
        if (command.args.len == 0) {
            try IO.eprint("den: builtin: missing argument\n", .{});
            return 1;
        }

        const builtin_name = command.args[0];
        if (!self.isBuiltin(builtin_name)) {
            try IO.eprint("den: builtin: {s}: not a shell builtin\n", .{builtin_name});
            return 1;
        }

        // TODO: When we add functions and aliases, we'll need to execute the builtin
        // For now, just confirm it exists
        try IO.print("den: builtin '{s}' exists\n", .{builtin_name});
        return 0;
    }

    fn builtinJobs(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        _ = command;

        // TODO: Implement job control when we have job tracking in Shell
        try IO.print("den: jobs: not yet fully implemented\n", .{});
        return 0;
    }

    fn builtinFg(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        _ = command;

        // TODO: Implement job control when we have job tracking in Shell
        try IO.print("den: fg: not yet fully implemented\n", .{});
        return 1;
    }

    fn builtinBg(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        _ = command;

        // TODO: Implement job control when we have job tracking in Shell
        try IO.print("den: bg: not yet fully implemented\n", .{});
        return 1;
    }

    fn builtinWait(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        _ = command;

        // TODO: Implement job control when we have job tracking in Shell
        try IO.print("den: wait: not yet fully implemented\n", .{});
        return 0;
    }

    fn builtinDisown(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        _ = command;

        // TODO: Implement job control when we have job tracking in Shell
        try IO.print("den: disown: not yet fully implemented\n", .{});
        return 0;
    }

    fn builtinKill(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        if (command.args.len == 0) {
            try IO.eprint("den: kill: missing argument\n", .{});
            return 1;
        }

        var signal: u8 = std.posix.SIG.TERM;
        var start_idx: usize = 0;

        // Parse signal if provided
        if (command.args[0].len > 0 and command.args[0][0] == '-') {
            const sig_str = command.args[0][1..];
            if (sig_str.len > 0) {
                // Try to parse as number
                signal = std.fmt.parseInt(u8, sig_str, 10) catch blk: {
                    // Try to parse as signal name
                    if (std.mem.eql(u8, sig_str, "HUP")) break :blk std.posix.SIG.HUP
                    else if (std.mem.eql(u8, sig_str, "INT")) break :blk std.posix.SIG.INT
                    else if (std.mem.eql(u8, sig_str, "QUIT")) break :blk std.posix.SIG.QUIT
                    else if (std.mem.eql(u8, sig_str, "KILL")) break :blk std.posix.SIG.KILL
                    else if (std.mem.eql(u8, sig_str, "TERM")) break :blk std.posix.SIG.TERM
                    else if (std.mem.eql(u8, sig_str, "STOP")) break :blk std.posix.SIG.STOP
                    else if (std.mem.eql(u8, sig_str, "CONT")) break :blk std.posix.SIG.CONT
                    else {
                        try IO.eprint("den: kill: invalid signal: {s}\n", .{sig_str});
                        return 1;
                    }
                };
            }
            start_idx = 1;
        }

        if (start_idx >= command.args.len) {
            try IO.eprint("den: kill: missing process ID\n", .{});
            return 1;
        }

        // Send signal to each PID
        for (command.args[start_idx..]) |pid_str| {
            const pid = std.fmt.parseInt(std.posix.pid_t, pid_str, 10) catch {
                try IO.eprint("den: kill: invalid process ID: {s}\n", .{pid_str});
                continue;
            };

            std.posix.kill(pid, signal) catch |err| {
                try IO.eprint("den: kill: ({d}): {}\n", .{ pid, err });
                return 1;
            };
        }

        return 0;
    }

    fn builtinTrap(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        _ = command;

        // TODO: Implement signal trapping when we have trap handler storage
        try IO.print("den: trap: not yet fully implemented\n", .{});
        return 0;
    }

    fn builtinTimes(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        _ = command;

        // Print shell and children process times
        // For now, just print placeholder
        try IO.print("0m0.000s 0m0.000s\n", .{});
        try IO.print("0m0.000s 0m0.000s\n", .{});
        return 0;
    }

    fn builtinUmask(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;

        if (command.args.len == 0) {
            // Print current umask
            if (builtin.os.tag == .windows) {
                try IO.print("den: umask: not supported on Windows\n", .{});
                return 1;
            }

            const current = std.c.umask(0);
            _ = std.c.umask(current);
            try IO.print("{o:0>4}\n", .{current});
            return 0;
        }

        // Set umask
        const mask_str = command.args[0];
        const mask = std.fmt.parseInt(std.c.mode_t, mask_str, 8) catch {
            try IO.eprint("den: umask: invalid mask: {s}\n", .{mask_str});
            return 1;
        };

        if (builtin.os.tag == .windows) {
            try IO.print("den: umask: not supported on Windows\n", .{});
            return 1;
        }

        _ = std.c.umask(mask);
        return 0;
    }

    fn builtinGetopts(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        _ = command;

        // TODO: Implement getopts for option parsing
        try IO.print("den: getopts: not yet fully implemented\n", .{});
        return 1;
    }

    fn builtinClear(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        _ = command;

        const utils = @import("../utils.zig");

        // Use ANSI escape sequences to clear screen
        try IO.print("{s}", .{utils.ansi.Sequences.clear_screen});
        try IO.print("{s}", .{utils.ansi.Sequences.cursor_home});

        return 0;
    }

    fn builtinTime(self: *Executor, command: *types.ParsedCommand) !i32 {
        if (command.args.len == 0) {
            try IO.eprint("den: time: missing command\n", .{});
            return 1;
        }

        // Time the execution of an external command
        // For now, we only support timing external commands to avoid circular dependencies
        const start_time = std.time.nanoTimestamp();

        var new_cmd = types.ParsedCommand{
            .name = command.args[0],
            .args = if (command.args.len > 1) command.args[1..] else &[_][]const u8{},
            .redirections = command.redirections,
        };

        // Execute as external command to avoid recursive error set inference
        const exit_code = try self.executeExternal(&new_cmd);

        const end_time = std.time.nanoTimestamp();
        const elapsed_ns = end_time - start_time;
        const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

        try IO.eprint("\nreal\t{d:.3}s\n", .{elapsed_s});
        try IO.eprint("user\t0.000s\n", .{});
        try IO.eprint("sys\t0.000s\n", .{});

        return exit_code;
    }

    fn builtinHash(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        _ = command;

        // TODO: Implement command hash table for faster lookups
        try IO.print("den: hash: not yet fully implemented\n", .{});
        return 0;
    }

    fn builtinYes(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;

        const output = if (command.args.len > 0) command.args[0] else "y";

        // Print the string repeatedly until interrupted
        while (true) {
            try IO.print("{s}\n", .{output});
        }

        return 0;
    }

    fn builtinReload(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        _ = command;

        // TODO: Implement shell reload (re-read config files)
        try IO.print("den: reload: not yet fully implemented\n", .{});
        return 0;
    }

    fn executeExternal(self: *Executor, command: *types.ParsedCommand) !i32 {
        if (builtin.os.tag == .windows) {
            return try self.executeExternalWindows(command);
        }
        return try self.executeExternalPosix(command);
    }

    fn executeExternalWindows(self: *Executor, command: *types.ParsedCommand) !i32 {
        // Build argv list
        var argv_list: std.ArrayList([]const u8) = .{};
        defer argv_list.deinit(self.allocator);

        try argv_list.append(self.allocator, command.name);
        for (command.args) |arg| {
            try argv_list.append(self.allocator, arg);
        }

        // Create child process
        var child = std.process.Child.init(argv_list.items, self.allocator);

        // Handle redirections (full support including FD duplication)
        var stdout_file: ?std.fs.File = null;
        for (command.redirections) |redir| {
            switch (redir.kind) {
                .output_truncate, .output_append => {
                    const file = try std.fs.cwd().createFile(redir.target, .{
                        .truncate = (redir.kind == .output_truncate),
                    });
                    if (redir.fd == 1) {
                        child.stdout = file;
                        stdout_file = file;
                    } else if (redir.fd == 2) {
                        child.stderr = file;
                    }
                },
                .input => {
                    const file = try std.fs.cwd().openFile(redir.target, .{});
                    child.stdin = file;
                },
                .fd_duplicate => {
                    // Handle 2>&1 (redirect stderr to stdout)
                    if (redir.fd == 2 and std.mem.eql(u8, redir.target, "1")) {
                        if (stdout_file) |f| {
                            child.stderr = f;
                        } else {
                            // stderr follows stdout (both inherit or both go to same pipe)
                            child.stderr_behavior = child.stdout_behavior;
                        }
                    }
                },
                else => {},
            }
        }

        try child.spawn();
        const term = try child.wait();

        return switch (term) {
            .Exited => |code| code,
            else => 1,
        };
    }

    fn executeExternalPosix(self: *Executor, command: *types.ParsedCommand) !i32 {
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

        if (builtin.os.tag == .windows) {
            return try self.executeCommandBackgroundWindows(command);
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

    fn executeBuiltinWithRedirectionsWindows(self: *Executor, command: *types.ParsedCommand) !i32 {
        // Windows SetStdHandle is not exposed in Zig std lib yet
        // For now, we'll use a simpler approach: pass file handles to builtins
        // This requires refactoring builtins to accept optional output files
        // For initial implementation, execute builtins without redirections on Windows
        // TODO: Refactor builtins to accept File parameters for proper redirection support

        // For now, just check if there are redirections and warn if so
        if (command.redirections.len > 0) {
            try IO.print("Warning: Builtin redirections not yet fully supported on Windows\n", .{});
        }

        return try self.executeBuiltin(command);
    }

    fn executeCommandBackgroundWindows(self: *Executor, command: *types.ParsedCommand) !void {
        // Build argv list
        var argv_list: std.ArrayList([]const u8) = .{};
        defer argv_list.deinit(self.allocator);

        try argv_list.append(self.allocator, command.name);
        for (command.args) |arg| {
            try argv_list.append(self.allocator, arg);
        }

        // Create detached child process
        var child = std.process.Child.init(argv_list.items, self.allocator);

        // Detach from parent - don't wait for it
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        // Handle redirections
        for (command.redirections) |redir| {
            switch (redir.kind) {
                .output_truncate, .output_append => {
                    const file = try std.fs.cwd().createFile(redir.target, .{
                        .truncate = (redir.kind == .output_truncate),
                    });
                    if (redir.fd == 1) {
                        child.stdout_behavior = .Ignore;
                        child.stdout = file;
                    } else if (redir.fd == 2) {
                        child.stderr_behavior = .Ignore;
                        child.stderr = file;
                    }
                },
                .input => {
                    const file = try std.fs.cwd().openFile(redir.target, .{});
                    child.stdin_behavior = .Ignore;
                    child.stdin = file;
                },
                else => {},
            }
        }

        try child.spawn();

        // On Windows, process handle serves as the ID
        const handle = child.id;
        try IO.print("[{d}]\n", .{@intFromPtr(handle)});

        // Detach - don't wait for completion
        // The process will continue running independently
    }
};
