const std = @import("std");

fn getenvFromSlice(key: []const u8) ?[]const u8 {
    var env_buf: [512]u8 = undefined;
    if (key.len >= env_buf.len) return null;
    @memcpy(env_buf[0..key.len], key);
    env_buf[key.len] = 0;
    const value = std.c.getenv(env_buf[0..key.len :0]) orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(value)));
}

/// Hook types that plugins can register
pub const HookType = enum {
    pre_command,   // Before command execution
    post_command,  // After command execution
    pre_prompt,    // Before showing prompt
    post_prompt,   // After prompt input
    shell_init,    // Shell initialization
    shell_exit,    // Shell exit
};

/// Custom command hook - triggers on specific command patterns
pub const CustomHook = struct {
    name: []const u8,           // Hook name (e.g., "git:push")
    pattern: []const u8,        // Command pattern to match (e.g., "git push")
    script: ?[]const u8,        // Script to execute (shell command)
    function: ?HookFn,          // Function to call (for plugins)
    enabled: bool,
    priority: i32,              // Lower runs first
    condition: ?HookCondition,  // Optional condition
};

/// Hook condition types
pub const HookCondition = union(enum) {
    file_exists: []const u8,    // Run only if file exists
    env_set: []const u8,        // Run only if env var is set
    env_equals: struct {        // Run only if env var equals value
        name: []const u8,
        value: []const u8,
    },
    always: void,               // Always run
};

/// Custom hook registry
pub const CustomHookRegistry = struct {
    allocator: std.mem.Allocator,
    hooks: std.ArrayListUnmanaged(CustomHook),

    pub fn init(allocator: std.mem.Allocator) CustomHookRegistry {
        return .{
            .allocator = allocator,
            .hooks = .{},
        };
    }

    pub fn deinit(self: *CustomHookRegistry) void {
        for (self.hooks.items) |hook| {
            self.allocator.free(hook.name);
            self.allocator.free(hook.pattern);
            if (hook.script) |script| {
                self.allocator.free(script);
            }
            if (hook.condition) |cond| {
                switch (cond) {
                    .file_exists => |path| self.allocator.free(path),
                    .env_set => |name| self.allocator.free(name),
                    .env_equals => |eq| {
                        self.allocator.free(eq.name);
                        self.allocator.free(eq.value);
                    },
                    .always => {},
                }
            }
        }
        self.hooks.deinit(self.allocator);
    }

    /// Register a custom command hook
    pub fn register(self: *CustomHookRegistry, name: []const u8, pattern: []const u8, script: ?[]const u8, function: ?HookFn, condition: ?HookCondition, priority: i32) !void {
        const hook = CustomHook{
            .name = try self.allocator.dupe(u8, name),
            .pattern = try self.allocator.dupe(u8, pattern),
            .script = if (script) |s| try self.allocator.dupe(u8, s) else null,
            .function = function,
            .enabled = true,
            .priority = priority,
            .condition = if (condition) |cond| blk: {
                break :blk switch (cond) {
                    .file_exists => |path| HookCondition{ .file_exists = try self.allocator.dupe(u8, path) },
                    .env_set => |name_str| HookCondition{ .env_set = try self.allocator.dupe(u8, name_str) },
                    .env_equals => |eq| HookCondition{ .env_equals = .{
                        .name = try self.allocator.dupe(u8, eq.name),
                        .value = try self.allocator.dupe(u8, eq.value),
                    } },
                    .always => HookCondition{ .always = {} },
                };
            } else null,
        };
        try self.hooks.append(self.allocator, hook);
    }

    /// Find hooks matching a command
    pub fn findMatchingHooks(self: *CustomHookRegistry, command: []const u8) []const CustomHook {
        var matches: [32]CustomHook = undefined;
        var count: usize = 0;

        for (self.hooks.items) |hook| {
            if (!hook.enabled) continue;
            if (count >= matches.len) break;

            // Check if command starts with pattern
            if (std.mem.startsWith(u8, command, hook.pattern)) {
                // Verify pattern is followed by space or end of command
                if (command.len == hook.pattern.len or
                    (command.len > hook.pattern.len and command[hook.pattern.len] == ' '))
                {
                    matches[count] = hook;
                    count += 1;
                }
            }
        }

        // Sort by priority (lower first)
        const slice = matches[0..count];
        std.mem.sort(CustomHook, slice, {}, struct {
            fn lessThan(_: void, a: CustomHook, b: CustomHook) bool {
                return a.priority < b.priority;
            }
        }.lessThan);

        // Return static slice (caller should copy if needed)
        return slice;
    }

    /// Check if a hook condition is met
    pub fn checkCondition(cond: ?HookCondition) bool {
        const condition = cond orelse return true; // No condition = always run

        switch (condition) {
            .file_exists => |path| {
                _ = std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{}) catch return false;
                return true;
            },
            .env_set => |name| {
                return getenvFromSlice(name) != null;
            },
            .env_equals => |eq| {
                const value = getenvFromSlice(eq.name) orelse return false;
                return std.mem.eql(u8, value, eq.value);
            },
            .always => return true,
        }
    }

    /// Unregister a hook by name
    pub fn unregister(self: *CustomHookRegistry, name: []const u8) bool {
        var i: usize = 0;
        while (i < self.hooks.items.len) {
            if (std.mem.eql(u8, self.hooks.items[i].name, name)) {
                const hook = self.hooks.orderedRemove(i);
                self.allocator.free(hook.name);
                self.allocator.free(hook.pattern);
                if (hook.script) |script| self.allocator.free(script);
                return true;
            }
            i += 1;
        }
        return false;
    }

    /// List all registered hooks
    pub fn list(self: *CustomHookRegistry) []const CustomHook {
        return self.hooks.items;
    }

    /// Enable/disable a hook
    pub fn setEnabled(self: *CustomHookRegistry, name: []const u8, enabled: bool) bool {
        for (self.hooks.items) |*hook| {
            if (std.mem.eql(u8, hook.name, name)) {
                hook.enabled = enabled;
                return true;
            }
        }
        return false;
    }
};

/// Hook function signature
pub const HookFn = *const fn (context: *HookContext) anyerror!void;

/// Hook context passed to hook functions
pub const HookContext = struct {
    hook_type: HookType,
    data: ?*anyopaque, // Hook-specific data
    user_data: ?*anyopaque, // Plugin-specific data
    allocator: std.mem.Allocator,

    /// Get command string (for pre/post_command hooks)
    pub fn getCommand(self: *HookContext) ?[]const u8 {
        if (self.data) |data| {
            // Cast to []const u8
            const cmd: *[]const u8 = @ptrCast(@alignCast(data));
            return cmd.*;
        }
        return null;
    }

    /// Set user data
    pub fn setUserData(self: *HookContext, data: *anyopaque) void {
        self.user_data = data;
    }

    /// Get user data
    pub fn getUserData(self: *HookContext) ?*anyopaque {
        return self.user_data;
    }
};

/// Registered hook
pub const Hook = struct {
    plugin_name: []const u8,
    hook_type: HookType,
    function: HookFn,
    priority: i32, // Lower numbers run first
    enabled: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Hook) void {
        self.allocator.free(self.plugin_name);
    }
};

/// Plugin command function signature
pub const CommandFn = *const fn (args: []const []const u8) anyerror!i32;

/// Registered plugin command
pub const PluginCommand = struct {
    name: []const u8,
    plugin_name: []const u8,
    description: []const u8,
    function: CommandFn,
    enabled: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PluginCommand) void {
        self.allocator.free(self.name);
        self.allocator.free(self.plugin_name);
        self.allocator.free(self.description);
    }

    /// Execute the command
    pub fn execute(self: *PluginCommand, args: []const []const u8) !i32 {
        if (!self.enabled) {
            return error.CommandDisabled;
        }
        return try self.function(args);
    }
};

/// Completion function signature
pub const CompletionFn = *const fn (input: []const u8, allocator: std.mem.Allocator) anyerror![][]const u8;

/// Registered completion provider
pub const CompletionProvider = struct {
    plugin_name: []const u8,
    prefix: []const u8, // Command/path prefix to match
    function: CompletionFn,
    enabled: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CompletionProvider) void {
        self.allocator.free(self.plugin_name);
        self.allocator.free(self.prefix);
    }

    /// Get completions
    pub fn getCompletions(self: *CompletionProvider, input: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
        if (!self.enabled) {
            return &[_][]const u8{};
        }
        return try self.function(input, allocator);
    }
};

/// Plugin Interface Registry - manages hooks, commands, and completions
/// Error statistics for a plugin
pub const PluginErrorStats = struct {
    plugin_name: []const u8,
    hook_errors: u64 = 0,
    command_errors: u64 = 0,
    last_error: ?[]const u8 = null,
    last_error_time: i64 = 0,
};

pub const PluginRegistry = struct {
    allocator: std.mem.Allocator,
    hooks: [6]std.ArrayList(Hook), // One list per HookType
    commands: std.StringHashMap(PluginCommand),
    completions: std.ArrayList(CompletionProvider),
    error_stats: std.StringHashMap(PluginErrorStats), // Error tracking per plugin
    verbose_errors: bool = true, // Whether to print errors to stderr

    pub fn init(allocator: std.mem.Allocator) PluginRegistry {
        var hooks: [6]std.ArrayList(Hook) = undefined;
        inline for (0..6) |i| {
            hooks[i] = .{
                .items = &[_]Hook{},
                .capacity = 0,
            };
        }

        return .{
            .allocator = allocator,
            .hooks = hooks,
            .commands = std.StringHashMap(PluginCommand).init(allocator),
            .completions = .{
                .items = &[_]CompletionProvider{},
                .capacity = 0,
            },
            .error_stats = std.StringHashMap(PluginErrorStats).init(allocator),
            .verbose_errors = true,
        };
    }

    pub fn deinit(self: *PluginRegistry) void {
        // Clean up hooks
        for (&self.hooks) |*hook_list| {
            for (hook_list.items) |*hook| {
                hook.deinit();
            }
            hook_list.deinit(self.allocator);
        }

        // Clean up commands
        var cmd_iter = self.commands.iterator();
        while (cmd_iter.next()) |entry| {
            var cmd = entry.value_ptr;
            cmd.deinit();
        }
        self.commands.deinit();

        // Clean up completions
        for (self.completions.items) |*completion| {
            completion.deinit();
        }
        self.completions.deinit(self.allocator);

        // Clean up error stats
        var stats_iter = self.error_stats.iterator();
        while (stats_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.plugin_name);
            if (entry.value_ptr.last_error) |err_msg| {
                self.allocator.free(err_msg);
            }
        }
        self.error_stats.deinit();
    }

    /// Register a hook
    pub fn registerHook(self: *PluginRegistry, plugin_name: []const u8, hook_type: HookType, function: HookFn, priority: i32) !void {
        const hook = Hook{
            .plugin_name = try self.allocator.dupe(u8, plugin_name),
            .hook_type = hook_type,
            .function = function,
            .priority = priority,
            .enabled = true,
            .allocator = self.allocator,
        };

        const index = @intFromEnum(hook_type);
        try self.hooks[index].append(self.allocator, hook);

        // Sort by priority
        const items = self.hooks[index].items;
        std.mem.sort(Hook, items, {}, hookCompare);
    }

    /// Unregister all hooks for a plugin
    pub fn unregisterHooks(self: *PluginRegistry, plugin_name: []const u8) void {
        for (&self.hooks) |*hook_list| {
            var i: usize = 0;
            while (i < hook_list.items.len) {
                if (std.mem.eql(u8, hook_list.items[i].plugin_name, plugin_name)) {
                    var hook = hook_list.orderedRemove(i);
                    hook.deinit();
                } else {
                    i += 1;
                }
            }
        }
    }

    /// Record an error for a plugin
    fn recordError(self: *PluginRegistry, plugin_name: []const u8, error_type: []const u8, err: anyerror) !void {
        const gop = try self.error_stats.getOrPut(plugin_name);
        if (!gop.found_existing) {
            gop.value_ptr.* = PluginErrorStats{
                .plugin_name = try self.allocator.dupe(u8, plugin_name),
            };
        }

        // Increment appropriate counter
        if (std.mem.eql(u8, error_type, "hook")) {
            gop.value_ptr.hook_errors += 1;
        } else if (std.mem.eql(u8, error_type, "command")) {
            gop.value_ptr.command_errors += 1;
        }

        // Update last error
        if (gop.value_ptr.last_error) |old_err| {
            self.allocator.free(old_err);
        }
        const err_msg = try std.fmt.allocPrint(self.allocator, "{s}: {}", .{ error_type, err });
        gop.value_ptr.last_error = err_msg;
        gop.value_ptr.last_error_time = 0; // Timestamp not available in Zig 0.16
    }

    /// Execute hooks of a specific type
    pub fn executeHooks(self: *PluginRegistry, hook_type: HookType, context: *HookContext) !void {
        const index = @intFromEnum(hook_type);
        for (self.hooks[index].items) |hook| {
            if (hook.enabled) {
                hook.function(context) catch |err| {
                    // Record the error
                    self.recordError(hook.plugin_name, "hook", err) catch {};

                    // Print error if verbose mode is enabled
                    if (self.verbose_errors) {
                        var buf: [512]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "[Plugin Error] {s} hook '{s}' failed: {}\n", .{
                            hook.plugin_name,
                            @tagName(hook_type),
                            err,
                        }) catch "[Plugin Error] Failed to format error message\n";

                        const stderr_file = std.Io.File{ .handle = std.posix.STDERR_FILENO, .flags = .{ .nonblocking = false } };
                        stderr_file.writeStreamingAll(std.Options.debug_io, msg) catch {};
                    }
                };
            }
        }
    }

    /// Register a command
    pub fn registerCommand(self: *PluginRegistry, plugin_name: []const u8, name: []const u8, description: []const u8, function: CommandFn) !void {
        // Check if command already exists
        if (self.commands.contains(name)) {
            return error.CommandAlreadyExists;
        }

        const cmd = PluginCommand{
            .name = try self.allocator.dupe(u8, name),
            .plugin_name = try self.allocator.dupe(u8, plugin_name),
            .description = try self.allocator.dupe(u8, description),
            .function = function,
            .enabled = true,
            .allocator = self.allocator,
        };

        try self.commands.put(cmd.name, cmd);
    }

    /// Unregister all commands for a plugin
    pub fn unregisterCommands(self: *PluginRegistry, plugin_name: []const u8) void {
        var to_remove_buffer: [256][]const u8 = undefined;
        var to_remove_count: usize = 0;

        var iter = self.commands.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.plugin_name, plugin_name)) {
                if (to_remove_count < to_remove_buffer.len) {
                    to_remove_buffer[to_remove_count] = entry.key_ptr.*;
                    to_remove_count += 1;
                }
            }
        }

        for (to_remove_buffer[0..to_remove_count]) |name| {
            if (self.commands.fetchRemove(name)) |kv| {
                var cmd = kv.value;
                cmd.deinit();
            }
        }
    }

    /// Get a command by name
    pub fn getCommand(self: *PluginRegistry, name: []const u8) ?*PluginCommand {
        return self.commands.getPtr(name);
    }

    /// Execute a plugin command
    pub fn executeCommand(self: *PluginRegistry, name: []const u8, args: []const []const u8) !i32 {
        const cmd = self.getCommand(name) orelse return error.CommandNotFound;
        return try cmd.execute(args);
    }

    /// List all registered commands
    pub fn listCommands(self: *PluginRegistry) ![][]const u8 {
        var names_buffer: [256][]const u8 = undefined;
        var count: usize = 0;

        var iter = self.commands.iterator();
        while (iter.next()) |entry| {
            if (count >= names_buffer.len) break;
            names_buffer[count] = entry.key_ptr.*;
            count += 1;
        }

        const names = try self.allocator.alloc([]const u8, count);
        @memcpy(names, names_buffer[0..count]);
        return names;
    }

    /// Register a completion provider
    pub fn registerCompletion(self: *PluginRegistry, plugin_name: []const u8, prefix: []const u8, function: CompletionFn) !void {
        const completion = CompletionProvider{
            .plugin_name = try self.allocator.dupe(u8, plugin_name),
            .prefix = try self.allocator.dupe(u8, prefix),
            .function = function,
            .enabled = true,
            .allocator = self.allocator,
        };

        try self.completions.append(self.allocator, completion);
    }

    /// Unregister all completions for a plugin
    pub fn unregisterCompletions(self: *PluginRegistry, plugin_name: []const u8) void {
        var i: usize = 0;
        while (i < self.completions.items.len) {
            if (std.mem.eql(u8, self.completions.items[i].plugin_name, plugin_name)) {
                var completion = self.completions.orderedRemove(i);
                completion.deinit();
            } else {
                i += 1;
            }
        }
    }

    /// Get completions for input
    pub fn getCompletions(self: *PluginRegistry, input: []const u8) ![][]const u8 {
        var all_completions_buffer: [1000][]const u8 = undefined;
        var all_completions_count: usize = 0;

        for (self.completions.items) |*completion| {
            if (completion.enabled and std.mem.startsWith(u8, input, completion.prefix)) {
                const items = try completion.getCompletions(input, self.allocator);
                for (items) |item| {
                    if (all_completions_count < all_completions_buffer.len) {
                        all_completions_buffer[all_completions_count] = item;
                        all_completions_count += 1;
                    }
                }
                self.allocator.free(items);
            }
        }

        const result = try self.allocator.alloc([]const u8, all_completions_count);
        @memcpy(result, all_completions_buffer[0..all_completions_count]);
        return result;
    }

    /// Get error statistics for a specific plugin
    pub fn getPluginErrors(self: *PluginRegistry, plugin_name: []const u8) ?PluginErrorStats {
        return self.error_stats.get(plugin_name);
    }

    /// Get all plugin error statistics
    pub fn getAllErrors(self: *PluginRegistry) ![]PluginErrorStats {
        var stats_buffer: [256]PluginErrorStats = undefined;
        var count: usize = 0;

        var iter = self.error_stats.iterator();
        while (iter.next()) |entry| {
            if (count >= stats_buffer.len) break;
            stats_buffer[count] = entry.value_ptr.*;
            count += 1;
        }

        const result = try self.allocator.alloc(PluginErrorStats, count);
        @memcpy(result, stats_buffer[0..count]);
        return result;
    }

    /// Clear error statistics for a plugin
    pub fn clearPluginErrors(self: *PluginRegistry, plugin_name: []const u8) void {
        if (self.error_stats.fetchRemove(plugin_name)) |kv| {
            self.allocator.free(kv.value.plugin_name);
            if (kv.value.last_error) |err| {
                self.allocator.free(err);
            }
        }
    }

    /// Set verbose error reporting
    pub fn setVerboseErrors(self: *PluginRegistry, verbose: bool) void {
        self.verbose_errors = verbose;
    }
};

/// Helper function for sorting hooks by priority
fn hookCompare(_: void, a: Hook, b: Hook) bool {
    return a.priority < b.priority;
}
