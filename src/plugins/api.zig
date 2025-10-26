const std = @import("std");
const interface_mod = @import("interface.zig");

const HookType = interface_mod.HookType;
const HookFn = interface_mod.HookFn;
const CommandFn = interface_mod.CommandFn;
const CompletionFn = interface_mod.CompletionFn;
const PluginRegistry = interface_mod.PluginRegistry;

/// Log level for plugin logging
pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,
};

/// Plugin API - provides access to shell functionality
pub const PluginAPI = struct {
    allocator: std.mem.Allocator,
    plugin_name: []const u8,
    registry: *PluginRegistry,
    config: std.StringHashMap([]const u8),
    logger: Logger,

    pub fn init(allocator: std.mem.Allocator, plugin_name: []const u8, registry: *PluginRegistry) !PluginAPI {
        return .{
            .allocator = allocator,
            .plugin_name = try allocator.dupe(u8, plugin_name),
            .registry = registry,
            .config = std.StringHashMap([]const u8).init(allocator),
            .logger = Logger.init(allocator, plugin_name),
        };
    }

    pub fn deinit(self: *PluginAPI) void {
        self.allocator.free(self.plugin_name);

        var iter = self.config.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.config.deinit();
    }

    // === Hook Registration API ===

    /// Register a hook with the plugin registry
    pub fn registerHook(
        self: *PluginAPI,
        hook_type: HookType,
        function: HookFn,
        priority: i32,
    ) !void {
        try self.registry.registerHook(self.plugin_name, hook_type, function, priority);
        try self.logger.log(.info, "Registered hook: {s}", .{@tagName(hook_type)});
    }

    /// Unregister all hooks for this plugin
    pub fn unregisterHooks(self: *PluginAPI) void {
        self.registry.unregisterHooks(self.plugin_name);
        self.logger.log(.info, "Unregistered all hooks", .{}) catch {};
    }

    // === Command Registration API ===

    /// Register a command with the plugin registry
    pub fn registerCommand(
        self: *PluginAPI,
        name: []const u8,
        description: []const u8,
        function: CommandFn,
    ) !void {
        try self.registry.registerCommand(self.plugin_name, name, description, function);
        try self.logger.log(.info, "Registered command: {s}", .{name});
    }

    /// Unregister all commands for this plugin
    pub fn unregisterCommands(self: *PluginAPI) void {
        self.registry.unregisterCommands(self.plugin_name);
        self.logger.log(.info, "Unregistered all commands", .{}) catch {};
    }

    // === Completion Registration API ===

    /// Register a completion provider
    pub fn registerCompletion(
        self: *PluginAPI,
        prefix: []const u8,
        function: CompletionFn,
    ) !void {
        try self.registry.registerCompletion(self.plugin_name, prefix, function);
        try self.logger.log(.info, "Registered completion for: {s}", .{prefix});
    }

    /// Unregister all completions for this plugin
    pub fn unregisterCompletions(self: *PluginAPI) void {
        self.registry.unregisterCompletions(self.plugin_name);
        self.logger.log(.info, "Unregistered all completions", .{}) catch {};
    }

    // === Configuration API ===

    /// Set a configuration value
    pub fn setConfig(self: *PluginAPI, key: []const u8, value: []const u8) !void {
        // Remove old value if exists
        if (self.config.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }

        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);

        try self.config.put(key_copy, value_copy);
        try self.logger.log(.debug, "Config set: {s} = {s}", .{ key, value });
    }

    /// Get a configuration value
    pub fn getConfig(self: *PluginAPI, key: []const u8) ?[]const u8 {
        return self.config.get(key);
    }

    /// Get a configuration value with a default
    pub fn getConfigOr(self: *PluginAPI, key: []const u8, default: []const u8) []const u8 {
        return self.config.get(key) orelse default;
    }

    /// Check if a configuration key exists
    pub fn hasConfig(self: *PluginAPI, key: []const u8) bool {
        return self.config.contains(key);
    }

    // === Logging API ===

    /// Log a message at debug level
    pub fn logDebug(self: *PluginAPI, comptime format: []const u8, args: anytype) !void {
        try self.logger.log(.debug, format, args);
    }

    /// Log a message at info level
    pub fn logInfo(self: *PluginAPI, comptime format: []const u8, args: anytype) !void {
        try self.logger.log(.info, format, args);
    }

    /// Log a message at warn level
    pub fn logWarn(self: *PluginAPI, comptime format: []const u8, args: anytype) !void {
        try self.logger.log(.warn, format, args);
    }

    /// Log a message at error level
    pub fn logError(self: *PluginAPI, comptime format: []const u8, args: anytype) !void {
        try self.logger.log(.err, format, args);
    }

    // === Utility Functions ===

    /// Split a string by delimiter
    pub fn splitString(self: *PluginAPI, string: []const u8, delimiter: u8) ![][]const u8 {
        var parts_buffer: [64][]const u8 = undefined;
        var parts_count: usize = 0;

        var iter = std.mem.splitScalar(u8, string, delimiter);
        while (iter.next()) |part| {
            if (parts_count < parts_buffer.len) {
                parts_buffer[parts_count] = try self.allocator.dupe(u8, part);
                parts_count += 1;
            }
        }

        const result = try self.allocator.alloc([]const u8, parts_count);
        @memcpy(result, parts_buffer[0..parts_count]);
        return result;
    }

    /// Join strings with delimiter
    pub fn joinStrings(self: *PluginAPI, strings: []const []const u8, delimiter: []const u8) ![]const u8 {
        if (strings.len == 0) {
            return try self.allocator.dupe(u8, "");
        }

        // Calculate total length
        var total_len: usize = 0;
        for (strings, 0..) |str, i| {
            total_len += str.len;
            if (i < strings.len - 1) {
                total_len += delimiter.len;
            }
        }

        // Allocate and build result
        var result = try self.allocator.alloc(u8, total_len);
        var offset: usize = 0;

        for (strings, 0..) |str, i| {
            @memcpy(result[offset .. offset + str.len], str);
            offset += str.len;

            if (i < strings.len - 1) {
                @memcpy(result[offset .. offset + delimiter.len], delimiter);
                offset += delimiter.len;
            }
        }

        return result;
    }

    /// Trim whitespace from string
    pub fn trimString(self: *PluginAPI, string: []const u8) ![]const u8 {
        const trimmed = std.mem.trim(u8, string, &std.ascii.whitespace);
        return try self.allocator.dupe(u8, trimmed);
    }

    /// Check if string starts with prefix
    pub fn startsWith(_: *PluginAPI, string: []const u8, prefix: []const u8) bool {
        return std.mem.startsWith(u8, string, prefix);
    }

    /// Check if string ends with suffix
    pub fn endsWith(_: *PluginAPI, string: []const u8, suffix: []const u8) bool {
        return std.mem.endsWith(u8, string, suffix);
    }

    /// Get current timestamp in milliseconds
    pub fn timestamp(_: *PluginAPI) i64 {
        return std.time.milliTimestamp();
    }
};

/// Logger for plugin messages
pub const Logger = struct {
    allocator: std.mem.Allocator,
    plugin_name: []const u8,
    min_level: LogLevel,

    pub fn init(allocator: std.mem.Allocator, plugin_name: []const u8) Logger {
        return .{
            .allocator = allocator,
            .plugin_name = plugin_name,
            .min_level = .info,
        };
    }

    pub fn log(self: *Logger, level: LogLevel, comptime format: []const u8, args: anytype) !void {
        if (@intFromEnum(level) < @intFromEnum(self.min_level)) {
            return;
        }

        const level_str = switch (level) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };

        const message = try std.fmt.allocPrint(self.allocator, format, args);
        defer self.allocator.free(message);

        std.debug.print("[{s}] [{s}] {s}\n", .{ self.plugin_name, level_str, message });
    }

    pub fn setMinLevel(self: *Logger, level: LogLevel) void {
        self.min_level = level;
    }
};

/// Plugin context - wrapper around PluginAPI for easier use
pub const PluginContext = struct {
    api: *PluginAPI,

    pub fn init(api: *PluginAPI) PluginContext {
        return .{ .api = api };
    }

    /// Get plugin name
    pub fn getName(self: PluginContext) []const u8 {
        return self.api.plugin_name;
    }

    /// Get allocator
    pub fn getAllocator(self: PluginContext) std.mem.Allocator {
        return self.api.allocator;
    }

    /// Register hook
    pub fn hook(self: PluginContext, hook_type: HookType, function: HookFn, priority: i32) !void {
        try self.api.registerHook(hook_type, function, priority);
    }

    /// Register command
    pub fn command(self: PluginContext, name: []const u8, description: []const u8, function: CommandFn) !void {
        try self.api.registerCommand(name, description, function);
    }

    /// Register completion
    pub fn completion(self: PluginContext, prefix: []const u8, function: CompletionFn) !void {
        try self.api.registerCompletion(prefix, function);
    }

    /// Log info message
    pub fn log(self: PluginContext, comptime format: []const u8, args: anytype) !void {
        try self.api.logInfo(format, args);
    }

    /// Get config value
    pub fn config(self: PluginContext, key: []const u8) ?[]const u8 {
        return self.api.getConfig(key);
    }
};
