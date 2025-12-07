const std = @import("std");
const types = @import("../types/mod.zig");
const IO = @import("../utils/io.zig").IO;
const Expansion = @import("../utils/expansion.zig").Expansion;
const builtin = @import("builtin");
const process = @import("../utils/process.zig");
const TypoCorrection = @import("../utils/typo_correction.zig").TypoCorrection;
const env_utils = @import("../utils/env.zig");
const networking = @import("networking.zig");
const memory_pool = @import("memory_pool.zig");
const redirection = @import("redirection.zig");
const builtins = @import("builtins/mod.zig");
const utilities = builtins.utilities;
const file_ops = builtins.file_ops;
const test_builtins = builtins.test_builtins;
const io_builtins = builtins.io_builtins;
const shell_builtins = builtins.shell_builtins;
const env_builtins = builtins.env_builtins;
const dir_builtins = builtins.dir_builtins;
const alias_builtins = builtins.alias_builtins;
const BuiltinContext = builtins.BuiltinContext;

// Forward declaration for Shell type
const Shell = @import("../shell.zig").Shell;

// Re-export networking functions for use in this module
const openDevNet = networking.openDevNet;
const parseDevNetPath = networking.parseDevNetPath;
const parseIPv4 = networking.parseIPv4;
const parseIPv6 = networking.parseIPv6;

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

// Networking code moved to networking.zig

pub const Executor = struct {
    allocator: std.mem.Allocator,
    environment: *std.StringHashMap([]const u8),
    shell: ?*Shell, // Optional reference to shell for options
    command_pool: memory_pool.CommandMemoryPool, // Memory pool for command execution

    /// Initialize an executor without a shell reference.
    /// Used for standalone command execution.
    pub fn init(allocator: std.mem.Allocator, environment: *std.StringHashMap([]const u8)) Executor {
        return .{
            .allocator = allocator,
            .environment = environment,
            .shell = null,
            .command_pool = memory_pool.CommandMemoryPool.init(allocator),
        };
    }

    /// Initialize an executor with a shell reference.
    /// Provides access to shell state like directory stack, aliases, and options.
    pub fn initWithShell(allocator: std.mem.Allocator, environment: *std.StringHashMap([]const u8), shell: *Shell) Executor {
        return .{
            .allocator = allocator,
            .environment = environment,
            .shell = shell,
            .command_pool = memory_pool.CommandMemoryPool.init(allocator),
        };
    }

    /// Cleanup resources
    pub fn deinit(self: *Executor) void {
        self.command_pool.deinit();
    }

    /// Get the memory pool allocator for temporary command allocations
    pub fn poolAllocator(self: *Executor) std.mem.Allocator {
        return self.command_pool.allocator();
    }

    /// Reset the memory pool after command execution
    pub fn resetPool(self: *Executor) void {
        self.command_pool.reset();
    }

    /// Execute a command chain, handling operators like && and ||.
    /// Returns the exit code of the last executed command.
    pub fn executeChain(self: *Executor, chain: *types.CommandChain) !i32 {
        // Reset the memory pool at the start of each command chain
        defer self.resetPool();

        if (chain.commands.len == 0) return 0;

        // Single command - execute directly
        if (chain.commands.len == 1) {
            const exit_code = try self.executeCommand(&chain.commands[0]);

            // Update shell's last_exit_code and execute ERR trap if command failed
            if (self.shell) |shell| {
                shell.last_exit_code = exit_code;
                if (exit_code != 0) {
                    shell.executeErrTrap();
                }
            }

            return exit_code;
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

                // Update shell's last_exit_code and execute ERR trap if command failed
                if (self.shell) |shell| {
                    shell.last_exit_code = last_exit_code;
                    if (last_exit_code != 0) {
                        shell.executeErrTrap();
                    }
                }

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

    /// Execute a pipeline of commands (e.g., "cmd1 | cmd2 | cmd3").
    /// Connects stdout of each command to stdin of the next.
    fn executePipeline(self: *Executor, commands: []types.ParsedCommand) !i32 {
        if (commands.len == 0) return 0;
        if (commands.len == 1) return try self.executeCommand(&commands[0]);

        if (builtin.os.tag == .windows) {
            return try self.executePipelineWindows(commands);
        }
        return try self.executePipelinePosix(commands);
    }

    /// Windows-specific pipeline implementation using std.process.Child.
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
                    .input_output => {
                        const file = try std.fs.cwd().openFile(redir.target, .{ .mode = .read_write });
                        // For <> the fd defaults to 0 (stdin) but can be specified
                        if (redir.fd == 0) {
                            children_buffer[i].stdin_behavior = .Ignore;
                            children_buffer[i].stdin = file;
                        } else if (redir.fd == 1) {
                            children_buffer[i].stdout_behavior = .Ignore;
                            children_buffer[i].stdout = file;
                        }
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
        // Build expansion context from shell if available (for heredocs/herestrings)
        const expansion_context: ?redirection.ExpansionContext = if (self.shell) |shell|
            .{
                .option_nounset = shell.option_nounset,
                .var_attributes = &shell.var_attributes,
                .arrays = &shell.arrays,
                .assoc_arrays = &shell.assoc_arrays,
            }
        else
            null;

        try redirection.applyRedirections(
            self.allocator,
            redirections,
            self.environment,
            expansion_context,
        );
    }

    /// Execute a single command, either as a builtin or external program.
    /// Handles shell options like xtrace (-x) and noexec (-n).
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

        // Check for suffix alias (zsh-style: typing "hello.ts" runs "bun hello.ts")
        if (self.shell) |shell| {
            if (self.trySuffixAlias(shell, command)) |new_command| {
                var suffix_cmd = new_command;
                return try self.executeExternal(&suffix_cmd);
            }
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

    /// Check for suffix alias and return a transformed command if applicable.
    /// Suffix aliases allow typing "hello.ts" to run "bun hello.ts" (zsh-style).
    fn trySuffixAlias(self: *Executor, shell: *Shell, command: *types.ParsedCommand) ?types.ParsedCommand {
        const cmd_name = command.name;

        // Get file extension (everything after the last dot)
        const dot_pos = std.mem.lastIndexOfScalar(u8, cmd_name, '.') orelse return null;
        if (dot_pos == cmd_name.len - 1) return null; // Ends with dot, no extension

        const extension = cmd_name[dot_pos + 1 ..];

        // Look up the extension in suffix aliases
        const alias_cmd = shell.suffix_aliases.get(extension) orelse return null;

        // Check if the file exists (either as absolute path, relative path, or in current directory)
        const file_exists = blk: {
            // Check if it's an absolute path or relative path that exists
            std.fs.cwd().access(cmd_name, .{}) catch {
                break :blk false;
            };
            break :blk true;
        };

        // Only apply suffix alias if the file exists
        if (!file_exists) return null;

        // Build new args: [original_filename] + original args
        // We need to create a new args array with the filename as first arg
        var new_args = self.allocator.alloc([]const u8, command.args.len + 1) catch return null;

        // First arg is the original command name (the filename)
        new_args[0] = self.allocator.dupe(u8, cmd_name) catch {
            self.allocator.free(new_args);
            return null;
        };

        // Copy remaining original args
        for (command.args, 0..) |arg, i| {
            new_args[i + 1] = self.allocator.dupe(u8, arg) catch {
                // Clean up on error
                for (new_args[0 .. i + 1]) |a| self.allocator.free(a);
                self.allocator.free(new_args);
                return null;
            };
        }

        // Create new command with suffix alias as the command name
        const new_cmd_name = self.allocator.dupe(u8, alias_cmd) catch {
            for (new_args) |a| self.allocator.free(a);
            self.allocator.free(new_args);
            return null;
        };

        return types.ParsedCommand{
            .name = new_cmd_name,
            .args = new_args,
            .redirections = command.redirections,
            .type = .external,
        };
    }

    /// Check if a command name is a shell builtin.
    fn isBuiltin(self: *Executor, name: []const u8) bool {
        const builtin_names = [_][]const u8{
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
            "show", "hide", "ft", "sys-stats", "netstats", "net-check", "log-tail", "proc-monitor", "log-parse", "dotfiles", "library", "hook",
            "ifind", "coproc",
        };
        for (builtin_names) |builtin_name| {
            if (std.mem.eql(u8, name, builtin_name)) return true;
        }
        // Check for loadable builtins
        if (self.shell) |shell| {
            if (shell.loadable_builtins.isEnabled(name)) return true;
        }
        return false;
    }

    /// Get a BuiltinContext for calling extracted builtins
    fn getBuiltinContext(self: *Executor) BuiltinContext {
        return BuiltinContext.initWithExecutor(
            self.allocator,
            self.environment,
            self.shell,
            isBuiltinStatic,
            executeCommandCallback,
            @ptrCast(self),
        );
    }

    /// Static wrapper for isBuiltin callback
    fn isBuiltinStatic(name: []const u8) bool {
        // Check against all known builtin names
        const builtin_names = [_][]const u8{
            "echo", "pwd", "cd", "env", "export", "set", "unset", "true", "false",
            "test", "[", "[[", "which", "type", "help", "alias", "unalias", "read",
            "printf", "source", ".", "history", "pushd", "popd", "dirs", "eval",
            "exec", "command", "builtin", "jobs", "fg", "bg", "wait", "disown",
            "kill", "trap", "times", "umask", "getopts", "clear", "time", "timeout",
            "hash", "yes", "reload", "watch", "tree", "grep", "find", "ft", "calc",
            "json", "ls", "seq", "date", "parallel", "http", "base64", "uuid",
            "localip", "ip", "shrug", "web", "return", "local", "copyssh", "reloaddns",
            "emptytrash", "wip", "bookmark", "code", "pstorm", "show", "hide",
            "sys-stats", "netstats", "net-check", "log-tail", "proc-monitor",
            "log-parse", "dotfiles", "library", "hook", "ifind", "coproc", "exit",
            ":", "declare", "typeset", "let", "shift", "break", "continue",
        };
        for (builtin_names) |b| {
            if (std.mem.eql(u8, name, b)) return true;
        }
        return false;
    }

    /// Callback wrapper for command execution
    fn executeCommandCallback(ctx_ptr: *anyopaque, name: []const u8, args: [][]const u8) anyerror!i32 {
        const self: *Executor = @ptrCast(@alignCast(ctx_ptr));
        var cmd = types.ParsedCommand{
            .name = name,
            .args = args,
            .redirections = &[_]types.Redirection{},
        };
        return self.executeCommand(&cmd);
    }

    /// Dispatch and execute a builtin command.
    fn executeBuiltin(self: *Executor, command: *types.ParsedCommand) !i32 {
        var ctx = self.getBuiltinContext();

        if (std.mem.eql(u8, command.name, "echo")) {
            return try io_builtins.echo(command);
        } else if (std.mem.eql(u8, command.name, "pwd")) {
            return try shell_builtins.pwd(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "cd")) {
            return try shell_builtins.cd(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "env")) {
            return try self.builtinEnvCmd(command);
        } else if (std.mem.eql(u8, command.name, "export")) {
            return try env_builtins.exportBuiltin(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "set")) {
            return try env_builtins.set(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "unset")) {
            return try env_builtins.unset(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "true")) {
            return 0;
        } else if (std.mem.eql(u8, command.name, "false")) {
            return 1;
        } else if (std.mem.eql(u8, command.name, "test") or std.mem.eql(u8, command.name, "[")) {
            return try test_builtins.testBuiltin(command);
        } else if (std.mem.eql(u8, command.name, "[[")) {
            return try test_builtins.extendedTest(command);
        } else if (std.mem.eql(u8, command.name, "which")) {
            return try builtins.command_builtins.which(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "type")) {
            return try builtins.command_builtins.typeBuiltin(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "help")) {
            return try utilities.help(command);
        } else if (std.mem.eql(u8, command.name, "alias")) {
            return try alias_builtins.alias(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "unalias")) {
            return try alias_builtins.unalias(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "read")) {
            return try shell_builtins.read(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "printf")) {
            return try io_builtins.printf(command);
        } else if (std.mem.eql(u8, command.name, "source") or std.mem.eql(u8, command.name, ".")) {
            return try shell_builtins.source(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "history")) {
            return try shell_builtins.history(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "pushd")) {
            return try dir_builtins.pushd(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "popd")) {
            return try dir_builtins.popd(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "dirs")) {
            return try dir_builtins.dirs(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "eval")) {
            return try self.builtinEval(command);
        } else if (std.mem.eql(u8, command.name, "exec")) {
            return try self.builtinExec(command);
        } else if (std.mem.eql(u8, command.name, "command")) {
            return try self.builtinCommand(command);
        } else if (std.mem.eql(u8, command.name, "builtin")) {
            return try self.builtinBuiltin(command);
        } else if (std.mem.eql(u8, command.name, "jobs")) {
            return try builtins.job_builtins.jobs(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "fg")) {
            return try builtins.job_builtins.fg(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "bg")) {
            return try builtins.job_builtins.bg(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "wait")) {
            return try builtins.job_builtins.wait(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "disown")) {
            return try builtins.job_builtins.disown(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "kill")) {
            return try builtins.signal_builtins.kill(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "trap")) {
            return try builtins.state_builtins.trap(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "times")) {
            return try builtins.process_builtins.times(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "umask")) {
            return try builtins.process_builtins.umask(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "getopts")) {
            return try self.builtinGetopts(command);
        } else if (std.mem.eql(u8, command.name, "clear")) {
            return try utilities.clear(command);
        } else if (std.mem.eql(u8, command.name, "time")) {
            return try self.builtinTime(command);
        } else if (std.mem.eql(u8, command.name, "timeout")) {
            return try builtins.process_builtins.timeout(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "hash")) {
            return try builtins.command_builtins.hash(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "yes")) {
            return try utilities.yes(command);
        } else if (std.mem.eql(u8, command.name, "reload")) {
            return try builtins.state_builtins.reload(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "watch")) {
            return try self.builtinWatch(command);
        } else if (std.mem.eql(u8, command.name, "tree")) {
            return try file_ops.tree(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "grep")) {
            return try file_ops.grep(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "find")) {
            return try file_ops.find(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "ft")) {
            return try file_ops.ft(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "calc")) {
            return try file_ops.calc(command);
        } else if (std.mem.eql(u8, command.name, "json")) {
            return try file_ops.json(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "ls")) {
            return try file_ops.ls(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "seq")) {
            return try utilities.seq(command);
        } else if (std.mem.eql(u8, command.name, "date")) {
            return try utilities.date(command);
        } else if (std.mem.eql(u8, command.name, "parallel")) {
            return try self.builtinParallel(command);
        } else if (std.mem.eql(u8, command.name, "http")) {
            return try utilities.http(command);
        } else if (std.mem.eql(u8, command.name, "base64")) {
            return try utilities.base64(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "uuid")) {
            return try utilities.uuid(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "localip")) {
            return try utilities.localip(command);
        } else if (std.mem.eql(u8, command.name, "ip")) {
            return try utilities.ip(command);
        } else if (std.mem.eql(u8, command.name, "shrug")) {
            return try utilities.shrug(command);
        } else if (std.mem.eql(u8, command.name, "web")) {
            return try utilities.web(command);
        } else if (std.mem.eql(u8, command.name, "return")) {
            return try self.builtinReturn(command);
        } else if (std.mem.eql(u8, command.name, "local")) {
            return try self.builtinLocal(command);
        } else if (std.mem.eql(u8, command.name, "copyssh")) {
            return try builtins.macos_builtins.copyssh(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "reloaddns")) {
            return try builtins.macos_builtins.reloaddns(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "emptytrash")) {
            return try builtins.macos_builtins.emptytrash(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "wip")) {
            return try builtins.dev_builtins.wip(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "bookmark")) {
            return try builtins.state_builtins.bookmark(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "code")) {
            return try builtins.dev_builtins.code(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "pstorm")) {
            return try builtins.dev_builtins.pstorm(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "show")) {
            return try builtins.macos_builtins.show(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "hide")) {
            return try builtins.macos_builtins.hide(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "sys-stats")) {
            return try builtins.monitoring_builtins.sysStats(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "netstats")) {
            return try builtins.monitoring_builtins.netstats(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "net-check")) {
            return try builtins.monitoring_builtins.netCheck(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "log-tail")) {
            return try builtins.monitoring_builtins.logTail(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "proc-monitor")) {
            return try builtins.monitoring_builtins.procMonitor(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "log-parse")) {
            return try builtins.monitoring_builtins.logParse(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "dotfiles")) {
            return try builtins.macos_builtins.dotfiles(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "library")) {
            return try builtins.macos_builtins.library(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "hook")) {
            return try builtinHook(self, command);
        } else if (std.mem.eql(u8, command.name, "ifind")) {
            return try builtins.interactive_builtins.ifind(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "coproc")) {
            return try self.builtinCoproc(command);
        }

        // Check for loadable builtins
        if (self.shell) |shell| {
            if (shell.loadable_builtins.isEnabled(command.name)) {
                return shell.loadable_builtins.execute(self.allocator, command.name, command.args) catch |err| {
                    switch (err) {
                        error.NotLoaded => try IO.eprint("den: {s}: not a loadable builtin\n", .{command.name}),
                        error.Disabled => try IO.eprint("den: {s}: loadable builtin is disabled\n", .{command.name}),
                        else => try IO.eprint("den: {s}: execution error\n", .{command.name}),
                    }
                    return 1;
                };
            }
        }

        try IO.eprint("den: builtin not implemented: {s}\n", .{command.name});
        return 1;
    }

    /// env command with VAR=value support
    /// Usage: env [-i] [-u name] [name=value]... [command [args]...]
    fn builtinEnvCmd(self: *Executor, command: *types.ParsedCommand) anyerror!i32 {
        // No args - just print environment
        if (command.args.len == 0) {
            var ctx = self.getBuiltinContext();
            return try env_builtins.env(&ctx);
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
                        try IO.eprint("den: env: option requires an argument -- 'u'\n", .{});
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
                    try IO.eprint("den: env: invalid option -- '{s}'\n", .{arg});
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

    fn builtinTime(self: *Executor, command: *types.ParsedCommand) !i32 {
        // Parse flags
        var posix_format = false; // -p: POSIX format output
        var verbose = false; // -v: verbose output with more details
        var arg_start: usize = 0;

        while (arg_start < command.args.len) {
            const arg = command.args[arg_start];
            if (arg.len > 0 and arg[0] == '-') {
                if (std.mem.eql(u8, arg, "-p")) {
                    posix_format = true;
                    arg_start += 1;
                } else if (std.mem.eql(u8, arg, "-v")) {
                    verbose = true;
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
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

        if (posix_format) {
            // POSIX format: "real %f\nuser %f\nsys %f\n"
            try IO.eprint("real {d:.2}\n", .{elapsed_s});
            try IO.eprint("user 0.00\n", .{});
            try IO.eprint("sys 0.00\n", .{});
        } else if (verbose) {
            // Verbose format with more details
            try IO.eprint("\n", .{});
            try IO.eprint("        Command: {s}", .{command.args[arg_start]});
            for (command.args[arg_start + 1 ..]) |arg| {
                try IO.eprint(" {s}", .{arg});
            }
            try IO.eprint("\n", .{});
            try IO.eprint("    Exit status: {d}\n", .{exit_code});
            if (elapsed_s >= 1.0) {
                try IO.eprint("      Real time: {d:.3}s\n", .{elapsed_s});
            } else {
                try IO.eprint("      Real time: {d:.1}ms\n", .{elapsed_ms});
            }
        } else {
            // Default format with tabs
            try IO.eprint("\nreal\t{d:.3}s\n", .{elapsed_s});
            try IO.eprint("user\t0.000s\n", .{});
            try IO.eprint("sys\t0.000s\n", .{});
        }

        return exit_code;
    }

    fn builtinWatch(self: *Executor, command: *types.ParsedCommand) !i32 {
        // watch [-n seconds] command [args...]
        // Repeatedly execute a command and display output

        if (command.args.len == 0) {
            try IO.eprint("den: watch: missing command\n", .{});
            try IO.eprint("den: watch: usage: watch [-n seconds] command [args...]\n", .{});
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
                try IO.eprint("den: watch: error executing command: {}\n", .{err});
            };

            // Sleep for the interval
            std.posix.nanosleep(interval_seconds, 0);
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

    /// Builtin: parallel - run commands in parallel (stub)
    fn builtinParallel(self: *Executor, command: *types.ParsedCommand) !i32 {
        _ = self;

        if (command.args.len == 0) {
            try IO.eprint("den: parallel: missing command\nden: parallel: usage: parallel command [args...]\n", .{});
            try IO.eprint("den: parallel: note: parallel is a stub implementation\n", .{});
            return 1;
        }

        // Stub implementation - just notify the user
        try IO.print("parallel: stub implementation - command would run in parallel\n", .{});
        try IO.print("Command: {s}\n", .{command.args[0]});

        return 0;
    }

    fn builtinReturn(self: *Executor, command: *types.ParsedCommand) !i32 {
        const shell = self.shell orelse {
            try IO.eprint("den: return: can only return from a function or sourced script\n", .{});
            return 1;
        };

        // Parse return code (default 0)
        var return_code: i32 = 0;
        if (command.args.len > 0) {
            return_code = std.fmt.parseInt(i32, command.args[0], 10) catch {
                try IO.eprint("den: return: {s}: numeric argument required\n", .{command.args[0]});
                return 2;
            };
        }

        // Request return from current function
        shell.function_manager.requestReturn(return_code) catch {
            try IO.eprint("den: return: can only return from a function or sourced script\n", .{});
            return 1;
        };

        return return_code;
    }

    fn builtinLocal(self: *Executor, command: *types.ParsedCommand) !i32 {
        const shell = self.shell orelse {
            try IO.eprint("den: local: can only be used in a function\n", .{});
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
                    try IO.eprint("den: local: {s}: can only be used in a function\n", .{name});
                    return 1;
                };
            } else {
                // Just declare as empty
                shell.function_manager.setLocal(arg, "") catch {
                    try IO.eprint("den: local: {s}: can only be used in a function\n", .{arg});
                    return 1;
                };
            }
        }

        return 0;
    }

    /// Coproc: run a command as a coprocess with bidirectional pipes
    /// Usage: coproc [NAME] command [args...]
    /// Sets COPROC[0] (read fd), COPROC[1] (write fd), COPROC_PID
    fn builtinCoproc(self: *Executor, command: *types.ParsedCommand) !i32 {
        if (command.args.len == 0) {
            try IO.eprint("coproc: command required\n", .{});
            return 1;
        }

        // Parse optional name and command
        var name: []const u8 = "COPROC";
        var cmd_start: usize = 0;

        // Check if first arg looks like a name (all caps, alphanumeric)
        if (command.args.len > 1) {
            const first = command.args[0];
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

        if (cmd_start >= command.args.len) {
            try IO.eprint("coproc: command required after name\n", .{});
            return 1;
        }

        // Create pipes for bidirectional communication
        // pipe_to_coproc: parent writes to [1], coproc reads from [0]
        // pipe_from_coproc: coproc writes to [1], parent reads from [0]
        const pipe_to_coproc = std.posix.pipe() catch |err| {
            try IO.eprint("coproc: failed to create pipe: {s}\n", .{@errorName(err)});
            return 1;
        };
        const pipe_from_coproc = std.posix.pipe() catch |err| {
            std.posix.close(pipe_to_coproc[0]);
            std.posix.close(pipe_to_coproc[1]);
            try IO.eprint("coproc: failed to create pipe: {s}\n", .{@errorName(err)});
            return 1;
        };

        // Fork to create coprocess
        const pid = std.posix.fork() catch |err| {
            std.posix.close(pipe_to_coproc[0]);
            std.posix.close(pipe_to_coproc[1]);
            std.posix.close(pipe_from_coproc[0]);
            std.posix.close(pipe_from_coproc[1]);
            try IO.eprint("coproc: failed to fork: {s}\n", .{@errorName(err)});
            return 1;
        };

        if (pid == 0) {
            // Child process (coprocess)
            // Close parent's ends
            std.posix.close(pipe_to_coproc[1]);
            std.posix.close(pipe_from_coproc[0]);

            // Redirect stdin from pipe_to_coproc[0]
            std.posix.dup2(pipe_to_coproc[0], std.posix.STDIN_FILENO) catch std.process.exit(1);
            std.posix.close(pipe_to_coproc[0]);

            // Redirect stdout to pipe_from_coproc[1]
            std.posix.dup2(pipe_from_coproc[1], std.posix.STDOUT_FILENO) catch std.process.exit(1);
            std.posix.close(pipe_from_coproc[1]);

            // Execute the command
            const cmd_name = command.args[cmd_start];

            // Convert command name to null-terminated
            const cmd_z = std.posix.toPosixPath(cmd_name) catch {
                std.process.exit(127);
            };

            // Build argv - allocate on stack
            var argv_storage: [64][std.fs.max_path_bytes:0]u8 = undefined;
            var argv: [64:null]?[*:0]const u8 = undefined;
            var argv_idx: usize = 0;

            for (command.args[cmd_start..]) |arg| {
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
            _ = std.posix.execvpeZ(&cmd_z, @ptrCast(argv[0..argv_idx :null]), getCEnviron()) catch {
                std.process.exit(127);
            };

            // If exec failed
            std.process.exit(127);
        }

        // Parent process
        // Close child's ends
        std.posix.close(pipe_to_coproc[0]);
        std.posix.close(pipe_from_coproc[1]);

        // Set up variables:
        // NAME[0] = fd for reading from coproc (pipe_from_coproc[0])
        // NAME[1] = fd for writing to coproc (pipe_to_coproc[1])
        // NAME_PID = pid of coprocess
        if (self.shell) |shell| {
            // Set NAME_PID
            var pid_name_buf: [128]u8 = undefined;
            const pid_name = std.fmt.bufPrint(&pid_name_buf, "{s}_PID", .{name}) catch {
                try IO.eprint("coproc: name too long\n", .{});
                return 1;
            };
            var pid_val_buf: [32]u8 = undefined;
            const pid_str = std.fmt.bufPrint(&pid_val_buf, "{d}", .{pid}) catch "0";

            // Duplicate strings for the hash map
            const pid_name_dup = self.allocator.dupe(u8, pid_name) catch {
                return 1;
            };
            const pid_str_dup = self.allocator.dupe(u8, pid_str) catch {
                self.allocator.free(pid_name_dup);
                return 1;
            };
            shell.environment.put(pid_name_dup, pid_str_dup) catch {};

            // For array-like access, we store as NAME_0 and NAME_1
            // (full array support is a separate feature)
            var read_fd_name_buf: [128]u8 = undefined;
            const read_fd_name = std.fmt.bufPrint(&read_fd_name_buf, "{s}_0", .{name}) catch name;
            var fd_buf: [32]u8 = undefined;
            const read_fd_str = std.fmt.bufPrint(&fd_buf, "{d}", .{pipe_from_coproc[0]}) catch "0";

            const read_name_dup = self.allocator.dupe(u8, read_fd_name) catch {
                return 1;
            };
            const read_str_dup = self.allocator.dupe(u8, read_fd_str) catch {
                self.allocator.free(read_name_dup);
                return 1;
            };
            shell.environment.put(read_name_dup, read_str_dup) catch {};

            var write_fd_name_buf: [128]u8 = undefined;
            const write_fd_name = std.fmt.bufPrint(&write_fd_name_buf, "{s}_1", .{name}) catch name;
            var fd_buf2: [32]u8 = undefined;
            const write_fd_str = std.fmt.bufPrint(&fd_buf2, "{d}", .{pipe_to_coproc[1]}) catch "0";

            const write_name_dup = self.allocator.dupe(u8, write_fd_name) catch {
                return 1;
            };
            const write_str_dup = self.allocator.dupe(u8, write_fd_str) catch {
                self.allocator.free(write_name_dup);
                return 1;
            };
            shell.environment.put(write_name_dup, write_str_dup) catch {};

            // Store coproc info in shell for later cleanup
            shell.coproc_pid = pid;
            shell.coproc_read_fd = pipe_from_coproc[0];
            shell.coproc_write_fd = pipe_to_coproc[1];
        }

        try IO.print("[coproc] {d}\n", .{pid});
        return 0;
    }

};


/// hook builtin - manage custom command hooks
fn builtinHook(self: *Executor, command: *types.ParsedCommand) !i32 {
    _ = self;
    const plugins = @import("../plugins/interface.zig");

    // Static custom hook registry (persists across calls)
    const S = struct {
        var registry: ?plugins.CustomHookRegistry = null;
    };

    // Initialize registry on first use
    if (S.registry == null) {
        S.registry = plugins.CustomHookRegistry.init(std.heap.page_allocator);
    }
    var registry = &(S.registry.?);

    // No arguments - show help
    if (command.args.len == 0) {
        try IO.print("hook - manage custom command hooks\n", .{});
        try IO.print("Usage: hook <command> [args]\n", .{});
        try IO.print("\nCommands:\n", .{});
        try IO.print("  list                  List registered hooks\n", .{});
        try IO.print("  add <name> <pattern> <script>\n", .{});
        try IO.print("                        Register a hook\n", .{});
        try IO.print("  remove <name>         Remove a hook\n", .{});
        try IO.print("  enable <name>         Enable a hook\n", .{});
        try IO.print("  disable <name>        Disable a hook\n", .{});
        try IO.print("  test <command>        Test which hooks match\n", .{});
        try IO.print("\nExamples:\n", .{});
        try IO.print("  hook add git:push \"git push\" \"echo 'Pushing...'\"\n", .{});
        try IO.print("  hook add npm:install \"npm install\" \"echo 'Installing deps'\"\n", .{});
        try IO.print("  hook add docker:build \"docker build\" \"echo 'Building image'\"\n", .{});
        try IO.print("  hook list\n", .{});
        try IO.print("  hook test \"git push origin main\"\n", .{});
        return 0;
    }

    const subcmd = command.args[0];

    if (std.mem.eql(u8, subcmd, "list")) {
        const hooks = registry.list();
        if (hooks.len == 0) {
            try IO.print("\x1b[2mNo hooks registered\x1b[0m\n", .{});
            try IO.print("\nUse 'hook add <name> <pattern> <script>' to add a hook.\n", .{});
            return 0;
        }

        try IO.print("\x1b[1;36m=== Registered Hooks ===\x1b[0m\n\n", .{});
        for (hooks) |hook| {
            const status = if (hook.enabled) "\x1b[1;32m●\x1b[0m" else "\x1b[2m○\x1b[0m";
            try IO.print("{s} \x1b[1m{s}\x1b[0m\n", .{ status, hook.name });
            try IO.print("    Pattern: {s}\n", .{hook.pattern});
            if (hook.script) |script| {
                try IO.print("    Script:  {s}\n", .{script});
            }
            try IO.print("\n", .{});
        }
        return 0;
    } else if (std.mem.eql(u8, subcmd, "add")) {
        if (command.args.len < 4) {
            try IO.eprint("den: hook: add: usage: hook add <name> <pattern> <script>\n", .{});
            try IO.eprint("den: hook: add: example: hook add git:push \"git push\" \"echo 'Pushing...'\"\n", .{});
            return 1;
        }

        const name = command.args[1];
        const pattern = command.args[2];
        const script = command.args[3];

        registry.register(name, pattern, script, null, null, 0) catch |err| {
            try IO.eprint("den: hook: add: failed to register: {}\n", .{err});
            return 1;
        };

        try IO.print("\x1b[1;32m✓\x1b[0m Registered hook '{s}'\n", .{name});
        try IO.print("  Pattern: {s}\n", .{pattern});
        try IO.print("  Script:  {s}\n", .{script});
        return 0;
    } else if (std.mem.eql(u8, subcmd, "remove")) {
        if (command.args.len < 2) {
            try IO.eprint("den: hook: remove: missing hook name\n", .{});
            return 1;
        }

        const name = command.args[1];
        if (registry.unregister(name)) {
            try IO.print("\x1b[1;32m✓\x1b[0m Removed hook '{s}'\n", .{name});
            return 0;
        } else {
            try IO.eprint("den: hook: remove: '{s}' not found\n", .{name});
            return 1;
        }
    } else if (std.mem.eql(u8, subcmd, "enable")) {
        if (command.args.len < 2) {
            try IO.eprint("den: hook: enable: missing hook name\n", .{});
            return 1;
        }

        const name = command.args[1];
        if (registry.setEnabled(name, true)) {
            try IO.print("\x1b[1;32m✓\x1b[0m Enabled hook '{s}'\n", .{name});
            return 0;
        } else {
            try IO.eprint("den: hook: enable: '{s}' not found\n", .{name});
            return 1;
        }
    } else if (std.mem.eql(u8, subcmd, "disable")) {
        if (command.args.len < 2) {
            try IO.eprint("den: hook: disable: missing hook name\n", .{});
            return 1;
        }

        const name = command.args[1];
        if (registry.setEnabled(name, false)) {
            try IO.print("\x1b[1;32m✓\x1b[0m Disabled hook '{s}'\n", .{name});
            return 0;
        } else {
            try IO.eprint("den: hook: disable: '{s}' not found\n", .{name});
            return 1;
        }
    } else if (std.mem.eql(u8, subcmd, "test")) {
        if (command.args.len < 2) {
            try IO.eprint("den: hook: test: missing command to test\n", .{});
            return 1;
        }

        // Join remaining args as the test command
        var test_cmd_buf: [1024]u8 = undefined;
        var pos: usize = 0;
        for (command.args[1..]) |arg| {
            if (pos > 0) {
                test_cmd_buf[pos] = ' ';
                pos += 1;
            }
            const len = @min(arg.len, test_cmd_buf.len - pos);
            @memcpy(test_cmd_buf[pos .. pos + len], arg[0..len]);
            pos += len;
        }
        const test_cmd = test_cmd_buf[0..pos];

        const matches = registry.findMatchingHooks(test_cmd);
        if (matches.len == 0) {
            try IO.print("\x1b[2mNo hooks match: {s}\x1b[0m\n", .{test_cmd});
        } else {
            try IO.print("\x1b[1;36mHooks matching '{s}':\x1b[0m\n\n", .{test_cmd});
            for (matches) |hook| {
                const cond_met = plugins.CustomHookRegistry.checkCondition(hook.condition);
                const cond_status = if (cond_met) "\x1b[1;32m✓\x1b[0m" else "\x1b[1;31m✗\x1b[0m";
                try IO.print("  {s} {s}\n", .{ cond_status, hook.name });
                if (hook.script) |script| {
                    try IO.print("      → {s}\n", .{script});
                }
            }
        }
        return 0;
    } else {
        try IO.eprint("den: hook: unknown command '{s}'\n", .{subcmd});
        try IO.eprint("den: hook: run 'hook' for usage.\n", .{});
        return 1;
    }
}

// ========================================
// Tests for /dev/tcp and /dev/udp support
// ========================================

test "parseDevNetPath - valid IPv4 TCP" {
    const result = parseDevNetPath("/dev/tcp/127.0.0.1/80");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("127.0.0.1", result.?.host);
    try std.testing.expectEqual(@as(u16, 80), result.?.port);
    try std.testing.expect(result.?.is_tcp);
}

test "parseDevNetPath - valid IPv4 UDP" {
    const result = parseDevNetPath("/dev/udp/192.168.1.1/53");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("192.168.1.1", result.?.host);
    try std.testing.expectEqual(@as(u16, 53), result.?.port);
    try std.testing.expect(!result.?.is_tcp);
}

test "parseDevNetPath - valid IPv6 TCP" {
    const result = parseDevNetPath("/dev/tcp/[::1]/8080");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("::1", result.?.host);
    try std.testing.expectEqual(@as(u16, 8080), result.?.port);
    try std.testing.expect(result.?.is_tcp);
}

test "parseDevNetPath - valid IPv6 full address" {
    const result = parseDevNetPath("/dev/tcp/[2001:db8::1]/443");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("2001:db8::1", result.?.host);
    try std.testing.expectEqual(@as(u16, 443), result.?.port);
}

test "parseDevNetPath - invalid: not /dev/tcp or /dev/udp" {
    try std.testing.expect(parseDevNetPath("/dev/null") == null);
    try std.testing.expect(parseDevNetPath("/dev/tty") == null);
    try std.testing.expect(parseDevNetPath("/tmp/foo") == null);
    try std.testing.expect(parseDevNetPath("") == null);
}

test "parseDevNetPath - invalid: missing port" {
    try std.testing.expect(parseDevNetPath("/dev/tcp/127.0.0.1") == null);
    try std.testing.expect(parseDevNetPath("/dev/tcp/127.0.0.1/") == null);
}

test "parseDevNetPath - invalid: missing host" {
    try std.testing.expect(parseDevNetPath("/dev/tcp//80") == null);
    try std.testing.expect(parseDevNetPath("/dev/tcp/") == null);
}

test "parseDevNetPath - invalid: port 0" {
    try std.testing.expect(parseDevNetPath("/dev/tcp/127.0.0.1/0") == null);
}

test "parseDevNetPath - invalid: non-numeric port" {
    try std.testing.expect(parseDevNetPath("/dev/tcp/127.0.0.1/abc") == null);
}

test "parseDevNetPath - invalid: port too large" {
    try std.testing.expect(parseDevNetPath("/dev/tcp/127.0.0.1/65536") == null);
}

test "parseIPv4 - valid addresses" {
    const result1 = parseIPv4("127.0.0.1");
    try std.testing.expect(result1 != null);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, result1.?);

    const result2 = parseIPv4("192.168.1.1");
    try std.testing.expect(result2 != null);
    try std.testing.expectEqual([4]u8{ 192, 168, 1, 1 }, result2.?);

    const result3 = parseIPv4("0.0.0.0");
    try std.testing.expect(result3 != null);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, result3.?);

    const result4 = parseIPv4("255.255.255.255");
    try std.testing.expect(result4 != null);
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, result4.?);
}

test "parseIPv4 - invalid addresses" {
    try std.testing.expect(parseIPv4("") == null);
    try std.testing.expect(parseIPv4("127.0.0") == null);
    try std.testing.expect(parseIPv4("127.0.0.1.2") == null);
    try std.testing.expect(parseIPv4("256.0.0.1") == null);
    try std.testing.expect(parseIPv4("127.0.0.256") == null);
    try std.testing.expect(parseIPv4("abc.def.ghi.jkl") == null);
    try std.testing.expect(parseIPv4("127.0.0.1a") == null);
    try std.testing.expect(parseIPv4("127..0.1") == null);
}

test "parseIPv6 - loopback" {
    const result = parseIPv6("::1");
    try std.testing.expect(result != null);
    try std.testing.expectEqual([16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, result.?);
}

test "parseIPv6 - all zeros" {
    const result = parseIPv6("::");
    try std.testing.expect(result != null);
    try std.testing.expectEqual([16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, result.?);
}

test "parseIPv6 - full address" {
    const result = parseIPv6("2001:db8:0:0:0:0:0:1");
    try std.testing.expect(result != null);
    try std.testing.expectEqual([16]u8{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, result.?);
}

test "parseIPv6 - invalid: too many groups" {
    try std.testing.expect(parseIPv6("1:2:3:4:5:6:7:8:9") == null);
}

test "parseIPv6 - invalid: multiple ::" {
    try std.testing.expect(parseIPv6("::1::2") == null);
}
