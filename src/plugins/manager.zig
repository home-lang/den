const std = @import("std");
const plugin_mod = @import("plugin.zig");
const Plugin = plugin_mod.Plugin;
const PluginInfo = plugin_mod.PluginInfo;
const PluginConfig = plugin_mod.PluginConfig;
const PluginInterface = plugin_mod.PluginInterface;
const PluginState = plugin_mod.PluginState;

/// Plugin Manager - manages loading, lifecycle, and execution of plugins
pub const PluginManager = struct {
    allocator: std.mem.Allocator,
    plugins: std.StringHashMap(Plugin),
    plugin_paths: [32]?[]const u8,
    plugin_paths_count: usize,
    auto_reload: bool,

    pub fn init(allocator: std.mem.Allocator) PluginManager {
        return .{
            .allocator = allocator,
            .plugins = std.StringHashMap(Plugin).init(allocator),
            .plugin_paths = [_]?[]const u8{null} ** 32,
            .plugin_paths_count = 0,
            .auto_reload = false,
        };
    }

    pub fn deinit(self: *PluginManager) void {
        // Shutdown all plugins
        var iter = self.plugins.iterator();
        while (iter.next()) |entry| {
            var plugin = entry.value_ptr;
            plugin.shutdown() catch |err| {
                // Log shutdown errors but continue cleanup
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "[Plugin Manager] Warning: Failed to shutdown plugin '{s}': {}\n", .{
                    entry.key_ptr.*,
                    err,
                }) catch "[Plugin Manager] Warning: Shutdown failed\n";

                const stderr_file = std.Io.File{ .handle = std.posix.STDERR_FILENO, .flags = .{ .nonblocking = false } };
                stderr_file.writeStreamingAll(std.Options.debug_io, msg) catch {};
            };
            plugin.deinit();
            // Free the key
            self.allocator.free(entry.key_ptr.*);
        }
        self.plugins.deinit();

        // Free plugin paths
        for (self.plugin_paths) |maybe_path| {
            if (maybe_path) |path| {
                self.allocator.free(path);
            }
        }
    }

    /// Add a plugin search path
    pub fn addPluginPath(self: *PluginManager, path: []const u8) !void {
        if (self.plugin_paths_count >= self.plugin_paths.len) {
            return error.TooManyPaths;
        }

        const path_copy = try self.allocator.dupe(u8, path);
        self.plugin_paths[self.plugin_paths_count] = path_copy;
        self.plugin_paths_count += 1;
    }

    /// Load a plugin from a path (simulated for now - real implementation would use dynamic loading)
    pub fn loadPluginFromPath(self: *PluginManager, path: []const u8, name: []const u8) !void {
        // Check if already loaded
        if (self.plugins.contains(name)) {
            return error.PluginAlreadyLoaded;
        }

        // Create plugin info
        const info = PluginInfo{
            .name = try self.allocator.dupe(u8, name),
            .version = try self.allocator.dupe(u8, "1.0.0"),
            .description = try self.allocator.dupe(u8, "Plugin loaded from path"),
            .author = try self.allocator.dupe(u8, "Unknown"),
            .path = try self.allocator.dupe(u8, path),
            .allocator = self.allocator,
        };

        // Create default config
        const config = PluginConfig.init(self.allocator, name, "1.0.0");

        // Create interface with no-op functions for now
        // Real implementation would load these from shared library
        const interface = PluginInterface{
            .init_fn = null,
            .start_fn = null,
            .stop_fn = null,
            .shutdown_fn = null,
            .execute_fn = null,
        };

        // Create plugin
        const plugin = Plugin.init(self.allocator, info, config, interface);

        // Store plugin
        const key = try self.allocator.dupe(u8, name);
        try self.plugins.put(key, plugin);
    }

    /// Register a built-in plugin
    pub fn registerPlugin(
        self: *PluginManager,
        name: []const u8,
        version: []const u8,
        description: []const u8,
        interface: PluginInterface,
    ) !void {
        // Check if already registered
        if (self.plugins.contains(name)) {
            return error.PluginAlreadyRegistered;
        }

        // Create plugin info
        const info = PluginInfo{
            .name = try self.allocator.dupe(u8, name),
            .version = try self.allocator.dupe(u8, version),
            .description = try self.allocator.dupe(u8, description),
            .author = try self.allocator.dupe(u8, "Built-in"),
            .path = try self.allocator.dupe(u8, "built-in"),
            .allocator = self.allocator,
        };

        // Create default config
        const config = PluginConfig.init(self.allocator, name, version);

        // Create plugin
        const plugin = Plugin.init(self.allocator, info, config, interface);

        // Store plugin
        const key = try self.allocator.dupe(u8, name);
        try self.plugins.put(key, plugin);
    }

    /// Unload a plugin
    pub fn unloadPlugin(self: *PluginManager, name: []const u8) !void {
        if (self.plugins.fetchRemove(name)) |entry| {
            var plugin = entry.value;
            try plugin.shutdown();
            plugin.deinit();
            self.allocator.free(entry.key);
        } else {
            return error.PluginNotFound;
        }
    }

    /// Initialize a plugin
    pub fn initializePlugin(self: *PluginManager, name: []const u8) !void {
        const plugin = self.plugins.getPtr(name) orelse return error.PluginNotFound;
        try plugin.initialize();
    }

    /// Start a plugin
    pub fn startPlugin(self: *PluginManager, name: []const u8) !void {
        const plugin = self.plugins.getPtr(name) orelse return error.PluginNotFound;
        try plugin.start();
    }

    /// Stop a plugin
    pub fn stopPlugin(self: *PluginManager, name: []const u8) !void {
        const plugin = self.plugins.getPtr(name) orelse return error.PluginNotFound;
        try plugin.stop();
    }

    /// Enable a plugin
    pub fn enablePlugin(self: *PluginManager, name: []const u8) !void {
        const plugin = self.plugins.getPtr(name) orelse return error.PluginNotFound;
        plugin.enable();
    }

    /// Disable a plugin
    pub fn disablePlugin(self: *PluginManager, name: []const u8) !void {
        const plugin = self.plugins.getPtr(name) orelse return error.PluginNotFound;
        try plugin.disable();
    }

    /// Execute a plugin command
    pub fn executePlugin(self: *PluginManager, name: []const u8, args: []const []const u8) !i32 {
        const plugin = self.plugins.getPtr(name) orelse return error.PluginNotFound;
        return try plugin.execute(args);
    }

    /// Get plugin info
    pub fn getPluginInfo(self: *PluginManager, name: []const u8) ?*const PluginInfo {
        const plugin = self.plugins.getPtr(name) orelse return null;
        return &plugin.info;
    }

    /// Get plugin state
    pub fn getPluginState(self: *PluginManager, name: []const u8) ?PluginState {
        const plugin = self.plugins.get(name) orelse return null;
        return plugin.state;
    }

    /// Get plugin config
    pub fn getPluginConfig(self: *PluginManager, name: []const u8) ?*PluginConfig {
        const plugin = self.plugins.getPtr(name) orelse return null;
        return &plugin.config;
    }

    /// Set plugin config value
    pub fn setPluginConfig(self: *PluginManager, name: []const u8, key: []const u8, value: []const u8) !void {
        const plugin = self.plugins.getPtr(name) orelse return error.PluginNotFound;
        try plugin.config.set(key, value);
    }

    /// List all plugins
    pub fn listPlugins(self: *PluginManager) ![][]const u8 {
        var names_buffer: [256][]const u8 = undefined;
        var count: usize = 0;

        var iter = self.plugins.iterator();
        while (iter.next()) |entry| {
            if (count >= names_buffer.len) break;
            names_buffer[count] = entry.key_ptr.*;
            count += 1;
        }

        const names = try self.allocator.alloc([]const u8, count);
        @memcpy(names, names_buffer[0..count]);
        return names;
    }

    /// Initialize all plugins
    pub fn initializeAll(self: *PluginManager) !void {
        var iter = self.plugins.iterator();
        while (iter.next()) |entry| {
            var plugin = entry.value_ptr;
            if (plugin.state == .loaded) {
                plugin.initialize() catch |err| {
                    std.debug.print("Failed to initialize plugin '{s}': {}\n", .{ plugin.info.name, err });
                };
            }
        }
    }

    /// Start all enabled plugins
    pub fn startAll(self: *PluginManager) !void {
        var iter = self.plugins.iterator();
        while (iter.next()) |entry| {
            var plugin = entry.value_ptr;
            if (plugin.config.enabled and plugin.config.auto_start) {
                if (plugin.state == .initialized or plugin.state == .stopped) {
                    plugin.start() catch |err| {
                        std.debug.print("Failed to start plugin '{s}': {}\n", .{ plugin.info.name, err });
                    };
                }
            }
        }
    }

    /// Stop all running plugins
    pub fn stopAll(self: *PluginManager) !void {
        var iter = self.plugins.iterator();
        while (iter.next()) |entry| {
            var plugin = entry.value_ptr;
            if (plugin.state == .started) {
                plugin.stop() catch |err| {
                    std.debug.print("Failed to stop plugin '{s}': {}\n", .{ plugin.info.name, err });
                };
            }
        }
    }

    /// Reload a plugin (stop, unload, load, initialize, start)
    pub fn reloadPlugin(self: *PluginManager, name: []const u8) !void {
        // Get current config and path
        const plugin = self.plugins.get(name) orelse return error.PluginNotFound;
        const path = try self.allocator.dupe(u8, plugin.info.path);
        const was_enabled = plugin.config.enabled;
        const was_auto_start = plugin.config.auto_start;
        defer self.allocator.free(path);

        // Unload
        try self.unloadPlugin(name);

        // Reload
        try self.loadPluginFromPath(path, name);

        // Restore config
        if (self.plugins.getPtr(name)) |new_plugin| {
            new_plugin.config.enabled = was_enabled;
            new_plugin.config.auto_start = was_auto_start;

            // Initialize and start if needed
            try new_plugin.initialize();
            if (was_enabled and was_auto_start) {
                try new_plugin.start();
            }
        }
    }

    /// Get plugin count
    pub fn getPluginCount(self: *PluginManager) usize {
        return self.plugins.count();
    }

    /// Get running plugin count
    pub fn getRunningCount(self: *PluginManager) usize {
        var count: usize = 0;
        var iter = self.plugins.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.state == .started) {
                count += 1;
            }
        }
        return count;
    }
};
