const std = @import("std");
const types = @import("types/mod.zig");
const parser_mod = @import("parser/mod.zig");
const executor_mod = @import("executor/mod.zig");
const IO = @import("utils/io.zig").IO;
const Expansion = @import("utils/expansion.zig").Expansion;

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

        for (chain.commands) |*cmd| {
            // Expand command name
            const expanded_name = try expander.expand(cmd.name);
            // Free the old name and replace with expanded version
            self.allocator.free(cmd.name);
            cmd.name = expanded_name;

            // Expand arguments
            for (cmd.args, 0..) |arg, i| {
                const expanded_arg = try expander.expand(arg);
                self.allocator.free(cmd.args[i]);
                cmd.args[i] = expanded_arg;
            }

            // Expand redirection targets
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
