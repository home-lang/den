const std = @import("std");
const types = @import("../types/mod.zig");
const IO = @import("../utils/io.zig").IO;
const Expansion = @import("../utils/expansion.zig").Expansion;
const builtin = @import("builtin");
const process = @import("../utils/process.zig");
const TypoCorrection = @import("../utils/typo_correction.zig").TypoCorrection;
const env_utils = @import("../utils/env.zig");

// Forward declaration for Shell type
const Shell = @import("../shell.zig").Shell;

// C library extern declarations for environment manipulation
const libc_env = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

// Get environ from C - returns the current environment pointer (updated by setenv/unsetenv)
fn getCEnviron() [*:null]const ?[*:0]const u8 {
    // On Darwin/macOS, environ is available via _NSGetEnviron()
    // On other platforms, we can directly access extern environ
    if (builtin.os.tag == .macos) {
        // macOS uses _NSGetEnviron() function which returns ***char (pointer to environ)
        const NSGetEnviron = @extern(*const fn () callconv(.c) *[*:null]?[*:0]u8, .{ .name = "_NSGetEnviron" });
        return @ptrCast(NSGetEnviron().*);
    } else {
        // Linux and other POSIX systems - environ is a global variable
        const c_environ = @extern(*[*:null]?[*:0]u8, .{ .name = "environ" });
        return @ptrCast(c_environ.*);
    }
}

// Windows process access rights (for job control)
const PROCESS_TERMINATE: u32 = 0x0001;

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
        var pipefail_status: i32 = 0;
        for (0..commands.len) |i| {
            const term = try children_buffer[i].wait();
            const status: i32 = switch (term) {
                .Exited => |code| code,
                else => 1,
            };
            last_status = status;
            // For pipefail: track rightmost non-zero exit status
            if (status != 0) {
                pipefail_status = status;
            }
        }

        // Handle pipefail option
        if (self.shell) |shell| {
            if (shell.option_pipefail and pipefail_status != 0) {
                return pipefail_status;
            }
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
        var pipefail_status: i32 = 0;
        for (pids_buffer[0..commands.len]) |pid| {
            const result = std.posix.waitpid(pid, 0);
            const status: i32 = @intCast(std.posix.W.EXITSTATUS(result.status));
            last_status = status;
            // For pipefail: track rightmost non-zero exit status
            if (status != 0) {
                pipefail_status = status;
            }
        }

        // Handle pipefail option
        if (self.shell) |shell| {
            if (shell.option_pipefail and pipefail_status != 0) {
                return pipefail_status;
            }
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
        // Use C's environ directly which is updated by setenv/unsetenv
        _ = std.posix.execvpeZ(cmd_z.ptr, @ptrCast(argv.ptr), getCEnviron()) catch {
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
                            // Set nounset option if enabled in shell
                            if (self.shell) |shell| {
                                expansion.option_nounset = shell.option_nounset;
                            }
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
        // Handle set -x (xtrace): print command before execution
        if (self.shell) |shell| {
            if (shell.option_xtrace) {
                // Print command with + prefix (like bash)
                try IO.eprint("+ {s}", .{command.name});
                for (command.args) |arg| {
                    try IO.eprint(" {s}", .{arg});
                }
                try IO.eprint("\n", .{});
            }

            // Handle set -n (noexec): don't execute, just return success
            if (shell.option_noexec) {
                return 0;
            }
        }

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
            "true", "false", "test", "[", "[[", "alias", "unalias", "which",
            "type", "help", "read", "printf", "source", ".", "history",
            "pushd", "popd", "dirs", "eval", "exec", "command", "builtin",
            "jobs", "fg", "bg", "wait", "disown", "kill", "trap", "times",
            "umask", "getopts", "clear", "time", "timeout", "hash", "yes", "reload",
            "watch", "tree", "grep", "find", "calc", "json", "ls",
            "seq", "date", "parallel", "http", "base64", "uuid",
            "localip", "shrug", "web", "ip", "return", "local", "copyssh",
            "reloaddns", "emptytrash", "wip", "bookmark", "code", "pstorm",
            "show", "hide", "ft", "sys-stats", "netstats", "net-check", "log-tail", "proc-monitor", "log-parse", "dotfiles", "library",
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
            return try self.builtinPwd(command);
        } else if (std.mem.eql(u8, command.name, "cd")) {
            return try self.builtinCd(command);
        } else if (std.mem.eql(u8, command.name, "env")) {
            return try self.builtinEnvCmd(command);
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
        } else if (std.mem.eql(u8, command.name, "[[")) {
            return try self.builtinExtendedTest(command);
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
        } else if (std.mem.eql(u8, command.name, "timeout")) {
            return try self.builtinTimeout(command);
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
        } else if (std.mem.eql(u8, command.name, "ft")) {
            return try self.builtinFt(command);
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
        } else if (std.mem.eql(u8, command.name, "localip")) {
            return try self.builtinLocalip(command);
        } else if (std.mem.eql(u8, command.name, "ip")) {
            return try self.builtinIp(command);
        } else if (std.mem.eql(u8, command.name, "shrug")) {
            return try self.builtinShrug(command);
        } else if (std.mem.eql(u8, command.name, "web")) {
            return try self.builtinWeb(command);
        } else if (std.mem.eql(u8, command.name, "return")) {
            return try self.builtinReturn(command);
        } else if (std.mem.eql(u8, command.name, "local")) {
            return try self.builtinLocal(command);
        } else if (std.mem.eql(u8, command.name, "copyssh")) {
            return try self.builtinCopyssh(command);
        } else if (std.mem.eql(u8, command.name, "reloaddns")) {
            return try self.builtinReloaddns(command);
        } else if (std.mem.eql(u8, command.name, "emptytrash")) {
            return try self.builtinEmptytrash(command);
        } else if (std.mem.eql(u8, command.name, "wip")) {
            return try self.builtinWip(command);
        } else if (std.mem.eql(u8, command.name, "bookmark")) {
            return try self.builtinBookmark(command);
        } else if (std.mem.eql(u8, command.name, "code")) {
            return try self.builtinCode(command);
        } else if (std.mem.eql(u8, command.name, "pstorm")) {
            return try self.builtinPstorm(command);
        } else if (std.mem.eql(u8, command.name, "show")) {
            return try self.builtinShow(command);
        } else if (std.mem.eql(u8, command.name, "hide")) {
            return try self.builtinHide(command);
        } else if (std.mem.eql(u8, command.name, "sys-stats")) {
            return try self.builtinSysStats(command);
        } else if (std.mem.eql(u8, command.name, "netstats")) {
            return try self.builtinNetstats(command);
        } else if (std.mem.eql(u8, command.name, "net-check")) {
            return try self.builtinNetCheck(command);
        } else if (std.mem.eql(u8, command.name, "log-tail")) {
            return try self.builtinLogTail(command);
        } else if (std.mem.eql(u8, command.name, "proc-monitor")) {
            return try self.builtinProcMonitor(command);
        } else if (std.mem.eql(u8, command.name, "log-parse")) {
            return try self.builtinLogParse(command);
        } else if (std.mem.eql(u8, command.name, "dotfiles")) {
            return try self.builtinDotfiles(command);
        } else if (std.mem.eql(u8, command.name, "library")) {
            return try self.builtinLibrary(command);
        }

        try IO.eprint("den: builtin not implemented: {s}\n", .{command.name});
        return 1;
    }

    fn builtinEcho(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;

        var no_newline = false;
        var interpret_escapes = false;
        var arg_start: usize = 0;

        // Parse flags (only at the beginning)
        for (command.args, 0..) |arg, i| {
            if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
                var valid_flag = true;
                var temp_no_newline = no_newline;
                var temp_interpret = interpret_escapes;

                for (arg[1..]) |c| {
                    switch (c) {
                        'n' => temp_no_newline = true,
                        'e' => temp_interpret = true,
                        'E' => temp_interpret = false,
                        else => {
                            valid_flag = false;
                            break;
                        },
                    }
                }

                if (valid_flag) {
                    no_newline = temp_no_newline;
                    interpret_escapes = temp_interpret;
                    arg_start = i + 1;
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        // Print arguments
        for (command.args[arg_start..], 0..) |arg, i| {
            if (interpret_escapes) {
                try printWithEscapes(arg);
            } else {
                try IO.print("{s}", .{arg});
            }
            if (i < command.args[arg_start..].len - 1) {
                try IO.print(" ", .{});
            }
        }

        if (!no_newline) {
            try IO.print("\n", .{});
        }
        return 0;
    }

    /// Helper function to print string with escape sequence interpretation
    fn printWithEscapes(s: []const u8) !void {
        var i: usize = 0;
        while (i < s.len) {
            if (s[i] == '\\' and i + 1 < s.len) {
                switch (s[i + 1]) {
                    'n' => {
                        try IO.print("\n", .{});
                        i += 2;
                    },
                    't' => {
                        try IO.print("\t", .{});
                        i += 2;
                    },
                    'r' => {
                        try IO.print("\r", .{});
                        i += 2;
                    },
                    '\\' => {
                        try IO.print("\\", .{});
                        i += 2;
                    },
                    'a' => {
                        try IO.print("\x07", .{}); // Bell
                        i += 2;
                    },
                    'b' => {
                        try IO.print("\x08", .{}); // Backspace
                        i += 2;
                    },
                    'f' => {
                        try IO.print("\x0c", .{}); // Form feed
                        i += 2;
                    },
                    'v' => {
                        try IO.print("\x0b", .{}); // Vertical tab
                        i += 2;
                    },
                    'e' => {
                        try IO.print("\x1b", .{}); // Escape
                        i += 2;
                    },
                    '0' => {
                        // Octal escape \0nnn
                        var val: u8 = 0;
                        var j: usize = i + 2;
                        var count: usize = 0;
                        while (j < s.len and count < 3) : (j += 1) {
                            if (s[j] >= '0' and s[j] <= '7') {
                                val = val * 8 + (s[j] - '0');
                                count += 1;
                            } else {
                                break;
                            }
                        }
                        if (count > 0) {
                            try IO.print("{c}", .{val});
                            i = j;
                        } else {
                            try IO.print("{c}", .{s[i]});
                            i += 1;
                        }
                    },
                    'x' => {
                        // Hex escape \xHH
                        if (i + 3 < s.len) {
                            const hex = s[i + 2 .. i + 4];
                            if (std.fmt.parseInt(u8, hex, 16)) |val| {
                                try IO.print("{c}", .{val});
                                i += 4;
                            } else |_| {
                                try IO.print("{c}", .{s[i]});
                                i += 1;
                            }
                        } else {
                            try IO.print("{c}", .{s[i]});
                            i += 1;
                        }
                    },
                    else => {
                        try IO.print("{c}", .{s[i]});
                        i += 1;
                    },
                }
            } else {
                try IO.print("{c}", .{s[i]});
                i += 1;
            }
        }
    }

    fn builtinPwd(self: *Executor, command: *types.ParsedCommand) !i32 {
        var use_physical = false;

        // Parse flags
        for (command.args) |arg| {
            if (std.mem.eql(u8, arg, "-P")) {
                use_physical = true;
            } else if (std.mem.eql(u8, arg, "-L")) {
                use_physical = false;
            } else if (arg.len > 0 and arg[0] == '-') {
                try IO.eprint("den: pwd: {s}: invalid option\n", .{arg});
                return 1;
            }
        }

        // Get current directory
        var buf: [std.fs.max_path_bytes]u8 = undefined;

        if (use_physical) {
            // -P: Physical path (resolve symlinks)
            const cwd = std.posix.getcwd(&buf) catch |err| {
                try IO.eprint("den: pwd: error getting current directory: {}\n", .{err});
                return 1;
            };
            try IO.print("{s}\n", .{cwd});
        } else {
            // -L: Logical path (default) - use PWD env var if set and valid
            if (self.environment.get("PWD")) |pwd| {
                // Verify the PWD env var points to current directory
                var real_buf: [std.fs.max_path_bytes]u8 = undefined;
                const real_cwd = std.posix.getcwd(&real_buf) catch null;

                if (real_cwd) |_| {
                    // PWD exists, use it (trust the logical path)
                    try IO.print("{s}\n", .{pwd});
                    return 0;
                }
            }
            // Fallback to physical path if PWD not set or invalid
            const cwd = std.posix.getcwd(&buf) catch |err| {
                try IO.eprint("den: pwd: error getting current directory: {}\n", .{err});
                return 1;
            };
            try IO.print("{s}\n", .{cwd});
        }
        return 0;
    }

    fn builtinCd(self: *Executor, command: *types.ParsedCommand) !i32 {
        var path = if (command.args.len > 0) command.args[0] else blk: {
            // Default to HOME
            if (self.environment.get("HOME")) |home| {
                break :blk home;
            }
            try IO.eprint("den: cd: HOME not set\n", .{});
            return 1;
        };

        // Handle special cd - (go to OLDPWD)
        if (std.mem.eql(u8, path, "-")) {
            if (self.environment.get("OLDPWD")) |oldpwd| {
                path = oldpwd;
                try IO.print("{s}\n", .{path});
            } else {
                try IO.eprint("den: cd: OLDPWD not set\n", .{});
                return 1;
            }
        }

        // Expand ~name for named directories (zsh-style)
        var expanded_path: ?[]const u8 = null;
        defer if (expanded_path) |p| self.allocator.free(p);

        if (path.len > 0 and path[0] == '~') {
            if (self.shell) |shell| {
                if (path.len > 1 and path[1] != '/') {
                    // ~name format - look up in named directories
                    const name_end = std.mem.indexOfAny(u8, path[1..], &[_]u8{ '/' }) orelse path.len - 1;
                    const name = path[1 .. name_end + 1];

                    if (shell.named_dirs.get(name)) |named_path| {
                        if (name_end + 1 < path.len) {
                            // ~name/rest format
                            expanded_path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ named_path, path[name_end + 1 ..] });
                            path = expanded_path.?;
                        } else {
                            // Just ~name
                            path = named_path;
                        }
                    }
                }
            }
        }

        // Save current directory as OLDPWD before changing
        var old_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const old_cwd = std.posix.getcwd(&old_cwd_buf) catch null;

        // Check if path is relative (doesn't start with / or ~ or .)
        const is_relative = path.len > 0 and path[0] != '/' and path[0] != '~' and path[0] != '.';

        // Try direct path first
        if (std.posix.chdir(path)) |_| {
            // Success - update OLDPWD
            if (old_cwd) |cwd| {
                const oldpwd_value = try self.allocator.dupe(u8, cwd);
                const gop = try self.environment.getOrPut("OLDPWD");
                if (gop.found_existing) {
                    self.allocator.free(gop.value_ptr.*);
                } else {
                    gop.key_ptr.* = try self.allocator.dupe(u8, "OLDPWD");
                }
                gop.value_ptr.* = oldpwd_value;
            }
            return 0;
        } else |direct_err| {
            // If relative path and CDPATH is set, try CDPATH directories
            if (is_relative) {
                if (self.environment.get("CDPATH")) |cdpath| {
                    var cdpath_path: ?[]const u8 = null;
                    defer if (cdpath_path) |p| self.allocator.free(p);

                    var iter = std.mem.splitScalar(u8, cdpath, ':');
                    while (iter.next()) |dir| {
                        // Build full path: dir/path
                        const full_path = if (dir.len == 0)
                            path // Empty entry means current directory
                        else blk: {
                            if (cdpath_path) |p| self.allocator.free(p);
                            cdpath_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, path });
                            break :blk cdpath_path.?;
                        };

                        if (std.posix.chdir(full_path)) |_| {
                            // Success via CDPATH - print directory and update OLDPWD
                            try IO.print("{s}\n", .{full_path});
                            if (old_cwd) |cwd| {
                                const oldpwd_value = try self.allocator.dupe(u8, cwd);
                                const gop = try self.environment.getOrPut("OLDPWD");
                                if (gop.found_existing) {
                                    self.allocator.free(gop.value_ptr.*);
                                } else {
                                    gop.key_ptr.* = try self.allocator.dupe(u8, "OLDPWD");
                                }
                                gop.value_ptr.* = oldpwd_value;
                            }
                            return 0;
                        } else |_| {
                            continue;
                        }
                    }
                }
            }

            // All attempts failed
            try IO.eprint("den: cd: {s}: {}\n", .{ path, direct_err });
            return 1;
        }
    }

    fn builtinEnv(self: *Executor) !i32 {
        var iter = self.environment.iterator();
        while (iter.next()) |entry| {
            try IO.print("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        return 0;
    }

    /// env command with VAR=value support
    /// Usage: env [-i] [-u name] [name=value]... [command [args]...]
    fn builtinEnvCmd(self: *Executor, command: *types.ParsedCommand) anyerror!i32 {
        // No args - just print environment
        if (command.args.len == 0) {
            return try self.builtinEnv();
        }

        // Parse flags and VAR=value assignments
        var ignore_env = false;
        var unset_vars = std.ArrayList([]const u8).empty;
        defer unset_vars.deinit(self.allocator);
        var env_overrides = std.ArrayList(struct { key: []const u8, value: []const u8 }).empty;
        defer env_overrides.deinit(self.allocator);

        var cmd_start: ?usize = null;
        var i: usize = 0;

        while (i < command.args.len) : (i += 1) {
            const arg = command.args[i];

            if (arg.len > 0 and arg[0] == '-') {
                // Parse flags
                if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-environment")) {
                    ignore_env = true;
                } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--unset")) {
                    // Next arg is the var name to unset
                    if (i + 1 < command.args.len) {
                        i += 1;
                        try unset_vars.append(self.allocator, command.args[i]);
                    } else {
                        try IO.eprint("env: option requires an argument -- 'u'\n", .{});
                        return 1;
                    }
                } else if (std.mem.eql(u8, arg, "--")) {
                    // End of options
                    cmd_start = i + 1;
                    break;
                } else if (std.mem.eql(u8, arg, "--help")) {
                    try IO.print("Usage: env [-i] [-u name] [name=value]... [command [args]...]\n", .{});
                    try IO.print("  -i, --ignore-environment  Start with empty environment\n", .{});
                    try IO.print("  -u, --unset=NAME          Unset variable NAME\n", .{});
                    return 0;
                } else {
                    try IO.eprint("env: invalid option -- '{s}'\n", .{arg});
                    return 1;
                }
            } else if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
                // VAR=value assignment (but only if key is valid - starts with letter/underscore)
                if (eq_pos > 0 and (std.ascii.isAlphabetic(arg[0]) or arg[0] == '_')) {
                    const key = arg[0..eq_pos];
                    const value = arg[eq_pos + 1 ..];
                    try env_overrides.append(self.allocator, .{ .key = key, .value = value });
                } else {
                    // Looks like a command (e.g., "/usr/bin/foo=bar" or "=foo")
                    cmd_start = i;
                    break;
                }
            } else {
                // This is the command to execute
                cmd_start = i;
                break;
            }
        }

        // If no command specified, just print modified environment
        if (cmd_start == null) {
            if (ignore_env) {
                // Only print overrides
                for (env_overrides.items) |override| {
                    try IO.print("{s}={s}\n", .{ override.key, override.value });
                }
            } else {
                // Print modified environment
                var iter = self.environment.iterator();
                while (iter.next()) |entry| {
                    // Skip if unset
                    var is_unset = false;
                    for (unset_vars.items) |unset_var| {
                        if (std.mem.eql(u8, entry.key_ptr.*, unset_var)) {
                            is_unset = true;
                            break;
                        }
                    }
                    if (is_unset) continue;

                    // Check if overridden
                    var is_overridden = false;
                    for (env_overrides.items) |override| {
                        if (std.mem.eql(u8, entry.key_ptr.*, override.key)) {
                            is_overridden = true;
                            break;
                        }
                    }
                    if (!is_overridden) {
                        try IO.print("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                    }
                }
                // Print overrides
                for (env_overrides.items) |override| {
                    try IO.print("{s}={s}\n", .{ override.key, override.value });
                }
            }
            return 0;
        }

        // Execute command with modified environment
        // Save original OS env values to restore later
        var saved_os_env = std.StringHashMap(?[]const u8).init(self.allocator);
        defer {
            // Free any allocated values
            var iter = saved_os_env.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.*) |v| {
                    self.allocator.free(v);
                }
            }
            saved_os_env.deinit();
        }

        // Apply unsets to OS environment
        for (unset_vars.items) |unset_var| {
            // Save original OS env value
            const original = std.posix.getenv(unset_var);
            if (original) |orig| {
                try saved_os_env.put(unset_var, try self.allocator.dupe(u8, orig));
            } else {
                try saved_os_env.put(unset_var, null);
            }
            // Unset in OS environment
            const unset_var_z = try self.allocator.dupeZ(u8, unset_var);
            defer self.allocator.free(unset_var_z);
            _ = libc_env.unsetenv(unset_var_z.ptr);
        }

        // Apply overrides to OS environment
        for (env_overrides.items) |override| {
            // Save original OS env value
            if (!saved_os_env.contains(override.key)) {
                const original = std.posix.getenv(override.key);
                if (original) |orig| {
                    try saved_os_env.put(override.key, try self.allocator.dupe(u8, orig));
                } else {
                    try saved_os_env.put(override.key, null);
                }
            }
            // Set in OS environment
            const key_z = try self.allocator.dupeZ(u8, override.key);
            defer self.allocator.free(key_z);
            const value_z = try self.allocator.dupeZ(u8, override.value);
            defer self.allocator.free(value_z);
            _ = libc_env.setenv(key_z.ptr, value_z.ptr, 1);
        }

        // Build new command from remaining args
        const start = cmd_start.?; // We know it's set if we got here
        const cmd_name = command.args[start];
        const cmd_args: [][]const u8 = if (start + 1 < command.args.len)
            @constCast(command.args[start + 1 ..])
        else
            @constCast(&[_][]const u8{});

        // Create a new ParsedCommand for the actual command
        var new_cmd = types.ParsedCommand{
            .name = cmd_name,
            .args = cmd_args,
            .redirections = @constCast(command.redirections),
        };

        // Execute the command
        const result = self.executeCommand(&new_cmd) catch |err| {
            // Restore OS environment on error
            self.restoreOsEnv(&saved_os_env);
            return err;
        };

        // Restore OS environment
        self.restoreOsEnv(&saved_os_env);

        return result;
    }

    fn restoreOsEnv(self: *Executor, saved_os_env: *std.StringHashMap(?[]const u8)) void {
        var iter = saved_os_env.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const key_z = self.allocator.dupeZ(u8, key) catch continue;
            defer self.allocator.free(key_z);

            if (entry.value_ptr.*) |original_value| {
                // Restore original value
                const value_z = self.allocator.dupeZ(u8, original_value) catch continue;
                defer self.allocator.free(value_z);
                _ = libc_env.setenv(key_z.ptr, value_z.ptr, 1);
            } else {
                // Was not set originally, unset it
                _ = libc_env.unsetenv(key_z.ptr);
            }
        }
    }

    fn builtinExport(self: *Executor, command: *types.ParsedCommand) !i32 {
        // export [-fnp] [VAR[=value] ...]
        if (command.args.len == 0) {
            // No args - print all exported variables (same as env for now)
            return try self.builtinEnv();
        }

        // Check for --help
        if (command.args.len == 1 and std.mem.eql(u8, command.args[0], "--help")) {
            try IO.print("Usage: export [-fnp] [name[=value] ...]\n", .{});
            try IO.print("Set export attribute for shell variables.\n\n", .{});
            try IO.print("Options:\n", .{});
            try IO.print("  -f    treat each NAME as a shell function\n", .{});
            try IO.print("  -n    remove the export property from NAME\n", .{});
            try IO.print("  -p    display all exported variables and functions\n", .{});
            try IO.print("\nWith no NAME, display all exported variables.\n", .{});
            return 0;
        }

        // Check for -p flag (print in reusable format)
        if (command.args.len == 1 and std.mem.eql(u8, command.args[0], "-p")) {
            // Print all variables in export format
            var iter = self.environment.iterator();
            while (iter.next()) |entry| {
                // Escape value for shell reuse
                try IO.print("export {s}=\"", .{entry.key_ptr.*});
                for (entry.value_ptr.*) |c| {
                    switch (c) {
                        '"' => try IO.print("\\\"", .{}),
                        '\\' => try IO.print("\\\\", .{}),
                        '$' => try IO.print("\\$", .{}),
                        '`' => try IO.print("\\`", .{}),
                        '\n' => try IO.print("\\n", .{}),
                        else => try IO.print("{c}", .{c}),
                    }
                }
                try IO.print("\"\n", .{});
            }
            return 0;
        }

        // Check for -n flag (unexport)
        var arg_start: usize = 0;
        var unexport_mode = false;
        if (command.args.len > 0 and std.mem.eql(u8, command.args[0], "-n")) {
            unexport_mode = true;
            arg_start = 1;
        }

        if (unexport_mode) {
            // -n: Remove variables from environment
            for (command.args[arg_start..]) |arg| {
                if (self.environment.fetchRemove(arg)) |kv| {
                    self.allocator.free(kv.key);
                    self.allocator.free(kv.value);
                }
            }
            return 0;
        }

        for (command.args[arg_start..]) |arg| {
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

        var arg_idx: usize = 0;
        while (arg_idx < command.args.len) {
            const arg = command.args[arg_idx];

            // Handle shell options (-e, -E, +e, +E, etc.)
            if (arg.len > 0 and (arg[0] == '-' or arg[0] == '+')) {
                const enable = arg[0] == '-';
                const option = arg[1..];

                if (self.shell) |shell| {
                    if (std.mem.eql(u8, option, "e")) {
                        shell.option_errexit = enable;
                    } else if (std.mem.eql(u8, option, "E")) {
                        shell.option_errtrace = enable;
                    } else if (std.mem.eql(u8, option, "x")) {
                        shell.option_xtrace = enable;
                    } else if (std.mem.eql(u8, option, "u")) {
                        shell.option_nounset = enable;
                    } else if (std.mem.eql(u8, option, "n")) {
                        shell.option_noexec = enable;
                    } else if (std.mem.eql(u8, option, "v")) {
                        shell.option_verbose = enable;
                    } else if (std.mem.eql(u8, option, "f")) {
                        shell.option_noglob = enable;
                    } else if (std.mem.eql(u8, option, "C")) {
                        shell.option_noclobber = enable;
                    } else if (std.mem.eql(u8, option, "o")) {
                        // set -o [option_name] / set +o [option_name]
                        if (arg_idx + 1 < command.args.len) {
                            // Next arg is the option name
                            const opt_name = command.args[arg_idx + 1];
                            if (std.mem.eql(u8, opt_name, "errexit")) {
                                shell.option_errexit = enable;
                            } else if (std.mem.eql(u8, opt_name, "errtrace")) {
                                shell.option_errtrace = enable;
                            } else if (std.mem.eql(u8, opt_name, "xtrace")) {
                                shell.option_xtrace = enable;
                            } else if (std.mem.eql(u8, opt_name, "nounset")) {
                                shell.option_nounset = enable;
                            } else if (std.mem.eql(u8, opt_name, "pipefail")) {
                                shell.option_pipefail = enable;
                            } else if (std.mem.eql(u8, opt_name, "noexec")) {
                                shell.option_noexec = enable;
                            } else if (std.mem.eql(u8, opt_name, "verbose")) {
                                shell.option_verbose = enable;
                            } else if (std.mem.eql(u8, opt_name, "noglob")) {
                                shell.option_noglob = enable;
                            } else if (std.mem.eql(u8, opt_name, "noclobber")) {
                                shell.option_noclobber = enable;
                            } else {
                                try IO.eprint("den: set: {s}: invalid option name\n", .{opt_name});
                                return 1;
                            }
                            arg_idx += 1; // Skip the option name
                        } else {
                            // No option name, list all options
                            try IO.print("Current option settings:\n", .{});
                            try IO.print("errexit        {s}\n", .{if (shell.option_errexit) "on" else "off"});
                            try IO.print("errtrace       {s}\n", .{if (shell.option_errtrace) "on" else "off"});
                            try IO.print("xtrace         {s}\n", .{if (shell.option_xtrace) "on" else "off"});
                            try IO.print("nounset        {s}\n", .{if (shell.option_nounset) "on" else "off"});
                            try IO.print("pipefail       {s}\n", .{if (shell.option_pipefail) "on" else "off"});
                            try IO.print("noexec         {s}\n", .{if (shell.option_noexec) "on" else "off"});
                            try IO.print("verbose        {s}\n", .{if (shell.option_verbose) "on" else "off"});
                            try IO.print("noglob         {s}\n", .{if (shell.option_noglob) "on" else "off"});
                            try IO.print("noclobber      {s}\n", .{if (shell.option_noclobber) "on" else "off"});
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
            arg_idx += 1;
        }

        return 0;
    }

    fn builtinUnset(self: *Executor, command: *types.ParsedCommand) !i32 {
        // unset [-fv] [name ...]
        // -f: unset functions only
        // -v: unset variables only (default)
        if (command.args.len == 0) {
            try IO.eprint("den: unset: not enough arguments\n", .{});
            return 1;
        }

        var unset_functions = false;
        var unset_variables = true;
        var arg_start: usize = 0;

        // Parse flags
        for (command.args, 0..) |arg, i| {
            if (arg.len > 0 and arg[0] == '-') {
                if (std.mem.eql(u8, arg, "-f")) {
                    unset_functions = true;
                    unset_variables = false;
                    arg_start = i + 1;
                } else if (std.mem.eql(u8, arg, "-v")) {
                    unset_variables = true;
                    unset_functions = false;
                    arg_start = i + 1;
                } else if (std.mem.eql(u8, arg, "-fv") or std.mem.eql(u8, arg, "-vf")) {
                    unset_variables = true;
                    unset_functions = true;
                    arg_start = i + 1;
                } else if (std.mem.eql(u8, arg, "--help")) {
                    try IO.print("Usage: unset [-fv] name [...]\n", .{});
                    try IO.print("Remove NAME from the shell environment.\n\n", .{});
                    try IO.print("Options:\n", .{});
                    try IO.print("  -f    treat each NAME as a shell function\n", .{});
                    try IO.print("  -v    treat each NAME as a shell variable (default)\n", .{});
                    return 0;
                } else if (std.mem.eql(u8, arg, "--")) {
                    arg_start = i + 1;
                    break;
                } else {
                    try IO.eprint("den: unset: invalid option -- '{s}'\n", .{arg});
                    return 1;
                }
            } else {
                break;
            }
        }

        if (arg_start >= command.args.len) {
            try IO.eprint("den: unset: not enough arguments\n", .{});
            return 1;
        }

        // Unset variables
        if (unset_variables) {
            for (command.args[arg_start..]) |var_name| {
                if (self.environment.fetchRemove(var_name)) |entry| {
                    // Free the removed key and value
                    self.allocator.free(entry.key);
                    self.allocator.free(entry.value);
                }
            }
        }

        // Unset functions
        if (unset_functions) {
            if (self.shell) |shell| {
                for (command.args[arg_start..]) |func_name| {
                    shell.function_manager.removeFunction(func_name);
                }
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

    /// Extended test builtin [[ ]] with pattern matching and regex support
    fn builtinExtendedTest(self: *Executor, command: *types.ParsedCommand) !i32 {
        // Remove trailing ]] if present
        var args = command.args;
        if (args.len > 0 and std.mem.eql(u8, args[args.len - 1], "]]")) {
            args = args[0 .. args.len - 1];
        }

        if (args.len == 0) return 1; // Empty test is false

        // Handle compound expressions with && and ||
        // First, check for these operators at the top level
        var i: usize = 0;
        var last_result: bool = true;
        var pending_op: ?enum { and_op, or_op } = null;

        while (i < args.len) {
            // Find the next && or || or end of args
            var expr_end = i;
            var paren_depth: u32 = 0;
            while (expr_end < args.len) {
                const arg = args[expr_end];
                if (std.mem.eql(u8, arg, "(")) {
                    paren_depth += 1;
                } else if (std.mem.eql(u8, arg, ")")) {
                    if (paren_depth > 0) paren_depth -= 1;
                } else if (paren_depth == 0) {
                    if (std.mem.eql(u8, arg, "&&") or std.mem.eql(u8, arg, "||")) {
                        break;
                    }
                }
                expr_end += 1;
            }

            // Evaluate the sub-expression
            const sub_result = try self.evaluateExtendedTestExpr(args[i..expr_end]);

            // Apply pending operator
            if (pending_op) |op| {
                switch (op) {
                    .and_op => last_result = last_result and sub_result,
                    .or_op => last_result = last_result or sub_result,
                }
            } else {
                last_result = sub_result;
            }

            // Short-circuit evaluation
            if (expr_end < args.len) {
                const op_str = args[expr_end];
                if (std.mem.eql(u8, op_str, "&&")) {
                    if (!last_result) return 1; // Short-circuit: false && ... = false
                    pending_op = .and_op;
                } else if (std.mem.eql(u8, op_str, "||")) {
                    if (last_result) return 0; // Short-circuit: true || ... = true
                    pending_op = .or_op;
                }
                i = expr_end + 1;
            } else {
                break;
            }
        }

        return if (last_result) 0 else 1;
    }

    /// Evaluate a single extended test expression (without && / ||)
    fn evaluateExtendedTestExpr(self: *Executor, args: [][]const u8) !bool {
        if (args.len == 0) return false;

        // Handle negation
        if (args.len >= 1 and std.mem.eql(u8, args[0], "!")) {
            return !(try self.evaluateExtendedTestExpr(args[1..]));
        }

        // Handle parentheses
        if (args.len >= 2 and std.mem.eql(u8, args[0], "(")) {
            // Find matching close paren
            var depth: u32 = 1;
            var close_idx: usize = 1;
            while (close_idx < args.len and depth > 0) {
                if (std.mem.eql(u8, args[close_idx], "(")) depth += 1;
                if (std.mem.eql(u8, args[close_idx], ")")) depth -= 1;
                if (depth > 0) close_idx += 1;
            }
            if (close_idx < args.len) {
                return try self.evaluateExtendedTestExpr(args[1..close_idx]);
            }
        }

        // Single argument - test if non-empty string
        if (args.len == 1) {
            return args[0].len > 0;
        }

        // Two arguments - unary operators
        if (args.len == 2) {
            const op = args[0];
            const arg = args[1];

            if (std.mem.eql(u8, op, "-z")) {
                return arg.len == 0;
            } else if (std.mem.eql(u8, op, "-n")) {
                return arg.len > 0;
            } else if (std.mem.eql(u8, op, "-f")) {
                const file = std.fs.cwd().openFile(arg, .{}) catch return false;
                defer file.close();
                const stat = file.stat() catch return false;
                return stat.kind == .file;
            } else if (std.mem.eql(u8, op, "-d")) {
                var dir = std.fs.cwd().openDir(arg, .{}) catch return false;
                dir.close();
                return true;
            } else if (std.mem.eql(u8, op, "-e")) {
                std.fs.cwd().access(arg, .{}) catch return false;
                return true;
            } else if (std.mem.eql(u8, op, "-r")) {
                const file = std.fs.cwd().openFile(arg, .{}) catch return false;
                file.close();
                return true;
            } else if (std.mem.eql(u8, op, "-w")) {
                const file = std.fs.cwd().openFile(arg, .{ .mode = .write_only }) catch return false;
                file.close();
                return true;
            } else if (std.mem.eql(u8, op, "-x")) {
                if (builtin.os.tag == .windows) {
                    std.fs.cwd().access(arg, .{}) catch return false;
                    return true;
                }
                const file = std.fs.cwd().openFile(arg, .{}) catch return false;
                defer file.close();
                const stat = file.stat() catch return false;
                return stat.mode & 0o111 != 0;
            } else if (std.mem.eql(u8, op, "-s")) {
                // True if file exists and has size > 0
                const file = std.fs.cwd().openFile(arg, .{}) catch return false;
                defer file.close();
                const stat = file.stat() catch return false;
                return stat.size > 0;
            } else if (std.mem.eql(u8, op, "-L") or std.mem.eql(u8, op, "-h")) {
                // True if file is a symlink
                const stat = std.fs.cwd().statFile(arg) catch return false;
                return stat.kind == .sym_link;
            }
        }

        // Three arguments - binary operators
        if (args.len == 3) {
            const left = args[0];
            const op = args[1];
            const right = args[2];

            // String comparison with pattern matching
            if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "=")) {
                // Pattern matching: right side can contain * and ?
                return self.matchGlobPattern(left, right);
            } else if (std.mem.eql(u8, op, "!=")) {
                return !self.matchGlobPattern(left, right);
            } else if (std.mem.eql(u8, op, "=~")) {
                // Regex matching
                return self.matchRegex(left, right);
            } else if (std.mem.eql(u8, op, "<")) {
                // Lexicographic comparison
                return std.mem.lessThan(u8, left, right);
            } else if (std.mem.eql(u8, op, ">")) {
                // Lexicographic comparison
                return std.mem.lessThan(u8, right, left);
            } else if (std.mem.eql(u8, op, "-eq")) {
                const left_num = std.fmt.parseInt(i64, left, 10) catch return false;
                const right_num = std.fmt.parseInt(i64, right, 10) catch return false;
                return left_num == right_num;
            } else if (std.mem.eql(u8, op, "-ne")) {
                const left_num = std.fmt.parseInt(i64, left, 10) catch return false;
                const right_num = std.fmt.parseInt(i64, right, 10) catch return false;
                return left_num != right_num;
            } else if (std.mem.eql(u8, op, "-lt")) {
                const left_num = std.fmt.parseInt(i64, left, 10) catch return false;
                const right_num = std.fmt.parseInt(i64, right, 10) catch return false;
                return left_num < right_num;
            } else if (std.mem.eql(u8, op, "-le")) {
                const left_num = std.fmt.parseInt(i64, left, 10) catch return false;
                const right_num = std.fmt.parseInt(i64, right, 10) catch return false;
                return left_num <= right_num;
            } else if (std.mem.eql(u8, op, "-gt")) {
                const left_num = std.fmt.parseInt(i64, left, 10) catch return false;
                const right_num = std.fmt.parseInt(i64, right, 10) catch return false;
                return left_num > right_num;
            } else if (std.mem.eql(u8, op, "-ge")) {
                const left_num = std.fmt.parseInt(i64, left, 10) catch return false;
                const right_num = std.fmt.parseInt(i64, right, 10) catch return false;
                return left_num >= right_num;
            } else if (std.mem.eql(u8, op, "-nt")) {
                // Newer than (file modification time)
                const left_stat = std.fs.cwd().statFile(left) catch return false;
                const right_stat = std.fs.cwd().statFile(right) catch return false;
                // Compare nanoseconds directly (Zig 0.16 Timestamp has single nanoseconds field)
                return left_stat.mtime.nanoseconds > right_stat.mtime.nanoseconds;
            } else if (std.mem.eql(u8, op, "-ot")) {
                // Older than (file modification time)
                const left_stat = std.fs.cwd().statFile(left) catch return false;
                const right_stat = std.fs.cwd().statFile(right) catch return false;
                return left_stat.mtime.nanoseconds < right_stat.mtime.nanoseconds;
            } else if (std.mem.eql(u8, op, "-ef")) {
                // Same file (same inode)
                const left_stat = std.fs.cwd().statFile(left) catch return false;
                const right_stat = std.fs.cwd().statFile(right) catch return false;
                return left_stat.inode == right_stat.inode;
            }
        }

        return false;
    }

    /// Simple glob pattern matching for [[ == ]]
    fn matchGlobPattern(self: *Executor, str: []const u8, pattern: []const u8) bool {
        _ = self;
        return globMatch(str, pattern);
    }

    /// Simple regex matching for [[ =~ ]]
    /// Supports: ^ (start anchor), $ (end anchor), . (any char), simple literal matching
    fn matchRegex(self: *Executor, str: []const u8, pattern: []const u8) bool {
        _ = self;
        if (pattern.len == 0) return true;

        const anchored_start = pattern[0] == '^';
        const anchored_end = pattern.len > 0 and pattern[pattern.len - 1] == '$';

        var actual_pattern = pattern;
        if (anchored_start) actual_pattern = actual_pattern[1..];
        if (anchored_end and actual_pattern.len > 0) actual_pattern = actual_pattern[0 .. actual_pattern.len - 1];

        if (actual_pattern.len == 0) {
            // ^$ matches empty string only
            return str.len == 0;
        }

        // Simple approach: try to find pattern in string
        if (anchored_start and anchored_end) {
            // Must match entire string
            return simplePatternMatch(str, actual_pattern);
        } else if (anchored_start) {
            // Must match at start
            return str.len >= actual_pattern.len and simplePatternMatch(str[0..actual_pattern.len], actual_pattern);
        } else if (anchored_end) {
            // Must match at end
            if (str.len < actual_pattern.len) return false;
            return simplePatternMatch(str[str.len - actual_pattern.len ..], actual_pattern);
        } else {
            // Find anywhere in string
            if (str.len < actual_pattern.len) return false;
            var i: usize = 0;
            while (i <= str.len - actual_pattern.len) : (i += 1) {
                if (simplePatternMatch(str[i .. i + actual_pattern.len], actual_pattern)) {
                    return true;
                }
            }
            return false;
        }
    }

    fn simplePatternMatch(str: []const u8, pattern: []const u8) bool {
        if (str.len != pattern.len) return false;
        for (str, pattern) |s, p| {
            if (p != '.' and s != p) return false;
        }
        return true;
    }

    fn builtinWhich(self: *Executor, command: *types.ParsedCommand) !i32 {
        if (command.args.len == 0) {
            try IO.eprint("den: which: missing argument\n", .{});
            return 1;
        }

        const utils = @import("../utils.zig");
        var found_all = true;
        var show_all = false;
        var arg_start: usize = 0;

        // Parse flags
        for (command.args, 0..) |arg, i| {
            if (arg.len > 0 and arg[0] == '-') {
                for (arg[1..]) |c| {
                    switch (c) {
                        'a' => show_all = true,
                        else => {},
                    }
                }
                arg_start = i + 1;
            } else {
                break;
            }
        }

        if (arg_start >= command.args.len) {
            try IO.eprint("den: which: missing argument\n", .{});
            return 1;
        }

        for (command.args[arg_start..]) |cmd_name| {
            // Check if it's a builtin
            if (self.isBuiltin(cmd_name)) {
                try IO.print("{s}: shell builtin command\n", .{cmd_name});
                if (!show_all) continue;
            }

            // Parse PATH and find executable
            var path_list = utils.env.PathList.fromEnv(self.allocator) catch {
                try IO.eprint("den: which: failed to parse PATH\n", .{});
                return 1;
            };
            defer path_list.deinit();

            if (show_all) {
                // Find all matches
                const all_paths = try path_list.findAllExecutables(self.allocator, cmd_name);
                defer {
                    for (all_paths) |p| self.allocator.free(p);
                    self.allocator.free(all_paths);
                }

                if (all_paths.len == 0 and !self.isBuiltin(cmd_name)) {
                    found_all = false;
                } else {
                    for (all_paths) |exec_path| {
                        try IO.print("{s}\n", .{exec_path});
                    }
                }
            } else {
                // Find first match only
                if (try path_list.findExecutable(self.allocator, cmd_name)) |exec_path| {
                    defer self.allocator.free(exec_path);
                    try IO.print("{s}\n", .{exec_path});
                } else {
                    found_all = false;
                }
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

        // Parse flags
        var show_all = false;      // -a: show all matches
        var type_only = false;     // -t: show type only (builtin, file, alias, etc.)
        var path_only = false;     // -p: show path only (for external commands)
        var arg_start: usize = 0;

        for (command.args, 0..) |arg, i| {
            if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
                for (arg[1..]) |c| {
                    switch (c) {
                        'a' => show_all = true,
                        't' => type_only = true,
                        'p' => path_only = true,
                        else => {
                            try IO.eprint("den: type: -{c}: invalid option\n", .{c});
                            return 1;
                        },
                    }
                }
                arg_start = i + 1;
            } else {
                break;
            }
        }

        if (arg_start >= command.args.len) {
            try IO.eprint("den: type: missing argument\n", .{});
            return 1;
        }

        var found_all = true;

        for (command.args[arg_start..]) |cmd_name| {
            var found_any = false;

            // Check if it's a builtin
            if (self.isBuiltin(cmd_name)) {
                found_any = true;
                if (type_only) {
                    try IO.print("builtin\n", .{});
                } else if (!path_only) {
                    try IO.print("{s} is a shell builtin\n", .{cmd_name});
                }
                if (!show_all) continue;
            }

            // Check if it's in PATH
            var path_list = utils.env.PathList.fromEnv(self.allocator) catch {
                try IO.eprint("den: type: failed to parse PATH\n", .{});
                return 1;
            };
            defer path_list.deinit();

            if (show_all) {
                // Show all matches in PATH
                for (path_list.paths.items) |path_dir| {
                    const full_path = std.fs.path.join(self.allocator, &[_][]const u8{ path_dir, cmd_name }) catch continue;
                    defer self.allocator.free(full_path);

                    // Check if file exists and is executable
                    std.fs.accessAbsolute(full_path, .{}) catch continue;

                    if (builtin.os.tag != .windows) {
                        const file = std.fs.openFileAbsolute(full_path, .{}) catch continue;
                        defer file.close();
                        const stat = file.stat() catch continue;
                        if (stat.mode & 0o111 == 0) continue;
                    }

                    found_any = true;
                    if (type_only) {
                        try IO.print("file\n", .{});
                    } else if (path_only) {
                        try IO.print("{s}\n", .{full_path});
                    } else {
                        try IO.print("{s} is {s}\n", .{ cmd_name, full_path });
                    }
                }
            } else {
                // Just find first match
                if (try path_list.findExecutable(self.allocator, cmd_name)) |exec_path| {
                    defer self.allocator.free(exec_path);
                    found_any = true;
                    if (type_only) {
                        try IO.print("file\n", .{});
                    } else if (path_only) {
                        try IO.print("{s}\n", .{exec_path});
                    } else {
                        try IO.print("{s} is {s}\n", .{ cmd_name, exec_path });
                    }
                }
            }

            if (!found_any) {
                if (!type_only and !path_only) {
                    try IO.print("den: type: {s}: not found\n", .{cmd_name});
                }
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
        try IO.print("  copyssh           Copy SSH public key to clipboard\n", .{});

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
        // Parse options: -p prompt, -r (raw), -a (array), -d (delimiter), -n (nchars), -s (silent), -t (timeout)
        var prompt: ?[]const u8 = null;
        var raw_mode = false;
        var array_name: ?[]const u8 = null; // -a: read into array
        var delimiter: u8 = '\n'; // -d: delimiter character
        var nchars: ?usize = null; // -n: read exactly n characters
        var silent = false; // -s: don't echo input
        var timeout_secs: ?f64 = null; // -t: timeout in seconds
        var var_name_start: usize = 0;

        var i: usize = 0;
        while (i < command.args.len) : (i += 1) {
            const arg = command.args[i];
            if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
                if (std.mem.eql(u8, arg, "-p")) {
                    // Next arg is the prompt
                    i += 1;
                    if (i >= command.args.len) {
                        try IO.eprint("den: read: -p requires an argument\n", .{});
                        return 1;
                    }
                    prompt = command.args[i];
                } else if (std.mem.eql(u8, arg, "-r")) {
                    raw_mode = true;
                } else if (std.mem.eql(u8, arg, "-a")) {
                    // Next arg is the array name
                    i += 1;
                    if (i >= command.args.len) {
                        try IO.eprint("den: read: -a requires an argument\n", .{});
                        return 1;
                    }
                    array_name = command.args[i];
                } else if (std.mem.eql(u8, arg, "-d")) {
                    // Next arg is the delimiter
                    i += 1;
                    if (i >= command.args.len) {
                        try IO.eprint("den: read: -d requires an argument\n", .{});
                        return 1;
                    }
                    if (command.args[i].len > 0) {
                        delimiter = command.args[i][0];
                    } else {
                        delimiter = 0; // Empty string means NUL delimiter
                    }
                } else if (std.mem.eql(u8, arg, "-n")) {
                    // Next arg is the number of characters
                    i += 1;
                    if (i >= command.args.len) {
                        try IO.eprint("den: read: -n requires an argument\n", .{});
                        return 1;
                    }
                    nchars = std.fmt.parseInt(usize, command.args[i], 10) catch {
                        try IO.eprint("den: read: {s}: invalid number\n", .{command.args[i]});
                        return 1;
                    };
                } else if (std.mem.eql(u8, arg, "-s")) {
                    silent = true;
                } else if (std.mem.eql(u8, arg, "-t")) {
                    // Next arg is the timeout in seconds
                    i += 1;
                    if (i >= command.args.len) {
                        try IO.eprint("den: read: -t requires an argument\n", .{});
                        return 1;
                    }
                    timeout_secs = std.fmt.parseFloat(f64, command.args[i]) catch {
                        try IO.eprint("den: read: {s}: invalid timeout\n", .{command.args[i]});
                        return 1;
                    };
                } else {
                    try IO.eprint("den: read: invalid option: {s}\n", .{arg});
                    return 1;
                }
            } else {
                // First variable name found
                var_name_start = i;
                break;
            }
        }

        // Get variable names (remaining args after options)
        const var_names = if (var_name_start < command.args.len)
            command.args[var_name_start..]
        else if (array_name == null)
            &[_][]const u8{"REPLY"}
        else
            &[_][]const u8{};

        // Display prompt if specified (no newline)
        if (prompt) |p| {
            try IO.writeBytes(p);
        }

        // Note: -s (silent) would require terminal manipulation (tcsetattr) to disable echo
        // For now, we acknowledge the flag but don't fully implement terminal control
        if (silent) {
            // Silent mode acknowledged - terminal echo control not yet implemented
        }

        // Note: -t (timeout) would require non-blocking I/O or poll/select
        // For now, we acknowledge the flag but don't implement actual timeout
        if (timeout_secs) |_| {
            // Timeout acknowledged - not yet implemented
        }

        // Read input based on mode
        var line_buf: [4096]u8 = undefined;
        var line_len: usize = 0;

        if (nchars) |n| {
            // Read exactly n characters using posix read
            var chars_read: usize = 0;
            while (chars_read < n and chars_read < line_buf.len) {
                var byte_buf: [1]u8 = undefined;
                const bytes_read = std.posix.read(std.posix.STDIN_FILENO, &byte_buf) catch break;
                if (bytes_read == 0) break; // EOF
                line_buf[chars_read] = byte_buf[0];
                chars_read += 1;
            }
            line_len = chars_read;
        } else if (delimiter != '\n') {
            // Read until delimiter using posix read
            while (line_len < line_buf.len) {
                var byte_buf: [1]u8 = undefined;
                const bytes_read = std.posix.read(std.posix.STDIN_FILENO, &byte_buf) catch break;
                if (bytes_read == 0) break; // EOF
                if (byte_buf[0] == delimiter) break;
                line_buf[line_len] = byte_buf[0];
                line_len += 1;
            }
        } else {
            // Normal line read
            const line_opt = try IO.readLine(self.allocator);
            if (line_opt) |line| {
                defer self.allocator.free(line);
                const copy_len = @min(line.len, line_buf.len);
                @memcpy(line_buf[0..copy_len], line[0..copy_len]);
                line_len = copy_len;
            } else {
                // EOF
                if (array_name) |arr_name| {
                    // Set empty array
                    if (self.shell) |shell_ref| {
                        if (shell_ref.arrays.fetchRemove(arr_name)) |old| {
                            for (old.value) |elem| {
                                self.allocator.free(elem);
                            }
                            self.allocator.free(old.value);
                            self.allocator.free(old.key);
                        }
                    }
                } else {
                    for (var_names) |var_name| {
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
                }
                return 1; // EOF returns 1
            }
        }

        const line = line_buf[0..line_len];

        // Process line (handle backslash escapes unless -r)
        var processed_line: []const u8 = line;
        var processed_buf: [4096]u8 = undefined;

        if (!raw_mode) {
            // Process backslash escapes
            var pos: usize = 0;
            var j: usize = 0;
            while (j < line.len and pos < processed_buf.len) {
                if (line[j] == '\\' and j + 1 < line.len) {
                    // Skip the backslash and include the next char
                    j += 1;
                    processed_buf[pos] = line[j];
                } else {
                    processed_buf[pos] = line[j];
                }
                j += 1;
                pos += 1;
            }
            processed_line = processed_buf[0..pos];
        }

        // Handle -a (array) mode
        if (array_name) |arr_name| {
            const shell_ref = self.shell orelse {
                try IO.eprint("den: read: -a requires shell context\n", .{});
                return 1;
            };

            // Split by IFS and store in array
            var words = std.ArrayList([]const u8).empty;
            defer words.deinit(self.allocator);

            var word_iter = std.mem.tokenizeAny(u8, processed_line, " \t");
            while (word_iter.next()) |word| {
                try words.append(self.allocator, try self.allocator.dupe(u8, word));
            }

            // Remove old array if exists
            if (shell_ref.arrays.fetchRemove(arr_name)) |old| {
                for (old.value) |elem| {
                    self.allocator.free(elem);
                }
                self.allocator.free(old.value);
                self.allocator.free(old.key);
            }

            // Store new array
            const key = try self.allocator.dupe(u8, arr_name);
            const arr_slice = try words.toOwnedSlice(self.allocator);
            try shell_ref.arrays.put(key, arr_slice);

            return 0;
        }

        // Split by IFS if multiple variable names
        if (var_names.len == 1) {
            // Single variable - store entire line
            const var_name = var_names[0];
            const value = try self.allocator.dupe(u8, processed_line);
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
            // Multiple variables - split by whitespace (IFS)
            var word_iter = std.mem.tokenizeAny(u8, processed_line, " \t");
            var var_idx: usize = 0;

            while (var_idx < var_names.len) : (var_idx += 1) {
                const var_name = var_names[var_idx];
                var value: []const u8 = "";

                if (var_idx == var_names.len - 1) {
                    // Last variable gets rest of the line
                    if (word_iter.next()) |first_word| {
                        const rest_start = @intFromPtr(first_word.ptr) - @intFromPtr(processed_line.ptr);
                        value = processed_line[rest_start..];
                    }
                } else {
                    if (word_iter.next()) |word| {
                        value = word;
                    }
                }

                const duped_value = try self.allocator.dupe(u8, value);
                const gop = try self.environment.getOrPut(var_name);
                if (gop.found_existing) {
                    self.allocator.free(gop.value_ptr.*);
                    gop.value_ptr.* = duped_value;
                } else {
                    const key = try self.allocator.dupe(u8, var_name);
                    gop.key_ptr.* = key;
                    gop.value_ptr.* = duped_value;
                }
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
                // Parse optional flags, width, and precision
                var j = i + 1;
                var left_justify = false;
                var zero_pad = false;
                var width: usize = 0;
                var precision: usize = 6; // Default precision for floats
                var has_precision = false;

                // Parse flags
                while (j < format.len) {
                    if (format[j] == '-') {
                        left_justify = true;
                        j += 1;
                    } else if (format[j] == '0') {
                        zero_pad = true;
                        j += 1;
                    } else if (format[j] == '+' or format[j] == ' ' or format[j] == '#') {
                        j += 1; // Skip unsupported flags
                    } else {
                        break;
                    }
                }

                // Parse width
                while (j < format.len and format[j] >= '0' and format[j] <= '9') {
                    width = width * 10 + (format[j] - '0');
                    j += 1;
                }

                // Parse precision
                if (j < format.len and format[j] == '.') {
                    j += 1;
                    precision = 0;
                    has_precision = true;
                    while (j < format.len and format[j] >= '0' and format[j] <= '9') {
                        precision = precision * 10 + (format[j] - '0');
                        j += 1;
                    }
                }

                if (j >= format.len) {
                    try IO.print("{c}", .{format[i]});
                    i += 1;
                    continue;
                }

                const spec = format[j];
                if (spec == 's') {
                    // String format
                    if (arg_idx < command.args.len) {
                        var str = command.args[arg_idx];
                        // Apply precision (truncate)
                        if (has_precision and str.len > precision) {
                            str = str[0..precision];
                        }
                        // Apply width (padding)
                        if (width > 0 and str.len < width) {
                            const pad = width - str.len;
                            if (left_justify) {
                                try IO.print("{s}", .{str});
                                var p: usize = 0;
                                while (p < pad) : (p += 1) try IO.print(" ", .{});
                            } else {
                                var p: usize = 0;
                                while (p < pad) : (p += 1) try IO.print(" ", .{});
                                try IO.print("{s}", .{str});
                            }
                        } else {
                            try IO.print("{s}", .{str});
                        }
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == 'd' or spec == 'i') {
                    // Integer format
                    if (arg_idx < command.args.len) {
                        const num = std.fmt.parseInt(i64, command.args[arg_idx], 10) catch 0;
                        try printfInt(num, width, zero_pad, left_justify);
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == 'u') {
                    // Unsigned integer format
                    if (arg_idx < command.args.len) {
                        const num = std.fmt.parseInt(u64, command.args[arg_idx], 10) catch 0;
                        try printfUint(num, width, zero_pad, left_justify, 10, false);
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == 'x') {
                    // Hex lowercase
                    if (arg_idx < command.args.len) {
                        const num = std.fmt.parseInt(u64, command.args[arg_idx], 10) catch 0;
                        try printfUint(num, width, zero_pad, left_justify, 16, false);
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == 'X') {
                    // Hex uppercase
                    if (arg_idx < command.args.len) {
                        const num = std.fmt.parseInt(u64, command.args[arg_idx], 10) catch 0;
                        try printfUint(num, width, zero_pad, left_justify, 16, true);
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == 'o') {
                    // Octal format
                    if (arg_idx < command.args.len) {
                        const num = std.fmt.parseInt(u64, command.args[arg_idx], 10) catch 0;
                        try printfUint(num, width, zero_pad, left_justify, 8, false);
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == 'c') {
                    // Character format
                    if (arg_idx < command.args.len) {
                        const arg = command.args[arg_idx];
                        if (arg.len > 0) {
                            try IO.print("{c}", .{arg[0]});
                        }
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == 'f' or spec == 'F') {
                    // Float format
                    if (arg_idx < command.args.len) {
                        const num = std.fmt.parseFloat(f64, command.args[arg_idx]) catch 0.0;
                        try printfFloat(num, width, precision, left_justify);
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == '%') {
                    // Escaped %
                    try IO.print("%", .{});
                    i = j + 1;
                } else if (spec == 'b') {
                    // String with escape interpretation (bash extension)
                    if (arg_idx < command.args.len) {
                        try printWithEscapes(command.args[arg_idx]);
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == 'q') {
                    // Shell-quoted string (bash extension)
                    if (arg_idx < command.args.len) {
                        try IO.print("'{s}'", .{command.args[arg_idx]});
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else {
                    // Unknown format, just print it
                    try IO.print("{c}", .{format[i]});
                    i += 1;
                }
            } else if (format[i] == '\\' and i + 1 < format.len) {
                const esc = format[i + 1];
                switch (esc) {
                    'n' => try IO.print("\n", .{}),
                    't' => try IO.print("\t", .{}),
                    'r' => try IO.print("\r", .{}),
                    '\\' => try IO.print("\\", .{}),
                    'a' => try IO.print("\x07", .{}),
                    'b' => try IO.print("\x08", .{}),
                    'f' => try IO.print("\x0c", .{}),
                    'v' => try IO.print("\x0b", .{}),
                    'e' => try IO.print("\x1b", .{}),
                    '0' => {
                        // Octal escape
                        var val: u8 = 0;
                        var k: usize = i + 2;
                        var count: usize = 0;
                        while (k < format.len and count < 3) : (k += 1) {
                            if (format[k] >= '0' and format[k] <= '7') {
                                val = val * 8 + (format[k] - '0');
                                count += 1;
                            } else break;
                        }
                        try IO.print("{c}", .{val});
                        i = k;
                        continue;
                    },
                    'x' => {
                        // Hex escape \xNN
                        if (i + 3 < format.len) {
                            const hex = format[i + 2 .. i + 4];
                            const val = std.fmt.parseInt(u8, hex, 16) catch {
                                try IO.print("{c}", .{format[i]});
                                i += 1;
                                continue;
                            };
                            try IO.print("{c}", .{val});
                            i += 4;
                            continue;
                        } else {
                            try IO.print("{c}", .{format[i]});
                            i += 1;
                            continue;
                        }
                    },
                    else => try IO.print("{c}", .{format[i]}),
                }
                i += 2;
            } else {
                try IO.print("{c}", .{format[i]});
                i += 1;
            }
        }

        return 0;
    }

    /// Helper for printf - format signed integer with width/padding
    fn printfInt(num: i64, width: usize, zero_pad: bool, left_justify: bool) !void {
        var buf: [32]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d}", .{num}) catch return;
        if (width > 0 and str.len < width) {
            const pad = width - str.len;
            const pad_char: u8 = if (zero_pad and !left_justify) '0' else ' ';
            if (left_justify) {
                try IO.print("{s}", .{str});
                var p: usize = 0;
                while (p < pad) : (p += 1) try IO.print(" ", .{});
            } else {
                var p: usize = 0;
                while (p < pad) : (p += 1) try IO.print("{c}", .{pad_char});
                try IO.print("{s}", .{str});
            }
        } else {
            try IO.print("{s}", .{str});
        }
    }

    /// Helper for printf - format unsigned integer with base and width
    fn printfUint(num: u64, width: usize, zero_pad: bool, left_justify: bool, base: u8, uppercase: bool) !void {
        var buf: [32]u8 = undefined;
        const str = if (base == 16)
            if (uppercase)
                std.fmt.bufPrint(&buf, "{X}", .{num}) catch return
            else
                std.fmt.bufPrint(&buf, "{x}", .{num}) catch return
        else if (base == 8)
            std.fmt.bufPrint(&buf, "{o}", .{num}) catch return
        else
            std.fmt.bufPrint(&buf, "{d}", .{num}) catch return;

        if (width > 0 and str.len < width) {
            const pad = width - str.len;
            const pad_char: u8 = if (zero_pad and !left_justify) '0' else ' ';
            if (left_justify) {
                try IO.print("{s}", .{str});
                var p: usize = 0;
                while (p < pad) : (p += 1) try IO.print(" ", .{});
            } else {
                var p: usize = 0;
                while (p < pad) : (p += 1) try IO.print("{c}", .{pad_char});
                try IO.print("{s}", .{str});
            }
        } else {
            try IO.print("{s}", .{str});
        }
    }

    /// Helper for printf - format float with precision and width
    fn printfFloat(num: f64, width: usize, precision: usize, left_justify: bool) !void {
        var buf: [64]u8 = undefined;
        // Zig doesn't support runtime precision, so use fixed cases
        const str = switch (precision) {
            0 => std.fmt.bufPrint(&buf, "{d:.0}", .{num}) catch return,
            1 => std.fmt.bufPrint(&buf, "{d:.1}", .{num}) catch return,
            2 => std.fmt.bufPrint(&buf, "{d:.2}", .{num}) catch return,
            3 => std.fmt.bufPrint(&buf, "{d:.3}", .{num}) catch return,
            4 => std.fmt.bufPrint(&buf, "{d:.4}", .{num}) catch return,
            5 => std.fmt.bufPrint(&buf, "{d:.5}", .{num}) catch return,
            else => std.fmt.bufPrint(&buf, "{d:.6}", .{num}) catch return,
        };

        if (width > 0 and str.len < width) {
            const pad = width - str.len;
            if (left_justify) {
                try IO.print("{s}", .{str});
                var p: usize = 0;
                while (p < pad) : (p += 1) try IO.print(" ", .{});
            } else {
                var p: usize = 0;
                while (p < pad) : (p += 1) try IO.print(" ", .{});
                try IO.print("{s}", .{str});
            }
        } else {
            try IO.print("{s}", .{str});
        }
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

        const arg = command.args[0];

        // Check for +N or -N rotation
        if (arg.len > 0 and (arg[0] == '+' or arg[0] == '-')) {
            const n = std.fmt.parseInt(usize, arg[1..], 10) catch {
                try IO.eprint("den: pushd: {s}: invalid number\n", .{arg});
                return 1;
            };

            // Total stack size is dir_stack_count + 1 (including cwd)
            const total_size = shell_ref.dir_stack_count + 1;
            if (n >= total_size) {
                try IO.eprint("den: pushd: {s}: directory stack index out of range\n", .{arg});
                return 1;
            }

            // Calculate index: +N counts from left, -N from right
            const index = if (arg[0] == '+') n else total_size - n;
            if (index == 0) {
                // Already at current directory, nothing to do
                return 0;
            }

            // Rotate stack: bring index to top
            // Index 1 = top of stack = dir_stack[count-1]
            const stack_idx = shell_ref.dir_stack_count - index;
            const target_dir = shell_ref.dir_stack[stack_idx] orelse unreachable;

            // Change to target directory
            std.posix.chdir(target_dir) catch |err| {
                try IO.eprint("den: pushd: {s}: {}\n", .{ target_dir, err });
                return err;
            };

            // Free the target entry and replace with cwd
            self.allocator.free(shell_ref.dir_stack[stack_idx].?);
            shell_ref.dir_stack[stack_idx] = try self.allocator.dupe(u8, cwd);

            return 0;
        }

        // pushd <dir>: push current dir and cd to new dir
        const new_dir = arg;

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

        if (shell_ref.dir_stack_count == 0) {
            try IO.eprint("den: popd: directory stack empty\n", .{});
            return 1;
        }

        // Check for +N/-N argument to remove specific entry
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
                    // Can't remove current directory
                    try IO.eprint("den: popd: cannot remove current directory\n", .{});
                    return 1;
                }

                // Remove entry at index (1 = top of stack)
                const stack_idx = shell_ref.dir_stack_count - index;
                self.allocator.free(shell_ref.dir_stack[stack_idx].?);

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
        const dir = shell_ref.dir_stack[shell_ref.dir_stack_count] orelse unreachable;
        defer self.allocator.free(dir);

        std.posix.chdir(dir) catch |err| {
            try IO.eprint("den: popd: {s}: {}\n", .{ dir, err });
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

        var clear_stack = false;
        var full_paths = false;
        var one_per_line = false;
        var verbose = false;

        // Parse flags
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

        // Handle -c: clear directory stack
        if (clear_stack) {
            var i: usize = 0;
            while (i < shell_ref.dir_stack_count) : (i += 1) {
                if (shell_ref.dir_stack[i]) |dir| {
                    self.allocator.free(dir);
                    shell_ref.dir_stack[i] = null;
                }
            }
            shell_ref.dir_stack_count = 0;
            return 0;
        }

        // Get current directory
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch |err| {
            try IO.eprint("den: dirs: cannot get current directory: {}\n", .{err});
            return 1;
        };

        // Get home for tilde substitution
        const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch null;
        defer if (home) |h| self.allocator.free(h);

        // Helper to print path with optional tilde substitution
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

        // Output directory stack
        var index: usize = 0;

        if (verbose) {
            IO.print(" {d}  ", .{index}) catch {};
        }
        printPath(cwd, full_paths, home);

        index += 1;

        // Show stack from top to bottom
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
        const shell_ref = self.shell orelse {
            try IO.eprint("den: jobs: shell context not available\n", .{});
            return 1;
        };

        // Parse flags: -l (PIDs), -p (PIDs only), -r (running), -s (stopped)
        var show_pids = false;
        var pids_only = false;
        var running_only = false;
        var stopped_only = false;

        for (command.args) |arg| {
            if (arg.len > 0 and arg[0] == '-') {
                for (arg[1..]) |c| {
                    switch (c) {
                        'l' => show_pids = true,
                        'p' => pids_only = true,
                        'r' => running_only = true,
                        's' => stopped_only = true,
                        else => {
                            try IO.eprint("den: jobs: -{c}: invalid option\n", .{c});
                            return 1;
                        },
                    }
                }
            }
        }

        // List all background jobs
        if (shell_ref.background_jobs_count == 0) {
            return 0;
        }

        for (shell_ref.background_jobs) |maybe_job| {
            if (maybe_job) |job| {
                // Filter by status if requested
                if (running_only and job.status != .running) continue;
                if (stopped_only and job.status != .stopped) continue;

                if (pids_only) {
                    // -p: Just print the PID
                    try IO.print("{d}\n", .{job.pid});
                } else if (show_pids) {
                    // -l: Show PID in output
                    const status_str = switch (job.status) {
                        .running => "Running",
                        .stopped => "Stopped",
                        .done => "Done",
                    };
                    try IO.print("[{d}]  {d} {s}                    {s}\n", .{ job.job_id, job.pid, status_str, job.command });
                } else {
                    // Default output
                    const status_str = switch (job.status) {
                        .running => "Running",
                        .stopped => "Stopped",
                        .done => "Done",
                    };
                    try IO.print("[{d}]  {s}                    {s}\n", .{ job.job_id, status_str, job.command });
                }
            }
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
        const result = process.waitProcess(job.pid, .{}) catch |err| {
            try IO.eprint("den: fg: failed to wait for job: {}\n", .{err});
            return 1;
        };
        shell_ref.last_exit_code = result.status.code;

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

        // Send SIGCONT to continue the process (POSIX only, no-op on Windows)
        process.continueProcess(job.pid) catch |err| {
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
                        const wait_result = process.waitProcess(job.pid, .{}) catch continue;
                        last_status = wait_result.status.code;
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
            var target_job_index: ?usize = null;
            var target_pid: ?process.ProcessId = null;

            if (arg.len > 0 and arg[0] == '%') {
                const job_id = std.fmt.parseInt(usize, arg[1..], 10) catch {
                    try IO.eprint("den: wait: {s}: no such job\n", .{arg});
                    continue;
                };

                // Find job by ID
                for (shell_ref.background_jobs, 0..) |maybe_job, i| {
                    if (maybe_job) |job| {
                        if (job.job_id == job_id) {
                            target_job_index = i;
                            target_pid = job.pid;
                            break;
                        }
                    }
                }

                if (target_pid == null) {
                    try IO.eprint("den: wait: {s}: no such job\n", .{arg});
                    continue;
                }
            } else {
                // Raw PID - only supported on POSIX
                if (builtin.os.tag == .windows) {
                    try IO.eprint("den: wait: {s}: raw PIDs not supported on Windows, use %%jobid\n", .{arg});
                    continue;
                }
                const pid_num = std.fmt.parseInt(i32, arg, 10) catch {
                    try IO.eprint("den: wait: {s}: not a pid or valid job spec\n", .{arg});
                    continue;
                };
                // Find job by PID
                for (shell_ref.background_jobs, 0..) |maybe_job, i| {
                    if (maybe_job) |job| {
                        if (@as(i32, @intCast(job.pid)) == pid_num) {
                            target_job_index = i;
                            target_pid = job.pid;
                            break;
                        }
                    }
                }
                if (target_pid == null) {
                    // PID not in our job list, try to wait for it directly (POSIX only)
                    target_pid = @intCast(pid_num);
                }
            }

            // Wait for the process
            const wait_result = process.waitProcess(target_pid.?, .{}) catch |err| {
                try IO.eprint("den: wait: failed to wait: {}\n", .{err});
                continue;
            };
            shell_ref.last_exit_code = wait_result.status.code;

            // Remove from job list if it was a tracked job
            if (target_job_index) |idx| {
                if (shell_ref.background_jobs[idx]) |job| {
                    self.allocator.free(job.command);
                }
                shell_ref.background_jobs[idx] = null;
                shell_ref.background_jobs_count -= 1;
            }
        }

        // Return the exit status of the last job waited for
        return shell_ref.last_exit_code;
    }

    fn builtinDisown(self: *Executor, command: *types.ParsedCommand) !i32 {
        const shell_ref = self.shell orelse {
            try IO.eprint("den: disown: shell context not available\n", .{});
            return 1;
        };

        // Parse flags: -h (keep but no SIGHUP), -a (all), -r (running only)
        var no_hup = false; // -h: Mark for no SIGHUP but keep in job table
        var all_jobs = false; // -a: All jobs
        var running_only = false; // -r: Running jobs only
        var arg_start: usize = 0;

        for (command.args, 0..) |arg, i| {
            if (arg.len > 0 and arg[0] == '-' and arg.len > 1 and arg[1] != '%') {
                for (arg[1..]) |c| {
                    switch (c) {
                        'h' => no_hup = true,
                        'a' => all_jobs = true,
                        'r' => running_only = true,
                        else => {
                            try IO.eprint("den: disown: -{c}: invalid option\n", .{c});
                            try IO.eprint("disown: usage: disown [-h] [-ar] [jobspec ... | pid ...]\n", .{});
                            return 1;
                        },
                    }
                }
                arg_start = i + 1;
            } else {
                break;
            }
        }

        // If -a flag or no job specs, operate on all (or filtered) jobs
        if (all_jobs or arg_start >= command.args.len) {
            for (shell_ref.background_jobs, 0..) |maybe_job, i| {
                if (maybe_job) |job| {
                    // Filter by running status if -r is set
                    if (running_only and job.status != .running) continue;

                    if (no_hup) {
                        // -h: Just mark for no SIGHUP (we don't actually send SIGHUP on exit anyway,
                        // but this is for compatibility - job stays in table)
                        // In practice, this is a no-op for our shell, but we acknowledge it
                        continue;
                    } else {
                        // Remove from job table
                        self.allocator.free(job.command);
                        shell_ref.background_jobs[i] = null;
                        shell_ref.background_jobs_count -= 1;
                    }
                }
            }
            return 0;
        }

        // Disown specific job(s)
        for (command.args[arg_start..]) |arg| {
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

            // Find and optionally remove job
            var found = false;
            for (shell_ref.background_jobs, 0..) |maybe_job, i| {
                if (maybe_job) |job| {
                    if (job.job_id == target_job_id) {
                        // Filter by running status if -r is set
                        if (running_only and job.status != .running) {
                            found = true; // Found but skipped due to filter
                            break;
                        }

                        if (no_hup) {
                            // -h: Keep in job table, just mark for no SIGHUP
                            found = true;
                        } else {
                            self.allocator.free(job.command);
                            shell_ref.background_jobs[i] = null;
                            shell_ref.background_jobs_count -= 1;
                            found = true;
                        }
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

        // Check for -l flag (list signals)
        if (std.mem.eql(u8, command.args[0], "-l") or std.mem.eql(u8, command.args[0], "-L") or std.mem.eql(u8, command.args[0], "--list")) {
            const signal_table = [_]struct { num: u6, name: []const u8 }{
                .{ .num = 1, .name = "HUP" },
                .{ .num = 2, .name = "INT" },
                .{ .num = 3, .name = "QUIT" },
                .{ .num = 4, .name = "ILL" },
                .{ .num = 5, .name = "TRAP" },
                .{ .num = 6, .name = "ABRT" },
                .{ .num = 7, .name = "BUS" },
                .{ .num = 8, .name = "FPE" },
                .{ .num = 9, .name = "KILL" },
                .{ .num = 10, .name = "USR1" },
                .{ .num = 11, .name = "SEGV" },
                .{ .num = 12, .name = "USR2" },
                .{ .num = 13, .name = "PIPE" },
                .{ .num = 14, .name = "ALRM" },
                .{ .num = 15, .name = "TERM" },
                .{ .num = 17, .name = "CHLD" },
                .{ .num = 18, .name = "CONT" },
                .{ .num = 19, .name = "STOP" },
                .{ .num = 20, .name = "TSTP" },
                .{ .num = 21, .name = "TTIN" },
                .{ .num = 22, .name = "TTOU" },
                .{ .num = 23, .name = "URG" },
                .{ .num = 24, .name = "XCPU" },
                .{ .num = 25, .name = "XFSZ" },
                .{ .num = 26, .name = "VTALRM" },
                .{ .num = 27, .name = "PROF" },
                .{ .num = 28, .name = "WINCH" },
                .{ .num = 29, .name = "IO" },
                .{ .num = 30, .name = "PWR" },
                .{ .num = 31, .name = "SYS" },
            };

            // If a signal number is given after -l, print just that signal name
            if (command.args.len >= 2) {
                const sig_num = std.fmt.parseInt(u6, command.args[1], 10) catch {
                    try IO.eprint("den: kill: {s}: invalid signal specification\n", .{command.args[1]});
                    return 1;
                };
                for (signal_table) |sig| {
                    if (sig.num == sig_num) {
                        try IO.print("{s}\n", .{sig.name});
                        return 0;
                    }
                }
                try IO.eprint("den: kill: {d}: invalid signal specification\n", .{sig_num});
                return 1;
            }

            // Print all signals
            if (builtin.os.tag == .windows) {
                try IO.print("Signals on Windows (only TERM/KILL are supported):\n", .{});
                try IO.print(" 9) SIGKILL    15) SIGTERM\n", .{});
            } else {
                var col: usize = 0;
                for (signal_table) |sig| {
                    try IO.print("{d:>2}) SIG{s: <8}", .{ sig.num, sig.name });
                    col += 1;
                    if (col >= 4) {
                        try IO.print("\n", .{});
                        col = 0;
                    }
                }
                if (col > 0) {
                    try IO.print("\n", .{});
                }
            }
            return 0;
        }

        // Check for -s flag (specify signal by name)
        var start_idx: usize = 0;
        var explicit_signal: ?u8 = null;
        if (std.mem.eql(u8, command.args[0], "-s")) {
            if (command.args.len < 2) {
                try IO.eprint("den: kill: -s requires a signal name\n", .{});
                return 1;
            }
            const sig_name = command.args[1];
            explicit_signal = signalFromName(sig_name);
            if (explicit_signal == null) {
                try IO.eprint("den: kill: invalid signal: {s}\n", .{sig_name});
                return 1;
            }
            start_idx = 2;
        }

        if (builtin.os.tag == .windows) {
            // Windows: parse optional signal flag but only support TERM/KILL (both terminate)
            if (command.args[0].len > 0 and command.args[0][0] == '-') {
                const sig_str = command.args[0][1..];
                // Only accept TERM, KILL, or their numeric equivalents (9, 15)
                if (sig_str.len > 0) {
                    const valid = std.mem.eql(u8, sig_str, "TERM") or
                        std.mem.eql(u8, sig_str, "KILL") or
                        std.mem.eql(u8, sig_str, "9") or
                        std.mem.eql(u8, sig_str, "15");
                    if (!valid) {
                        // Check for other signals and warn
                        if (std.mem.eql(u8, sig_str, "HUP") or
                            std.mem.eql(u8, sig_str, "INT") or
                            std.mem.eql(u8, sig_str, "QUIT") or
                            std.mem.eql(u8, sig_str, "STOP") or
                            std.mem.eql(u8, sig_str, "CONT"))
                        {
                            try IO.eprint("den: kill: signal {s} not supported on Windows, using TERM\n", .{sig_str});
                        } else {
                            try IO.eprint("den: kill: invalid signal: {s}\n", .{sig_str});
                            return 1;
                        }
                    }
                }
                start_idx = 1;
            }

            if (start_idx >= command.args.len) {
                try IO.eprint("den: kill: missing process ID\n", .{});
                return 1;
            }

            // Terminate each process on Windows
            for (command.args[start_idx..]) |pid_str| {
                const pid = std.fmt.parseInt(u32, pid_str, 10) catch {
                    try IO.eprint("den: kill: invalid process ID: {s}\n", .{pid_str});
                    continue;
                };

                // Open process with TERMINATE permission
                const handle = std.os.windows.kernel32.OpenProcess(
                    PROCESS_TERMINATE,
                    std.os.windows.FALSE,
                    pid,
                );
                if (handle == null) {
                    try IO.eprint("den: kill: ({d}): cannot open process\n", .{pid});
                    return 1;
                }
                defer std.os.windows.CloseHandle(handle.?);

                // Terminate the process
                if (std.os.windows.kernel32.TerminateProcess(handle.?, 1) == 0) {
                    try IO.eprint("den: kill: ({d}): cannot terminate process\n", .{pid});
                    return 1;
                }
            }

            return 0;
        }

        // POSIX implementation
        var signal: u8 = explicit_signal orelse @intFromEnum(std.posix.SIG.TERM);

        // Parse signal if provided (and not already set via -s)
        if (explicit_signal == null and start_idx < command.args.len and
            command.args[start_idx].len > 0 and command.args[start_idx][0] == '-')
        {
            const sig_str = command.args[start_idx][1..];
            if (sig_str.len > 0) {
                // Try to parse as number
                signal = std.fmt.parseInt(u8, sig_str, 10) catch blk: {
                    // Try to parse as signal name
                    break :blk signalFromName(sig_str) orelse {
                        try IO.eprint("den: kill: invalid signal: {s}\n", .{sig_str});
                        return 1;
                    };
                };
            }
            start_idx += 1;
        }

        if (start_idx >= command.args.len) {
            try IO.eprint("den: kill: missing process ID\n", .{});
            return 1;
        }

        // Send signal to each PID
        for (command.args[start_idx..]) |pid_str| {
            const pid = std.fmt.parseInt(process.ProcessId, pid_str, 10) catch {
                try IO.eprint("den: kill: invalid process ID: {s}\n", .{pid_str});
                continue;
            };

            process.killProcess(pid, signal) catch |err| {
                try IO.eprint("den: kill: ({d}): {}\n", .{ pid, err });
                return 1;
            };
        }

        return 0;
    }

    /// Helper to convert signal name to signal number
    fn signalFromName(name: []const u8) ?u8 {
        if (builtin.os.tag == .windows) {
            if (std.mem.eql(u8, name, "TERM") or std.mem.eql(u8, name, "KILL")) {
                return 15; // Just return TERM, as Windows only supports terminate
            }
            return null;
        }

        if (std.mem.eql(u8, name, "HUP")) return @intFromEnum(std.posix.SIG.HUP)
        else if (std.mem.eql(u8, name, "INT")) return @intFromEnum(std.posix.SIG.INT)
        else if (std.mem.eql(u8, name, "QUIT")) return @intFromEnum(std.posix.SIG.QUIT)
        else if (std.mem.eql(u8, name, "ILL")) return @intFromEnum(std.posix.SIG.ILL)
        else if (std.mem.eql(u8, name, "TRAP")) return @intFromEnum(std.posix.SIG.TRAP)
        else if (std.mem.eql(u8, name, "ABRT")) return @intFromEnum(std.posix.SIG.ABRT)
        else if (std.mem.eql(u8, name, "BUS")) return @intFromEnum(std.posix.SIG.BUS)
        else if (std.mem.eql(u8, name, "FPE")) return @intFromEnum(std.posix.SIG.FPE)
        else if (std.mem.eql(u8, name, "KILL")) return @intFromEnum(std.posix.SIG.KILL)
        else if (std.mem.eql(u8, name, "USR1")) return @intFromEnum(std.posix.SIG.USR1)
        else if (std.mem.eql(u8, name, "SEGV")) return @intFromEnum(std.posix.SIG.SEGV)
        else if (std.mem.eql(u8, name, "USR2")) return @intFromEnum(std.posix.SIG.USR2)
        else if (std.mem.eql(u8, name, "PIPE")) return @intFromEnum(std.posix.SIG.PIPE)
        else if (std.mem.eql(u8, name, "ALRM")) return @intFromEnum(std.posix.SIG.ALRM)
        else if (std.mem.eql(u8, name, "TERM")) return @intFromEnum(std.posix.SIG.TERM)
        else if (std.mem.eql(u8, name, "CHLD")) return @intFromEnum(std.posix.SIG.CHLD)
        else if (std.mem.eql(u8, name, "CONT")) return @intFromEnum(std.posix.SIG.CONT)
        else if (std.mem.eql(u8, name, "STOP")) return @intFromEnum(std.posix.SIG.STOP)
        else if (std.mem.eql(u8, name, "TSTP")) return @intFromEnum(std.posix.SIG.TSTP)
        else if (std.mem.eql(u8, name, "TTIN")) return @intFromEnum(std.posix.SIG.TTIN)
        else if (std.mem.eql(u8, name, "TTOU")) return @intFromEnum(std.posix.SIG.TTOU)
        else if (std.mem.eql(u8, name, "URG")) return @intFromEnum(std.posix.SIG.URG)
        else if (std.mem.eql(u8, name, "XCPU")) return @intFromEnum(std.posix.SIG.XCPU)
        else if (std.mem.eql(u8, name, "XFSZ")) return @intFromEnum(std.posix.SIG.XFSZ)
        else if (std.mem.eql(u8, name, "VTALRM")) return @intFromEnum(std.posix.SIG.VTALRM)
        else if (std.mem.eql(u8, name, "PROF")) return @intFromEnum(std.posix.SIG.PROF)
        else if (std.mem.eql(u8, name, "WINCH")) return @intFromEnum(std.posix.SIG.WINCH)
        else if (std.mem.eql(u8, name, "IO")) return @intFromEnum(std.posix.SIG.IO)
        else if (std.mem.eql(u8, name, "SYS")) return @intFromEnum(std.posix.SIG.SYS)
        else return null;
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

        if (builtin.os.tag == .windows) {
            try IO.print("den: umask: not supported on Windows\n", .{});
            return 1;
        }

        // Parse flags
        var symbolic = false; // -S: symbolic output
        var portable = false; // -p: portable output (can be used as input)
        var arg_idx: usize = 0;

        while (arg_idx < command.args.len) {
            const arg = command.args[arg_idx];
            if (arg.len > 0 and arg[0] == '-') {
                for (arg[1..]) |c| {
                    switch (c) {
                        'S' => symbolic = true,
                        'p' => portable = true,
                        else => {
                            try IO.eprint("den: umask: -{c}: invalid option\n", .{c});
                            try IO.eprint("umask: usage: umask [-p] [-S] [mode]\n", .{});
                            return 1;
                        },
                    }
                }
                arg_idx += 1;
            } else {
                break;
            }
        }

        // Get current umask
        const current = std.c.umask(0);
        _ = std.c.umask(current);

        if (arg_idx >= command.args.len) {
            // No mask argument - print current umask
            if (symbolic) {
                // Symbolic format: u=rwx,g=rx,o=rx (showing what IS allowed, not masked)
                const perms: u9 = @truncate(~current & 0o777);
                const u_r: u8 = if (perms & 0o400 != 0) 'r' else '-';
                const u_w: u8 = if (perms & 0o200 != 0) 'w' else '-';
                const u_x: u8 = if (perms & 0o100 != 0) 'x' else '-';
                const g_r: u8 = if (perms & 0o040 != 0) 'r' else '-';
                const g_w: u8 = if (perms & 0o020 != 0) 'w' else '-';
                const g_x: u8 = if (perms & 0o010 != 0) 'x' else '-';
                const o_r: u8 = if (perms & 0o004 != 0) 'r' else '-';
                const o_w: u8 = if (perms & 0o002 != 0) 'w' else '-';
                const o_x: u8 = if (perms & 0o001 != 0) 'x' else '-';
                try IO.print("u={c}{c}{c},g={c}{c}{c},o={c}{c}{c}\n", .{ u_r, u_w, u_x, g_r, g_w, g_x, o_r, o_w, o_x });
            } else if (portable) {
                // Portable format: umask 0022
                try IO.print("umask {o:0>4}\n", .{current});
            } else {
                // Default octal format
                try IO.print("{o:0>4}\n", .{current});
            }
            return 0;
        }

        // Set umask
        const mask_str = command.args[arg_idx];

        // Check if it's symbolic mode (contains letters)
        var is_symbolic_mode = false;
        for (mask_str) |c| {
            if (c == 'u' or c == 'g' or c == 'o' or c == 'a' or c == '+' or c == '-' or c == '=') {
                is_symbolic_mode = true;
                break;
            }
        }

        if (is_symbolic_mode) {
            // Parse symbolic mode like u=rwx,g=rx,o=rx or u+w,g-w
            var new_mask = current;

            var iter = std.mem.splitScalar(u8, mask_str, ',');
            while (iter.next()) |part| {
                if (part.len < 2) continue;

                // Parse who (u, g, o, a)
                var who_mask: std.c.mode_t = 0;
                var i: usize = 0;
                while (i < part.len and (part[i] == 'u' or part[i] == 'g' or part[i] == 'o' or part[i] == 'a')) : (i += 1) {
                    switch (part[i]) {
                        'u' => who_mask |= 0o700,
                        'g' => who_mask |= 0o070,
                        'o' => who_mask |= 0o007,
                        'a' => who_mask |= 0o777,
                        else => {},
                    }
                }
                if (who_mask == 0) who_mask = 0o777; // default to all

                if (i >= part.len) continue;

                // Parse operator (+, -, =)
                const op = part[i];
                i += 1;

                // Parse permissions (r, w, x)
                var perm_bits: std.c.mode_t = 0;
                while (i < part.len) : (i += 1) {
                    switch (part[i]) {
                        'r' => perm_bits |= 0o444,
                        'w' => perm_bits |= 0o222,
                        'x' => perm_bits |= 0o111,
                        else => {},
                    }
                }

                // Apply based on who
                perm_bits &= who_mask;

                switch (op) {
                    '=' => {
                        // Clear and set
                        new_mask = (new_mask & ~who_mask) | (~perm_bits & who_mask);
                    },
                    '+' => {
                        // Remove from mask (allow permission)
                        new_mask &= ~perm_bits;
                    },
                    '-' => {
                        // Add to mask (deny permission)
                        new_mask |= perm_bits;
                    },
                    else => {},
                }
            }

            _ = std.c.umask(new_mask);
        } else {
            // Octal mode
            const mask = std.fmt.parseInt(std.c.mode_t, mask_str, 8) catch {
                try IO.eprint("den: umask: {s}: invalid octal number\n", .{mask_str});
                return 1;
            };
            _ = std.c.umask(mask);
        }

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
        // Parse flags
        var posix_format = false; // -p: POSIX format output
        var arg_start: usize = 0;

        while (arg_start < command.args.len) {
            const arg = command.args[arg_start];
            if (arg.len > 0 and arg[0] == '-') {
                if (std.mem.eql(u8, arg, "-p")) {
                    posix_format = true;
                    arg_start += 1;
                } else if (std.mem.eql(u8, arg, "--")) {
                    arg_start += 1;
                    break;
                } else {
                    // Unknown flag or start of command (like -c for some commands)
                    break;
                }
            } else {
                break;
            }
        }

        if (arg_start >= command.args.len) {
            try IO.eprint("den: time: missing command\n", .{});
            return 1;
        }

        // Time the execution of an external command
        // For now, we only support timing external commands to avoid circular dependencies
        const start_time = std.time.Instant.now() catch return 1;

        var new_cmd = types.ParsedCommand{
            .name = command.args[arg_start],
            .args = if (arg_start + 1 < command.args.len) command.args[arg_start + 1 ..] else &[_][]const u8{},
            .redirections = command.redirections,
        };

        // Execute as external command to avoid recursive error set inference
        const exit_code = try self.executeExternal(&new_cmd);

        const end_time = std.time.Instant.now() catch return exit_code;
        const elapsed_ns = end_time.since(start_time);
        const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

        if (posix_format) {
            // POSIX format: "real %f\nuser %f\nsys %f\n"
            try IO.eprint("real {d:.2}\n", .{elapsed_s});
            try IO.eprint("user 0.00\n", .{});
            try IO.eprint("sys 0.00\n", .{});
        } else {
            // Default format with tabs
            try IO.eprint("\nreal\t{d:.3}s\n", .{elapsed_s});
            try IO.eprint("user\t0.000s\n", .{});
            try IO.eprint("sys\t0.000s\n", .{});
        }

        return exit_code;
    }

    fn builtinTimeout(_: *Executor, command: *types.ParsedCommand) !i32 {
        // timeout [-s signal] [-k duration] duration command [args...]
        var signal_name: []const u8 = "TERM"; // Default signal
        var kill_after: ?f64 = null; // -k: send KILL after duration
        var preserve_status = false; // --preserve-status
        var foreground = false; // --foreground
        var arg_start: usize = 0;

        // Parse options
        while (arg_start < command.args.len) {
            const arg = command.args[arg_start];
            if (arg.len > 0 and arg[0] == '-') {
                if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--signal")) {
                    arg_start += 1;
                    if (arg_start >= command.args.len) {
                        try IO.eprint("den: timeout: -s requires an argument\n", .{});
                        return 1;
                    }
                    signal_name = command.args[arg_start];
                } else if (std.mem.eql(u8, arg, "-k") or std.mem.eql(u8, arg, "--kill-after")) {
                    arg_start += 1;
                    if (arg_start >= command.args.len) {
                        try IO.eprint("den: timeout: -k requires an argument\n", .{});
                        return 1;
                    }
                    kill_after = parseDuration(command.args[arg_start]) catch {
                        try IO.eprint("den: timeout: invalid duration: {s}\n", .{command.args[arg_start]});
                        return 1;
                    };
                } else if (std.mem.eql(u8, arg, "--preserve-status")) {
                    preserve_status = true;
                } else if (std.mem.eql(u8, arg, "--foreground")) {
                    foreground = true;
                } else if (std.mem.eql(u8, arg, "--help")) {
                    try IO.print("Usage: timeout [OPTION] DURATION COMMAND [ARG]...\n", .{});
                    try IO.print("Start COMMAND, and kill it if still running after DURATION.\n\n", .{});
                    try IO.print("Options:\n", .{});
                    try IO.print("  -s, --signal=SIGNAL    Signal to send (default: TERM)\n", .{});
                    try IO.print("  -k, --kill-after=DUR   Send KILL signal after DUR if still running\n", .{});
                    try IO.print("  --preserve-status      Exit with the same status as COMMAND\n", .{});
                    try IO.print("  --foreground           Don't create a new process group\n", .{});
                    try IO.print("\nDURATION is a number with optional suffix: s (seconds), m (minutes), h (hours), d (days)\n", .{});
                    return 0;
                } else if (std.mem.eql(u8, arg, "--")) {
                    arg_start += 1;
                    break;
                } else {
                    // Unknown option or start of duration
                    break;
                }
                arg_start += 1;
            } else {
                break;
            }
        }

        // Need at least duration and command
        if (arg_start + 1 >= command.args.len) {
            try IO.eprint("den: timeout: missing operand\n", .{});
            try IO.eprint("Usage: timeout [OPTION] DURATION COMMAND [ARG]...\n", .{});
            return 1;
        }

        // Parse duration
        const duration_str = command.args[arg_start];
        const duration_secs = parseDuration(duration_str) catch {
            try IO.eprint("den: timeout: invalid duration: {s}\n", .{duration_str});
            return 1;
        };

        // Get command and args
        const cmd_name = command.args[arg_start + 1];
        const cmd_args = if (arg_start + 2 < command.args.len) command.args[arg_start + 2 ..] else &[_][]const u8{};

        // Acknowledge options we don't fully use yet
        if (foreground) {
            // Foreground mode - acknowledged but not changing behavior
        }

        // Get signal number from name
        const sig = parseSignalName(signal_name);

        // Fork and exec the command
        const fork_result = std.posix.fork() catch |err| {
            try IO.eprint("den: timeout: fork failed: {}\n", .{err});
            return 1;
        };

        if (fork_result == 0) {
            // Child process - exec the command
            // Use a page allocator since we're post-fork
            const page_alloc = std.heap.page_allocator;

            // Create null-terminated command name
            const cmd_z = page_alloc.dupeZ(u8, cmd_name) catch {
                std.posix.exit(127);
            };

            // Build argv array with null-terminated strings
            var argv_buf: [256]?[*:0]const u8 = undefined;
            argv_buf[0] = cmd_z.ptr;

            var argv_idx: usize = 1;
            for (cmd_args) |arg| {
                if (argv_idx >= argv_buf.len - 1) break;
                const arg_z = page_alloc.dupeZ(u8, arg) catch {
                    std.posix.exit(127);
                };
                argv_buf[argv_idx] = arg_z.ptr;
                argv_idx += 1;
            }
            argv_buf[argv_idx] = null;

            _ = std.posix.execvpeZ(cmd_z.ptr, @ptrCast(argv_buf[0..argv_idx :null]), getCEnviron()) catch {
                // exec failed
                std.posix.exit(127);
            };
            // If we get here, exec failed
            std.posix.exit(127);
        }

        // Parent process - wait with timeout
        const child_pid = fork_result;
        const timeout_ns: u64 = @intFromFloat(duration_secs * 1_000_000_000);
        const start_time = std.time.Instant.now() catch {
            // Can't get time, just wait normally
            const result = std.posix.waitpid(child_pid, 0);
            return @intCast(std.posix.W.EXITSTATUS(result.status));
        };

        // Poll for child completion with timeout
        while (true) {
            // Check if child has exited (non-blocking)
            const wait_result = std.posix.waitpid(child_pid, std.posix.W.NOHANG);
            if (wait_result.pid != 0) {
                // Child exited
                if (std.posix.W.IFEXITED(wait_result.status)) {
                    return @intCast(std.posix.W.EXITSTATUS(wait_result.status));
                } else if (std.posix.W.IFSIGNALED(wait_result.status)) {
                    return 128 + @as(i32, @intCast(std.posix.W.TERMSIG(wait_result.status)));
                }
                return 1;
            }

            // Check timeout
            const now = std.time.Instant.now() catch break;
            if (now.since(start_time) >= timeout_ns) {
                // Timeout - send signal
                std.posix.kill(child_pid, sig) catch {};

                // Wait a bit for graceful exit, then send KILL if -k was specified
                if (kill_after) |ka| {
                    const ka_secs: u64 = @intFromFloat(ka);
                    const ka_nanos: u64 = @intFromFloat((ka - @as(f64, @floatFromInt(ka_secs))) * 1_000_000_000);
                    std.posix.nanosleep(ka_secs, ka_nanos);
                    // Check if still running
                    const check = std.posix.waitpid(child_pid, std.posix.W.NOHANG);
                    if (check.pid == 0) {
                        // Still running, send KILL
                        std.posix.kill(child_pid, std.posix.SIG.KILL) catch {};
                    }
                }

                // Wait for child to actually exit
                const final_result = std.posix.waitpid(child_pid, 0);
                if (preserve_status) {
                    if (std.posix.W.IFEXITED(final_result.status)) {
                        return @intCast(std.posix.W.EXITSTATUS(final_result.status));
                    } else if (std.posix.W.IFSIGNALED(final_result.status)) {
                        return 128 + @as(i32, @intCast(std.posix.W.TERMSIG(final_result.status)));
                    }
                }
                return 124; // Standard timeout exit code
            }

            // Sleep briefly before checking again
            std.posix.nanosleep(0, 10_000_000); // 10ms
        }

        return 1;
    }

    /// Parse duration string (e.g., "5", "5s", "2m", "1h", "1d")
    fn parseDuration(str: []const u8) !f64 {
        if (str.len == 0) return error.InvalidDuration;

        var num_end: usize = str.len;
        var multiplier: f64 = 1.0;

        // Check for suffix
        if (str.len > 0) {
            const last = str[str.len - 1];
            if (last == 's' or last == 'S') {
                num_end = str.len - 1;
                multiplier = 1.0;
            } else if (last == 'm' or last == 'M') {
                num_end = str.len - 1;
                multiplier = 60.0;
            } else if (last == 'h' or last == 'H') {
                num_end = str.len - 1;
                multiplier = 3600.0;
            } else if (last == 'd' or last == 'D') {
                num_end = str.len - 1;
                multiplier = 86400.0;
            }
        }

        if (num_end == 0) return error.InvalidDuration;

        const num = std.fmt.parseFloat(f64, str[0..num_end]) catch return error.InvalidDuration;
        return num * multiplier;
    }

    /// Convert signal name to signal enum for timeout
    fn parseSignalName(name: []const u8) std.posix.SIG {
        const upper = blk: {
            var buf: [16]u8 = undefined;
            const len = @min(name.len, buf.len);
            for (name[0..len], 0..) |c, i| {
                buf[i] = std.ascii.toUpper(c);
            }
            break :blk buf[0..len];
        };

        // Handle numeric signal
        if (std.fmt.parseInt(u6, name, 10)) |num| {
            return @enumFromInt(num);
        } else |_| {}

        // Remove SIG prefix if present
        const sig_name = if (std.mem.startsWith(u8, upper, "SIG")) upper[3..] else upper;

        // Map common signal names
        if (std.mem.eql(u8, sig_name, "HUP")) return .HUP;
        if (std.mem.eql(u8, sig_name, "INT")) return .INT;
        if (std.mem.eql(u8, sig_name, "QUIT")) return .QUIT;
        if (std.mem.eql(u8, sig_name, "ILL")) return .ILL;
        if (std.mem.eql(u8, sig_name, "TRAP")) return .TRAP;
        if (std.mem.eql(u8, sig_name, "ABRT")) return .ABRT;
        if (std.mem.eql(u8, sig_name, "BUS")) return .BUS;
        if (std.mem.eql(u8, sig_name, "FPE")) return .FPE;
        if (std.mem.eql(u8, sig_name, "KILL")) return .KILL;
        if (std.mem.eql(u8, sig_name, "USR1")) return .USR1;
        if (std.mem.eql(u8, sig_name, "SEGV")) return .SEGV;
        if (std.mem.eql(u8, sig_name, "USR2")) return .USR2;
        if (std.mem.eql(u8, sig_name, "PIPE")) return .PIPE;
        if (std.mem.eql(u8, sig_name, "ALRM")) return .ALRM;
        if (std.mem.eql(u8, sig_name, "TERM")) return .TERM;
        if (std.mem.eql(u8, sig_name, "CHLD")) return .CHLD;
        if (std.mem.eql(u8, sig_name, "CONT")) return .CONT;
        if (std.mem.eql(u8, sig_name, "STOP")) return .STOP;
        if (std.mem.eql(u8, sig_name, "TSTP")) return .TSTP;

        return .TERM; // Default to SIGTERM
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
            var has_entries = false;
            while (iter.next()) |entry| {
                try IO.print("{s}\t{s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                has_entries = true;
            }
            if (!has_entries) {
                try IO.print("hash: hash table empty\n", .{});
            }
            return 0;
        }

        // Parse flags
        var arg_idx: usize = 0;
        while (arg_idx < command.args.len) {
            const arg = command.args[arg_idx];

            // hash -r - clear hash table
            if (std.mem.eql(u8, arg, "-r")) {
                var iter = shell_ref.command_cache.iterator();
                while (iter.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.*);
                }
                shell_ref.command_cache.clearRetainingCapacity();
                arg_idx += 1;
                continue;
            }

            // hash -l - list in reusable format
            if (std.mem.eql(u8, arg, "-l")) {
                var iter = shell_ref.command_cache.iterator();
                while (iter.next()) |entry| {
                    try IO.print("builtin hash -p {s} {s}\n", .{ entry.value_ptr.*, entry.key_ptr.* });
                }
                return 0;
            }

            // hash -d name - delete specific entry
            if (std.mem.eql(u8, arg, "-d")) {
                if (arg_idx + 1 >= command.args.len) {
                    try IO.eprint("den: hash: -d: option requires an argument\n", .{});
                    return 1;
                }
                const name = command.args[arg_idx + 1];
                if (shell_ref.command_cache.fetchRemove(name)) |kv| {
                    self.allocator.free(kv.key);
                    self.allocator.free(kv.value);
                } else {
                    try IO.eprint("den: hash: {s}: not found\n", .{name});
                    return 1;
                }
                arg_idx += 2;
                continue;
            }

            // hash -p path name - add specific path for name
            if (std.mem.eql(u8, arg, "-p")) {
                if (arg_idx + 2 >= command.args.len) {
                    try IO.eprint("den: hash: -p: option requires path and name arguments\n", .{});
                    return 1;
                }
                const path = command.args[arg_idx + 1];
                const name = command.args[arg_idx + 2];

                // Remove old entry if exists
                if (shell_ref.command_cache.fetchRemove(name)) |kv| {
                    self.allocator.free(kv.key);
                    self.allocator.free(kv.value);
                }

                // Add new entry with specified path
                const key = try self.allocator.dupe(u8, name);
                errdefer self.allocator.free(key);
                const value = try self.allocator.dupe(u8, path);
                errdefer self.allocator.free(value);
                try shell_ref.command_cache.put(key, value);
                arg_idx += 3;
                continue;
            }

            // hash -t name... - print cached path for name
            if (std.mem.eql(u8, arg, "-t")) {
                if (arg_idx + 1 >= command.args.len) {
                    try IO.eprint("den: hash: -t: option requires an argument\n", .{});
                    return 1;
                }
                var found_all = true;
                for (command.args[arg_idx + 1 ..]) |name| {
                    if (shell_ref.command_cache.get(name)) |path| {
                        try IO.print("{s}\n", .{path});
                    } else {
                        try IO.eprint("den: hash: {s}: not found\n", .{name});
                        found_all = false;
                    }
                }
                return if (found_all) 0 else 1;
            }

            // Not a flag, must be command name(s) to hash
            break;
        }

        // If we only had -r flag with no commands, we're done
        if (arg_idx >= command.args.len) {
            return 0;
        }

        // hash command [command...] - add commands to hash table
        const path_var = std.posix.getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
        var path_list = utils.env.PathList.parse(self.allocator, path_var) catch {
            return 1;
        };
        defer path_list.deinit();

        for (command.args[arg_idx..]) |cmd_name| {
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
        const shell_ref = self.shell orelse {
            try IO.eprint("den: reload: shell context not available\n", .{});
            return 1;
        };

        // Check for --help
        for (command.args) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                try IO.print("reload - reload shell configuration\n", .{});
                try IO.print("Usage: reload [options]\n", .{});
                try IO.print("Options:\n", .{});
                try IO.print("  -v, --verbose  Show detailed reload information\n", .{});
                try IO.print("  --aliases      Reload only aliases\n", .{});
                try IO.print("  --config       Reload only config (no aliases)\n", .{});
                try IO.print("\nConfig search order:\n", .{});
                try IO.print("  1. ./den.jsonc\n", .{});
                try IO.print("  2. ./package.jsonc (\"den\" key)\n", .{});
                try IO.print("  3. ./config/den.jsonc\n", .{});
                try IO.print("  4. ./.config/den.jsonc\n", .{});
                try IO.print("  5. ~/.config/den.jsonc\n", .{});
                try IO.print("  6. ~/package.jsonc (\"den\" key)\n", .{});
                return 0;
            }
        }

        var verbose = false;
        var reload_aliases = true;
        var reload_config = true;

        for (command.args) |arg| {
            if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
                verbose = true;
            } else if (std.mem.eql(u8, arg, "--aliases")) {
                reload_config = false;
            } else if (std.mem.eql(u8, arg, "--config")) {
                reload_aliases = false;
            }
        }

        const config_loader = @import("../config_loader.zig");

        if (reload_config) {
            // Load config with source information
            const result = config_loader.loadConfigWithSource(self.allocator) catch {
                try IO.eprint("den: reload: failed to load configuration\n", .{});
                return 1;
            };

            // Update shell config
            shell_ref.config = result.config;

            if (verbose) {
                const source_name = switch (result.source.source_type) {
                    .default => "defaults",
                    .den_jsonc => "den.jsonc",
                    .package_jsonc => "package.jsonc",
                    .custom_path => "custom path",
                };
                if (result.source.path) |path| {
                    try IO.print("Configuration loaded from: {s} ({s})\n", .{ path, source_name });
                } else {
                    try IO.print("Configuration loaded from: {s}\n", .{source_name});
                }
            }
        }

        if (reload_aliases) {
            // Reload aliases from config
            shell_ref.loadAliasesFromConfig() catch {
                try IO.eprint("den: reload: failed to reload aliases\n", .{});
                return 1;
            };
            if (verbose) {
                try IO.print("Aliases reloaded from configuration\n", .{});
            }
        }

        if (!verbose) {
            try IO.print("Configuration reloaded\n", .{});
        } else {
            try IO.print("Reload complete\n", .{});
        }

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
            std.posix.nanosleep(interval_seconds, 0);
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
            try IO.eprint("Usage: grep [-i] [-n] [-v] [-c] [--color] [--no-color] pattern [file...]\n", .{});
            return 1;
        }

        var case_insensitive = false;
        var show_line_numbers = false;
        var invert_match = false;
        var count_only = false;
        var use_color = true; // Default to color on
        var show_filename = false;
        var pattern_idx: usize = 0;

        // Parse flags
        for (command.args, 0..) |arg, i| {
            if (arg.len > 0 and arg[0] == '-') {
                if (std.mem.eql(u8, arg, "--color") or std.mem.eql(u8, arg, "--colour")) {
                    use_color = true;
                    pattern_idx = i + 1;
                } else if (std.mem.eql(u8, arg, "--no-color") or std.mem.eql(u8, arg, "--no-colour")) {
                    use_color = false;
                    pattern_idx = i + 1;
                } else if (std.mem.eql(u8, arg, "-H")) {
                    show_filename = true;
                    pattern_idx = i + 1;
                } else if (std.mem.eql(u8, arg, "--help")) {
                    try IO.print("grep - search for patterns in files\n", .{});
                    try IO.print("Usage: grep [options] pattern [file...]\n", .{});
                    try IO.print("Options:\n", .{});
                    try IO.print("  -i          Case insensitive search\n", .{});
                    try IO.print("  -n          Show line numbers\n", .{});
                    try IO.print("  -v          Invert match (show non-matching lines)\n", .{});
                    try IO.print("  -c          Count matches only\n", .{});
                    try IO.print("  -H          Show filename for each match\n", .{});
                    try IO.print("  --color     Highlight matches (default)\n", .{});
                    try IO.print("  --no-color  Disable highlighting\n", .{});
                    return 0;
                } else {
                    for (arg[1..]) |c| {
                        if (c == 'i') case_insensitive = true
                        else if (c == 'n') show_line_numbers = true
                        else if (c == 'v') invert_match = true
                        else if (c == 'c') count_only = true
                        else if (c == 'H') show_filename = true
                        else {
                            try IO.eprint("den: grep: invalid option: -{c}\n", .{c});
                            return 1;
                        }
                    }
                    pattern_idx = i + 1;
                }
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

        // Auto-enable filename display for multiple files
        const display_filename = show_filename or files.len > 1;

        // ANSI color codes for highlighting
        const color_match = "\x1b[1;31m"; // Bold red
        const color_linenum = "\x1b[32m"; // Green
        const color_filename = "\x1b[35m"; // Magenta
        const color_reset = "\x1b[0m";

        var total_matches: usize = 0;

        // Search each file
        for (files) |file_path| {
            const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
                try IO.eprint("den: grep: {s}: {}\n", .{ file_path, err });
                continue;
            };
            defer file.close();

            const max_size: usize = 10 * 1024 * 1024;
            const file_size = file.getEndPos() catch {
                try IO.eprint("den: grep: error reading {s}\n", .{file_path});
                continue;
            };
            const read_size: usize = @min(file_size, max_size);
            const buffer = self.allocator.alloc(u8, read_size) catch {
                try IO.eprint("den: grep: out of memory\n", .{});
                continue;
            };
            defer self.allocator.free(buffer);
            var total_read: usize = 0;
            while (total_read < read_size) {
                const n = file.read(buffer[total_read..]) catch break;
                if (n == 0) break;
                total_read += n;
            }
            const content = buffer[0..total_read];

            var line_iter = std.mem.splitScalar(u8, content, '\n');
            var line_num: usize = 1;
            var file_matches: usize = 0;

            while (line_iter.next()) |line| {
                var matches = false;
                var match_pos: ?usize = null;

                if (case_insensitive) {
                    // Simple case-insensitive search
                    var idx: usize = 0;
                    while (idx + pattern.len <= line.len) : (idx += 1) {
                        if (std.ascii.eqlIgnoreCase(line[idx .. idx + pattern.len], pattern)) {
                            matches = true;
                            match_pos = idx;
                            break;
                        }
                    }
                } else {
                    match_pos = std.mem.indexOf(u8, line, pattern);
                    matches = match_pos != null;
                }

                if (invert_match) matches = !matches;

                if (matches) {
                    file_matches += 1;
                    total_matches += 1;

                    if (!count_only) {
                        // Build output with highlighting
                        if (display_filename) {
                            if (use_color) {
                                try IO.print("{s}{s}{s}:", .{ color_filename, file_path, color_reset });
                            } else {
                                try IO.print("{s}:", .{file_path});
                            }
                        }

                        if (show_line_numbers) {
                            if (use_color) {
                                try IO.print("{s}{d}{s}:", .{ color_linenum, line_num, color_reset });
                            } else {
                                try IO.print("{d}:", .{line_num});
                            }
                        }

                        // Print line with highlighted matches (only if not inverted)
                        if (use_color and !invert_match and match_pos != null) {
                            try self.printHighlightedLine(line, pattern, case_insensitive, color_match, color_reset);
                        } else {
                            try IO.print("{s}\n", .{line});
                        }
                    }
                }

                line_num += 1;
            }

            if (count_only) {
                if (display_filename) {
                    try IO.print("{s}:{d}\n", .{ file_path, file_matches });
                } else {
                    try IO.print("{d}\n", .{file_matches});
                }
            }
        }

        return if (total_matches > 0) 0 else 1;
    }

    /// Print a line with all occurrences of pattern highlighted
    fn printHighlightedLine(_: *Executor, line: []const u8, pattern: []const u8, case_insensitive: bool, color_on: []const u8, color_off: []const u8) !void {
        if (pattern.len == 0) {
            try IO.print("{s}\n", .{line});
            return;
        }

        var pos: usize = 0;
        while (pos < line.len) {
            // Find next match
            var match_start: ?usize = null;

            if (case_insensitive) {
                var idx = pos;
                while (idx + pattern.len <= line.len) : (idx += 1) {
                    if (std.ascii.eqlIgnoreCase(line[idx .. idx + pattern.len], pattern)) {
                        match_start = idx;
                        break;
                    }
                }
            } else {
                match_start = std.mem.indexOfPos(u8, line, pos, pattern);
            }

            if (match_start) |start| {
                // Print text before match
                if (start > pos) {
                    try IO.print("{s}", .{line[pos..start]});
                }
                // Print highlighted match
                try IO.print("{s}{s}{s}", .{ color_on, line[start .. start + pattern.len], color_off });
                pos = start + pattern.len;
            } else {
                // No more matches, print rest of line
                try IO.print("{s}", .{line[pos..]});
                break;
            }
        }
        try IO.print("\n", .{});
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

    /// Fuzzy file finder - ft [pattern] [-t type] [-d depth] [-n limit]
    fn builtinFt(self: *Executor, command: *types.ParsedCommand) !i32 {
        var pattern: ?[]const u8 = null;
        var type_filter: ?u8 = null; // 'f' for file, 'd' for directory
        var max_depth: usize = 10;
        var max_results: usize = 50;
        var start_path: []const u8 = ".";

        // Parse arguments
        var i: usize = 0;
        while (i < command.args.len) : (i += 1) {
            const arg = command.args[i];
            if (std.mem.eql(u8, arg, "-t") and i + 1 < command.args.len) {
                const type_str = command.args[i + 1];
                if (type_str.len >= 1) {
                    type_filter = type_str[0];
                }
                i += 1;
            } else if (std.mem.eql(u8, arg, "-d") and i + 1 < command.args.len) {
                max_depth = std.fmt.parseInt(usize, command.args[i + 1], 10) catch 10;
                i += 1;
            } else if (std.mem.eql(u8, arg, "-n") and i + 1 < command.args.len) {
                max_results = std.fmt.parseInt(usize, command.args[i + 1], 10) catch 50;
                i += 1;
            } else if (std.mem.eql(u8, arg, "-p") and i + 1 < command.args.len) {
                start_path = command.args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                try IO.print("ft - fuzzy file finder\n", .{});
                try IO.print("Usage: ft [pattern] [-t f|d] [-d depth] [-n limit] [-p path]\n", .{});
                try IO.print("Options:\n", .{});
                try IO.print("  -t f|d    Filter by type (f=file, d=directory)\n", .{});
                try IO.print("  -d N      Maximum depth (default: 10)\n", .{});
                try IO.print("  -n N      Maximum results (default: 50)\n", .{});
                try IO.print("  -p PATH   Start path (default: .)\n", .{});
                try IO.print("Examples:\n", .{});
                try IO.print("  ft main       Find files matching 'main'\n", .{});
                try IO.print("  ft .zig -t f  Find .zig files only\n", .{});
                try IO.print("  ft src -t d   Find directories matching 'src'\n", .{});
                return 0;
            } else if (arg[0] != '-') {
                pattern = arg;
            }
        }

        if (pattern == null) {
            try IO.eprint("den: ft: missing pattern\n", .{});
            try IO.eprint("Usage: ft [pattern] [-t f|d] [-d depth] [-n limit]\n", .{});
            return 1;
        }

        // Collect matching files with scores
        var results = std.ArrayList(FuzzyResult).empty;
        defer {
            for (results.items) |*item| {
                self.allocator.free(item.path);
            }
            results.deinit(self.allocator);
        }

        try self.fuzzyFindRecursive(start_path, pattern.?, type_filter, max_depth, 0, &results, max_results * 2);

        // Sort by score (descending)
        std.mem.sort(FuzzyResult, results.items, {}, struct {
            fn lessThan(_: void, a: FuzzyResult, b: FuzzyResult) bool {
                return a.score > b.score; // Higher score first
            }
        }.lessThan);

        // Print top results
        const count = @min(results.items.len, max_results);
        for (results.items[0..count]) |result| {
            try IO.print("{s}\n", .{result.path});
        }

        if (results.items.len == 0) {
            try IO.eprint("No matches found for '{s}'\n", .{pattern.?});
            return 1;
        }

        return 0;
    }

    const FuzzyResult = struct {
        path: []const u8,
        score: u32,
    };

    fn fuzzyFindRecursive(
        self: *Executor,
        dir_path: []const u8,
        pattern: []const u8,
        type_filter: ?u8,
        max_depth: usize,
        current_depth: usize,
        results: *std.ArrayList(FuzzyResult),
        max_collect: usize,
    ) !void {
        if (current_depth >= max_depth) return;
        if (results.items.len >= max_collect) return;

        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
            return;
        };
        defer dir.close();

        var iter = dir.iterate();

        while (try iter.next()) |entry| {
            if (results.items.len >= max_collect) break;

            // Skip hidden files and common unneeded directories
            if (entry.name[0] == '.') continue;
            if (std.mem.eql(u8, entry.name, "node_modules")) continue;
            if (std.mem.eql(u8, entry.name, "target")) continue;
            if (std.mem.eql(u8, entry.name, "zig-cache")) continue;
            if (std.mem.eql(u8, entry.name, ".zig-cache")) continue;
            if (std.mem.eql(u8, entry.name, "zig-out")) continue;
            if (std.mem.eql(u8, entry.name, "__pycache__")) continue;
            if (std.mem.eql(u8, entry.name, ".git")) continue;

            // Check type filter
            if (type_filter) |filter| {
                if (filter == 'f' and entry.kind != .file) {
                    if (entry.kind == .directory) {
                        const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, entry.name });
                        defer self.allocator.free(full_path);
                        try self.fuzzyFindRecursive(full_path, pattern, type_filter, max_depth, current_depth + 1, results, max_collect);
                    }
                    continue;
                }
                if (filter == 'd' and entry.kind != .directory) continue;
            }

            // Calculate fuzzy match score
            const score = fuzzyMatchScore(entry.name, pattern);
            if (score > 0) {
                const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, entry.name });
                try results.append(self.allocator, .{ .path = full_path, .score = score });
            }

            // Recurse into directories
            if (entry.kind == .directory) {
                const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, entry.name });
                defer self.allocator.free(full_path);
                try self.fuzzyFindRecursive(full_path, pattern, type_filter, max_depth, current_depth + 1, results, max_collect);
            }
        }
    }

    /// Calculate fuzzy match score between filename and pattern
    /// Returns 0 for no match, higher values for better matches
    fn fuzzyMatchScore(name: []const u8, pattern: []const u8) u32 {
        if (pattern.len == 0) return 0;
        if (name.len == 0) return 0;

        // Convert both to lowercase for case-insensitive matching
        var name_lower: [256]u8 = undefined;
        var pattern_lower: [256]u8 = undefined;

        const name_len = @min(name.len, 255);
        const pattern_len = @min(pattern.len, 255);

        for (name[0..name_len], 0..) |c, idx| {
            name_lower[idx] = std.ascii.toLower(c);
        }
        for (pattern[0..pattern_len], 0..) |c, idx| {
            pattern_lower[idx] = std.ascii.toLower(c);
        }

        const name_lc = name_lower[0..name_len];
        const pattern_lc = pattern_lower[0..pattern_len];

        // Exact match (highest score)
        if (std.mem.eql(u8, name_lc, pattern_lc)) {
            return 1000;
        }

        // Starts with pattern (high score)
        if (std.mem.startsWith(u8, name_lc, pattern_lc)) {
            return 800;
        }

        // Contains pattern as substring (medium-high score)
        if (std.mem.indexOf(u8, name_lc, pattern_lc) != null) {
            return 600;
        }

        // Ends with pattern (medium score)
        if (std.mem.endsWith(u8, name_lc, pattern_lc)) {
            return 500;
        }

        // Fuzzy match: all pattern chars appear in order
        var score: u32 = 0;
        var name_idx: usize = 0;
        var consecutive: u32 = 0;
        var first_match: bool = true;

        for (pattern_lc) |pc| {
            var found = false;
            while (name_idx < name_len) : (name_idx += 1) {
                if (name_lc[name_idx] == pc) {
                    found = true;
                    score += 10;

                    // Bonus for consecutive matches
                    if (consecutive > 0) {
                        score += consecutive * 5;
                    }
                    consecutive += 1;

                    // Bonus for matching at start
                    if (first_match and name_idx == 0) {
                        score += 50;
                    }

                    // Bonus for matching after separator (., -, _, /)
                    if (name_idx > 0) {
                        const prev = name_lc[name_idx - 1];
                        if (prev == '.' or prev == '-' or prev == '_' or prev == '/') {
                            score += 30;
                        }
                    }

                    first_match = false;
                    name_idx += 1;
                    break;
                } else {
                    consecutive = 0;
                }
            }
            if (!found) return 0; // Pattern char not found
        }

        return score;
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

        const max_size: usize = 10 * 1024 * 1024;
        const file_size = file.getEndPos() catch |err| {
            try IO.eprint("den: json: error reading {s}: {}\n", .{ file_path, err });
            return 1;
        };
        const read_size: usize = @min(file_size, max_size);
        const buffer = self.allocator.alloc(u8, read_size) catch |err| {
            try IO.eprint("den: json: out of memory: {}\n", .{err});
            return 1;
        };
        defer self.allocator.free(buffer);
        var total_read: usize = 0;
        while (total_read < read_size) {
            const n = file.read(buffer[total_read..]) catch |err| {
                try IO.eprint("den: json: error reading {s}: {}\n", .{ file_path, err });
                return 1;
            };
            if (n == 0) break;
            total_read += n;
        }
        const content = buffer[0..total_read];

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
            mtime_ns: i96,
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
                    const dir_stat = dir.stat() catch {
                        entries[count] = .{
                            .name = try self.allocator.dupe(u8, entry.name),
                            .kind = entry.kind,
                            .size = 0,
                            .mtime_ns = 0,
                        };
                        count += 1;
                        continue;
                    };
                    entries[count] = .{
                        .name = try self.allocator.dupe(u8, entry.name),
                        .kind = entry.kind,
                        .size = dir_stat.size,
                        .mtime_ns = dir_stat.mtime.nanoseconds,
                    };
                } else {
                    entries[count] = .{
                        .name = try self.allocator.dupe(u8, entry.name),
                        .kind = entry.kind,
                        .size = 0,
                        .mtime_ns = 0,
                    };
                }
                count += 1;
                continue;
            };

            entries[count] = .{
                .name = try self.allocator.dupe(u8, entry.name),
                .kind = entry.kind,
                .size = stat.size,
                .mtime_ns = stat.mtime.nanoseconds,
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
                        entries[i].mtime_ns < entries[j].mtime_ns
                    else
                        entries[i].mtime_ns > entries[j].mtime_ns
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
                const time_ns: u64 = @intCast(@max(0, entry.mtime_ns));
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
        // Check if command exists before forking to provide better error messages
        if (!self.commandExistsInPath(command.name)) {
            try IO.eprint("den: {s}: command not found\n", .{command.name});

            // Try to provide typo correction suggestions
            var tc = TypoCorrection.init(self.allocator);
            if (tc.formatSuggestionMessage(command.name)) |maybe_msg| {
                if (maybe_msg) |suggestion_msg| {
                    defer self.allocator.free(suggestion_msg);
                    try IO.eprint("{s}\n", .{suggestion_msg});
                }
            } else |_| {}

            return 127; // Standard "command not found" exit code
        }

        if (builtin.os.tag == .windows) {
            return try self.executeExternalWindows(command);
        }
        return try self.executeExternalPosix(command);
    }

    /// Check if a command exists in PATH or as an absolute/relative path
    fn commandExistsInPath(self: *Executor, cmd: []const u8) bool {
        _ = self;

        // If command contains a slash, it's a path - check directly
        if (std.mem.indexOf(u8, cmd, "/") != null or
            (builtin.os.tag == .windows and std.mem.indexOf(u8, cmd, "\\") != null))
        {
            const stat = std.fs.cwd().statFile(cmd) catch return false;
            // Check if it's executable (Unix) or just exists (Windows)
            if (builtin.os.tag == .windows) {
                return stat.kind == .file;
            }
            return (stat.mode & 0o111) != 0;
        }

        // Search in PATH
        const path = env_utils.getEnv("PATH") orelse return false;
        var path_iter = std.mem.splitScalar(u8, path, if (builtin.os.tag == .windows) ';' else ':');

        while (path_iter.next()) |dir_path| {
            if (dir_path.len == 0) continue;

            // Try to open the directory and check for the file
            var dir = std.fs.cwd().openDir(dir_path, .{}) catch continue;
            defer dir.close();

            const stat = dir.statFile(cmd) catch continue;

            // Check if it's executable
            if (builtin.os.tag == .windows) {
                // On Windows, also check common extensions
                if (stat.kind == .file) return true;
            } else {
                if ((stat.mode & 0o111) != 0) return true;
            }
        }

        // On Windows, also try with common extensions
        if (builtin.os.tag == .windows) {
            const extensions = [_][]const u8{ ".exe", ".cmd", ".bat", ".com" };
            for (extensions) |ext| {
                var buf: [512]u8 = undefined;
                const cmd_with_ext = std.fmt.bufPrint(&buf, "{s}{s}", .{ cmd, ext }) catch continue;

                path_iter = std.mem.splitScalar(u8, path, ';');
                while (path_iter.next()) |dir_path| {
                    if (dir_path.len == 0) continue;

                    var dir = std.fs.cwd().openDir(dir_path, .{}) catch continue;
                    defer dir.close();

                    _ = dir.statFile(cmd_with_ext) catch continue;
                    return true;
                }
            }
        }

        return false;
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

            // Use C's environ directly which is updated by setenv/unsetenv
            _ = std.posix.execvpeZ(cmd_z.ptr, @ptrCast(argv.ptr), getCEnviron()) catch {
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

            // Use C's environ directly which is updated by setenv/unsetenv
            _ = std.posix.execvpeZ(cmd_z.ptr, @ptrCast(argv.ptr), getCEnviron()) catch {
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

        // Get current time - use seconds from the timestamp
        const instant = std.time.Instant.now() catch {
            try IO.eprint("date: cannot get current time\n", .{});
            return 1;
        };
        const epoch_seconds: u64 = @intCast(instant.timestamp.sec);

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
        const seed: u64 = blk: {
            const instant = std.time.Instant.now() catch break :blk 0;
            break :blk @intCast(instant.timestamp.sec);
        };
        var rng = std.Random.DefaultPrng.init(seed);
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

    fn builtinLocalip(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        _ = command;

        // On macOS/Linux, get local IP using hostname command or read from system
        if (builtin.os.tag == .macos or builtin.os.tag == .linux) {
            // Try to get IP from environment or use a simple approach
            // For simplicity, we'll suggest using 'ifconfig' or 'ip addr'
            try IO.print("Use 'ifconfig | grep inet' or 'ip addr' to see local IP addresses\n", .{});
            try IO.print("Tip: On macOS: ipconfig getifaddr en0\n", .{});
        } else {
            try IO.print("localip: not supported on this platform\n", .{});
            return 1;
        }
        return 0;
    }

    fn builtinIp(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        _ = command;

        try IO.print("Use 'curl -s ifconfig.me' or 'curl -s icanhazip.com' to get public IP\n", .{});
        return 0;
    }

    fn builtinShrug(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        _ = command;

        try IO.print("¯\\_(ツ)_/¯\n", .{});
        return 0;
    }

    fn builtinWeb(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;

        if (command.args.len == 0) {
            try IO.eprint("web: usage: web <url>\n", .{});
            return 1;
        }

        const url = command.args[0];

        // Use platform-specific command to open URL
        if (builtin.os.tag == .macos) {
            try IO.print("Opening: {s}\n", .{url});
            try IO.print("Run: open \"{s}\"\n", .{url});
        } else if (builtin.os.tag == .linux) {
            try IO.print("Opening: {s}\n", .{url});
            try IO.print("Run: xdg-open \"{s}\"\n", .{url});
        } else if (builtin.os.tag == .windows) {
            try IO.print("Opening: {s}\n", .{url});
            try IO.print("Run: start \"{s}\"\n", .{url});
        } else {
            try IO.eprint("web: not supported on this platform\n", .{});
            return 1;
        }
        return 0;
    }

    fn builtinReturn(self: *Executor, command: *types.ParsedCommand) !i32 {
        const shell = self.shell orelse {
            try IO.eprint("return: can only return from a function or sourced script\n", .{});
            return 1;
        };

        // Parse return code (default 0)
        var return_code: i32 = 0;
        if (command.args.len > 0) {
            return_code = std.fmt.parseInt(i32, command.args[0], 10) catch {
                try IO.eprint("return: {s}: numeric argument required\n", .{command.args[0]});
                return 2;
            };
        }

        // Request return from current function
        shell.function_manager.requestReturn(return_code) catch {
            try IO.eprint("return: can only return from a function or sourced script\n", .{});
            return 1;
        };

        return return_code;
    }

    fn builtinLocal(self: *Executor, command: *types.ParsedCommand) !i32 {
        const shell = self.shell orelse {
            try IO.eprint("local: can only be used in a function\n", .{});
            return 1;
        };

        if (command.args.len == 0) {
            // List local variables
            if (shell.function_manager.currentFrame()) |frame| {
                var iter = frame.local_vars.iterator();
                while (iter.next()) |entry| {
                    try IO.print("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                }
            }
            return 0;
        }

        // Set local variables
        for (command.args) |arg| {
            // Parse name=value or just name
            if (std.mem.indexOf(u8, arg, "=")) |eq_pos| {
                const name = arg[0..eq_pos];
                const value = arg[eq_pos + 1 ..];
                shell.function_manager.setLocal(name, value) catch {
                    try IO.eprint("local: {s}: can only be used in a function\n", .{name});
                    return 1;
                };
            } else {
                // Just declare as empty
                shell.function_manager.setLocal(arg, "") catch {
                    try IO.eprint("local: {s}: can only be used in a function\n", .{arg});
                    return 1;
                };
            }
        }

        return 0;
    }

    fn builtinCopyssh(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        _ = command;

        // Get home directory
        const home = std.posix.getenv("HOME") orelse {
            try IO.eprint("copyssh: HOME environment variable not set\n", .{});
            return 1;
        };

        // SSH key files to try (in order of preference)
        const key_files = [_][]const u8{
            "/.ssh/id_ed25519.pub",
            "/.ssh/id_rsa.pub",
            "/.ssh/id_ecdsa.pub",
            "/.ssh/id_dsa.pub",
        };

        var found_key: ?[]const u8 = null;
        var found_path: ?[]const u8 = null;
        var key_buffer: [8192]u8 = undefined;

        for (key_files) |key_suffix| {
            // Build full path
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ home, key_suffix }) catch continue;

            // Try to open and read the key file
            const file = std.fs.cwd().openFile(full_path, .{}) catch continue;
            defer file.close();

            const bytes_read = file.read(&key_buffer) catch continue;
            if (bytes_read > 0) {
                found_key = key_buffer[0..bytes_read];
                found_path = key_suffix;
                break;
            }
        }

        const key_content = found_key orelse {
            try IO.eprint("copyssh: no SSH public key found\n", .{});
            try IO.eprint("Try generating one with: ssh-keygen -t ed25519\n", .{});
            return 1;
        };

        // Remove trailing newline if present
        var trimmed_key = key_content;
        while (trimmed_key.len > 0 and (trimmed_key[trimmed_key.len - 1] == '\n' or trimmed_key[trimmed_key.len - 1] == '\r')) {
            trimmed_key = trimmed_key[0 .. trimmed_key.len - 1];
        }

        // Copy to clipboard using platform-specific command
        if (builtin.os.tag == .macos) {
            // Use pbcopy on macOS
            var child = std.process.Child.init(&[_][]const u8{"pbcopy"}, std.heap.page_allocator);
            child.stdin_behavior = .Pipe;
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;

            child.spawn() catch {
                try IO.eprint("copyssh: failed to run pbcopy\n", .{});
                return 1;
            };

            if (child.stdin) |stdin| {
                stdin.writeAll(trimmed_key) catch {
                    try IO.eprint("copyssh: failed to write to pbcopy\n", .{});
                    return 1;
                };
                stdin.close();
                child.stdin = null;
            }

            _ = child.wait() catch {
                try IO.eprint("copyssh: pbcopy failed\n", .{});
                return 1;
            };

            try IO.print("SSH public key (~{s}) copied to clipboard\n", .{found_path.?});
        } else if (builtin.os.tag == .linux) {
            // Try xclip or xsel on Linux
            var child = std.process.Child.init(&[_][]const u8{ "xclip", "-selection", "clipboard" }, std.heap.page_allocator);
            child.stdin_behavior = .Pipe;
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;

            if (child.spawn()) |_| {
                if (child.stdin) |stdin| {
                    stdin.writeAll(trimmed_key) catch {};
                    stdin.close();
                    child.stdin = null;
                }
                _ = child.wait() catch {};
                try IO.print("SSH public key (~{s}) copied to clipboard\n", .{found_path.?});
            } else |_| {
                // Fallback: just print the key
                try IO.print("{s}\n", .{trimmed_key});
                try IO.eprint("(xclip not found - key printed above)\n", .{});
            }
        } else {
            // Fallback: just print the key
            try IO.print("{s}\n", .{trimmed_key});
        }

        return 0;
    }

    fn builtinReloaddns(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        _ = command;

        if (builtin.os.tag != .macos) {
            try IO.eprint("reloaddns: only supported on macOS\n", .{});
            return 1;
        }

        // Run dscacheutil -flushcache
        var flush_child = std.process.Child.init(&[_][]const u8{ "dscacheutil", "-flushcache" }, std.heap.page_allocator);
        flush_child.stdin_behavior = .Ignore;
        flush_child.stdout_behavior = .Ignore;
        flush_child.stderr_behavior = .Pipe;

        flush_child.spawn() catch {
            try IO.eprint("reloaddns: failed to run dscacheutil\n", .{});
            return 1;
        };

        const flush_result = flush_child.wait() catch {
            try IO.eprint("reloaddns: dscacheutil failed\n", .{});
            return 1;
        };

        if (flush_result.Exited != 0) {
            try IO.eprint("reloaddns: dscacheutil returned error\n", .{});
            return 1;
        }

        // Run killall -HUP mDNSResponder
        var kill_child = std.process.Child.init(&[_][]const u8{ "killall", "-HUP", "mDNSResponder" }, std.heap.page_allocator);
        kill_child.stdin_behavior = .Ignore;
        kill_child.stdout_behavior = .Ignore;
        kill_child.stderr_behavior = .Pipe;

        kill_child.spawn() catch {
            try IO.eprint("reloaddns: failed to run killall\n", .{});
            return 1;
        };

        const kill_result = kill_child.wait() catch {
            try IO.eprint("reloaddns: killall failed\n", .{});
            return 1;
        };

        if (kill_result.Exited != 0) {
            try IO.eprint("reloaddns: killall mDNSResponder returned error (may need sudo)\n", .{});
            return 1;
        }

        try IO.print("DNS cache flushed successfully\n", .{});
        return 0;
    }

    fn builtinEmptytrash(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;
        _ = command;

        if (builtin.os.tag != .macos) {
            try IO.eprint("emptytrash: only supported on macOS\n", .{});
            return 1;
        }

        // Use osascript to empty trash
        var child = std.process.Child.init(&[_][]const u8{
            "osascript", "-e", "tell application \"Finder\" to empty trash",
        }, std.heap.page_allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Pipe;

        child.spawn() catch {
            try IO.eprint("emptytrash: failed to run osascript\n", .{});
            return 1;
        };

        const result = child.wait() catch {
            try IO.eprint("emptytrash: osascript failed\n", .{});
            return 1;
        };

        if (result.Exited != 0) {
            try IO.eprint("emptytrash: failed to empty trash\n", .{});
            return 1;
        }

        try IO.print("Trash emptied successfully\n", .{});
        return 0;
    }

    fn builtinWip(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;

        // Get custom message if provided
        var message: []const u8 = "WIP";
        if (command.args.len > 0) {
            message = command.args[0];
        }

        // Run git add .
        var add_child = std.process.Child.init(&[_][]const u8{ "git", "add", "." }, std.heap.page_allocator);
        add_child.stdin_behavior = .Ignore;
        add_child.stdout_behavior = .Inherit;
        add_child.stderr_behavior = .Inherit;

        add_child.spawn() catch {
            try IO.eprint("wip: failed to run git add\n", .{});
            return 1;
        };

        const add_result = add_child.wait() catch {
            try IO.eprint("wip: git add failed\n", .{});
            return 1;
        };

        if (add_result.Exited != 0) {
            try IO.eprint("wip: git add returned error\n", .{});
            return 1;
        }

        // Run git commit -m "message"
        var commit_child = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", message }, std.heap.page_allocator);
        commit_child.stdin_behavior = .Ignore;
        commit_child.stdout_behavior = .Inherit;
        commit_child.stderr_behavior = .Inherit;

        commit_child.spawn() catch {
            try IO.eprint("wip: failed to run git commit\n", .{});
            return 1;
        };

        const commit_result = commit_child.wait() catch {
            try IO.eprint("wip: git commit failed\n", .{});
            return 1;
        };

        return @intCast(commit_result.Exited);
    }

    fn builtinBookmark(self: *Executor, command: *types.ParsedCommand) !i32 {
        // bookmark         - list all bookmarks
        // bookmark name    - cd to bookmark
        // bookmark -a name - add current dir as bookmark
        // bookmark -d name - delete bookmark

        if (command.args.len == 0) {
            // List all bookmarks
            if (self.shell) |shell| {
                var iter = shell.named_dirs.iterator();
                var count: usize = 0;
                while (iter.next()) |entry| {
                    try IO.print("{s} -> {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                    count += 1;
                }
                if (count == 0) {
                    try IO.print("No bookmarks set. Use 'bookmark -a name' to add one.\n", .{});
                }
            } else {
                try IO.eprint("bookmark: shell not available\n", .{});
                return 1;
            }
            return 0;
        }

        const first_arg = command.args[0];

        if (std.mem.eql(u8, first_arg, "-a")) {
            // Add bookmark
            if (command.args.len < 2) {
                try IO.eprint("bookmark: -a requires a name\n", .{});
                return 1;
            }
            const name = command.args[1];

            // Get current directory
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = std.posix.getcwd(&cwd_buf) catch {
                try IO.eprint("bookmark: failed to get current directory\n", .{});
                return 1;
            };

            if (self.shell) |shell| {
                // Add to named directories
                const key = try self.allocator.dupe(u8, name);
                const value = try self.allocator.dupe(u8, cwd);

                const result = shell.named_dirs.fetchPut(key, value) catch {
                    self.allocator.free(key);
                    self.allocator.free(value);
                    try IO.eprint("bookmark: failed to save bookmark\n", .{});
                    return 1;
                };

                if (result) |old| {
                    self.allocator.free(old.key);
                    self.allocator.free(old.value);
                }

                try IO.print("Bookmark '{s}' -> {s}\n", .{ name, cwd });
            } else {
                try IO.eprint("bookmark: shell not available\n", .{});
                return 1;
            }
            return 0;
        }

        if (std.mem.eql(u8, first_arg, "-d")) {
            // Delete bookmark
            if (command.args.len < 2) {
                try IO.eprint("bookmark: -d requires a name\n", .{});
                return 1;
            }
            const name = command.args[1];

            if (self.shell) |shell| {
                if (shell.named_dirs.fetchRemove(name)) |old| {
                    self.allocator.free(old.key);
                    self.allocator.free(old.value);
                    try IO.print("Bookmark '{s}' removed\n", .{name});
                } else {
                    try IO.eprint("bookmark: '{s}' not found\n", .{name});
                    return 1;
                }
            } else {
                try IO.eprint("bookmark: shell not available\n", .{});
                return 1;
            }
            return 0;
        }

        // No flag - cd to bookmark
        const name = first_arg;

        if (self.shell) |shell| {
            if (shell.named_dirs.get(name)) |path| {
                std.posix.chdir(path) catch |err| {
                    try IO.eprint("bookmark: {s}: {}\n", .{ path, err });
                    return 1;
                };
                try IO.print("{s}\n", .{path});
            } else {
                try IO.eprint("bookmark: '{s}' not found\n", .{name});
                return 1;
            }
        } else {
            try IO.eprint("bookmark: shell not available\n", .{});
            return 1;
        }

        return 0;
    }

    /// Open file or directory in VS Code
    fn builtinCode(self: *Executor, command: *types.ParsedCommand) !i32 {
        if (builtin.os.tag != .macos) {
            try IO.eprint("code: only supported on macOS\n", .{});
            return 1;
        }

        // Get path - use current directory if not specified
        const path = if (command.args.len > 0) command.args[0] else ".";

        // Execute: open -a "Visual Studio Code" <path>
        const argv = [_]?[*:0]const u8{
            "open",
            "-a",
            "Visual Studio Code",
            try self.allocator.dupeZ(u8, path),
            null,
        };
        defer self.allocator.free(std.mem.span(argv[3].?));

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

    /// Open file or directory in PhpStorm
    fn builtinPstorm(self: *Executor, command: *types.ParsedCommand) !i32 {
        if (builtin.os.tag != .macos) {
            try IO.eprint("pstorm: only supported on macOS\n", .{});
            return 1;
        }

        // Get path - use current directory if not specified
        const path = if (command.args.len > 0) command.args[0] else ".";

        // Execute: open -a "PhpStorm" <path>
        const argv = [_]?[*:0]const u8{
            "open",
            "-a",
            "PhpStorm",
            try self.allocator.dupeZ(u8, path),
            null,
        };
        defer self.allocator.free(std.mem.span(argv[3].?));

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

    /// Show hidden files (macOS) - removes hidden attribute
    fn builtinShow(self: *Executor, command: *types.ParsedCommand) !i32 {
        if (builtin.os.tag != .macos) {
            try IO.eprint("show: only supported on macOS\n", .{});
            return 1;
        }

        if (command.args.len == 0) {
            try IO.eprint("show: usage: show <file>...\n", .{});
            return 1;
        }

        var exit_code: i32 = 0;
        for (command.args) |file| {
            // Execute: chflags nohidden <file>
            const file_z = try self.allocator.dupeZ(u8, file);
            defer self.allocator.free(file_z);

            const argv = [_]?[*:0]const u8{
                "chflags",
                "nohidden",
                file_z,
                null,
            };

            const pid = try std.posix.fork();
            if (pid == 0) {
                _ = std.posix.execvpeZ("chflags", @ptrCast(&argv), getCEnviron()) catch {
                    std.posix.exit(127);
                };
                unreachable;
            } else {
                const result = std.posix.waitpid(pid, 0);
                const code: i32 = @intCast(std.posix.W.EXITSTATUS(result.status));
                if (code != 0) {
                    try IO.eprint("show: failed to show {s}\n", .{file});
                    exit_code = code;
                }
            }
        }
        return exit_code;
    }

    /// Hide files (macOS) - sets hidden attribute
    fn builtinHide(self: *Executor, command: *types.ParsedCommand) !i32 {
        if (builtin.os.tag != .macos) {
            try IO.eprint("hide: only supported on macOS\n", .{});
            return 1;
        }

        if (command.args.len == 0) {
            try IO.eprint("hide: usage: hide <file>...\n", .{});
            return 1;
        }

        var exit_code: i32 = 0;
        for (command.args) |file| {
            // Execute: chflags hidden <file>
            const file_z = try self.allocator.dupeZ(u8, file);
            defer self.allocator.free(file_z);

            const argv = [_]?[*:0]const u8{
                "chflags",
                "hidden",
                file_z,
                null,
            };

            const pid = try std.posix.fork();
            if (pid == 0) {
                _ = std.posix.execvpeZ("chflags", @ptrCast(&argv), getCEnviron()) catch {
                    std.posix.exit(127);
                };
                unreachable;
            } else {
                const result = std.posix.waitpid(pid, 0);
                const code: i32 = @intCast(std.posix.W.EXITSTATUS(result.status));
                if (code != 0) {
                    try IO.eprint("hide: failed to hide {s}\n", .{file});
                    exit_code = code;
                }
            }
        }
        return exit_code;
    }

    fn builtinSysStats(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;

        // Check for help
        for (command.args) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                try IO.print("sys-stats - display system statistics\n", .{});
                try IO.print("Usage: sys-stats [options]\n", .{});
                try IO.print("Options:\n", .{});
                try IO.print("  -c, --cpu     Show CPU info only\n", .{});
                try IO.print("  -m, --memory  Show memory info only\n", .{});
                try IO.print("  -d, --disk    Show disk info only\n", .{});
                try IO.print("  -u, --uptime  Show uptime only\n", .{});
                try IO.print("  -a, --all     Show all stats (default)\n", .{});
                return 0;
            }
        }

        var show_cpu = false;
        var show_memory = false;
        var show_disk = false;
        var show_uptime = false;
        var show_all = command.args.len == 0;

        for (command.args) |arg| {
            if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--cpu")) {
                show_cpu = true;
            } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--memory")) {
                show_memory = true;
            } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--disk")) {
                show_disk = true;
            } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--uptime")) {
                show_uptime = true;
            } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
                show_all = true;
            }
        }

        if (show_all) {
            show_cpu = true;
            show_memory = true;
            show_disk = true;
            show_uptime = true;
        }

        // Header
        try IO.print("\x1b[1;36m=== System Statistics ===\x1b[0m\n\n", .{});

        // CPU Info
        if (show_cpu) {
            try IO.print("\x1b[1;33mCPU:\x1b[0m\n", .{});
            if (builtin.os.tag == .macos) {
                // Get CPU info via sysctl on macOS
                try IO.print("  Cores: {d}\n", .{try std.Thread.getCpuCount()});
            } else if (builtin.os.tag == .linux) {
                // On Linux, read /proc/cpuinfo
                if (std.fs.cwd().openFile("/proc/cpuinfo", .{})) |file| {
                    defer file.close();
                    var cores: u32 = 0;
                    var buf: [4096]u8 = undefined;
                    const n = file.read(&buf) catch 0;
                    var iter = std.mem.splitScalar(u8, buf[0..n], '\n');
                    while (iter.next()) |line| {
                        if (std.mem.startsWith(u8, line, "processor")) {
                            cores += 1;
                        }
                    }
                    try IO.print("  Cores: {d}\n", .{cores});
                } else |_| {
                    try IO.print("  Cores: {d}\n", .{try std.Thread.getCpuCount()});
                }
            } else {
                try IO.print("  Cores: {d}\n", .{try std.Thread.getCpuCount()});
            }
            try IO.print("\n", .{});
        }

        // Memory Info
        if (show_memory) {
            try IO.print("\x1b[1;33mMemory:\x1b[0m\n", .{});
            if (builtin.os.tag == .linux) {
                if (std.fs.cwd().openFile("/proc/meminfo", .{})) |file| {
                    defer file.close();
                    var buf: [4096]u8 = undefined;
                    const n = file.read(&buf) catch 0;
                    var iter = std.mem.splitScalar(u8, buf[0..n], '\n');
                    while (iter.next()) |line| {
                        if (std.mem.startsWith(u8, line, "MemTotal:")) {
                            try IO.print("  {s}\n", .{line});
                        } else if (std.mem.startsWith(u8, line, "MemFree:")) {
                            try IO.print("  {s}\n", .{line});
                        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
                            try IO.print("  {s}\n", .{line});
                        }
                    }
                } else |_| {
                    try IO.print("  (unable to read memory info)\n", .{});
                }
            } else if (builtin.os.tag == .macos) {
                // On macOS, use vm_stat output format description
                try IO.print("  (use 'vm_stat' for detailed memory info)\n", .{});
                // We can get page size at least
                try IO.print("  Page size: 16384 bytes (typical for macOS)\n", .{});
            } else {
                try IO.print("  (memory info not available on this platform)\n", .{});
            }
            try IO.print("\n", .{});
        }

        // Disk Info
        if (show_disk) {
            try IO.print("\x1b[1;33mDisk:\x1b[0m\n", .{});
            // Get current directory disk usage
            const cwd = std.fs.cwd();
            const stat = cwd.statFile(".") catch null;
            if (stat) |_| {
                try IO.print("  (use 'df -h' for detailed disk info)\n", .{});
            } else {
                try IO.print("  (unable to read disk info)\n", .{});
            }
            try IO.print("\n", .{});
        }

        // Uptime
        if (show_uptime) {
            try IO.print("\x1b[1;33mUptime:\x1b[0m\n", .{});
            if (builtin.os.tag == .linux) {
                if (std.fs.cwd().openFile("/proc/uptime", .{})) |file| {
                    defer file.close();
                    var buf: [128]u8 = undefined;
                    const n = file.read(&buf) catch 0;
                    if (n > 0) {
                        var iter = std.mem.splitScalar(u8, buf[0..n], ' ');
                        if (iter.next()) |uptime_str| {
                            const uptime_float = std.fmt.parseFloat(f64, uptime_str) catch 0;
                            const uptime_secs: u64 = @intFromFloat(uptime_float);
                            const days = uptime_secs / 86400;
                            const hours = (uptime_secs % 86400) / 3600;
                            const mins = (uptime_secs % 3600) / 60;
                            try IO.print("  {d} days, {d} hours, {d} minutes\n", .{ days, hours, mins });
                        }
                    }
                } else |_| {
                    try IO.print("  (unable to read uptime)\n", .{});
                }
            } else if (builtin.os.tag == .macos) {
                try IO.print("  (use 'uptime' command for uptime info)\n", .{});
            } else {
                try IO.print("  (uptime not available on this platform)\n", .{});
            }
        }

        return 0;
    }

    fn builtinNetstats(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;

        // Check for help
        for (command.args) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                try IO.print("netstats - display network statistics\n", .{});
                try IO.print("Usage: netstats [options]\n", .{});
                try IO.print("Options:\n", .{});
                try IO.print("  -i, --interfaces  Show network interfaces\n", .{});
                try IO.print("  -c, --connections Show active connections\n", .{});
                try IO.print("  -l, --listening   Show listening ports\n", .{});
                try IO.print("  -a, --all         Show all stats (default)\n", .{});
                return 0;
            }
        }

        var show_interfaces = false;
        var show_connections = false;
        var show_listening = false;
        var show_all = command.args.len == 0;

        for (command.args) |arg| {
            if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--interfaces")) {
                show_interfaces = true;
            } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--connections")) {
                show_connections = true;
            } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--listening")) {
                show_listening = true;
            } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
                show_all = true;
            }
        }

        if (show_all) {
            show_interfaces = true;
            show_connections = true;
            show_listening = true;
        }

        try IO.print("\x1b[1;36m=== Network Statistics ===\x1b[0m\n\n", .{});

        if (show_interfaces) {
            try IO.print("\x1b[1;33mNetwork Interfaces:\x1b[0m\n", .{});
            if (builtin.os.tag == .linux) {
                // Read from /sys/class/net
                var dir = std.fs.openDirAbsolute("/sys/class/net", .{ .iterate = true }) catch {
                    try IO.print("  (unable to list interfaces)\n", .{});
                    return 0;
                };
                defer dir.close();

                var iter = dir.iterate();
                while (iter.next() catch null) |entry| {
                    if (entry.kind == .sym_link or entry.kind == .directory) {
                        try IO.print("  - {s}\n", .{entry.name});
                    }
                }
            } else if (builtin.os.tag == .macos) {
                try IO.print("  (use 'ifconfig' or 'networksetup -listallhardwareports' for interfaces)\n", .{});
            } else {
                try IO.print("  (interface listing not available on this platform)\n", .{});
            }
            try IO.print("\n", .{});
        }

        if (show_connections or show_listening) {
            if (show_connections) {
                try IO.print("\x1b[1;33mActive Connections:\x1b[0m\n", .{});
            }
            if (show_listening) {
                try IO.print("\x1b[1;33mListening Ports:\x1b[0m\n", .{});
            }

            if (builtin.os.tag == .linux) {
                // Read from /proc/net/tcp and /proc/net/tcp6
                try IO.print("  (use 'ss -tuln' or 'netstat -tuln' for connection details)\n", .{});
            } else if (builtin.os.tag == .macos) {
                try IO.print("  (use 'lsof -i' or 'netstat -an' for connection details)\n", .{});
            } else {
                try IO.print("  (connection info not available on this platform)\n", .{});
            }
        }

        return 0;
    }

    fn builtinNetCheck(self: *Executor, command: *types.ParsedCommand) !i32 {
        // Check for help
        for (command.args) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                try IO.print("net-check - check network connectivity\n", .{});
                try IO.print("Usage: net-check [options] [host]\n", .{});
                try IO.print("Options:\n", .{});
                try IO.print("  -q, --quiet   Only return exit code (0=ok, 1=fail)\n", .{});
                try IO.print("  -p, --port    Check specific port (e.g., -p 443)\n", .{});
                try IO.print("\nExamples:\n", .{});
                try IO.print("  net-check                  # Check default (google.com)\n", .{});
                try IO.print("  net-check example.com      # Check specific host\n", .{});
                try IO.print("  net-check -p 443 example.com  # Check port 443\n", .{});
                return 0;
            }
        }

        var quiet = false;
        var port: ?[]const u8 = null;
        var host: []const u8 = "google.com";
        var i: usize = 0;

        while (i < command.args.len) : (i += 1) {
            const arg = command.args[i];
            if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
                quiet = true;
            } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--port")) {
                if (i + 1 < command.args.len) {
                    i += 1;
                    port = command.args[i];
                }
            } else if (arg.len > 0 and arg[0] != '-') {
                host = arg;
            }
        }

        if (!quiet) {
            try IO.print("\x1b[1;36m=== Network Connectivity Check ===\x1b[0m\n\n", .{});
        }

        // Use curl or nc to check connectivity (cross-platform via external command)
        if (port) |p| {
            if (!quiet) {
                try IO.print("\x1b[1;33mPort Check:\x1b[0m {s}:{s}\n", .{ host, p });
            }

            // Use nc (netcat) for port check
            const host_z = try self.allocator.dupeZ(u8, host);
            defer self.allocator.free(host_z);
            const port_z = try self.allocator.dupeZ(u8, p);
            defer self.allocator.free(port_z);

            const argv = [_]?[*:0]const u8{
                "nc",
                "-z",
                "-w",
                "3",
                host_z,
                port_z,
                null,
            };

            const pid = std.posix.fork() catch {
                if (!quiet) {
                    try IO.print("  \x1b[1;31m✗\x1b[0m Failed to fork process\n", .{});
                }
                return 1;
            };

            if (pid == 0) {
                // Child: redirect stderr to /dev/null
                const dev_null = std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only }) catch std.posix.exit(127);
                std.posix.dup2(dev_null.handle, std.posix.STDERR_FILENO) catch {};
                std.posix.dup2(dev_null.handle, std.posix.STDOUT_FILENO) catch {};

                _ = std.posix.execvpeZ("nc", @ptrCast(&argv), getCEnviron()) catch {
                    std.posix.exit(127);
                };
                unreachable;
            } else {
                const result = std.posix.waitpid(pid, 0);
                const code: i32 = @intCast(std.posix.W.EXITSTATUS(result.status));

                if (code == 0) {
                    if (!quiet) {
                        try IO.print("  \x1b[1;32m✓\x1b[0m Port {s} is open\n", .{p});
                    }
                } else {
                    if (!quiet) {
                        try IO.print("  \x1b[1;31m✗\x1b[0m Port {s} is closed or unreachable\n", .{p});
                    }
                    return 1;
                }
            }
        } else {
            // Default: ping check
            if (!quiet) {
                try IO.print("\x1b[1;33mConnectivity Check:\x1b[0m {s}\n", .{host});
            }

            const host_z = try self.allocator.dupeZ(u8, host);
            defer self.allocator.free(host_z);

            // Use ping with count 1 and timeout 3 seconds
            const argv = if (builtin.os.tag == .macos)
                [_]?[*:0]const u8{ "ping", "-c", "1", "-t", "3", host_z, null }
            else
                [_]?[*:0]const u8{ "ping", "-c", "1", "-W", "3", host_z, null };

            const pid = std.posix.fork() catch {
                if (!quiet) {
                    try IO.print("  \x1b[1;31m✗\x1b[0m Failed to fork process\n", .{});
                }
                return 1;
            };

            if (pid == 0) {
                // Child: redirect output to /dev/null
                const dev_null = std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only }) catch std.posix.exit(127);
                std.posix.dup2(dev_null.handle, std.posix.STDERR_FILENO) catch {};
                std.posix.dup2(dev_null.handle, std.posix.STDOUT_FILENO) catch {};

                _ = std.posix.execvpeZ("ping", @ptrCast(&argv), getCEnviron()) catch {
                    std.posix.exit(127);
                };
                unreachable;
            } else {
                const result = std.posix.waitpid(pid, 0);
                const code: i32 = @intCast(std.posix.W.EXITSTATUS(result.status));

                if (code == 0) {
                    if (!quiet) {
                        try IO.print("  \x1b[1;32m✓\x1b[0m Host is reachable\n", .{});
                    }
                } else {
                    if (!quiet) {
                        try IO.print("  \x1b[1;31m✗\x1b[0m Host is unreachable\n", .{});
                    }
                    return 1;
                }
            }
        }

        if (!quiet) {
            try IO.print("\n\x1b[1;32mNetwork is reachable\x1b[0m\n", .{});
        }

        return 0;
    }

    /// log-tail builtin - tail log files with filtering and highlighting
    fn builtinLogTail(self: *Executor, command: *types.ParsedCommand) !i32 {
        // Parse options
        var num_lines: usize = 10;
        var follow = false;
        var filter: ?[]const u8 = null;
        var highlight: ?[]const u8 = null;
        var file_path: ?[]const u8 = null;
        var show_help = false;

        var i: usize = 0;
        while (i < command.args.len) : (i += 1) {
            const arg = command.args[i];
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                show_help = true;
            } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--lines")) {
                if (i + 1 < command.args.len) {
                    i += 1;
                    num_lines = std.fmt.parseInt(usize, command.args[i], 10) catch 10;
                }
            } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--follow")) {
                follow = true;
            } else if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--grep")) {
                if (i + 1 < command.args.len) {
                    i += 1;
                    filter = command.args[i];
                }
            } else if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--highlight")) {
                if (i + 1 < command.args.len) {
                    i += 1;
                    highlight = command.args[i];
                }
            } else if (arg.len > 0 and arg[0] != '-') {
                file_path = arg;
            }
        }

        if (show_help or file_path == null) {
            try IO.print("log-tail - tail log files with filtering and highlighting\n", .{});
            try IO.print("Usage: log-tail [options] FILE\n", .{});
            try IO.print("Options:\n", .{});
            try IO.print("  -n, --lines N      Show last N lines (default: 10)\n", .{});
            try IO.print("  -f, --follow       Follow file (like tail -f)\n", .{});
            try IO.print("  -g, --grep PATTERN Filter lines by pattern\n", .{});
            try IO.print("  -H, --highlight PATTERN  Highlight pattern in output\n", .{});
            try IO.print("\nExamples:\n", .{});
            try IO.print("  log-tail /var/log/system.log\n", .{});
            try IO.print("  log-tail -n 50 app.log\n", .{});
            try IO.print("  log-tail -f -g ERROR server.log\n", .{});
            try IO.print("  log-tail -H \"WARN|ERROR\" app.log\n", .{});
            return if (show_help) 0 else 1;
        }

        const path = file_path.?;

        // Open file
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            try IO.eprint("log-tail: cannot open '{s}': {}\n", .{ path, err });
            return 1;
        };
        defer file.close();

        // Read file to get last N lines
        const stat = file.stat() catch |err| {
            try IO.eprint("log-tail: cannot stat '{s}': {}\n", .{ path, err });
            return 1;
        };

        // Read entire file (for simplicity with smaller log files)
        const max_size: usize = 10 * 1024 * 1024; // 10MB max
        const read_size = @min(stat.size, max_size);

        const content = self.allocator.alloc(u8, read_size) catch {
            try IO.eprint("log-tail: out of memory\n", .{});
            return 1;
        };
        defer self.allocator.free(content);

        // Read file contents
        var total_read: usize = 0;
        while (total_read < read_size) {
            const n = file.read(content[total_read..]) catch |err| {
                try IO.eprint("log-tail: read error: {}\n", .{err});
                return 1;
            };
            if (n == 0) break;
            total_read += n;
        }
        const bytes_read = total_read;

        // Split into lines
        var lines = std.ArrayList([]const u8).empty;
        defer lines.deinit(self.allocator);

        var line_iter = std.mem.splitScalar(u8, content[0..bytes_read], '\n');
        while (line_iter.next()) |line| {
            // Apply filter if specified
            if (filter) |f| {
                if (std.mem.indexOf(u8, line, f) == null) {
                    continue;
                }
            }
            lines.append(self.allocator, line) catch {};
        }

        // Get last N lines
        const start_idx = if (lines.items.len > num_lines) lines.items.len - num_lines else 0;

        // Print lines
        for (lines.items[start_idx..]) |line| {
            if (highlight) |h| {
                // Highlight matching patterns
                try logTailHighlightLine(line, h);
            } else {
                // Auto-highlight common log levels
                try logTailAutoHighlightLine(line);
            }
        }

        // Follow mode
        if (follow) {
            try IO.print("\n\x1b[2m--- Following {s} (Ctrl+C to stop) ---\x1b[0m\n", .{path});

            var last_pos = stat.size;

            // Simple follow loop (non-blocking would be better but this works)
            while (true) {
                std.posix.nanosleep(0, 500_000_000); // 500ms

                const new_stat = file.stat() catch continue;
                if (new_stat.size > last_pos) {
                    file.seekTo(last_pos) catch continue;

                    var buf: [4096]u8 = undefined;
                    while (true) {
                        const n = file.read(&buf) catch break;
                        if (n == 0) break;

                        // Print new content
                        var new_lines = std.mem.splitScalar(u8, buf[0..n], '\n');
                        while (new_lines.next()) |new_line| {
                            if (new_line.len == 0) continue;

                            // Apply filter
                            if (filter) |f| {
                                if (std.mem.indexOf(u8, new_line, f) == null) {
                                    continue;
                                }
                            }

                            if (highlight) |h| {
                                try logTailHighlightLine(new_line, h);
                            } else {
                                try logTailAutoHighlightLine(new_line);
                            }
                        }
                    }

                    last_pos = new_stat.size;
                }
            }
        }

        return 0;
    }

    /// proc-monitor builtin - monitor processes
    fn builtinProcMonitor(_: *Executor, command: *types.ParsedCommand) !i32 {
        // Parse options
        var pattern: ?[]const u8 = null;
        var pid_filter: ?i32 = null;
        var interval: u32 = 2; // seconds
        var count: ?u32 = null;
        var show_help = false;

        var i: usize = 0;
        while (i < command.args.len) : (i += 1) {
            const arg = command.args[i];
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                show_help = true;
            } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--pid")) {
                if (i + 1 < command.args.len) {
                    i += 1;
                    pid_filter = std.fmt.parseInt(i32, command.args[i], 10) catch null;
                }
            } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--interval")) {
                if (i + 1 < command.args.len) {
                    i += 1;
                    interval = std.fmt.parseInt(u32, command.args[i], 10) catch 2;
                }
            } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count")) {
                if (i + 1 < command.args.len) {
                    i += 1;
                    count = std.fmt.parseInt(u32, command.args[i], 10) catch null;
                }
            } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--sort")) {
                if (i + 1 < command.args.len) {
                    i += 1;
                    // Note: sort_by option recognized but not yet implemented
                }
            } else if (arg.len > 0 and arg[0] != '-') {
                pattern = arg;
            }
        }

        if (show_help) {
            try IO.print("proc-monitor - monitor processes\n", .{});
            try IO.print("Usage: proc-monitor [options] [PATTERN]\n", .{});
            try IO.print("Options:\n", .{});
            try IO.print("  -p, --pid PID       Monitor specific PID\n", .{});
            try IO.print("  -n, --interval N    Update interval in seconds (default: 2)\n", .{});
            try IO.print("  -c, --count N       Number of iterations (default: continuous)\n", .{});
            try IO.print("  -s, --sort FIELD    Sort by: cpu, mem, pid, name (default: cpu)\n", .{});
            try IO.print("\nExamples:\n", .{});
            try IO.print("  proc-monitor              # Show top processes by CPU\n", .{});
            try IO.print("  proc-monitor -p 1234      # Monitor specific PID\n", .{});
            try IO.print("  proc-monitor node         # Monitor processes matching 'node'\n", .{});
            try IO.print("  proc-monitor -s mem -c 5  # Sort by memory, 5 iterations\n", .{});
            return 0;
        }

        var iterations: u32 = 0;
        const max_iterations = count orelse std.math.maxInt(u32);

        while (iterations < max_iterations) : (iterations += 1) {
            // Clear screen and move cursor to top (for continuous monitoring)
            if (iterations > 0) {
                try IO.print("\x1b[2J\x1b[H", .{}); // Clear screen
            }

            try IO.print("\x1b[1;36m=== Process Monitor ===\x1b[0m", .{});
            if (pattern) |p| {
                try IO.print(" (filter: {s})", .{p});
            }
            if (pid_filter) |pid| {
                try IO.print(" (pid: {})", .{pid});
            }
            try IO.print("\n\n", .{});

            // Use ps command to get process info
            // On macOS: ps -axo pid,pcpu,pmem,rss,comm
            const ps_args = if (builtin.os.tag == .macos)
                [_]?[*:0]const u8{ "ps", "-axo", "pid,pcpu,pmem,rss,comm", null }
            else
                [_]?[*:0]const u8{ "ps", "-eo", "pid,pcpu,pmem,rss,comm", null };

            // Create pipe for ps output
            const pipe_fds = std.posix.pipe() catch {
                try IO.eprint("proc-monitor: failed to create pipe\n", .{});
                return 1;
            };

            const pid = std.posix.fork() catch {
                try IO.eprint("proc-monitor: failed to fork\n", .{});
                return 1;
            };

            if (pid == 0) {
                // Child: redirect stdout to pipe
                std.posix.close(pipe_fds[0]);
                std.posix.dup2(pipe_fds[1], std.posix.STDOUT_FILENO) catch {};
                std.posix.close(pipe_fds[1]);

                // Redirect stderr to /dev/null
                const dev_null = std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only }) catch std.posix.exit(127);
                std.posix.dup2(dev_null.handle, std.posix.STDERR_FILENO) catch {};

                _ = std.posix.execvpeZ("ps", @ptrCast(&ps_args), getCEnviron()) catch {};
                std.posix.exit(127);
            } else {
                // Parent: read ps output
                std.posix.close(pipe_fds[1]);

                var buf: [8192]u8 = undefined;
                var total_read: usize = 0;

                while (total_read < buf.len) {
                    const n = std.posix.read(pipe_fds[0], buf[total_read..]) catch break;
                    if (n == 0) break;
                    total_read += n;
                }

                std.posix.close(pipe_fds[0]);
                _ = std.posix.waitpid(pid, 0);

                // Parse and display output
                var line_num: usize = 0;
                var proc_count: usize = 0;
                var lines = std.mem.splitScalar(u8, buf[0..total_read], '\n');

                // Print header
                try IO.print("\x1b[1m{s:>7}  {s:>6}  {s:>6}  {s:>10}  {s}\x1b[0m\n", .{
                    "PID", "%CPU", "%MEM", "RSS", "COMMAND",
                });
                try IO.print("{s:-<60}\n", .{""});

                while (lines.next()) |line| {
                    line_num += 1;
                    if (line_num == 1) continue; // Skip header

                    if (line.len == 0) continue;

                    // Parse line: PID %CPU %MEM RSS COMMAND
                    var fields = std.mem.tokenizeScalar(u8, line, ' ');

                    const pid_str = fields.next() orelse continue;
                    const cpu_str = fields.next() orelse continue;
                    const mem_str = fields.next() orelse continue;
                    const rss_str = fields.next() orelse continue;

                    // Rest is command name
                    var cmd_start: usize = 0;
                    var field_count: usize = 0;
                    for (line, 0..) |c, idx| {
                        if (c != ' ' and field_count < 4) {
                            while (idx + cmd_start < line.len and line[idx + cmd_start] != ' ') : (cmd_start += 1) {}
                            field_count += 1;
                            if (field_count == 4) {
                                cmd_start = idx;
                                break;
                            }
                        }
                    }
                    const cmd_name = std.mem.trim(u8, line[cmd_start..], " ");

                    // Apply filters
                    if (pid_filter) |filter_pid| {
                        const proc_pid = std.fmt.parseInt(i32, pid_str, 10) catch continue;
                        if (proc_pid != filter_pid) continue;
                    }

                    if (pattern) |p| {
                        if (std.mem.indexOf(u8, cmd_name, p) == null) continue;
                    }

                    // Format RSS (in KB)
                    const rss_kb = std.fmt.parseInt(u64, rss_str, 10) catch 0;
                    var rss_display: [16]u8 = undefined;
                    const rss_formatted = if (rss_kb >= 1024 * 1024)
                        std.fmt.bufPrint(&rss_display, "{d:.1}G", .{@as(f64, @floatFromInt(rss_kb)) / (1024.0 * 1024.0)}) catch "?"
                    else if (rss_kb >= 1024)
                        std.fmt.bufPrint(&rss_display, "{d:.1}M", .{@as(f64, @floatFromInt(rss_kb)) / 1024.0}) catch "?"
                    else
                        std.fmt.bufPrint(&rss_display, "{}K", .{rss_kb}) catch "?";

                    // Color based on CPU usage
                    const cpu_val = std.fmt.parseFloat(f64, cpu_str) catch 0.0;
                    const color = if (cpu_val >= 50.0) "\x1b[1;31m" // Red for high CPU
                    else if (cpu_val >= 20.0) "\x1b[1;33m" // Yellow for medium
                    else "\x1b[0m";

                    try IO.print("{s}{s:>7}  {s:>6}  {s:>6}  {s:>10}  {s}\x1b[0m\n", .{
                        color, pid_str, cpu_str, mem_str, rss_formatted, cmd_name,
                    });

                    proc_count += 1;
                    if (proc_count >= 20) break; // Limit to top 20
                }

                try IO.print("\n\x1b[2mShowing top {} processes", .{proc_count});
                if (count == null) {
                    try IO.print(" (updating every {}s, Ctrl+C to stop)", .{interval});
                }
                try IO.print("\x1b[0m\n", .{});
            }

            // Sleep before next iteration (unless this is the last one)
            if (iterations + 1 < max_iterations) {
                std.posix.nanosleep(interval, 0);
            }
        }

        return 0;
    }

    /// log-parse builtin - parse structured logs
    fn builtinLogParse(self: *Executor, command: *types.ParsedCommand) !i32 {
        // Parse options
        var format: enum { auto, json, kv, csv } = .auto;
        var fields: ?[]const u8 = null;
        var filter_field: ?[]const u8 = null;
        var filter_value: ?[]const u8 = null;
        var file_path: ?[]const u8 = null;
        var show_help = false;
        var pretty = false;
        var count_only = false;

        var i: usize = 0;
        while (i < command.args.len) : (i += 1) {
            const arg = command.args[i];
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                show_help = true;
            } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--format")) {
                if (i + 1 < command.args.len) {
                    i += 1;
                    const fmt = command.args[i];
                    if (std.mem.eql(u8, fmt, "json")) format = .json
                    else if (std.mem.eql(u8, fmt, "kv")) format = .kv
                    else if (std.mem.eql(u8, fmt, "csv")) format = .csv
                    else format = .auto;
                }
            } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--select")) {
                if (i + 1 < command.args.len) {
                    i += 1;
                    fields = command.args[i];
                }
            } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--where")) {
                if (i + 1 < command.args.len) {
                    i += 1;
                    const where_clause = command.args[i];
                    // Parse field=value
                    if (std.mem.indexOf(u8, where_clause, "=")) |eq_idx| {
                        filter_field = where_clause[0..eq_idx];
                        filter_value = where_clause[eq_idx + 1 ..];
                    }
                }
            } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--pretty")) {
                pretty = true;
            } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count")) {
                count_only = true;
            } else if (arg.len > 0 and arg[0] != '-') {
                file_path = arg;
            }
        }

        if (show_help) {
            try IO.print("log-parse - parse structured log files\n", .{});
            try IO.print("Usage: log-parse [options] FILE\n", .{});
            try IO.print("       cat FILE | log-parse [options]\n", .{});
            try IO.print("\nFormats:\n", .{});
            try IO.print("  -f, --format FORMAT  Log format: json, kv, csv, auto (default)\n", .{});
            try IO.print("\nFiltering:\n", .{});
            try IO.print("  -s, --select FIELDS  Select specific fields (comma-separated)\n", .{});
            try IO.print("  -w, --where EXPR     Filter by field=value\n", .{});
            try IO.print("  -c, --count          Only show count of matching lines\n", .{});
            try IO.print("\nOutput:\n", .{});
            try IO.print("  -p, --pretty         Pretty print output\n", .{});
            try IO.print("\nExamples:\n", .{});
            try IO.print("  log-parse app.log                    # Auto-detect format\n", .{});
            try IO.print("  log-parse -f json server.log         # Parse JSON logs\n", .{});
            try IO.print("  log-parse -s level,message app.log   # Select fields\n", .{});
            try IO.print("  log-parse -w level=ERROR app.log     # Filter by level\n", .{});
            try IO.print("  log-parse -c -w level=ERROR app.log  # Count errors\n", .{});
            try IO.print("\nSupported formats:\n", .{});
            try IO.print("  json: ", .{});
            try IO.print("{s}\n", .{"{\"level\":\"INFO\",\"msg\":\"...\"}"});
            try IO.print("  kv:   level=INFO msg=\"message here\"\n", .{});
            try IO.print("  csv:  level,timestamp,message (first line is header)\n", .{});
            return 0;
        }

        // Read input
        var content_buf: [1024 * 1024]u8 = undefined; // 1MB buffer
        var content_len: usize = 0;

        if (file_path) |path| {
            const file = std.fs.cwd().openFile(path, .{}) catch |err| {
                try IO.eprint("log-parse: cannot open '{s}': {}\n", .{ path, err });
                return 1;
            };
            defer file.close();

            while (content_len < content_buf.len) {
                const n = file.read(content_buf[content_len..]) catch break;
                if (n == 0) break;
                content_len += n;
            }
        } else {
            try IO.eprint("log-parse: no file specified\n", .{});
            return 1;
        }

        const content = content_buf[0..content_len];

        // Process lines
        var line_count: usize = 0;
        var match_count: usize = 0;
        var csv_headers: ?[]const u8 = null;

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            line_count += 1;

            // Auto-detect format on first line
            var line_format = format;
            if (format == .auto) {
                if (line.len > 0 and line[0] == '{') {
                    line_format = .json;
                } else if (std.mem.indexOf(u8, line, "=") != null) {
                    line_format = .kv;
                } else if (std.mem.indexOf(u8, line, ",") != null) {
                    line_format = .csv;
                } else {
                    line_format = .kv; // Default fallback
                }
            }

            // Parse line based on format
            var field_map: [32]struct { key: []const u8, value: []const u8 } = undefined;
            var field_count: usize = 0;

            switch (line_format) {
                .json => {
                    // Simple JSON parsing (key-value pairs only)
                    var in_key = false;
                    var in_value = false;
                    var in_string = false;
                    var key_start: usize = 0;
                    var key_end: usize = 0;
                    var value_start: usize = 0;

                    for (line, 0..) |c, idx| {
                        if (c == '"' and (idx == 0 or line[idx - 1] != '\\')) {
                            if (!in_string) {
                                in_string = true;
                                if (!in_key and !in_value) {
                                    in_key = true;
                                    key_start = idx + 1;
                                } else if (in_value) {
                                    value_start = idx + 1;
                                }
                            } else {
                                in_string = false;
                                if (in_key) {
                                    key_end = idx;
                                } else if (in_value and field_count < field_map.len) {
                                    field_map[field_count] = .{
                                        .key = line[key_start..key_end],
                                        .value = line[value_start..idx],
                                    };
                                    field_count += 1;
                                    in_value = false;
                                }
                            }
                        } else if (c == ':' and !in_string and in_key) {
                            in_key = false;
                            in_value = true;
                        } else if ((c == ',' or c == '}') and !in_string and in_value) {
                            // Handle non-string values
                            if (value_start == 0) {
                                // Find value start (skip whitespace after :)
                                var vs: usize = key_end + 1;
                                while (vs < idx and (line[vs] == ':' or line[vs] == ' ')) : (vs += 1) {}
                                if (field_count < field_map.len) {
                                    field_map[field_count] = .{
                                        .key = line[key_start..key_end],
                                        .value = std.mem.trim(u8, line[vs..idx], " \t"),
                                    };
                                    field_count += 1;
                                }
                            }
                            in_value = false;
                            value_start = 0;
                        }
                    }
                },
                .kv => {
                    // Parse key=value format
                    var tokens = std.mem.tokenizeScalar(u8, line, ' ');
                    while (tokens.next()) |token| {
                        if (std.mem.indexOf(u8, token, "=")) |eq_idx| {
                            if (field_count < field_map.len) {
                                var value = token[eq_idx + 1 ..];
                                // Strip quotes if present
                                if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                                    value = value[1 .. value.len - 1];
                                }
                                field_map[field_count] = .{
                                    .key = token[0..eq_idx],
                                    .value = value,
                                };
                                field_count += 1;
                            }
                        }
                    }
                },
                .csv => {
                    // Parse CSV format
                    if (line_count == 1) {
                        csv_headers = line;
                        continue; // Skip header line for output
                    }

                    if (csv_headers) |headers| {
                        var header_iter = std.mem.splitScalar(u8, headers, ',');
                        var value_iter = std.mem.splitScalar(u8, line, ',');

                        while (header_iter.next()) |header| {
                            if (value_iter.next()) |value| {
                                if (field_count < field_map.len) {
                                    field_map[field_count] = .{
                                        .key = std.mem.trim(u8, header, " \t\""),
                                        .value = std.mem.trim(u8, value, " \t\""),
                                    };
                                    field_count += 1;
                                }
                            }
                        }
                    }
                },
                .auto => unreachable,
            }

            // Apply filter
            if (filter_field) |ff| {
                var matches = false;
                for (field_map[0..field_count]) |field| {
                    if (std.mem.eql(u8, field.key, ff)) {
                        if (filter_value) |fv| {
                            if (std.mem.indexOf(u8, field.value, fv) != null) {
                                matches = true;
                            }
                        } else {
                            matches = true;
                        }
                        break;
                    }
                }
                if (!matches) continue;
            }

            match_count += 1;

            if (count_only) continue;

            // Output
            if (fields) |selected| {
                // Select specific fields
                var field_list = std.mem.splitScalar(u8, selected, ',');
                var first = true;
                while (field_list.next()) |wanted| {
                    for (field_map[0..field_count]) |field| {
                        if (std.mem.eql(u8, field.key, wanted)) {
                            if (!first) try IO.print(" ", .{});
                            if (pretty) {
                                try IO.print("\x1b[1;36m{s}\x1b[0m=\x1b[33m{s}\x1b[0m", .{ field.key, field.value });
                            } else {
                                try IO.print("{s}", .{field.value});
                            }
                            first = false;
                            break;
                        }
                    }
                }
                try IO.print("\n", .{});
            } else {
                // Output all fields
                if (pretty) {
                    for (field_map[0..field_count], 0..) |field, idx| {
                        if (idx > 0) try IO.print(" ", .{});
                        // Color code common fields
                        const color = if (std.mem.eql(u8, field.key, "level") or std.mem.eql(u8, field.key, "severity"))
                            getLevelColor(field.value)
                        else
                            "\x1b[0m";
                        try IO.print("\x1b[1;36m{s}\x1b[0m={s}{s}\x1b[0m", .{ field.key, color, field.value });
                    }
                    try IO.print("\n", .{});
                } else {
                    for (field_map[0..field_count], 0..) |field, idx| {
                        if (idx > 0) try IO.print("\t", .{});
                        try IO.print("{s}={s}", .{ field.key, field.value });
                    }
                    try IO.print("\n", .{});
                }
            }
        }

        if (count_only) {
            try IO.print("{}\n", .{match_count});
        }

        _ = self;
        return 0;
    }

    /// dotfiles builtin - manage dotfiles
    fn builtinDotfiles(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;

        if (command.args.len == 0) {
            try IO.print("dotfiles - manage your dotfiles\n", .{});
            try IO.print("Usage: dotfiles <command> [args]\n", .{});
            try IO.print("\nCommands:\n", .{});
            try IO.print("  list              List tracked dotfiles\n", .{});
            try IO.print("  status            Show status of dotfiles\n", .{});
            try IO.print("  link <file>       Create symlink for dotfile\n", .{});
            try IO.print("  unlink <file>     Remove symlink\n", .{});
            try IO.print("  backup <file>     Backup a dotfile\n", .{});
            try IO.print("  restore <file>    Restore from backup\n", .{});
            try IO.print("  edit <file>       Edit a dotfile\n", .{});
            try IO.print("  diff <file>       Show diff with backup\n", .{});
            try IO.print("\nCommon dotfiles:\n", .{});
            try IO.print("  .bashrc, .zshrc, .vimrc, .gitconfig, .tmux.conf\n", .{});
            try IO.print("  .config/*, .ssh/config\n", .{});
            return 0;
        }

        const subcmd = command.args[0];

        if (std.mem.eql(u8, subcmd, "list")) {
            return try dotfilesList();
        } else if (std.mem.eql(u8, subcmd, "status")) {
            return try dotfilesStatus();
        } else if (std.mem.eql(u8, subcmd, "link")) {
            if (command.args.len < 2) {
                try IO.eprint("dotfiles link: missing file argument\n", .{});
                return 1;
            }
            return try dotfilesLink(command.args[1]);
        } else if (std.mem.eql(u8, subcmd, "unlink")) {
            if (command.args.len < 2) {
                try IO.eprint("dotfiles unlink: missing file argument\n", .{});
                return 1;
            }
            return try dotfilesUnlink(command.args[1]);
        } else if (std.mem.eql(u8, subcmd, "backup")) {
            if (command.args.len < 2) {
                try IO.eprint("dotfiles backup: missing file argument\n", .{});
                return 1;
            }
            return try dotfilesBackup(command.args[1]);
        } else if (std.mem.eql(u8, subcmd, "restore")) {
            if (command.args.len < 2) {
                try IO.eprint("dotfiles restore: missing file argument\n", .{});
                return 1;
            }
            return try dotfilesRestore(command.args[1]);
        } else if (std.mem.eql(u8, subcmd, "edit")) {
            if (command.args.len < 2) {
                try IO.eprint("dotfiles edit: missing file argument\n", .{});
                return 1;
            }
            return try dotfilesEdit(command.args[1]);
        } else if (std.mem.eql(u8, subcmd, "diff")) {
            if (command.args.len < 2) {
                try IO.eprint("dotfiles diff: missing file argument\n", .{});
                return 1;
            }
            return try dotfilesDiff(command.args[1]);
        } else {
            try IO.eprint("dotfiles: unknown command '{s}'\n", .{subcmd});
            return 1;
        }
    }

    /// library builtin - manage shell function libraries
    fn builtinLibrary(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;

        if (command.args.len == 0) {
            try IO.print("library - manage shell function libraries\n", .{});
            try IO.print("Usage: library <command> [args]\n", .{});
            try IO.print("\nCommands:\n", .{});
            try IO.print("  list                  List available libraries\n", .{});
            try IO.print("  info <name>           Show library information\n", .{});
            try IO.print("  load <name|path>      Load a library\n", .{});
            try IO.print("  unload <name>         Unload a library\n", .{});
            try IO.print("  create <name>         Create a new library template\n", .{});
            try IO.print("  path                  Show library search paths\n", .{});
            try IO.print("\nLibrary locations:\n", .{});
            try IO.print("  ~/.config/den/lib/    User libraries\n", .{});
            try IO.print("  /usr/local/share/den/lib/  System libraries\n", .{});
            try IO.print("\nExamples:\n", .{});
            try IO.print("  library list\n", .{});
            try IO.print("  library load git-helpers\n", .{});
            try IO.print("  library create my-utils\n", .{});
            return 0;
        }

        const subcmd = command.args[0];

        if (std.mem.eql(u8, subcmd, "list")) {
            return try libraryList();
        } else if (std.mem.eql(u8, subcmd, "path")) {
            return try libraryPath();
        } else if (std.mem.eql(u8, subcmd, "info")) {
            if (command.args.len < 2) {
                try IO.eprint("library info: missing library name\n", .{});
                return 1;
            }
            return try libraryInfo(command.args[1]);
        } else if (std.mem.eql(u8, subcmd, "load")) {
            if (command.args.len < 2) {
                try IO.eprint("library load: missing library name\n", .{});
                return 1;
            }
            return try libraryLoad(command.args[1]);
        } else if (std.mem.eql(u8, subcmd, "unload")) {
            if (command.args.len < 2) {
                try IO.eprint("library unload: missing library name\n", .{});
                return 1;
            }
            try IO.print("library unload: not yet implemented\n", .{});
            return 1;
        } else if (std.mem.eql(u8, subcmd, "create")) {
            if (command.args.len < 2) {
                try IO.eprint("library create: missing library name\n", .{});
                return 1;
            }
            return try libraryCreate(command.args[1]);
        } else {
            try IO.eprint("library: unknown command '{s}'\n", .{subcmd});
            return 1;
        }
    }
};

/// List available libraries
fn libraryList() !i32 {
    const home = std.posix.getenv("HOME") orelse {
        try IO.eprint("library: HOME not set\n", .{});
        return 1;
    };

    try IO.print("\x1b[1;36m=== Shell Libraries ===\x1b[0m\n\n", .{});

    // Check user library directory
    var user_lib_buf: [std.fs.max_path_bytes]u8 = undefined;
    const user_lib_path = std.fmt.bufPrint(&user_lib_buf, "{s}/.config/den/lib", .{home}) catch return 1;

    try IO.print("\x1b[1;33mUser libraries:\x1b[0m {s}\n", .{user_lib_path});

    if (std.fs.cwd().openDir(user_lib_path, .{ .iterate = true })) |dir_val| {
        var dir = dir_val;
        defer dir.close();
        var iter = dir.iterate();
        var count: usize = 0;
        while (iter.next() catch null) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".den") or
                std.mem.endsWith(u8, entry.name, ".sh"))
            {
                try IO.print("  \x1b[1;32m•\x1b[0m {s}\n", .{entry.name});
                count += 1;
            }
        }
        if (count == 0) {
            try IO.print("  \x1b[2m(none)\x1b[0m\n", .{});
        }
    } else |_| {
        try IO.print("  \x1b[2m(directory not found)\x1b[0m\n", .{});
    }

    // Check system library directory
    try IO.print("\n\x1b[1;33mSystem libraries:\x1b[0m /usr/local/share/den/lib\n", .{});

    if (std.fs.cwd().openDir("/usr/local/share/den/lib", .{ .iterate = true })) |dir_val| {
        var dir = dir_val;
        defer dir.close();
        var iter = dir.iterate();
        var count: usize = 0;
        while (iter.next() catch null) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".den") or
                std.mem.endsWith(u8, entry.name, ".sh"))
            {
                try IO.print("  \x1b[1;32m•\x1b[0m {s}\n", .{entry.name});
                count += 1;
            }
        }
        if (count == 0) {
            try IO.print("  \x1b[2m(none)\x1b[0m\n", .{});
        }
    } else |_| {
        try IO.print("  \x1b[2m(directory not found)\x1b[0m\n", .{});
    }

    return 0;
}

/// Show library search paths
fn libraryPath() !i32 {
    const home = std.posix.getenv("HOME") orelse "";

    try IO.print("\x1b[1;36m=== Library Search Paths ===\x1b[0m\n\n", .{});

    var user_lib_buf: [std.fs.max_path_bytes]u8 = undefined;
    const user_lib_path = std.fmt.bufPrint(&user_lib_buf, "{s}/.config/den/lib", .{home}) catch "(error)";

    const paths = [_][]const u8{
        user_lib_path,
        "/usr/local/share/den/lib",
        "/usr/share/den/lib",
    };

    for (paths, 1..) |path, i| {
        const exists = std.fs.cwd().statFile(path) catch null;
        const status = if (exists != null) "\x1b[1;32m✓\x1b[0m" else "\x1b[2m✗\x1b[0m";
        try IO.print("{s} {}. {s}\n", .{ status, i, path });
    }

    return 0;
}

/// Show library info
fn libraryInfo(name: []const u8) !i32 {
    const home = std.posix.getenv("HOME") orelse {
        try IO.eprint("library: HOME not set\n", .{});
        return 1;
    };

    // Try to find the library
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    // Try user lib directory
    const user_path = std.fmt.bufPrint(&path_buf, "{s}/.config/den/lib/{s}.den", .{ home, name }) catch return 1;

    var lib_path: []const u8 = user_path;
    var file = std.fs.cwd().openFile(user_path, .{}) catch blk: {
        // Try with .sh extension
        const user_sh_path = std.fmt.bufPrint(&path_buf, "{s}/.config/den/lib/{s}.sh", .{ home, name }) catch return 1;
        lib_path = user_sh_path;
        break :blk std.fs.cwd().openFile(user_sh_path, .{}) catch {
            try IO.eprint("library: '{s}' not found\n", .{name});
            return 1;
        };
    };
    defer file.close();

    try IO.print("\x1b[1;36m=== Library: {s} ===\x1b[0m\n\n", .{name});
    try IO.print("\x1b[1;33mPath:\x1b[0m {s}\n", .{lib_path});

    const stat = file.stat() catch return 1;
    try IO.print("\x1b[1;33mSize:\x1b[0m {} bytes\n", .{stat.size});

    // Read and show header comments
    var buf: [4096]u8 = undefined;
    const n = file.read(&buf) catch 0;

    if (n > 0) {
        try IO.print("\n\x1b[1;33mDescription:\x1b[0m\n", .{});

        var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
        var found_desc = false;
        while (lines.next()) |line| {
            if (line.len > 0 and line[0] == '#') {
                if (line.len > 2) {
                    try IO.print("  {s}\n", .{line[2..]});
                    found_desc = true;
                }
            } else if (found_desc) {
                break;
            }
        }

        if (!found_desc) {
            try IO.print("  \x1b[2m(no description)\x1b[0m\n", .{});
        }

        // Count functions
        try IO.print("\n\x1b[1;33mFunctions:\x1b[0m\n", .{});
        var func_count: usize = 0;
        var content_lines = std.mem.splitScalar(u8, buf[0..n], '\n');
        while (content_lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "function ") or
                (std.mem.indexOf(u8, line, "()") != null and !std.mem.startsWith(u8, line, "#")))
            {
                // Extract function name
                var func_name: []const u8 = "";
                if (std.mem.startsWith(u8, line, "function ")) {
                    const rest = line[9..];
                    if (std.mem.indexOf(u8, rest, " ")) |space_idx| {
                        func_name = rest[0..space_idx];
                    } else if (std.mem.indexOf(u8, rest, "(")) |paren_idx| {
                        func_name = rest[0..paren_idx];
                    }
                } else if (std.mem.indexOf(u8, line, "()")) |paren_idx| {
                    func_name = std.mem.trim(u8, line[0..paren_idx], " \t");
                }

                if (func_name.len > 0) {
                    try IO.print("  \x1b[1;32m•\x1b[0m {s}\n", .{func_name});
                    func_count += 1;
                }
            }
        }

        if (func_count == 0) {
            try IO.print("  \x1b[2m(no functions found)\x1b[0m\n", .{});
        }
    }

    return 0;
}

/// Load a library
fn libraryLoad(name: []const u8) !i32 {
    const home = std.posix.getenv("HOME") orelse {
        try IO.eprint("library: HOME not set\n", .{});
        return 1;
    };

    // Try to find the library
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    // If it's an absolute path, use directly
    if (name[0] == '/') {
        _ = std.fs.cwd().statFile(name) catch {
            try IO.eprint("library: '{s}' not found\n", .{name});
            return 1;
        };
        try IO.print("\x1b[1;32m✓\x1b[0m Loading {s}\n", .{name});
        try IO.print("  \x1b[2mRun: source {s}\x1b[0m\n", .{name});
        return 0;
    }

    // Try user lib directory
    const extensions = [_][]const u8{ ".den", ".sh", "" };
    for (extensions) |ext| {
        const path = std.fmt.bufPrint(&path_buf, "{s}/.config/den/lib/{s}{s}", .{ home, name, ext }) catch continue;

        if (std.fs.cwd().statFile(path)) |_| {
            try IO.print("\x1b[1;32m✓\x1b[0m Found library: {s}\n", .{path});
            try IO.print("  \x1b[2mRun: source {s}\x1b[0m\n", .{path});
            return 0;
        } else |_| {}
    }

    // Try system lib directory
    for (extensions) |ext| {
        const path = std.fmt.bufPrint(&path_buf, "/usr/local/share/den/lib/{s}{s}", .{ name, ext }) catch continue;

        if (std.fs.cwd().statFile(path)) |_| {
            try IO.print("\x1b[1;32m✓\x1b[0m Found library: {s}\n", .{path});
            try IO.print("  \x1b[2mRun: source {s}\x1b[0m\n", .{path});
            return 0;
        } else |_| {}
    }

    try IO.eprint("library: '{s}' not found\n", .{name});
    try IO.eprint("Try: library list\n", .{});
    return 1;
}

/// Create a new library template
fn libraryCreate(name: []const u8) !i32 {
    const home = std.posix.getenv("HOME") orelse {
        try IO.eprint("library: HOME not set\n", .{});
        return 1;
    };

    // Create lib directory if needed
    var lib_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lib_dir = std.fmt.bufPrint(&lib_dir_buf, "{s}/.config/den/lib", .{home}) catch return 1;

    std.fs.cwd().makePath(lib_dir) catch |err| {
        try IO.eprint("library: cannot create directory: {}\n", .{err});
        return 1;
    };

    // Create library file
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.den", .{ lib_dir, name }) catch return 1;

    // Check if file exists
    if (std.fs.cwd().statFile(path)) |_| {
        try IO.eprint("library: '{s}' already exists\n", .{path});
        return 1;
    } else |_| {}

    // Create template
    const template =
        \\# {s} - Den Shell Library
        \\# Description: Add your description here
        \\# Author: Your Name
        \\# Version: 1.0.0
        \\
        \\# Example function
        \\{s}_hello() {{
        \\    echo "Hello from {s} library!"
        \\}}
        \\
        \\# Add your functions below
        \\
    ;

    var content_buf: [2048]u8 = undefined;
    const content = std.fmt.bufPrint(&content_buf, template, .{ name, name, name }) catch return 1;

    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        try IO.eprint("library: cannot create file: {}\n", .{err});
        return 1;
    };
    defer file.close();

    _ = file.write(content) catch |err| {
        try IO.eprint("library: cannot write file: {}\n", .{err});
        return 1;
    };

    try IO.print("\x1b[1;32m✓\x1b[0m Created library: {s}\n", .{path});
    try IO.print("\nNext steps:\n", .{});
    try IO.print("  1. Edit: dotfiles edit {s}\n", .{path});
    try IO.print("  2. Load: source {s}\n", .{path});
    try IO.print("  3. Use:  {s}_hello\n", .{name});

    return 0;
}

/// List common dotfiles
fn dotfilesList() !i32 {
    const home = std.posix.getenv("HOME") orelse {
        try IO.eprint("dotfiles: HOME not set\n", .{});
        return 1;
    };

    try IO.print("\x1b[1;36m=== Dotfiles ===\x1b[0m\n\n", .{});

    const dotfiles = [_][]const u8{
        ".bashrc",
        ".bash_profile",
        ".zshrc",
        ".zprofile",
        ".vimrc",
        ".gitconfig",
        ".gitignore_global",
        ".tmux.conf",
        ".inputrc",
        ".profile",
        ".denrc",
    };

    for (dotfiles) |dotfile| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, dotfile }) catch continue;

        const stat = std.fs.cwd().statFile(path) catch {
            // File doesn't exist
            continue;
        };

        const kind_str = switch (stat.kind) {
            .sym_link => "\x1b[1;36m→\x1b[0m", // Symlink
            .file => "\x1b[1;32m•\x1b[0m", // Regular file
            else => " ",
        };

        const size_kb = stat.size / 1024;
        if (size_kb > 0) {
            try IO.print("{s} {s:<20} ({} KB)\n", .{ kind_str, dotfile, size_kb });
        } else {
            try IO.print("{s} {s:<20} ({} bytes)\n", .{ kind_str, dotfile, stat.size });
        }
    }

    // Check .config directory
    var config_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = std.fmt.bufPrint(&config_path_buf, "{s}/.config", .{home}) catch return 0;

    var dir = std.fs.cwd().openDir(config_path, .{ .iterate = true }) catch return 0;
    defer dir.close();

    try IO.print("\n\x1b[1;33m.config/\x1b[0m\n", .{});

    var iter = dir.iterate();
    var count: usize = 0;
    while (iter.next() catch null) |entry| {
        if (count >= 10) {
            try IO.print("  ... and more\n", .{});
            break;
        }
        const kind_str = switch (entry.kind) {
            .directory => "\x1b[1;34m📁\x1b[0m",
            .file => "\x1b[1;32m📄\x1b[0m",
            .sym_link => "\x1b[1;36m🔗\x1b[0m",
            else => "  ",
        };
        try IO.print("  {s} {s}\n", .{ kind_str, entry.name });
        count += 1;
    }

    return 0;
}

/// Show status of dotfiles
fn dotfilesStatus() !i32 {
    const home = std.posix.getenv("HOME") orelse {
        try IO.eprint("dotfiles: HOME not set\n", .{});
        return 1;
    };

    try IO.print("\x1b[1;36m=== Dotfiles Status ===\x1b[0m\n\n", .{});

    const dotfiles = [_][]const u8{
        ".bashrc",
        ".zshrc",
        ".vimrc",
        ".gitconfig",
        ".tmux.conf",
        ".denrc",
    };

    for (dotfiles) |dotfile| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, dotfile }) catch continue;

        var backup_buf: [std.fs.max_path_bytes]u8 = undefined;
        const backup_path = std.fmt.bufPrint(&backup_buf, "{s}/{s}.bak", .{ home, dotfile }) catch continue;

        const exists = std.fs.cwd().statFile(path) catch null;
        const backup_exists = std.fs.cwd().statFile(backup_path) catch null;

        if (exists != null) {
            const stat = exists.?;
            const is_symlink = stat.kind == .sym_link;

            if (is_symlink) {
                try IO.print("\x1b[1;36m[symlink]\x1b[0m {s}\n", .{dotfile});
            } else if (backup_exists != null) {
                try IO.print("\x1b[1;33m[modified]\x1b[0m {s} (backup exists)\n", .{dotfile});
            } else {
                try IO.print("\x1b[1;32m[ok]\x1b[0m      {s}\n", .{dotfile});
            }
        } else {
            try IO.print("\x1b[2m[missing]\x1b[0m {s}\n", .{dotfile});
        }
    }

    return 0;
}

/// Create symlink for dotfile
fn dotfilesLink(file: []const u8) !i32 {
    const home = std.posix.getenv("HOME") orelse {
        try IO.eprint("dotfiles: HOME not set\n", .{});
        return 1;
    };

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = std.fmt.bufPrint(&target_buf, "{s}/{s}", .{ home, file }) catch {
        try IO.eprint("dotfiles: path too long\n", .{});
        return 1;
    };

    // Check if source file exists
    _ = std.fs.cwd().statFile(file) catch {
        try IO.eprint("dotfiles link: source file '{s}' not found\n", .{file});
        return 1;
    };

    // Check if target already exists
    if (std.fs.cwd().statFile(target)) |_| {
        try IO.eprint("dotfiles link: '{s}' already exists\n", .{target});
        try IO.eprint("Use 'dotfiles backup {s}' first, then try again\n", .{file});
        return 1;
    } else |_| {}

    // Get absolute path to source
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch {
        try IO.eprint("dotfiles: cannot get current directory\n", .{});
        return 1;
    };

    var abs_source_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_source = std.fmt.bufPrint(&abs_source_buf, "{s}/{s}", .{ cwd, file }) catch {
        try IO.eprint("dotfiles: path too long\n", .{});
        return 1;
    };

    // Create symlink
    std.posix.symlink(abs_source, target) catch |err| {
        try IO.eprint("dotfiles link: failed to create symlink: {}\n", .{err});
        return 1;
    };

    try IO.print("\x1b[1;32m✓\x1b[0m Linked {s} → {s}\n", .{ target, abs_source });
    return 0;
}

/// Remove symlink
fn dotfilesUnlink(file: []const u8) !i32 {
    const home = std.posix.getenv("HOME") orelse {
        try IO.eprint("dotfiles: HOME not set\n", .{});
        return 1;
    };

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = std.fmt.bufPrint(&target_buf, "{s}/{s}", .{ home, file }) catch {
        try IO.eprint("dotfiles: path too long\n", .{});
        return 1;
    };

    const stat = std.fs.cwd().statFile(target) catch {
        try IO.eprint("dotfiles unlink: '{s}' not found\n", .{target});
        return 1;
    };

    if (stat.kind != .sym_link) {
        try IO.eprint("dotfiles unlink: '{s}' is not a symlink\n", .{target});
        return 1;
    }

    std.fs.cwd().deleteFile(target) catch |err| {
        try IO.eprint("dotfiles unlink: failed to remove: {}\n", .{err});
        return 1;
    };

    try IO.print("\x1b[1;32m✓\x1b[0m Unlinked {s}\n", .{target});
    return 0;
}

/// Backup a dotfile
fn dotfilesBackup(file: []const u8) !i32 {
    const home = std.posix.getenv("HOME") orelse {
        try IO.eprint("dotfiles: HOME not set\n", .{});
        return 1;
    };

    var source_buf: [std.fs.max_path_bytes]u8 = undefined;
    var backup_buf: [std.fs.max_path_bytes]u8 = undefined;

    const source = if (file[0] == '/')
        file
    else blk: {
        const s = std.fmt.bufPrint(&source_buf, "{s}/{s}", .{ home, file }) catch {
            try IO.eprint("dotfiles: path too long\n", .{});
            return 1;
        };
        break :blk s;
    };

    const backup = std.fmt.bufPrint(&backup_buf, "{s}.bak", .{source}) catch {
        try IO.eprint("dotfiles: path too long\n", .{});
        return 1;
    };

    // Check if source exists
    _ = std.fs.cwd().statFile(source) catch {
        try IO.eprint("dotfiles backup: '{s}' not found\n", .{source});
        return 1;
    };

    // Copy file
    std.fs.cwd().copyFile(source, std.fs.cwd(), backup, .{}) catch |err| {
        try IO.eprint("dotfiles backup: failed to copy: {}\n", .{err});
        return 1;
    };

    try IO.print("\x1b[1;32m✓\x1b[0m Backed up {s} → {s}\n", .{ source, backup });
    return 0;
}

/// Restore from backup
fn dotfilesRestore(file: []const u8) !i32 {
    const home = std.posix.getenv("HOME") orelse {
        try IO.eprint("dotfiles: HOME not set\n", .{});
        return 1;
    };

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    var backup_buf: [std.fs.max_path_bytes]u8 = undefined;

    const target = if (file[0] == '/')
        file
    else blk: {
        const t = std.fmt.bufPrint(&target_buf, "{s}/{s}", .{ home, file }) catch {
            try IO.eprint("dotfiles: path too long\n", .{});
            return 1;
        };
        break :blk t;
    };

    const backup = std.fmt.bufPrint(&backup_buf, "{s}.bak", .{target}) catch {
        try IO.eprint("dotfiles: path too long\n", .{});
        return 1;
    };

    // Check if backup exists
    _ = std.fs.cwd().statFile(backup) catch {
        try IO.eprint("dotfiles restore: backup '{s}' not found\n", .{backup});
        return 1;
    };

    // Copy backup to original
    std.fs.cwd().copyFile(backup, std.fs.cwd(), target, .{}) catch |err| {
        try IO.eprint("dotfiles restore: failed to copy: {}\n", .{err});
        return 1;
    };

    try IO.print("\x1b[1;32m✓\x1b[0m Restored {s} from {s}\n", .{ target, backup });
    return 0;
}

/// Edit a dotfile
fn dotfilesEdit(file: []const u8) !i32 {
    const home = std.posix.getenv("HOME") orelse {
        try IO.eprint("dotfiles: HOME not set\n", .{});
        return 1;
    };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = if (file[0] == '/' or file[0] == '.')
        file
    else blk: {
        const p = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, file }) catch {
            try IO.eprint("dotfiles: path too long\n", .{});
            return 1;
        };
        break :blk p;
    };

    // Get editor
    const editor = std.posix.getenv("EDITOR") orelse std.posix.getenv("VISUAL") orelse "vim";

    try IO.print("Opening {s} with {s}...\n", .{ path, editor });

    // Fork and exec editor
    const pid = std.posix.fork() catch {
        try IO.eprint("dotfiles edit: failed to fork\n", .{});
        return 1;
    };

    if (pid == 0) {
        // Child process
        var editor_buf: [256]u8 = undefined;
        const editor_z = std.fmt.bufPrintZ(&editor_buf, "{s}", .{editor}) catch std.posix.exit(127);

        var path_z_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path}) catch std.posix.exit(127);

        const argv = [_]?[*:0]const u8{ editor_z, path_z, null };
        _ = std.posix.execvpeZ(editor_z, @ptrCast(&argv), getCEnviron()) catch {};
        std.posix.exit(127);
    } else {
        // Parent process - wait for editor
        const result = std.posix.waitpid(pid, 0);
        return @intCast(std.posix.W.EXITSTATUS(result.status));
    }
}

/// Show diff with backup
fn dotfilesDiff(file: []const u8) !i32 {
    const home = std.posix.getenv("HOME") orelse {
        try IO.eprint("dotfiles: HOME not set\n", .{});
        return 1;
    };

    var current_buf: [std.fs.max_path_bytes]u8 = undefined;
    var backup_buf: [std.fs.max_path_bytes]u8 = undefined;

    const current = if (file[0] == '/')
        file
    else blk: {
        const c = std.fmt.bufPrint(&current_buf, "{s}/{s}", .{ home, file }) catch {
            try IO.eprint("dotfiles: path too long\n", .{});
            return 1;
        };
        break :blk c;
    };

    const backup = std.fmt.bufPrint(&backup_buf, "{s}.bak", .{current}) catch {
        try IO.eprint("dotfiles: path too long\n", .{});
        return 1;
    };

    // Check both files exist
    _ = std.fs.cwd().statFile(current) catch {
        try IO.eprint("dotfiles diff: '{s}' not found\n", .{current});
        return 1;
    };

    _ = std.fs.cwd().statFile(backup) catch {
        try IO.eprint("dotfiles diff: backup '{s}' not found\n", .{backup});
        return 1;
    };

    // Fork and exec diff
    const pid = std.posix.fork() catch {
        try IO.eprint("dotfiles diff: failed to fork\n", .{});
        return 1;
    };

    if (pid == 0) {
        // Child process
        var backup_z_buf: [std.fs.max_path_bytes]u8 = undefined;
        const backup_z = std.fmt.bufPrintZ(&backup_z_buf, "{s}", .{backup}) catch std.posix.exit(127);

        var current_z_buf: [std.fs.max_path_bytes]u8 = undefined;
        const current_z = std.fmt.bufPrintZ(&current_z_buf, "{s}", .{current}) catch std.posix.exit(127);

        const argv = [_]?[*:0]const u8{ "diff", "-u", "--color=auto", backup_z, current_z, null };
        _ = std.posix.execvpeZ("diff", @ptrCast(&argv), getCEnviron()) catch {};
        std.posix.exit(127);
    } else {
        // Parent process - wait for diff
        const result = std.posix.waitpid(pid, 0);
        const code = std.posix.W.EXITSTATUS(result.status);
        // diff returns 0 if same, 1 if different, 2 if error
        if (code == 0) {
            try IO.print("\x1b[1;32m✓\x1b[0m No differences\n", .{});
        }
        return @intCast(code);
    }
}

/// Get color code for log level
fn getLevelColor(level: []const u8) []const u8 {
    const upper = level;
    if (std.mem.indexOf(u8, upper, "ERROR") != null or
        std.mem.indexOf(u8, upper, "FATAL") != null or
        std.mem.indexOf(u8, upper, "error") != null or
        std.mem.indexOf(u8, upper, "fatal") != null)
    {
        return "\x1b[1;31m"; // Red
    } else if (std.mem.indexOf(u8, upper, "WARN") != null or
        std.mem.indexOf(u8, upper, "warn") != null)
    {
        return "\x1b[1;33m"; // Yellow
    } else if (std.mem.indexOf(u8, upper, "INFO") != null or
        std.mem.indexOf(u8, upper, "info") != null)
    {
        return "\x1b[1;32m"; // Green
    } else if (std.mem.indexOf(u8, upper, "DEBUG") != null or
        std.mem.indexOf(u8, upper, "debug") != null or
        std.mem.indexOf(u8, upper, "TRACE") != null or
        std.mem.indexOf(u8, upper, "trace") != null)
    {
        return "\x1b[2m"; // Dim
    }
    return "\x1b[0m";
}

/// Print a line with custom highlight pattern (for log-tail)
fn logTailHighlightLine(line: []const u8, pattern: []const u8) !void {
    var remaining = line;
    while (remaining.len > 0) {
        if (std.mem.indexOf(u8, remaining, pattern)) |idx| {
            // Print before match
            if (idx > 0) {
                try IO.print("{s}", .{remaining[0..idx]});
            }
            // Print match in red bold
            try IO.print("\x1b[1;31m{s}\x1b[0m", .{pattern});
            remaining = remaining[idx + pattern.len ..];
        } else {
            try IO.print("{s}\n", .{remaining});
            break;
        }
    }
}

/// Print a line with auto-highlighting for common log levels (for log-tail)
fn logTailAutoHighlightLine(line: []const u8) !void {
    // Check for common log levels and colorize
    if (std.mem.indexOf(u8, line, "ERROR") != null or
        std.mem.indexOf(u8, line, "FATAL") != null or
        std.mem.indexOf(u8, line, "CRITICAL") != null)
    {
        try IO.print("\x1b[1;31m{s}\x1b[0m\n", .{line}); // Red
    } else if (std.mem.indexOf(u8, line, "WARN") != null or
        std.mem.indexOf(u8, line, "WARNING") != null)
    {
        try IO.print("\x1b[1;33m{s}\x1b[0m\n", .{line}); // Yellow
    } else if (std.mem.indexOf(u8, line, "INFO") != null) {
        try IO.print("\x1b[1;32m{s}\x1b[0m\n", .{line}); // Green
    } else if (std.mem.indexOf(u8, line, "DEBUG") != null or
        std.mem.indexOf(u8, line, "TRACE") != null)
    {
        try IO.print("\x1b[2m{s}\x1b[0m\n", .{line}); // Dim
    } else {
        try IO.print("{s}\n", .{line});
    }
}

/// Simple glob pattern matching for [[ == ]] operator
fn globMatch(str: []const u8, pattern: []const u8) bool {
    var s_idx: usize = 0;
    var p_idx: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (s_idx < str.len) {
        if (p_idx < pattern.len and (pattern[p_idx] == '?' or pattern[p_idx] == str[s_idx])) {
            s_idx += 1;
            p_idx += 1;
        } else if (p_idx < pattern.len and pattern[p_idx] == '*') {
            star_idx = p_idx;
            match_idx = s_idx;
            p_idx += 1;
        } else if (star_idx) |si| {
            p_idx = si + 1;
            match_idx += 1;
            s_idx = match_idx;
        } else {
            return false;
        }
    }

    while (p_idx < pattern.len and pattern[p_idx] == '*') {
        p_idx += 1;
    }

    return p_idx == pattern.len;
}

/// Simple regex matching at a specific position
fn regexMatchAt(str: []const u8, s_start: usize, pattern: []const u8, p_start: usize, anchored_end: bool) bool {
    var s_idx = s_start;
    var p_idx = p_start;

    while (p_idx < pattern.len) {
        const pat_char = pattern[p_idx];

        // Check for quantifiers (look ahead)
        const has_quantifier = p_idx + 1 < pattern.len and
            (pattern[p_idx + 1] == '*' or pattern[p_idx + 1] == '+' or pattern[p_idx + 1] == '?');

        if (has_quantifier) {
            const quantifier = pattern[p_idx + 1];
            const min_matches: usize = if (quantifier == '+') 1 else 0;
            const max_matches: usize = if (quantifier == '?') 1 else std.math.maxInt(usize);

            // Count matches
            var matches: usize = 0;
            while (s_idx + matches < str.len and matches < max_matches) {
                if (matchChar(str[s_idx + matches], pat_char)) {
                    matches += 1;
                } else {
                    break;
                }
            }

            // Try different match counts (greedy backtracking)
            var try_matches = matches;
            while (try_matches >= min_matches) : (try_matches -= 1) {
                if (regexMatchAt(str, s_idx + try_matches, pattern, p_idx + 2, anchored_end)) {
                    return true;
                }
                if (try_matches == 0) break;
            }
            return false;
        }

        // Handle character class [...]
        if (pat_char == '[') {
            const class_end = findCharClassEnd(pattern, p_idx);
            if (class_end == null) return false;
            if (s_idx >= str.len) return false;
            if (!matchCharClass(str[s_idx], pattern[p_idx + 1 .. class_end.?])) {
                return false;
            }
            s_idx += 1;
            p_idx = class_end.? + 1;
            continue;
        }

        // Normal character match
        if (s_idx >= str.len) return false;
        if (!matchChar(str[s_idx], pat_char)) return false;
        s_idx += 1;
        p_idx += 1;
    }

    // Check end anchor
    if (anchored_end) {
        return s_idx == str.len;
    }
    return true;
}

fn matchChar(c: u8, pat: u8) bool {
    if (pat == '.') return true;
    return c == pat;
}

fn findCharClassEnd(pattern: []const u8, start: usize) ?usize {
    var i = start + 1;
    if (i < pattern.len and pattern[i] == '^') i += 1;
    if (i < pattern.len and pattern[i] == ']') i += 1; // ] as first char is literal

    while (i < pattern.len) {
        if (pattern[i] == ']') return i;
        i += 1;
    }
    return null;
}

fn matchCharClass(c: u8, class: []const u8) bool {
    var negate = false;
    var i: usize = 0;

    if (class.len > 0 and class[0] == '^') {
        negate = true;
        i = 1;
    }

    var matched = false;
    while (i < class.len) {
        // Check for range (e.g., a-z)
        if (i + 2 < class.len and class[i + 1] == '-') {
            if (c >= class[i] and c <= class[i + 2]) {
                matched = true;
            }
            i += 3;
        } else {
            if (c == class[i]) {
                matched = true;
            }
            i += 1;
        }
    }

    return if (negate) !matched else matched;
}
