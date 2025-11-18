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

        // Check if it's a directory path (auto cd feature, like zsh)
        if (try self.isDirectory(command.name)) {
            // Auto cd to the directory
            var args = [_][]const u8{command.name};
            var redirections = [_]types.Redirection{};
            var cd_command = types.ParsedCommand{
                .name = "cd",
                .args = args[0..],
                .redirections = redirections[0..],
                .type = .builtin,
            };
            return try self.executeBuiltin(&cd_command);
        }

        // Execute external command
        return try self.executeExternal(command);
    }

    fn isDirectory(self: *Executor, path: []const u8) !bool {
        _ = self;

        // Handle special directory shortcuts
        if (std.mem.eql(u8, path, "..") or
            std.mem.eql(u8, path, "../") or
            std.mem.eql(u8, path, ".") or
            std.mem.eql(u8, path, "./") or
            std.mem.eql(u8, path, "-"))
        {
            return true;
        }

        // Handle tilde expansion
        if (path.len > 0 and path[0] == '~') {
            return true;
        }

        // Check if it's a valid directory path
        // Try to open as directory
        var dir = std.fs.cwd().openDir(path, .{}) catch {
            // Not a directory or doesn't exist
            return false;
        };
        dir.close();
        return true;
    }

    fn isBuiltin(self: *Executor, name: []const u8) bool {
        _ = self;
        const builtins = [_][]const u8{
            "cd", "pwd", "echo", "exit", "env", "export", "set", "unset",
            "true", "false", "test", "[", "alias", "unalias", "which",
            "type", "help", "read", "printf", "source", ".", "history",
            "pushd", "popd", "dirs", "eval", "exec", "command", "builtin",
            "jobs", "fg", "bg", "wait", "disown", "kill", "trap", "times",
            "umask", "getopts", "clear", "time", "hash", "yes", "reload",
            "watch", "tree", "grep", "find", "calc", "json", "ls",
            "seq", "date", "parallel", "http", "base64", "uuid"
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
        } else if (std.mem.eql(u8, command.name, "watch")) {
            return try self.builtinWatch(command);
        } else if (std.mem.eql(u8, command.name, "tree")) {
            return try self.builtinTree(command);
        } else if (std.mem.eql(u8, command.name, "grep")) {
            return try self.builtinGrep(command);
        } else if (std.mem.eql(u8, command.name, "find")) {
            return try self.builtinFind(command);
        } else if (std.mem.eql(u8, command.name, "calc")) {
            return try self.builtinCalc(command);
        } else if (std.mem.eql(u8, command.name, "json")) {
            return try self.builtinJson(command);
        } else if (std.mem.eql(u8, command.name, "ls")) {
            return try self.builtinLs(command);
        } else if (std.mem.eql(u8, command.name, "seq")) {
            return try self.builtinSeq(command);
        } else if (std.mem.eql(u8, command.name, "date")) {
            return try self.builtinDate(command);
        } else if (std.mem.eql(u8, command.name, "parallel")) {
            return try self.builtinParallel(command);
        } else if (std.mem.eql(u8, command.name, "http")) {
            return try self.builtinHttp(command);
        } else if (std.mem.eql(u8, command.name, "base64")) {
            return try self.builtinBase64(command);
        } else if (std.mem.eql(u8, command.name, "uuid")) {
            return try self.builtinUuid(command);
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
        const shell_ref = self.shell orelse {
            try IO.eprint("den: alias: shell context not available\n", .{});
            return 1;
        };

        if (command.args.len == 0) {
            // Display all aliases
            if (shell_ref.aliases.count() == 0) {
                return 0;
            }

            var iter = shell_ref.aliases.iterator();
            while (iter.next()) |entry| {
                try IO.print("alias {s}='{s}'\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
            return 0;
        }

        // Parse alias definition: name=value
        const arg = command.args[0];
        const eq_pos = std.mem.indexOf(u8, arg, "=") orelse {
            // No '=', just show the alias value
            if (shell_ref.aliases.get(arg)) |value| {
                try IO.print("alias {s}='{s}'\n", .{ arg, value });
            } else {
                try IO.eprint("den: alias: {s}: not found\n", .{arg});
                return 1;
            }
            return 0;
        };

        const name = arg[0..eq_pos];
        const value = arg[eq_pos + 1 ..];

        // Store the alias
        const name_owned = try self.allocator.dupe(u8, name);
        const value_owned = try self.allocator.dupe(u8, value);

        const gop = try shell_ref.aliases.getOrPut(name_owned);
        if (gop.found_existing) {
            self.allocator.free(name_owned); // We don't need the new key
            self.allocator.free(gop.value_ptr.*); // Free old value
        }
        gop.value_ptr.* = value_owned;

        return 0;
    }

    fn builtinUnalias(self: *Executor, command: *types.ParsedCommand) !i32 {
        const shell_ref = self.shell orelse {
            try IO.eprint("den: unalias: shell context not available\n", .{});
            return 1;
        };

        if (command.args.len == 0) {
            try IO.eprint("den: unalias: missing argument\n", .{});
            return 1;
        }

        // Support -a flag to remove all aliases
        if (std.mem.eql(u8, command.args[0], "-a")) {
            var iter = shell_ref.aliases.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            shell_ref.aliases.clearRetainingCapacity();
            return 0;
        }

        // Remove specific alias
        for (command.args) |name| {
            if (shell_ref.aliases.fetchRemove(name)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value);
            } else {
                try IO.eprint("den: unalias: {s}: not found\n", .{name});
                return 1;
            }
        }

        return 0;
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
        const shell_ref = self.shell orelse {
            try IO.eprint("den: source: shell context not available\n", .{});
            return 1;
        };

        if (command.args.len == 0) {
            try IO.eprint("den: source: missing filename\n", .{});
            return 1;
        }

        const filename = command.args[0];
        const script_args = if (command.args.len > 1) command.args[1..] else &[_][]const u8{};

        // Execute using script manager
        const result = shell_ref.script_manager.executeScript(shell_ref, filename, script_args) catch |err| {
            try IO.eprint("den: source: error executing {s}: {}\n", .{ filename, err });
            return 1;
        };

        return result.exit_code;
    }

    fn builtinHistory(self: *Executor, command: *types.ParsedCommand) !i32 {
        const shell_ref = self.shell orelse {
            try IO.eprint("den: history: shell context not available\n", .{});
            return 1;
        };

        // Parse optional count argument
        var count: ?usize = null;
        if (command.args.len > 0) {
            count = std.fmt.parseInt(usize, command.args[0], 10) catch {
                try IO.eprint("den: history: invalid number: {s}\n", .{command.args[0]});
                return 1;
            };
        }

        // Display history
        const start_idx = if (count) |c|
            if (c < shell_ref.history_count) shell_ref.history_count - c else 0
        else
            0;

        var idx = start_idx;
        while (idx < shell_ref.history_count) : (idx += 1) {
            if (shell_ref.history[idx]) |entry| {
                try IO.print("  {d}  {s}\n", .{ idx + 1, entry });
            }
        }

        return 0;
    }

    fn builtinPushd(self: *Executor, command: *types.ParsedCommand) !i32 {
        const shell_ref = self.shell orelse {
            try IO.eprint("den: pushd: shell context not available\n", .{});
            return 1;
        };

        // Get current directory
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch |err| {
            try IO.eprint("den: pushd: cannot get current directory: {}\n", .{err});
            return 1;
        };

        if (command.args.len == 0) {
            // pushd with no args: swap top two dirs
            if (shell_ref.dir_stack_count == 0) {
                try IO.eprint("den: pushd: directory stack empty\n", .{});
                return 1;
            }

            const top_dir = shell_ref.dir_stack[shell_ref.dir_stack_count - 1] orelse unreachable;

            // Change to top dir
            std.posix.chdir(top_dir) catch |err| {
                try IO.eprint("den: pushd: {s}: {}\n", .{ top_dir, err });
                return 1;
            };

            // Update stack: replace top with current cwd
            self.allocator.free(shell_ref.dir_stack[shell_ref.dir_stack_count - 1].?);
            shell_ref.dir_stack[shell_ref.dir_stack_count - 1] = try self.allocator.dupe(u8, cwd);

            return 0;
        }

        // pushd <dir>: push current dir and cd to new dir
        const new_dir = command.args[0];

        // Change to new directory
        std.posix.chdir(new_dir) catch |err| {
            try IO.eprint("den: pushd: {s}: {}\n", .{ new_dir, err });
            return 1;
        };

        // Push current dir onto stack
        if (shell_ref.dir_stack_count >= shell_ref.dir_stack.len) {
            try IO.eprint("den: pushd: directory stack full\n", .{});
            return 1;
        }

        shell_ref.dir_stack[shell_ref.dir_stack_count] = try self.allocator.dupe(u8, cwd);
        shell_ref.dir_stack_count += 1;

        return 0;
    }

    fn builtinPopd(self: *Executor, command: *types.ParsedCommand) !i32 {
        const shell_ref = self.shell orelse {
            try IO.eprint("den: popd: shell context not available\n", .{});
            return 1;
        };

        _ = command;

        if (shell_ref.dir_stack_count == 0) {
            try IO.eprint("den: popd: directory stack empty\n", .{});
            return 1;
        }

        // Pop directory from stack
        shell_ref.dir_stack_count -= 1;
        const dir = shell_ref.dir_stack[shell_ref.dir_stack_count] orelse unreachable;
        defer self.allocator.free(dir);

        // Change to popped directory
        std.posix.chdir(dir) catch |err| {
            try IO.eprint("den: popd: {s}: {}\n", .{ dir, err });
            // Put it back on the stack since we failed
            shell_ref.dir_stack_count += 1;
            return 1;
        };

        shell_ref.dir_stack[shell_ref.dir_stack_count] = null;

        return 0;
    }

    fn builtinDirs(self: *Executor, command: *types.ParsedCommand) !i32 {
        const shell_ref = self.shell orelse {
            try IO.eprint("den: dirs: shell context not available\n", .{});
            return 1;
        };

        _ = command;

        // Print current directory first
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch |err| {
            try IO.eprint("den: dirs: cannot get current directory: {}\n", .{err});
            return 1;
        };
        try IO.print("{s}", .{cwd});

        // Print directory stack (from bottom to top)
        if (shell_ref.dir_stack_count > 0) {
            var i: usize = 0;
            while (i < shell_ref.dir_stack_count) : (i += 1) {
                if (shell_ref.dir_stack[i]) |dir| {
                    try IO.print(" {s}", .{dir});
                }
            }
        }

        try IO.print("\n", .{});

        return 0;
    }

    fn builtinEval(self: *Executor, command: *types.ParsedCommand) anyerror!i32 {
        const shell_ref = self.shell orelse {
            try IO.eprint("den: eval: shell context not available\n", .{});
            return 1;
        };

        if (command.args.len == 0) {
            return 0;
        }

        // Concatenate all args into a single command string
        var eval_str = std.ArrayList(u8){};
        defer eval_str.deinit(self.allocator);

        for (command.args, 0..) |arg, i| {
            try eval_str.appendSlice(self.allocator, arg);
            if (i < command.args.len - 1) {
                try eval_str.append(self.allocator, ' ');
            }
        }

        // Execute the concatenated string directly as a command
        _ = shell_ref.executeCommand(eval_str.items) catch {};

        return shell_ref.last_exit_code;
    }

    fn builtinExec(self: *Executor, command: *types.ParsedCommand) !i32 {
        if (command.args.len == 0) {
            // exec with no args - do nothing
            return 0;
        }

        const cmd_name = command.args[0];

        // Find the executable in PATH
        const path_var = std.posix.getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
        var path_iter = std.mem.splitScalar(u8, path_var, ':');

        var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var exe_path: ?[]const u8 = null;

        // Check if command contains a slash (is a path)
        if (std.mem.indexOf(u8, cmd_name, "/") != null) {
            exe_path = cmd_name;
        } else {
            // Search in PATH
            while (path_iter.next()) |dir| {
                const full_path = std.fmt.bufPrint(&exe_path_buf, "{s}/{s}", .{ dir, cmd_name }) catch continue;
                std.fs.accessAbsolute(full_path, .{}) catch continue;
                exe_path = full_path;
                break;
            }
        }

        if (exe_path == null) {
            try IO.eprint("den: exec: {s}: command not found\n", .{cmd_name});
            return 127;
        }

        // Build argv for execve
        const argv_len = command.args.len + 1;
        var argv = try self.allocator.alloc(?[*:0]const u8, argv_len);
        defer self.allocator.free(argv);

        // Allocate command name and args as null-terminated strings
        var arg_zs = try self.allocator.alloc([:0]u8, command.args.len);
        defer {
            for (arg_zs) |arg_z| {
                self.allocator.free(arg_z);
            }
            self.allocator.free(arg_zs);
        }

        for (command.args, 0..) |arg, i| {
            arg_zs[i] = try self.allocator.dupeZ(u8, arg);
            argv[i] = arg_zs[i].ptr;
        }
        argv[command.args.len] = null;

        // Build envp from current environment
        var env_count: usize = 0;
        if (self.shell) |shell_ref| {
            env_count = shell_ref.environment.count();
        }

        // Allocate envp array (+1 for null terminator)
        const envp_len = env_count + 1;
        var envp = try self.allocator.alloc(?[*:0]const u8, envp_len);
        defer self.allocator.free(envp);

        // Allocate storage for the environment strings
        var env_strings = try self.allocator.alloc([:0]u8, env_count);
        defer {
            for (env_strings) |env_str| {
                self.allocator.free(env_str);
            }
            self.allocator.free(env_strings);
        }

        // Build the environment strings
        if (self.shell) |shell_ref| {
            var env_iter = shell_ref.environment.iterator();
            var i: usize = 0;
            while (env_iter.next()) |entry| {
                const env_formatted = try std.fmt.allocPrint(self.allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
                defer self.allocator.free(env_formatted);
                env_strings[i] = try self.allocator.dupeZ(u8, env_formatted);
                envp[i] = env_strings[i].ptr;
                i += 1;
            }
        }
        envp[env_count] = null;

        const exe_path_z = try self.allocator.dupeZ(u8, exe_path.?);
        defer self.allocator.free(exe_path_z);

        // Replace the current process with the new program
        const result = std.posix.execveZ(exe_path_z.ptr, @ptrCast(argv.ptr), @ptrCast(envp.ptr));

        // If execve returns, it failed
        try IO.eprint("den: exec: {}\n", .{result});
        return 126;
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

        const utils = @import("../utils.zig");

        // -p flag: use default PATH instead of current PATH
        const default_path = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
        var path_to_use: []const u8 = undefined;

        if (use_default_path) {
            path_to_use = default_path;
        } else {
            path_to_use = std.posix.getenv("PATH") orelse default_path;
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

            // Check PATH (or default PATH if -p)
            var path_list = utils.env.PathList.parse(self.allocator, path_to_use) catch {
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

    fn builtinBuiltin(self: *Executor, command: *types.ParsedCommand) anyerror!i32 {
        // The 'builtin' command is used to bypass shell functions and aliases
        // and execute a builtin directly.
        if (command.args.len == 0) {
            try IO.eprint("den: builtin: missing argument\n", .{});
            return 1;
        }

        const builtin_name = command.args[0];
        if (!self.isBuiltin(builtin_name)) {
            try IO.eprint("den: builtin: {s}: not a shell builtin\n", .{builtin_name});
            return 1;
        }

        // Execute the builtin, bypassing alias/function resolution
        var builtin_cmd = types.ParsedCommand{
            .name = builtin_name,
            .args = if (command.args.len > 1) command.args[1..] else &[_][]const u8{},
            .redirections = command.redirections,
        };

        return try self.executeBuiltin(&builtin_cmd);
    }

    fn builtinJobs(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = command;
        const shell_ref = self.shell orelse {
            try IO.eprint("den: jobs: shell context not available\n", .{});
            return 1;
        };

        // List all background jobs
        if (shell_ref.background_jobs_count == 0) {
            return 0;
        }

        for (shell_ref.background_jobs, 0..) |maybe_job, i| {
            if (maybe_job) |job| {
                const status_str = switch (job.status) {
                    .running => "Running",
                    .stopped => "Stopped",
                    .done => "Done",
                };
                try IO.print("[{d}]  {s}                    {s}\n", .{ job.job_id, status_str, job.command });
            }
            _ = i;
        }
        return 0;
    }

    fn builtinFg(self: *Executor, command: *types.ParsedCommand) !i32 {
        const shell_ref = self.shell orelse {
            try IO.eprint("den: fg: shell context not available\n", .{});
            return 1;
        };

        if (shell_ref.background_jobs_count == 0) {
            try IO.eprint("den: fg: no current job\n", .{});
            return 1;
        }

        // Parse job ID or use most recent job
        var target_job_id: ?usize = null;
        if (command.args.len > 0) {
            const arg = command.args[0];
            if (arg.len > 0 and arg[0] == '%') {
                target_job_id = std.fmt.parseInt(usize, arg[1..], 10) catch {
                    try IO.eprint("den: fg: {s}: no such job\n", .{arg});
                    return 1;
                };
            } else {
                target_job_id = std.fmt.parseInt(usize, arg, 10) catch {
                    try IO.eprint("den: fg: {s}: no such job\n", .{arg});
                    return 1;
                };
            }
        }

        // Find the job to foreground
        var job_index: ?usize = null;
        if (target_job_id) |jid| {
            for (shell_ref.background_jobs, 0..) |maybe_job, i| {
                if (maybe_job) |job| {
                    if (job.job_id == jid) {
                        job_index = i;
                        break;
                    }
                }
            }
        } else {
            // Use most recent job
            var i = shell_ref.background_jobs.len;
            while (i > 0) {
                i -= 1;
                if (shell_ref.background_jobs[i]) |_| {
                    job_index = i;
                    break;
                }
            }
        }

        if (job_index == null) {
            try IO.eprint("den: fg: no such job\n", .{});
            return 1;
        }

        const job = shell_ref.background_jobs[job_index.?].?;
        try IO.print("{s}\n", .{job.command});

        // Wait for the process to complete
        const result = std.posix.waitpid(@intCast(job.pid), 0);
        shell_ref.last_exit_code = std.posix.W.EXITSTATUS(result.status);

        // Remove from job list
        self.allocator.free(job.command);
        shell_ref.background_jobs[job_index.?] = null;
        shell_ref.background_jobs_count -= 1;

        return shell_ref.last_exit_code;
    }

    fn builtinBg(self: *Executor, command: *types.ParsedCommand) !i32 {
        const shell_ref = self.shell orelse {
            try IO.eprint("den: bg: shell context not available\n", .{});
            return 1;
        };

        if (shell_ref.background_jobs_count == 0) {
            try IO.eprint("den: bg: no current job\n", .{});
            return 1;
        }

        // Parse job ID or use most recent stopped job
        var target_job_id: ?usize = null;
        if (command.args.len > 0) {
            const arg = command.args[0];
            if (arg.len > 0 and arg[0] == '%') {
                target_job_id = std.fmt.parseInt(usize, arg[1..], 10) catch {
                    try IO.eprint("den: bg: {s}: no such job\n", .{arg});
                    return 1;
                };
            } else {
                target_job_id = std.fmt.parseInt(usize, arg, 10) catch {
                    try IO.eprint("den: bg: {s}: no such job\n", .{arg});
                    return 1;
                };
            }
        }

        // Find the job to continue in background
        var job_index: ?usize = null;
        if (target_job_id) |jid| {
            for (shell_ref.background_jobs, 0..) |maybe_job, i| {
                if (maybe_job) |job| {
                    if (job.job_id == jid) {
                        job_index = i;
                        break;
                    }
                }
            }
        } else {
            // Use most recent stopped job
            var i = shell_ref.background_jobs.len;
            while (i > 0) {
                i -= 1;
                if (shell_ref.background_jobs[i]) |job| {
                    if (job.status == .stopped) {
                        job_index = i;
                        break;
                    }
                }
            }
        }

        if (job_index == null) {
            try IO.eprint("den: bg: no such job\n", .{});
            return 1;
        }

        var job = &shell_ref.background_jobs[job_index.?].?;

        // Send SIGCONT to continue the process
        std.posix.kill(@intCast(job.pid), std.posix.SIG.CONT) catch |err| {
            try IO.eprint("den: bg: failed to continue job: {}\n", .{err});
            return 1;
        };

        job.status = .running;
        try IO.print("[{d}] {s} &\n", .{ job.job_id, job.command });

        return 0;
    }

    fn builtinWait(self: *Executor, command: *types.ParsedCommand) !i32 {
        const shell_ref = self.shell orelse {
            try IO.eprint("den: wait: shell context not available\n", .{});
            return 1;
        };

        // If no arguments, wait for all background jobs
        if (command.args.len == 0) {
            var last_status: i32 = 0;
            for (shell_ref.background_jobs, 0..) |maybe_job, i| {
                if (maybe_job) |job| {
                    if (job.status == .running) {
                        const result = std.posix.waitpid(@intCast(job.pid), 0);
                        last_status = std.posix.W.EXITSTATUS(result.status);
                        self.allocator.free(job.command);
                        shell_ref.background_jobs[i] = null;
                        shell_ref.background_jobs_count -= 1;
                    }
                }
            }
            return last_status;
        }

        // Wait for specific job(s)
        for (command.args) |arg| {
            // Parse job ID or PID
            var target_pid: std.posix.pid_t = 0;

            if (arg.len > 0 and arg[0] == '%') {
                const job_id = std.fmt.parseInt(usize, arg[1..], 10) catch {
                    try IO.eprint("den: wait: {s}: no such job\n", .{arg});
                    continue;
                };

                // Find job by ID
                var found = false;
                for (shell_ref.background_jobs) |maybe_job| {
                    if (maybe_job) |job| {
                        if (job.job_id == job_id) {
                            target_pid = @intCast(job.pid);
                            found = true;
                            break;
                        }
                    }
                }

                if (!found) {
                    try IO.eprint("den: wait: {s}: no such job\n", .{arg});
                    continue;
                }
            } else {
                target_pid = @intCast(std.fmt.parseInt(i32, arg, 10) catch {
                    try IO.eprint("den: wait: {s}: not a pid or valid job spec\n", .{arg});
                    continue;
                });
            }

            // Wait for the process
            const result = std.posix.waitpid(target_pid, 0);
            shell_ref.last_exit_code = std.posix.W.EXITSTATUS(result.status);

            // Remove from job list
            for (shell_ref.background_jobs, 0..) |maybe_job, i| {
                if (maybe_job) |job| {
                    if (@as(i32, @intCast(job.pid)) == target_pid) {
                        self.allocator.free(job.command);
                        shell_ref.background_jobs[i] = null;
                        shell_ref.background_jobs_count -= 1;
                        break;
                    }
                }
            }
        }

        return 0;
    }

    fn builtinDisown(self: *Executor, command: *types.ParsedCommand) !i32 {
        const shell_ref = self.shell orelse {
            try IO.eprint("den: disown: shell context not available\n", .{});
            return 1;
        };

        // If no arguments, disown all jobs
        if (command.args.len == 0) {
            for (shell_ref.background_jobs, 0..) |maybe_job, i| {
                if (maybe_job) |job| {
                    self.allocator.free(job.command);
                    shell_ref.background_jobs[i] = null;
                    shell_ref.background_jobs_count -= 1;
                }
            }
            return 0;
        }

        // Disown specific job(s)
        for (command.args) |arg| {
            var target_job_id: usize = 0;

            if (arg.len > 0 and arg[0] == '%') {
                target_job_id = std.fmt.parseInt(usize, arg[1..], 10) catch {
                    try IO.eprint("den: disown: {s}: no such job\n", .{arg});
                    continue;
                };
            } else {
                target_job_id = std.fmt.parseInt(usize, arg, 10) catch {
                    try IO.eprint("den: disown: {s}: not a valid job spec\n", .{arg});
                    continue;
                };
            }

            // Find and remove job
            var found = false;
            for (shell_ref.background_jobs, 0..) |maybe_job, i| {
                if (maybe_job) |job| {
                    if (job.job_id == target_job_id) {
                        self.allocator.free(job.command);
                        shell_ref.background_jobs[i] = null;
                        shell_ref.background_jobs_count -= 1;
                        found = true;
                        break;
                    }
                }
            }

            if (!found) {
                try IO.eprint("den: disown: {s}: no such job\n", .{arg});
            }
        }

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

    fn builtinTrap(self: *Executor, command: *types.ParsedCommand) anyerror!i32 {
        const shell_ref = self.shell orelse {
            try IO.eprint("den: trap: shell context not available\n", .{});
            return 1;
        };

        // If no arguments, list all traps
        if (command.args.len == 0) {
            var iter = shell_ref.signal_handlers.iterator();
            while (iter.next()) |entry| {
                const signal = entry.key_ptr.*;
                const action = entry.value_ptr.*;
                if (action.len > 0) {
                    try IO.print("trap -- '{s}' {s}\n", .{ action, signal });
                } else {
                    try IO.print("trap -- '' {s}\n", .{signal});
                }
            }
            return 0;
        }

        var start_idx: usize = 0;

        // Skip '--' if present (POSIX compatibility)
        if (std.mem.eql(u8, command.args[0], "--")) {
            start_idx = 1;
            if (command.args.len == 1) {
                try IO.eprint("den: trap: usage: trap [-lp] [[arg] signal_spec ...]\n", .{});
                return 1;
            }
        }

        // Handle -l flag (list signal names)
        if (std.mem.eql(u8, command.args[start_idx], "-l") or std.mem.eql(u8, command.args[start_idx], "--list")) {
            const signal_names = [_][]const u8{
                "HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT", "BUS", "FPE",
                "KILL", "USR1", "SEGV", "USR2", "PIPE", "ALRM", "TERM",
                "CHLD", "CONT", "STOP", "TSTP", "TTIN", "TTOU", "URG",
                "XCPU", "XFSZ", "VTALRM", "PROF", "WINCH", "IO", "SYS",
            };
            for (signal_names, 0..) |sig, i| {
                try IO.print("{d}) {s}\n", .{ i + 1, sig });
            }
            return 0;
        }

        // Handle -p flag (print trap commands)
        if (std.mem.eql(u8, command.args[start_idx], "-p") or std.mem.eql(u8, command.args[start_idx], "--print")) {
            if (command.args.len <= start_idx + 1) {
                return 0;
            }
            for (command.args[start_idx + 1 ..]) |signal| {
                if (shell_ref.signal_handlers.get(signal)) |action| {
                    try IO.print("trap -- '{s}' {s}\n", .{ action, signal });
                }
            }
            return 0;
        }

        // Need at least 2 args: action and signal
        if (command.args.len < start_idx + 2) {
            try IO.eprint("den: trap: usage: trap [-lp] [[arg] signal_spec ...]\n", .{});
            return 1;
        }

        const action = command.args[start_idx];
        const signals = command.args[start_idx + 1 ..];

        // Handle empty string action - remove the trap
        if (action.len == 0) {
            for (signals) |signal| {
                if (shell_ref.signal_handlers.fetchRemove(signal)) |kv| {
                    self.allocator.free(kv.key);
                    self.allocator.free(kv.value);
                }
            }
            return 0;
        }

        // Handle '-' action - reset to default handler
        if (std.mem.eql(u8, action, "-")) {
            for (signals) |signal| {
                const sig_key = try self.allocator.dupe(u8, signal);
                errdefer self.allocator.free(sig_key);
                const sig_value = try self.allocator.dupe(u8, "");

                // Remove existing handler if present
                if (shell_ref.signal_handlers.fetchRemove(signal)) |kv| {
                    self.allocator.free(kv.key);
                    self.allocator.free(kv.value);
                }

                try shell_ref.signal_handlers.put(sig_key, sig_value);
            }
            return 0;
        }

        // Set up the trap
        for (signals) |signal| {
            const sig_key = try self.allocator.dupe(u8, signal);
            errdefer self.allocator.free(sig_key);
            const sig_value = try self.allocator.dupe(u8, action);

            // Remove existing handler if present
            if (shell_ref.signal_handlers.fetchRemove(signal)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value);
            }

            try shell_ref.signal_handlers.put(sig_key, sig_value);
        }

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

    fn builtinGetopts(self: *Executor, command: *types.ParsedCommand) anyerror!i32 {
        const shell_ref = self.shell orelse {
            try IO.eprint("den: getopts: shell context not available\n", .{});
            return 1;
        };

        // getopts optstring name [args...]
        if (command.args.len < 2) {
            try IO.eprint("den: getopts: usage: getopts optstring name [args]\n", .{});
            return 2;
        }

        const optstring = command.args[0];
        const var_name = command.args[1];
        const params = if (command.args.len > 2) command.args[2..] else &[_][]const u8{};

        // Get OPTIND from environment (defaults to 1)
        const optind_str = shell_ref.environment.get("OPTIND") orelse "1";
        const optind = std.fmt.parseInt(usize, optind_str, 10) catch 1;

        // Check if we're past the end of params
        if (optind > params.len) {
            try shell_ref.environment.put("OPTARG", try self.allocator.dupe(u8, ""));
            return 1;
        }

        const current = params[optind - 1];

        // Check if current param doesn't start with '-' or is just '-'
        if (current.len == 0 or current[0] != '-' or std.mem.eql(u8, current, "-")) {
            try shell_ref.environment.put("OPTARG", try self.allocator.dupe(u8, ""));
            return 1;
        }

        // Handle '--' (end of options)
        if (std.mem.eql(u8, current, "--")) {
            const new_optind = try std.fmt.allocPrint(self.allocator, "{d}", .{optind + 1});
            try shell_ref.environment.put("OPTIND", new_optind);
            try shell_ref.environment.put("OPTARG", try self.allocator.dupe(u8, ""));
            return 1;
        }

        // Extract the flag (first character after '-')
        if (current.len < 2) {
            try shell_ref.environment.put("OPTARG", try self.allocator.dupe(u8, ""));
            return 1;
        }

        const flag = current[1..2];

        // Check if this flag expects an argument (has ':' after it in optstring)
        var expects_arg = false;
        for (optstring, 0..) |c, i| {
            if (c == flag[0] and i + 1 < optstring.len and optstring[i + 1] == ':') {
                expects_arg = true;
                break;
            }
        }

        // Set the variable to the flag character
        try shell_ref.environment.put(var_name, try self.allocator.dupe(u8, flag));

        // Handle argument if needed
        if (expects_arg) {
            const arg_value = if (optind < params.len) params[optind] else "";
            try shell_ref.environment.put("OPTARG", try self.allocator.dupe(u8, arg_value));
            const new_optind = try std.fmt.allocPrint(self.allocator, "{d}", .{optind + 2});
            try shell_ref.environment.put("OPTIND", new_optind);
        } else {
            try shell_ref.environment.put("OPTARG", try self.allocator.dupe(u8, ""));
            const new_optind = try std.fmt.allocPrint(self.allocator, "{d}", .{optind + 1});
            try shell_ref.environment.put("OPTIND", new_optind);
        }

        return 0;
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

    fn builtinHash(self: *Executor, command: *types.ParsedCommand) anyerror!i32 {
        const shell_ref = self.shell orelse {
            try IO.eprint("den: hash: shell context not available\n", .{});
            return 1;
        };

        const utils = @import("../utils.zig");

        // hash with no args - list all cached paths
        if (command.args.len == 0) {
            var iter = shell_ref.command_cache.iterator();
            while (iter.next()) |entry| {
                try IO.print("{s}\t{s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
            return 0;
        }

        // hash -r - clear hash table
        if (std.mem.eql(u8, command.args[0], "-r")) {
            var iter = shell_ref.command_cache.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            shell_ref.command_cache.clearRetainingCapacity();
            return 0;
        }

        // hash command [command...] - add commands to hash table
        const path_var = std.posix.getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
        var path_list = utils.env.PathList.parse(self.allocator, path_var) catch {
            return 1;
        };
        defer path_list.deinit();

        for (command.args) |cmd_name| {
            if (try path_list.findExecutable(self.allocator, cmd_name)) |exec_path| {
                // Remove old entry if exists
                if (shell_ref.command_cache.fetchRemove(cmd_name)) |kv| {
                    self.allocator.free(kv.key);
                    self.allocator.free(kv.value);
                }

                // Add new entry
                const key = try self.allocator.dupe(u8, cmd_name);
                errdefer self.allocator.free(key);
                try shell_ref.command_cache.put(key, exec_path);
            } else {
                try IO.eprint("den: hash: {s}: not found\n", .{cmd_name});
                return 1;
            }
        }

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
        _ = command;
        const shell_ref = self.shell orelse {
            try IO.eprint("den: reload: shell context not available\n", .{});
            return 1;
        };

        // Reload shell configuration files
        // For 1.0, we'll just reload aliases and environment from the config
        const config_loader = @import("../config_loader.zig");
        const new_config = config_loader.loadConfig(self.allocator) catch {
            try IO.eprint("den: reload: failed to load configuration\n", .{});
            return 1;
        };

        // Update shell config
        shell_ref.config = new_config;
        try IO.print("Configuration reloaded\n", .{});

        return 0;
    }

    fn builtinWatch(self: *Executor, command: *types.ParsedCommand) !i32 {
        // watch [-n seconds] command [args...]
        // Repeatedly execute a command and display output

        if (command.args.len == 0) {
            try IO.eprint("den: watch: missing command\n", .{});
            try IO.eprint("Usage: watch [-n seconds] command [args...]\n", .{});
            return 1;
        }

        var interval_seconds: u64 = 2; // default 2 seconds
        var cmd_start: usize = 0;

        // Parse -n flag if present
        if (command.args.len >= 2 and std.mem.eql(u8, command.args[0], "-n")) {
            interval_seconds = std.fmt.parseInt(u64, command.args[1], 10) catch {
                try IO.eprint("den: watch: invalid interval: {s}\n", .{command.args[1]});
                return 1;
            };
            cmd_start = 2;
        }

        if (cmd_start >= command.args.len) {
            try IO.eprint("den: watch: missing command\n", .{});
            return 1;
        }

        const interval_ns = interval_seconds * std.time.ns_per_s;

        // Repeatedly execute the command
        while (true) {
            // Clear screen and show header
            const utils = @import("../utils.zig");
            try IO.print("{s}", .{utils.ansi.Sequences.clear_screen});
            try IO.print("{s}", .{utils.ansi.Sequences.cursor_home});
            try IO.print("Every {d}s: {s}", .{ interval_seconds, command.args[cmd_start] });
            for (command.args[cmd_start + 1 ..]) |arg| {
                try IO.print(" {s}", .{arg});
            }
            try IO.print("\n\n", .{});

            // Execute the command
            var new_cmd = types.ParsedCommand{
                .name = command.args[cmd_start],
                .args = if (cmd_start + 1 < command.args.len) command.args[cmd_start + 1 ..] else &[_][]const u8{},
                .redirections = command.redirections,
            };

            // Execute as external command to avoid issues
            _ = self.executeExternal(&new_cmd) catch |err| {
                try IO.eprint("Error executing command: {}\n", .{err});
            };

            // Sleep for the interval
            std.Thread.sleep(interval_ns);
        }

        return 0;
    }

    fn builtinTree(self: *Executor, command: *types.ParsedCommand) !i32 {
        const path = if (command.args.len > 0) command.args[0] else ".";

        // Simple tree implementation
        try IO.print("{s}\n", .{path});
        try self.printTree(path, "");

        return 0;
    }

    fn printTree(self: *Executor, dir_path: []const u8, prefix: []const u8) !void {

        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            try IO.eprint("den: tree: cannot open {s}: {}\n", .{ dir_path, err });
            return;
        };
        defer dir.close();

        var iter = dir.iterate();
        var entries: std.ArrayList(std.fs.Dir.Entry) = .{};
        defer entries.deinit(self.allocator);

        // Collect all entries
        while (try iter.next()) |entry| {
            try entries.append(self.allocator, entry);
        }

        // Print each entry
        for (entries.items, 0..) |entry, i| {
            const is_last_entry = i == entries.items.len - 1;
            const connector = if (is_last_entry) "└── " else "├── ";

            try IO.print("{s}{s}{s}\n", .{ prefix, connector, entry.name });

            // Recurse into directories
            if (entry.kind == .directory) {
                const new_prefix_buf = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}{s}",
                    .{ prefix, if (is_last_entry) "    " else "│   " },
                );
                defer self.allocator.free(new_prefix_buf);

                const sub_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, entry.name });
                defer self.allocator.free(sub_path);

                try self.printTree(sub_path, new_prefix_buf);
            }
        }
    }

    fn builtinGrep(self: *Executor, command: *types.ParsedCommand) !i32 {
        // grep [options] pattern [file...]
        if (command.args.len == 0) {
            try IO.eprint("den: grep: missing pattern\n", .{});
            try IO.eprint("Usage: grep [-i] [-n] [-v] pattern [file...]\n", .{});
            return 1;
        }

        var case_insensitive = false;
        var show_line_numbers = false;
        var invert_match = false;
        var pattern_idx: usize = 0;

        // Parse flags
        for (command.args, 0..) |arg, i| {
            if (arg.len > 0 and arg[0] == '-') {
                for (arg[1..]) |c| {
                    if (c == 'i') case_insensitive = true
                    else if (c == 'n') show_line_numbers = true
                    else if (c == 'v') invert_match = true
                    else {
                        try IO.eprint("den: grep: invalid option: -{c}\n", .{c});
                        return 1;
                    }
                }
                pattern_idx = i + 1;
            } else {
                break;
            }
        }

        if (pattern_idx >= command.args.len) {
            try IO.eprint("den: grep: missing pattern\n", .{});
            return 1;
        }

        const pattern = command.args[pattern_idx];
        const files = if (pattern_idx + 1 < command.args.len) command.args[pattern_idx + 1 ..] else &[_][]const u8{};

        // If no files, read from stdin
        if (files.len == 0) {
            try IO.print("den: grep: reading from stdin not yet implemented\n", .{});
            return 1;
        }

        // Search each file
        for (files) |file_path| {
            const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
                try IO.eprint("den: grep: {s}: {}\n", .{ file_path, err });
                continue;
            };
            defer file.close();

            const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch |err| {
                try IO.eprint("den: grep: error reading {s}: {}\n", .{ file_path, err });
                continue;
            };
            defer self.allocator.free(content);

            var line_iter = std.mem.splitScalar(u8, content, '\n');
            var line_num: usize = 1;

            while (line_iter.next()) |line| {
                var matches = false;

                if (case_insensitive) {
                    // Simple case-insensitive search
                    var i: usize = 0;
                    while (i + pattern.len <= line.len) : (i += 1) {
                        if (std.ascii.eqlIgnoreCase(line[i .. i + pattern.len], pattern)) {
                            matches = true;
                            break;
                        }
                    }
                } else {
                    matches = std.mem.indexOf(u8, line, pattern) != null;
                }

                if (invert_match) matches = !matches;

                if (matches) {
                    if (show_line_numbers) {
                        try IO.print("{d}:{s}\n", .{ line_num, line });
                    } else {
                        try IO.print("{s}\n", .{line});
                    }
                }

                line_num += 1;
            }
        }

        return 0;
    }

    fn builtinFind(self: *Executor, command: *types.ParsedCommand) !i32 {
        // find [path] [-name pattern] [-type f|d]
        const start_path = if (command.args.len > 0 and command.args[0][0] != '-') command.args[0] else ".";

        var name_pattern: ?[]const u8 = null;
        var type_filter: ?u8 = null; // 'f' for file, 'd' for directory

        // Parse options
        var i: usize = if (std.mem.eql(u8, start_path, ".")) 0 else 1;
        while (i < command.args.len) : (i += 1) {
            const arg = command.args[i];
            if (std.mem.eql(u8, arg, "-name") and i + 1 < command.args.len) {
                name_pattern = command.args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, arg, "-type") and i + 1 < command.args.len) {
                const type_str = command.args[i + 1];
                if (type_str.len == 1) {
                    type_filter = type_str[0];
                }
                i += 1;
            }
        }

        try self.findRecursive(start_path, name_pattern, type_filter);
        return 0;
    }

    fn findRecursive(self: *Executor, dir_path: []const u8, name_pattern: ?[]const u8, type_filter: ?u8) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            try IO.eprint("den: find: cannot open {s}: {}\n", .{ dir_path, err });
            return;
        };
        defer dir.close();

        var iter = dir.iterate();

        while (try iter.next()) |entry| {
            // Skip . and ..
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) {
                continue;
            }

            const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, entry.name });
            defer self.allocator.free(full_path);

            // Check type filter
            if (type_filter) |filter| {
                if (filter == 'f' and entry.kind != .file) continue;
                if (filter == 'd' and entry.kind != .directory) continue;
            }

            // Check name pattern (simple wildcard support)
            if (name_pattern) |pattern| {
                if (!matchPattern(entry.name, pattern)) {
                    if (entry.kind == .directory) {
                        try self.findRecursive(full_path, name_pattern, type_filter);
                    }
                    continue;
                }
            }

            try IO.print("{s}\n", .{full_path});

            // Recurse into directories
            if (entry.kind == .directory) {
                try self.findRecursive(full_path, name_pattern, type_filter);
            }
        }
    }

    fn matchPattern(name: []const u8, pattern: []const u8) bool {
        // Simple wildcard matching: * matches any sequence
        if (std.mem.indexOf(u8, pattern, "*")) |star_pos| {
            const prefix = pattern[0..star_pos];
            const suffix = pattern[star_pos + 1 ..];

            if (prefix.len > 0 and !std.mem.startsWith(u8, name, prefix)) {
                return false;
            }

            if (suffix.len > 0 and !std.mem.endsWith(u8, name, suffix)) {
                return false;
            }

            return true;
        } else {
            // Exact match
            return std.mem.eql(u8, name, pattern);
        }
    }

    fn builtinCalc(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;

        if (command.args.len == 0) {
            try IO.eprint("den: calc: missing expression\n", .{});
            try IO.eprint("Usage: calc <expression>\n", .{});
            try IO.eprint("Examples: calc 2 + 2, calc 10 * 5, calc 100 / 4\n", .{});
            return 1;
        }

        // Join all args into a single expression
        var expr_buf: [1024]u8 = undefined;
        var expr_len: usize = 0;

        for (command.args, 0..) |arg, i| {
            if (i > 0 and expr_len < expr_buf.len) {
                expr_buf[expr_len] = ' ';
                expr_len += 1;
            }

            const copy_len = @min(arg.len, expr_buf.len - expr_len);
            @memcpy(expr_buf[expr_len .. expr_len + copy_len], arg[0..copy_len]);
            expr_len += copy_len;
        }

        const expr = expr_buf[0..expr_len];

        // Simple calculator: evaluate basic arithmetic
        const result = evaluateExpression(expr) catch |err| {
            try IO.eprint("den: calc: invalid expression: {}\n", .{err});
            return 1;
        };

        try IO.print("{d}\n", .{result});
        return 0;
    }

    fn evaluateExpression(expr: []const u8) !f64 {
        // Very simple evaluator: split by operators and evaluate left to right
        // This is not a proper expression parser, but works for simple cases

        var trimmed = std.mem.trim(u8, expr, " \t");

        // Try to find operators in order of precedence (low to high)
        // + and -
        var i: usize = trimmed.len;
        while (i > 0) {
            i -= 1;
            const c = trimmed[i];
            if (c == '+' or c == '-') {
                if (i == 0) continue; // Skip leading sign
                const left = try evaluateExpression(trimmed[0..i]);
                const right = try evaluateExpression(trimmed[i + 1 ..]);
                return if (c == '+') left + right else left - right;
            }
        }

        // * and /
        i = trimmed.len;
        while (i > 0) {
            i -= 1;
            const c = trimmed[i];
            if (c == '*' or c == '/') {
                const left = try evaluateExpression(trimmed[0..i]);
                const right = try evaluateExpression(trimmed[i + 1 ..]);
                return if (c == '*') left * right else left / right;
            }
        }

        // No operators found, parse as number
        return std.fmt.parseFloat(f64, trimmed);
    }

    fn builtinJson(self: *Executor, command: *types.ParsedCommand) !i32 {
        // json [file] - pretty print JSON
        if (command.args.len == 0) {
            try IO.eprint("den: json: missing file argument\n", .{});
            try IO.eprint("Usage: json <file>\n", .{});
            return 1;
        }

        const file_path = command.args[0];
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            try IO.eprint("den: json: cannot open {s}: {}\n", .{ file_path, err });
            return 1;
        };
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch |err| {
            try IO.eprint("den: json: error reading {s}: {}\n", .{ file_path, err });
            return 1;
        };
        defer self.allocator.free(content);

        // Parse JSON to validate it
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, content, .{}) catch |err| {
            try IO.eprint("den: json: invalid JSON: {}\n", .{err});
            return 1;
        };
        defer parsed.deinit();

        // Print the validated JSON content
        // Note: Pretty printing requires using std.json.stringify with proper options.
        // The Zig 0.15 JSON API has changed significantly. For 1.0, we validate and print as-is.
        // Future versions can implement indented output using the new stringify API.
        try IO.print("{s}\n", .{content});

        return 0;
    }

    fn builtinLs(self: *Executor, command: *types.ParsedCommand) !i32 {
        // Parse flags
        var show_all = false;
        var long_format = false;
        var reverse = false;
        var sort_by_time = false;
        var sort_by_size = false;
        var human_readable = false;
        var recursive = false;
        var one_per_line = false;
        var directory_only = false;
        var target_path: []const u8 = ".";

        for (command.args) |arg| {
            if (arg.len > 0 and arg[0] == '-') {
                // Parse flags
                for (arg[1..]) |c| {
                    switch (c) {
                        'a' => show_all = true,
                        'l' => long_format = true,
                        'r' => reverse = true,
                        't' => sort_by_time = true,
                        'S' => sort_by_size = true,
                        'h' => human_readable = true,
                        'R' => recursive = true,
                        '1' => one_per_line = true,
                        'd' => directory_only = true,
                        else => {
                            try IO.eprint("ls: invalid option -- '{c}'\n", .{c});
                            return 1;
                        },
                    }
                }
            } else {
                // Path argument
                target_path = arg;
            }
        }

        // Handle -d flag (directory itself, not contents)
        if (directory_only) {
            try IO.print("{s}\n", .{target_path});
            return 0;
        }

        var dir = std.fs.cwd().openDir(target_path, .{ .iterate = true }) catch |err| {
            try IO.eprint("ls: cannot access '{s}': {}\n", .{ target_path, err });
            return 1;
        };
        defer dir.close();

        // Entry info for sorting
        const EntryInfo = struct {
            name: []const u8,
            kind: std.fs.Dir.Entry.Kind,
            size: u64,
            mtime: i128,
        };

        var entries: [512]EntryInfo = undefined;
        var count: usize = 0;

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            // Skip hidden files unless -a flag
            if (!show_all and entry.name.len > 0 and entry.name[0] == '.') continue;
            if (count >= 512) break;

            // Get file stats
            const stat = dir.statFile(entry.name) catch |err| {
                if (err == error.IsDir) {
                    // For directories, use stat instead
                    const dir_stat = dir.stat() catch std.fs.File.Stat{
                        .size = 0,
                        .mtime = 0,
                        .atime = 0,
                        .ctime = 0,
                        .mode = 0,
                        .kind = .directory,
                        .inode = 0,
                    };
                    entries[count] = .{
                        .name = try self.allocator.dupe(u8, entry.name),
                        .kind = entry.kind,
                        .size = dir_stat.size,
                        .mtime = dir_stat.mtime,
                    };
                } else {
                    entries[count] = .{
                        .name = try self.allocator.dupe(u8, entry.name),
                        .kind = entry.kind,
                        .size = 0,
                        .mtime = 0,
                    };
                }
                count += 1;
                continue;
            };

            entries[count] = .{
                .name = try self.allocator.dupe(u8, entry.name),
                .kind = entry.kind,
                .size = stat.size,
                .mtime = stat.mtime,
            };
            count += 1;
        }

        // Sort entries
        var i: usize = 0;
        while (i < count) : (i += 1) {
            var j: usize = i + 1;
            while (j < count) : (j += 1) {
                const should_swap = if (sort_by_size)
                    if (reverse)
                        entries[i].size < entries[j].size
                    else
                        entries[i].size > entries[j].size
                else if (sort_by_time)
                    if (reverse)
                        entries[i].mtime < entries[j].mtime
                    else
                        entries[i].mtime > entries[j].mtime
                else if (reverse)
                    std.mem.order(u8, entries[i].name, entries[j].name) == .lt
                else
                    std.mem.order(u8, entries[i].name, entries[j].name) == .gt;

                if (should_swap) {
                    const temp = entries[i];
                    entries[i] = entries[j];
                    entries[j] = temp;
                }
            }
        }

        // Print entries
        if (long_format) {
            // Calculate total blocks using actual stat() calls to get real block count
            var total_blocks: u64 = 0;
            i = 0;
            while (i < count) : (i += 1) {
                // Get actual allocated blocks from filesystem
                const path_buf = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ target_path, entries[i].name });
                defer self.allocator.free(path_buf);

                const path_z = try std.posix.toPosixPath(path_buf);
                var st: std.c.Stat = undefined;
                const result = std.c.stat(&path_z, &st);
                if (result != 0) {
                    // Fallback to size-based calculation if stat fails
                    total_blocks += (entries[i].size + 511) / 512;
                    continue;
                }

                // st_blocks is in 512-byte blocks on POSIX systems
                total_blocks += @intCast(st.blocks);
            }
            try IO.print("total {d}\n", .{total_blocks});

            // Long format: permissions links owner group size date name
            i = 0;
            while (i < count) : (i += 1) {
                const entry = entries[i];

                // Get actual file stats including permissions and links
                const path_buf = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ target_path, entry.name });
                defer self.allocator.free(path_buf);

                const path_z = try std.posix.toPosixPath(path_buf);
                var st: std.c.Stat = undefined;
                const stat_result = std.c.stat(&path_z, &st);

                const kind_char: u8 = switch (entry.kind) {
                    .directory => 'd',
                    .sym_link => 'l',
                    else => '-',
                };

                // Get actual permissions from stat
                var perms_buf: [9]u8 = undefined;
                if (stat_result == 0) {
                    const mode = st.mode;
                    // Owner permissions
                    perms_buf[0] = if (mode & 0o400 != 0) 'r' else '-';
                    perms_buf[1] = if (mode & 0o200 != 0) 'w' else '-';
                    perms_buf[2] = if (mode & 0o100 != 0) 'x' else '-';
                    // Group permissions
                    perms_buf[3] = if (mode & 0o040 != 0) 'r' else '-';
                    perms_buf[4] = if (mode & 0o020 != 0) 'w' else '-';
                    perms_buf[5] = if (mode & 0o010 != 0) 'x' else '-';
                    // Other permissions
                    perms_buf[6] = if (mode & 0o004 != 0) 'r' else '-';
                    perms_buf[7] = if (mode & 0o002 != 0) 'w' else '-';
                    perms_buf[8] = if (mode & 0o001 != 0) 'x' else '-';
                } else {
                    // Fallback if stat fails
                    @memcpy(&perms_buf, "rw-r--r--");
                }
                const perms = perms_buf[0..];

                // Check for extended attributes (macOS-specific)
                var has_xattr = false;
                if (stat_result == 0) {
                    // Use extern function for listxattr on macOS
                    const listxattr = struct {
                        extern "c" fn listxattr(path: [*:0]const u8, namebuf: ?[*]u8, size: usize, options: c_int) isize;
                    }.listxattr;
                    const xattr_list_size = listxattr(&path_z, null, 0, 0);
                    has_xattr = xattr_list_size > 0;
                }

                // Get hard link count
                const nlink: u64 = if (stat_result == 0) @intCast(st.nlink) else 1;

                // Get username and group (simplified - use env vars)
                const username = std.posix.getenv("USER") orelse "user";
                const groupname = "staff";

                // Format size
                const size_str = if (human_readable) blk: {
                    if (entry.size < 1024) {
                        break :blk try std.fmt.allocPrint(self.allocator, "{d}", .{entry.size});
                    } else if (entry.size < 1024 * 1024) {
                        break :blk try std.fmt.allocPrint(self.allocator, "{d}K", .{entry.size / 1024});
                    } else if (entry.size < 1024 * 1024 * 1024) {
                        break :blk try std.fmt.allocPrint(self.allocator, "{d}M", .{entry.size / (1024 * 1024)});
                    } else {
                        break :blk try std.fmt.allocPrint(self.allocator, "{d}G", .{entry.size / (1024 * 1024 * 1024)});
                    }
                } else try std.fmt.allocPrint(self.allocator, "{d}", .{entry.size});
                defer self.allocator.free(size_str);

                // Format time (convert to "Mon DD HH:MM" format)
                const time_ns: u64 = @intCast(@max(0, entry.mtime));
                const time_s = time_ns / std.time.ns_per_s;

                // Simple date conversion
                const seconds_per_day = 86400;
                const days_since_epoch = time_s / seconds_per_day;
                const seconds_today = time_s % seconds_per_day;
                const hours = seconds_today / 3600;
                const minutes = (seconds_today % 3600) / 60;

                // Approximate month/day (simplified)
                const day_of_year = @mod(days_since_epoch, 365);
                const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
                const month_idx = @min((day_of_year / 30), 11);
                const day = @mod(day_of_year, 30) + 1;

                const time_str = try std.fmt.allocPrint(
                    self.allocator,
                    "{s} {d:>2} {d:0>2}:{d:0>2}",
                    .{ month_names[month_idx], day, hours, minutes },
                );
                defer self.allocator.free(time_str);

                // Print with standard ls format
                // Format: permissions[@] nlink user group size date name
                const xattr_char = if (has_xattr) "@" else " ";
                if (entry.kind == .directory) {
                    try IO.print("{c}{s}{s} {d:>3} {s:<20} {s:<10} {d:>8} {s} \x1b[1;36m{s}\x1b[0m\n", .{
                        kind_char,
                        perms,
                        xattr_char,
                        nlink,
                        username,
                        groupname,
                        entry.size,
                        time_str,
                        entry.name,
                    });
                } else {
                    try IO.print("{c}{s}{s} {d:>3} {s:<20} {s:<10} {d:>8} {s} {s}\n", .{
                        kind_char,
                        perms,
                        xattr_char,
                        nlink,
                        username,
                        groupname,
                        entry.size,
                        time_str,
                        entry.name,
                    });
                }
            }
        } else {
            // Simple format: just names
            if (one_per_line) {
                // One per line
                i = 0;
                while (i < count) : (i += 1) {
                    if (entries[i].kind == .directory) {
                        try IO.print("\x1b[1;36m{s}\x1b[0m\n", .{entries[i].name});
                    } else {
                        try IO.print("{s}\n", .{entries[i].name});
                    }
                }
            } else {
                // Multi-column format
                // First, find the longest filename to determine column width
                var max_len: usize = 0;
                i = 0;
                while (i < count) : (i += 1) {
                    if (entries[i].name.len > max_len) {
                        max_len = entries[i].name.len;
                    }
                }

                // Get terminal width (use signal handling module)
                const signals = @import("../utils/signals.zig");
                const term_width = if (signals.getWindowSize()) |ws| ws.cols else |_| 80;

                // Calculate column width (name + 2 spaces padding)
                const col_width = max_len + 2;
                const num_cols = @max(1, term_width / col_width);
                const num_rows = (count + num_cols - 1) / num_cols;

                // Print in column-major order (down then across)
                var row: usize = 0;
                while (row < num_rows) : (row += 1) {
                    var col: usize = 0;
                    while (col < num_cols) : (col += 1) {
                        const idx = col * num_rows + row;
                        if (idx >= count) break;

                        const entry = entries[idx];
                        const padding = col_width - entry.name.len;

                        if (entry.kind == .directory) {
                            try IO.print("\x1b[1;36m{s}\x1b[0m", .{entry.name});
                        } else {
                            try IO.print("{s}", .{entry.name});
                        }

                        // Add padding except for last column
                        if (col < num_cols - 1 and idx + num_rows < count) {
                            var p: usize = 0;
                            while (p < padding) : (p += 1) {
                                try IO.print(" ", .{});
                            }
                        }
                    }
                    try IO.print("\n", .{});
                }
            }
        }

        // Handle recursive flag (simplified - just show subdirectories)
        if (recursive) {
            i = 0;
            while (i < count) : (i += 1) {
                if (entries[i].kind == .directory) {
                    // Skip . and .. directories
                    if (std.mem.eql(u8, entries[i].name, ".") or std.mem.eql(u8, entries[i].name, "..")) {
                        continue;
                    }

                    // Print directory header
                    try IO.print("\n{s}/{s}:\n", .{ target_path, entries[i].name });

                    // Build new path
                    const new_path = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}/{s}",
                        .{ target_path, entries[i].name },
                    );
                    defer self.allocator.free(new_path);

                    // Create simple args array for recursion
                    var recursive_args_buf: [2][]const u8 = undefined;
                    var recursive_args_len: usize = 0;

                    // Add flags (without R to prevent deep recursion for now)
                    var flag_buf: [32]u8 = undefined;
                    var flag_len: usize = 0;
                    flag_buf[flag_len] = '-';
                    flag_len += 1;
                    if (show_all) {
                        flag_buf[flag_len] = 'a';
                        flag_len += 1;
                    }
                    if (long_format) {
                        flag_buf[flag_len] = 'l';
                        flag_len += 1;
                    }
                    if (flag_len > 1) {
                        recursive_args_buf[recursive_args_len] = flag_buf[0..flag_len];
                        recursive_args_len += 1;
                    }

                    recursive_args_buf[recursive_args_len] = new_path;
                    recursive_args_len += 1;

                    var recursive_cmd = types.ParsedCommand{
                        .name = "ls",
                        .args = recursive_args_buf[0..recursive_args_len],
                        .redirections = &[_]types.Redirection{},
                    };

                    _ = self.builtinLs(&recursive_cmd) catch {};
                }
            }
        }

        // Free copied names
        i = 0;
        while (i < count) : (i += 1) {
            self.allocator.free(entries[i].name);
        }

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
        // Note: Full builtin redirection support requires refactoring all builtin functions
        // to accept File parameters instead of using the global IO module. This is a
        // significant architectural change deferred to post-1.0. Current builtins work
        // correctly without redirections, which covers the majority of use cases.

        // Check if there are redirections and warn if so
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

    /// Builtin: seq - generate number sequences
    fn builtinSeq(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;

        if (command.args.len == 0) {
            try IO.eprint("seq: missing operand\nUsage: seq [FIRST [INCREMENT]] LAST\n", .{});
            return 1;
        }

        const first: i64 = if (command.args.len >= 2)
            try std.fmt.parseInt(i64, command.args[0], 10)
        else
            1;

        const increment: i64 = if (command.args.len >= 3)
            try std.fmt.parseInt(i64, command.args[1], 10)
        else
            1;

        const last_idx: usize = if (command.args.len >= 3) 2 else if (command.args.len >= 2) 1 else 0;
        const last = try std.fmt.parseInt(i64, command.args[last_idx], 10);

        if (increment == 0) {
            try IO.eprint("seq: INCREMENT must not be zero\n", .{});
            return 1;
        }

        if (increment > 0) {
            var i = first;
            while (i <= last) : (i += increment) {
                try IO.print("{d}\n", .{i});
            }
        } else {
            var i = first;
            while (i >= last) : (i += increment) {
                try IO.print("{d}\n", .{i});
            }
        }

        return 0;
    }

    /// Builtin: date - display or set date/time
    fn builtinDate(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;

        const timestamp = std.time.timestamp();
        const epoch_seconds: u64 = @intCast(timestamp);

        // Parse format string if provided
        const format = if (command.args.len > 0) command.args[0] else "+%a %b %d %H:%M:%S %Z %Y";

        // Simple format string support
        if (std.mem.startsWith(u8, format, "+")) {
            const fmt = format[1..];

            // Convert epoch to calendar date
            const seconds_per_day = 86400;
            const days_since_epoch = epoch_seconds / seconds_per_day;
            const seconds_today = epoch_seconds % seconds_per_day;

            const hours = seconds_today / 3600;
            const minutes = (seconds_today % 3600) / 60;
            const seconds = seconds_today % 60;

            // Simple date calculation (Unix epoch: 1970-01-01 was a Thursday)
            const days_since_1970 = days_since_epoch;
            const day_of_week = @mod((days_since_1970 + 4), 7); // Thursday = 4

            // Approximate year calculation
            const days_per_year = 365;
            const year = 1970 + (days_since_1970 / days_per_year);

            const weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
            const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

            // Very simple format parsing
            if (std.mem.eql(u8, fmt, "%s")) {
                try IO.print("{d}\n", .{epoch_seconds});
            } else if (std.mem.eql(u8, fmt, "%Y")) {
                try IO.print("{d}\n", .{year});
            } else if (std.mem.eql(u8, fmt, "%H:%M:%S")) {
                try IO.print("{d:0>2}:{d:0>2}:{d:0>2}\n", .{ hours, minutes, seconds });
            } else {
                // Default format
                try IO.print("{s} {s} 01 {d:0>2}:{d:0>2}:{d:0>2} UTC {d}\n", .{
                    weekdays[day_of_week],
                    months[0],
                    hours,
                    minutes,
                    seconds,
                    year,
                });
            }
        } else if (std.mem.eql(u8, format, "--iso-8601")) {
            // ISO 8601 format
            const days_since_epoch = epoch_seconds / 86400;
            const year = 1970 + (days_since_epoch / 365);
            try IO.print("{d}-01-01\n", .{year});
        } else {
            try IO.eprint("date: invalid format\nUsage: date [+FORMAT]\n", .{});
            return 1;
        }

        return 0;
    }

    /// Builtin: parallel - run commands in parallel (stub)
    fn builtinParallel(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;

        if (command.args.len == 0) {
            try IO.eprint("parallel: missing command\nUsage: parallel command [args...]\n", .{});
            try IO.eprint("Note: parallel is a stub implementation\n", .{});
            return 1;
        }

        // Stub implementation - just notify the user
        try IO.print("parallel: stub implementation - command would run in parallel\n", .{});
        try IO.print("Command: {s}\n", .{command.args[0]});

        return 0;
    }

    fn builtinHttp(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;

        if (command.args.len == 0) {
            try IO.eprint("http: missing URL\n", .{});
            try IO.eprint("Usage: http [OPTIONS] URL\n", .{});
            try IO.eprint("Options:\n", .{});
            try IO.eprint("  -X METHOD     HTTP method (GET, POST, PUT, DELETE)\n", .{});
            try IO.eprint("  -d DATA       Request body data\n", .{});
            try IO.eprint("  -i            Show response headers\n", .{});
            try IO.eprint("\nExamples:\n", .{});
            try IO.eprint("  http https://api.example.com/users\n", .{});
            try IO.eprint("  http -X POST -d 'data' https://api.example.com/users\n", .{});
            try IO.eprint("\nNote: This is a stub implementation.\n", .{});
            try IO.eprint("For full HTTP client functionality, use curl or wget.\n", .{});
            return 1;
        }

        var method: []const u8 = "GET";
        var url: ?[]const u8 = null;
        var data: ?[]const u8 = null;

        // Parse arguments
        var i: usize = 0;
        while (i < command.args.len) : (i += 1) {
            const arg = command.args[i];

            if (std.mem.eql(u8, arg, "-X") or std.mem.eql(u8, arg, "--request")) {
                if (i + 1 >= command.args.len) {
                    try IO.eprint("http: -X requires an argument\n", .{});
                    return 1;
                }
                i += 1;
                method = command.args[i];
            } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--data")) {
                if (i + 1 >= command.args.len) {
                    try IO.eprint("http: -d requires an argument\n", .{});
                    return 1;
                }
                i += 1;
                data = command.args[i];
            } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--include")) {
                // Accepted but ignored in stub
            } else if (arg[0] != '-') {
                url = arg;
            } else {
                try IO.eprint("http: unknown option {s}\n", .{arg});
                return 1;
            }
        }

        if (url == null) {
            try IO.eprint("http: missing URL\n", .{});
            return 1;
        }

        const target_url = url.?;

        // Stub implementation - show what would be done
        try IO.print("http: stub implementation\n", .{});
        try IO.print("Would perform {s} {s}\n", .{ method, target_url });
        if (data) |body| {
            try IO.print("With data {s}\n", .{body});
        }
        try IO.print("\nTo use full HTTP functionality, use:\n", .{});
        if (data) |body| {
            try IO.print("  curl -X {s} -d '{s}' {s}\n", .{ method, body, target_url });
        } else {
            try IO.print("  curl {s}\n", .{target_url});
        }

        return 0;
    }

    fn builtinBase64(self: *Executor, command: *types.ParsedCommand) !i32 {
        if (command.args.len == 0) {
            try IO.eprint("base64: missing input\n", .{});
            try IO.eprint("Usage: base64 [-d] <string>\n", .{});
            try IO.eprint("Options:\n", .{});
            try IO.eprint("  -d    Decode base64 input\n", .{});
            try IO.eprint("\nExamples:\n", .{});
            try IO.eprint("  base64 'Hello World'\n", .{});
            try IO.eprint("  base64 -d 'SGVsbG8gV29ybGQ='\n", .{});
            return 1;
        }

        var decode: bool = false;
        var input: ?[]const u8 = null;

        // Parse arguments
        var i: usize = 0;
        while (i < command.args.len) : (i += 1) {
            const arg = command.args[i];
            if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--decode")) {
                decode = true;
            } else {
                input = arg;
            }
        }

        if (input == null) {
            try IO.eprint("base64: missing input\n", .{});
            return 1;
        }

        const data = input.?;

        if (decode) {
            // Decode base64
            const decoder = std.base64.standard.Decoder;
            const max_size = try decoder.calcSizeForSlice(data);
            const output = try self.allocator.alloc(u8, max_size);
            defer self.allocator.free(output);

            decoder.decode(output, data) catch {
                try IO.eprint("base64: invalid base64 input\n", .{});
                return 1;
            };

            try IO.print("{s}\n", .{output[0..max_size]});
        } else {
            // Encode to base64
            const encoder = std.base64.standard.Encoder;
            const output_size = encoder.calcSize(data.len);
            const output = try self.allocator.alloc(u8, output_size);
            defer self.allocator.free(output);

            const encoded = encoder.encode(output, data);
            try IO.print("{s}\n", .{encoded});
        }

        return 0;
    }

    fn builtinUuid(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = command;

        // Generate a simple UUID v4 (random)
        var rng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
        var random = rng.random();

        var uuid: [16]u8 = undefined;
        random.bytes(&uuid);

        // Set version (4) and variant bits
        uuid[6] = (uuid[6] & 0x0f) | 0x40; // Version 4
        uuid[8] = (uuid[8] & 0x3f) | 0x80; // Variant

        // Format as UUID string
        const uuid_str = try std.fmt.allocPrint(
            self.allocator,
            "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
            .{
                uuid[0],  uuid[1],  uuid[2],  uuid[3],
                uuid[4],  uuid[5],  uuid[6],  uuid[7],
                uuid[8],  uuid[9],  uuid[10], uuid[11],
                uuid[12], uuid[13], uuid[14], uuid[15],
            },
        );
        defer self.allocator.free(uuid_str);

        try IO.print("{s}\n", .{uuid_str});
        return 0;
    }
};
