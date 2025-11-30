const std = @import("std");

/// Completion specification type (similar to bash's complete)
pub const CompletionSpec = struct {
    /// Command name this completion applies to
    command: []const u8,
    /// Completion options/flags
    options: Options,
    /// Wordlist for static completions
    wordlist: ?[]const []const u8,

    pub const Options = struct {
        /// -f: Complete filenames
        filenames: bool = false,
        /// -d: Complete directories
        directories: bool = false,
        /// -c: Complete commands
        commands: bool = false,
        /// -a: Complete aliases
        aliases: bool = false,
        /// -b: Complete builtins
        builtins: bool = false,
        /// -e: Complete environment variables
        variables: bool = false,
        /// -u: Complete usernames
        users: bool = false,
        /// -W wordlist: Use words from wordlist
        use_wordlist: bool = false,
        /// -S suffix: Append suffix to completions
        suffix: ?[]const u8 = null,
        /// -P prefix: Prepend prefix to completions
        prefix: ?[]const u8 = null,
    };

    pub fn deinit(self: *CompletionSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
        if (self.options.suffix) |suffix| allocator.free(suffix);
        if (self.options.prefix) |prefix| allocator.free(prefix);
        if (self.wordlist) |wordlist| {
            for (wordlist) |word| {
                allocator.free(word);
            }
            allocator.free(wordlist);
        }
    }
};

/// Registry for custom completion specifications
pub const CompletionRegistry = struct {
    allocator: std.mem.Allocator,
    /// Map of command name -> completion specification
    specs: std.StringHashMap(CompletionSpec),

    pub fn init(allocator: std.mem.Allocator) CompletionRegistry {
        return .{
            .allocator = allocator,
            .specs = std.StringHashMap(CompletionSpec).init(allocator),
        };
    }

    pub fn deinit(self: *CompletionRegistry) void {
        var iter = self.specs.iterator();
        while (iter.next()) |entry| {
            var spec = entry.value_ptr.*;
            spec.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.specs.deinit();
    }

    /// Register a completion specification for a command
    pub fn register(self: *CompletionRegistry, command: []const u8, spec: CompletionSpec) !void {
        const key = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(key);

        // Remove existing if present
        if (self.specs.fetchRemove(key)) |old| {
            var old_spec = old.value;
            old_spec.deinit(self.allocator);
            self.allocator.free(old.key);
        }

        var new_spec = spec;
        new_spec.command = try self.allocator.dupe(u8, spec.command);
        try self.specs.put(key, new_spec);
    }

    /// Unregister completion for a command
    pub fn unregister(self: *CompletionRegistry, command: []const u8) bool {
        if (self.specs.fetchRemove(command)) |entry| {
            var spec = entry.value;
            spec.deinit(self.allocator);
            self.allocator.free(entry.key);
            return true;
        }
        return false;
    }

    /// Get completion specification for a command
    pub fn get(self: *CompletionRegistry, command: []const u8) ?CompletionSpec {
        return self.specs.get(command);
    }

    /// Check if a command has custom completions
    pub fn hasSpec(self: *CompletionRegistry, command: []const u8) bool {
        return self.specs.contains(command);
    }

    /// Get all registered commands
    pub fn getCommands(self: *CompletionRegistry) ![][]const u8 {
        var result = std.ArrayList([]const u8).empty;
        errdefer result.deinit(self.allocator);

        var iter = self.specs.keyIterator();
        while (iter.next()) |key| {
            try result.append(self.allocator, try self.allocator.dupe(u8, key.*));
        }

        return try result.toOwnedSlice(self.allocator);
    }
};

/// Parse completion options from command arguments (like bash's complete)
pub fn parseCompletionOptions(args: [][]const u8) !struct { options: CompletionSpec.Options, wordlist: ?[][]const u8, remaining_args: [][]const u8 } {
    var options = CompletionSpec.Options{};
    const wordlist: ?[][]const u8 = null;
    var arg_idx: usize = 0;

    while (arg_idx < args.len) {
        const arg = args[arg_idx];

        if (arg.len > 0 and arg[0] == '-') {
            // Single letter options
            if (arg.len == 2) {
                switch (arg[1]) {
                    'f' => options.filenames = true,
                    'd' => options.directories = true,
                    'c' => options.commands = true,
                    'a' => options.aliases = true,
                    'b' => options.builtins = true,
                    'e' => options.variables = true,
                    'u' => options.users = true,
                    'r' => {}, // Remove (handled separately)
                    'p' => {}, // Print (handled separately)
                    'W' => {
                        // Next arg is wordlist
                        if (arg_idx + 1 < args.len) {
                            arg_idx += 1;
                            // Parse wordlist (space-separated words)
                            options.use_wordlist = true;
                            // Note: Caller should parse the wordlist from the next arg
                        }
                    },
                    'S' => {
                        // Next arg is suffix
                        if (arg_idx + 1 < args.len) {
                            arg_idx += 1;
                            options.suffix = args[arg_idx];
                        }
                    },
                    'P' => {
                        // Next arg is prefix
                        if (arg_idx + 1 < args.len) {
                            arg_idx += 1;
                            options.prefix = args[arg_idx];
                        }
                    },
                    else => {},
                }
            }
            arg_idx += 1;
        } else {
            // Non-option argument - this is the command name
            break;
        }
    }

    return .{
        .options = options,
        .wordlist = wordlist,
        .remaining_args = args[arg_idx..],
    };
}

test "CompletionRegistry - register and get" {
    const allocator = std.testing.allocator;

    var registry = CompletionRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("mycommand", .{
        .command = "mycommand",
        .options = .{ .filenames = true, .directories = true },
        .wordlist = null,
    });

    const spec = registry.get("mycommand");
    try std.testing.expect(spec != null);
    try std.testing.expect(spec.?.options.filenames);
    try std.testing.expect(spec.?.options.directories);
}

test "CompletionRegistry - unregister" {
    const allocator = std.testing.allocator;

    var registry = CompletionRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("test", .{
        .command = "test",
        .options = .{ .commands = true },
        .wordlist = null,
    });

    try std.testing.expect(registry.hasSpec("test"));
    try std.testing.expect(registry.unregister("test"));
    try std.testing.expect(!registry.hasSpec("test"));
}
