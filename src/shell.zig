const std = @import("std");
const types = @import("types/mod.zig");
const parser_mod = @import("parser/mod.zig");
const executor_mod = @import("executor/mod.zig");
const IO = @import("utils/io.zig").IO;
const Expansion = @import("utils/expansion.zig").Expansion;
const Glob = @import("utils/glob.zig").Glob;

pub const Shell = struct {
    allocator: std.mem.Allocator,
    running: bool,
    config: types.DenConfig,
    environment: std.StringHashMap([]const u8),
    aliases: std.StringHashMap([]const u8),
    last_exit_code: i32,

    pub fn init(allocator: std.mem.Allocator) !Shell {
        const config = types.DenConfig{};

        // Initialize environment from system
        var env = std.StringHashMap([]const u8).init(allocator);

        // Add some basic environment variables
        const home = std.posix.getenv("HOME") orelse "/";
        try env.put("HOME", try allocator.dupe(u8, home));

        const path = std.posix.getenv("PATH") orelse "/usr/bin:/bin";
        try env.put("PATH", try allocator.dupe(u8, path));

        return Shell{
            .allocator = allocator,
            .running = false,
            .config = config,
            .environment = env,
            .aliases = std.StringHashMap([]const u8).init(allocator),
            .last_exit_code = 0,
        };
    }

    pub fn deinit(self: *Shell) void {
        self.environment.deinit();
        self.aliases.deinit();
    }

    pub fn run(self: *Shell) !void {
        self.running = true;

        try IO.print("Den shell initialized!\n", .{});
        try IO.print("Type 'exit' to quit or Ctrl+D to exit.\n\n", .{});

        while (self.running) {
            // Render prompt
            try self.renderPrompt();

            // Read line from stdin
            const line = try IO.readLine(self.allocator);

            if (line == null) {
                // EOF (Ctrl+D)
                try IO.print("\nGoodbye from Den!\n", .{});
                break;
            }

            defer self.allocator.free(line.?);

            const trimmed = std.mem.trim(u8, line.?, &std.ascii.whitespace);

            if (trimmed.len == 0) continue;

            // Handle exit command
            if (std.mem.eql(u8, trimmed, "exit")) {
                self.running = false;
                try IO.print("Goodbye from Den!\n", .{});
                break;
            }

            // Execute command
            try self.executeCommand(trimmed);
        }
    }

    fn renderPrompt(self: *Shell) !void {
        _ = self;
        try IO.print("den> ", .{});
    }

    fn executeCommand(self: *Shell, input: []const u8) !void {
        // Tokenize
        var tokenizer = parser_mod.Tokenizer.init(self.allocator, input);
        const tokens = tokenizer.tokenize() catch |err| {
            try IO.eprint("den: parse error: {}\n", .{err});
            self.last_exit_code = 1;
            return;
        };
        defer self.allocator.free(tokens);

        if (tokens.len == 0) return;

        // Parse
        var parser = parser_mod.Parser.init(self.allocator, tokens);
        var chain = parser.parse() catch |err| {
            try IO.eprint("den: parse error: {}\n", .{err});
            self.last_exit_code = 1;
            return;
        };
        defer chain.deinit(self.allocator);

        // Expand variables in all commands
        try self.expandCommandChain(&chain);

        // Execute
        var executor = executor_mod.Executor.init(self.allocator, &self.environment);
        const exit_code = executor.executeChain(&chain) catch |err| {
            try IO.eprint("den: execution error: {}\n", .{err});
            self.last_exit_code = 1;
            return;
        };

        self.last_exit_code = exit_code;
    }

    fn expandCommandChain(self: *Shell, chain: *types.CommandChain) !void {
        var expander = Expansion.init(self.allocator, &self.environment, self.last_exit_code);
        var glob = Glob.init(self.allocator);

        // Get current working directory for glob expansion
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = try std.posix.getcwd(&cwd_buf);

        for (chain.commands) |*cmd| {
            // Expand command name (variables only, no globs for command names)
            const expanded_name = try expander.expand(cmd.name);
            self.allocator.free(cmd.name);
            cmd.name = expanded_name;

            // Expand arguments (variables + globs)
            var expanded_args_buffer: [128][]const u8 = undefined;
            var expanded_args_count: usize = 0;

            for (cmd.args) |arg| {
                // First expand variables
                const var_expanded = try expander.expand(arg);
                defer self.allocator.free(var_expanded);

                // Then expand globs
                const glob_expanded = try glob.expand(var_expanded, cwd);
                defer {
                    for (glob_expanded) |path| {
                        self.allocator.free(path);
                    }
                    self.allocator.free(glob_expanded);
                }

                // Add all glob matches to args
                for (glob_expanded) |path| {
                    if (expanded_args_count >= expanded_args_buffer.len) {
                        return error.TooManyArguments;
                    }
                    expanded_args_buffer[expanded_args_count] = try self.allocator.dupe(u8, path);
                    expanded_args_count += 1;
                }

                // Free original arg
                self.allocator.free(arg);
            }

            // Replace args with expanded version
            self.allocator.free(cmd.args);
            const new_args = try self.allocator.alloc([]const u8, expanded_args_count);
            @memcpy(new_args, expanded_args_buffer[0..expanded_args_count]);
            cmd.args = new_args;

            // Expand redirection targets (variables only, no globs)
            for (cmd.redirections, 0..) |*redir, i| {
                const expanded_target = try expander.expand(redir.target);
                self.allocator.free(cmd.redirections[i].target);
                cmd.redirections[i].target = expanded_target;
            }
        }
    }
};

test "shell initialization" {
    const allocator = std.testing.allocator;
    var sh = try Shell.init(allocator);
    defer sh.deinit();

    try std.testing.expect(!sh.running);
}
