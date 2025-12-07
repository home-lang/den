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

    // Simplified: execute as a single-command chain
    const single_cmd = types.ParsedCommand{
        .name = cmd.args[0],
        .args = if (cmd.args.len > 1) cmd.args[1..] else &[_][]const u8{},
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
