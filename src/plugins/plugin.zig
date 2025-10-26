const std = @import("std");

/// Plugin lifecycle state
pub const PluginState = enum {
    unloaded,
    loaded,
    initialized,
    started,
    stopped,
    error_state,
};

/// Plugin configuration
pub const PluginConfig = struct {
    name: []const u8,
    version: []const u8,
    enabled: bool,
    auto_start: bool,
    config_data: std.StringHashMap([]const u8), // Key-value config
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, version: []const u8) PluginConfig {
        return .{
            .name = name,
            .version = version,
            .enabled = true,
            .auto_start = true,
            .config_data = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PluginConfig) void {
        var iter = self.config_data.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.config_data.deinit();
    }

    pub fn set(self: *PluginConfig, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.config_data.put(key_copy, value_copy);
    }

    pub fn get(self: *PluginConfig, key: []const u8) ?[]const u8 {
        return self.config_data.get(key);
    }
};

/// Plugin metadata
pub const PluginInfo = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    author: []const u8,
    path: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PluginInfo) void {
        self.allocator.free(self.name);
        self.allocator.free(self.version);
        self.allocator.free(self.description);
        self.allocator.free(self.author);
        self.allocator.free(self.path);
    }
};

/// Plugin interface - plugins must implement these lifecycle hooks
pub const PluginInterface = struct {
    /// Initialize plugin (called once after loading)
    init_fn: ?*const fn (config: *PluginConfig) anyerror!void,

    /// Start plugin (called when plugin is activated)
    start_fn: ?*const fn (config: *PluginConfig) anyerror!void,

    /// Stop plugin (called when plugin is deactivated)
    stop_fn: ?*const fn () anyerror!void,

    /// Shutdown plugin (called before unloading)
    shutdown_fn: ?*const fn () anyerror!void,

    /// Execute plugin command
    execute_fn: ?*const fn (args: []const []const u8) anyerror!i32,
};

/// Plugin instance
pub const Plugin = struct {
    info: PluginInfo,
    config: PluginConfig,
    interface: PluginInterface,
    state: PluginState,
    error_message: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, info: PluginInfo, config: PluginConfig, interface: PluginInterface) Plugin {
        return .{
            .info = info,
            .config = config,
            .interface = interface,
            .state = .loaded,
            .error_message = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Plugin) void {
        self.info.deinit();
        self.config.deinit();
        if (self.error_message) |msg| {
            self.allocator.free(msg);
        }
    }

    /// Initialize the plugin
    pub fn initialize(self: *Plugin) !void {
        if (self.state != .loaded) {
            return error.InvalidState;
        }

        if (self.interface.init_fn) |init_fn| {
            init_fn(&self.config) catch |err| {
                self.state = .error_state;
                self.error_message = try std.fmt.allocPrint(
                    self.allocator,
                    "Init failed: {}",
                    .{err},
                );
                return err;
            };
        }

        self.state = .initialized;
    }

    /// Start the plugin
    pub fn start(self: *Plugin) !void {
        if (self.state != .initialized and self.state != .stopped) {
            return error.InvalidState;
        }

        if (!self.config.enabled) {
            return error.PluginDisabled;
        }

        if (self.interface.start_fn) |start_fn| {
            start_fn(&self.config) catch |err| {
                self.state = .error_state;
                self.error_message = try std.fmt.allocPrint(
                    self.allocator,
                    "Start failed: {}",
                    .{err},
                );
                return err;
            };
        }

        self.state = .started;
    }

    /// Stop the plugin
    pub fn stop(self: *Plugin) !void {
        if (self.state != .started) {
            return error.InvalidState;
        }

        if (self.interface.stop_fn) |stop_fn| {
            stop_fn() catch |err| {
                self.state = .error_state;
                self.error_message = try std.fmt.allocPrint(
                    self.allocator,
                    "Stop failed: {}",
                    .{err},
                );
                return err;
            };
        }

        self.state = .stopped;
    }

    /// Shutdown the plugin
    pub fn shutdown(self: *Plugin) !void {
        // Stop if running
        if (self.state == .started) {
            try self.stop();
        }

        if (self.interface.shutdown_fn) |shutdown_fn| {
            shutdown_fn() catch |err| {
                self.state = .error_state;
                self.error_message = try std.fmt.allocPrint(
                    self.allocator,
                    "Shutdown failed: {}",
                    .{err},
                );
                return err;
            };
        }

        self.state = .unloaded;
    }

    /// Execute plugin command
    pub fn execute(self: *Plugin, args: []const []const u8) !i32 {
        if (self.state != .started) {
            return error.PluginNotStarted;
        }

        if (self.interface.execute_fn) |execute_fn| {
            return execute_fn(args) catch |err| {
                self.error_message = try std.fmt.allocPrint(
                    self.allocator,
                    "Execute failed: {}",
                    .{err},
                );
                return err;
            };
        }

        return 0;
    }

    /// Enable plugin
    pub fn enable(self: *Plugin) void {
        self.config.enabled = true;
    }

    /// Disable plugin
    pub fn disable(self: *Plugin) !void {
        if (self.state == .started) {
            try self.stop();
        }
        self.config.enabled = false;
    }
};
