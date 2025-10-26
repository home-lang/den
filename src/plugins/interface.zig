const std = @import("std");

/// Hook types that plugins can register
pub const HookType = enum {
    pre_command,   // Before command execution
    post_command,  // After command execution
    pre_prompt,    // Before showing prompt
    post_prompt,   // After prompt input
    shell_init,    // Shell initialization
    shell_exit,    // Shell exit
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
pub const PluginRegistry = struct {
    allocator: std.mem.Allocator,
    hooks: [6]std.ArrayList(Hook), // One list per HookType
    commands: std.StringHashMap(PluginCommand),
    completions: std.ArrayList(CompletionProvider),

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

    /// Execute hooks of a specific type
    pub fn executeHooks(self: *PluginRegistry, hook_type: HookType, context: *HookContext) !void {
        const index = @intFromEnum(hook_type);
        for (self.hooks[index].items) |hook| {
            if (hook.enabled) {
                hook.function(context) catch |err| {
                    std.debug.print("Hook error ({s}): {}\n", .{ hook.plugin_name, err });
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
};

/// Helper function for sorting hooks by priority
fn hookCompare(_: void, a: Hook, b: Hook) bool {
    return a.priority < b.priority;
}
