//! Eval-related Builtins Implementation
//!
//! This module implements command evaluation builtins:
//! - read: read line from stdin into variable
//! - command: execute command bypassing functions
//! - eval: execute arguments as shell command
//! - shift: shift positional parameters
//! - builtin: execute builtin command

const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");
const parser_mod = @import("../parser/mod.zig");
const executor_mod = @import("../executor/mod.zig");

// Forward declaration for Shell type
const Shell = @import("../shell.zig").Shell;

// Format parse error for display
fn formatParseError(err: anyerror) []const u8 {
    return switch (err) {
        error.OutOfMemory => "out of memory",
        error.UnexpectedToken => "unexpected token",
        error.UnterminatedString => "unterminated string",
        error.EmptyCommand => "empty command",
        error.InvalidSyntax => "invalid syntax",
        error.MissingOperand => "missing operand",
        error.InvalidRedirection => "invalid redirection",
        error.UnmatchedParenthesis => "unmatched parenthesis",
        else => "parse error",
    };
}

/// Builtin: read - read line from stdin into variable
pub fn builtinRead(self: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        try IO.eprint("den: read: usage: read varname\n", .{});
        return;
    }

    const varname = cmd.args[0];

    // Read line from stdin
    const line = try IO.readLine(self.allocator);
    if (line) |value| {
        defer self.allocator.free(value);

        // Store in environment
        const value_copy = try self.allocator.dupe(u8, value);

        // Get or put entry to avoid memory leak
        const gop = try self.environment.getOrPut(varname);
        if (gop.found_existing) {
            // Free old value and update
            self.allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = value_copy;
        } else {
            // New key - duplicate it
            const key = try self.allocator.dupe(u8, varname);
            gop.key_ptr.* = key;
            gop.value_ptr.* = value_copy;
        }
    }
}

/// Builtin: command - execute command bypassing functions
pub fn builtinCommand(self: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        try IO.eprint("den: command: missing command argument\n", .{});
        self.last_exit_code = 1;
        return;
    }

    // Handle -v, -V, -p flags
    var verbose = false;
    var short_output = false;
    var start_idx: usize = 0;

    for (cmd.args, 0..) |arg, i| {
        if (arg.len > 0 and arg[0] == '-') {
            for (arg[1..]) |c| {
                if (c == 'V') {
                    verbose = true;
                } else if (c == 'v') {
                    short_output = true;
                } else if (c == 'p') {
                    // use default PATH - ignored for -v/-V
                } else {
                    try IO.eprint("den: command: invalid option: -{c}\n", .{c});
                    self.last_exit_code = 1;
                    return;
                }
            }
            start_idx = i + 1;
        } else {
            break;
        }
    }

    if (start_idx >= cmd.args.len) {
        if (verbose or short_output) {
            // No command name after flags
            self.last_exit_code = 1;
            return;
        }
        try IO.eprint("den: command: missing command argument\n", .{});
        self.last_exit_code = 1;
        return;
    }

    const cmd_name = cmd.args[start_idx];

    if (verbose or short_output) {
        // command -v / command -V: locate command
        const builtins = [_][]const u8{
            "cd",      "echo",    "exit",    "export",  "set",     "unset",
            "alias",   "unalias", "source",  ".",       "eval",    "exec",
            "command", "builtin", "type",    "which",   "test",    "[",
            "[[",      "true",    "false",   "read",    "printf",  "pwd",
            "pushd",   "popd",    "dirs",    "history", "jobs",    "fg",
            "bg",      "kill",    "wait",    "trap",    "shift",   "return",
            "break",   "continue","local",   "declare", "typeset", "readonly",
            "let",     "hash",    "umask",   "ulimit",  "getopts", ":",
        };
        for (builtins) |b| {
            if (std.mem.eql(u8, cmd_name, b)) {
                if (verbose) {
                    try IO.print("{s} is a shell builtin\n", .{cmd_name});
                } else {
                    try IO.print("{s}\n", .{cmd_name});
                }
                self.last_exit_code = 0;
                return;
            }
        }

        // Check functions
        if (self.function_manager.hasFunction(cmd_name)) {
            if (verbose) {
                try IO.print("{s} is a function\n", .{cmd_name});
            } else {
                try IO.print("{s}\n", .{cmd_name});
            }
            self.last_exit_code = 0;
            return;
        }

        // Check aliases
        if (self.aliases.contains(cmd_name)) {
            if (verbose) {
                if (self.aliases.get(cmd_name)) |val| {
                    try IO.print("{s} is aliased to `{s}'\n", .{ cmd_name, val });
                }
            } else {
                try IO.print("{s}\n", .{cmd_name});
            }
            self.last_exit_code = 0;
            return;
        }

        // Search PATH
        if (self.environment.get("PATH")) |path_val| {
            var iter = std.mem.splitScalar(u8, path_val, ':');
            while (iter.next()) |dir| {
                if (dir.len == 0) continue;
                const full_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, cmd_name }) catch continue;
                defer self.allocator.free(full_path);
                // Check if file exists and is executable
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                @memcpy(path_buf[0..full_path.len], full_path);
                path_buf[full_path.len] = 0;
                const c_path: [*:0]const u8 = path_buf[0..full_path.len :0];
                if (std.c.access(c_path, std.posix.X_OK) == 0) {
                    if (verbose) {
                        try IO.print("{s} is {s}\n", .{ cmd_name, full_path });
                    } else {
                        try IO.print("{s}\n", .{full_path});
                    }
                    self.last_exit_code = 0;
                    return;
                }
            }
        }

        // Not found
        if (verbose) {
            try IO.eprint("den: command not found: {s}\n", .{cmd_name});
        }
        self.last_exit_code = 1;
        return;
    }

    // No flags: execute as a single-command chain (bypass functions/aliases)
    const single_cmd = types.ParsedCommand{
        .name = cmd_name,
        .args = if (start_idx + 1 < cmd.args.len) cmd.args[start_idx + 1 ..] else &[_][]const u8{},
        .redirections = &[_]types.Redirection{},
        .type = .external,
    };

    const cmds = [_]types.ParsedCommand{single_cmd};
    const ops: []types.Operator = &[_]types.Operator{};

    var chain = types.CommandChain{
        .commands = @constCast(&cmds),
        .operators = ops,
    };

    var executor = executor_mod.Executor.init(self.allocator, &self.environment);
    const exit_code = executor.executeChain(&chain) catch |err| {
        try IO.eprint("den: command: {}\n", .{err});
        self.last_exit_code = 127;
        return;
    };

    self.last_exit_code = exit_code;
}

/// Builtin: eval - execute arguments as shell command
pub fn builtinEval(self: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        self.last_exit_code = 0;
        return;
    }

    // Join all arguments into a single command string
    var cmd_buf: [4096]u8 = undefined;
    var cmd_len: usize = 0;

    for (cmd.args, 0..) |arg, i| {
        if (i > 0 and cmd_len < cmd_buf.len) {
            cmd_buf[cmd_len] = ' ';
            cmd_len += 1;
        }

        const copy_len = @min(arg.len, cmd_buf.len - cmd_len);
        @memcpy(cmd_buf[cmd_len .. cmd_len + copy_len], arg[0..copy_len]);
        cmd_len += copy_len;

        if (cmd_len >= cmd_buf.len) break;
    }

    const command_str = cmd_buf[0..cmd_len];

    // Execute as if typed at prompt
    // Tokenize
    var tokenizer = parser_mod.Tokenizer.init(self.allocator, command_str);
    const tokens = tokenizer.tokenize() catch |err| {
        try IO.eprint("den: eval: parse error: {}\n", .{err});
        self.last_exit_code = 1;
        return;
    };
    defer self.allocator.free(tokens);

    if (tokens.len == 0) {
        self.last_exit_code = 0;
        return;
    }

    // Parse
    var parser = parser_mod.Parser.init(self.allocator, tokens);
    var chain = parser.parse() catch |err| {
        try IO.eprint("den: eval: {s}\n", .{formatParseError(err)});
        self.last_exit_code = 2;
        return;
    };
    defer chain.deinit(self.allocator);

    // Expand variables and aliases
    try self.expandCommandChain(&chain);
    try self.expandAliases(&chain);

    // Execute
    var executor = executor_mod.Executor.init(self.allocator, &self.environment);
    const exit_code = executor.executeChain(&chain) catch |err| {
        try IO.eprint("den: eval: execution error: {}\n", .{err});
        self.last_exit_code = 1;
        return;
    };

    self.last_exit_code = exit_code;
}

/// Builtin: shift - shift positional parameters
pub fn builtinShift(self: *Shell, cmd: *types.ParsedCommand) !void {
    // Parse shift count (default 1)
    const n: usize = if (cmd.args.len > 0)
        std.fmt.parseInt(usize, cmd.args[0], 10) catch 1
    else
        1;

    if (n > self.positional_params_count) {
        try IO.eprint("den: shift: shift count too large\n", .{});
        self.last_exit_code = 1;
        return;
    }

    // Shift parameters by freeing first n and moving rest
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (self.positional_params[i]) |param| {
            self.allocator.free(param);
            self.positional_params[i] = null;
        }
    }

    // Move remaining parameters down
    var dest: usize = 0;
    var src: usize = n;
    while (src < self.positional_params.len) : (src += 1) {
        self.positional_params[dest] = self.positional_params[src];
        if (dest != src) {
            self.positional_params[src] = null;
        }
        dest += 1;
    }

    self.positional_params_count -= n;
    self.last_exit_code = 0;
}

/// Builtin: builtin - execute builtin command
pub fn builtinBuiltin(self: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        try IO.eprint("den: builtin: usage: builtin [shell-builtin [arg ...]]\n", .{});
        self.last_exit_code = 1;
        return;
    }

    // Execute the specified builtin, bypassing any functions with the same name
    const builtin_name = cmd.args[0];
    const new_cmd = types.ParsedCommand{
        .name = builtin_name,
        .args = if (cmd.args.len > 1) cmd.args[1..] else &[_][]const u8{},
        .redirections = &[_]types.Redirection{},
    };

    // Create a simple chain with just this command
    const cmds = [_]types.ParsedCommand{new_cmd};
    const ops = [_]types.Operator{};
    var chain = types.CommandChain{
        .commands = @constCast(&cmds),
        .operators = @constCast(&ops),
    };

    // Execute using executor (builtins will be dispatched there)
    var executor = executor_mod.Executor.init(self.allocator, &self.environment);
    const exit_code = try executor.executeChain(&chain);
    self.last_exit_code = exit_code;
}
