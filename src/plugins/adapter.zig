const std = @import("std");
const interface = @import("interface.zig");
const manager = @import("manager.zig");

const HookType = interface.HookType;
const HookContext = interface.HookContext;
const PluginRegistry = interface.PluginRegistry;
const PluginManager = manager.PluginManager;

/// Plugin Adapter provides a simplified interface for the shell to interact
/// with the plugin system.
///
/// This module centralizes plugin lifecycle management to keep shell.zig
/// focused on core state management. It manages:
/// - Plugin initialization and shutdown
/// - Hook dispatch for shell events
/// - Plugin error tracking and reporting
/// - Plugin configuration integration
pub const PluginAdapter = struct {
    allocator: std.mem.Allocator,
    registry: PluginRegistry,
    manager: PluginManager,
    error_count: usize,
    last_error: ?[]const u8,
    hooks_enabled: bool,

    const Self = @This();

    /// Initialize the plugin adapter.
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .registry = PluginRegistry.init(allocator),
            .manager = PluginManager.init(allocator),
            .error_count = 0,
            .last_error = null,
            .hooks_enabled = true,
        };
    }

    /// Deinitialize and cleanup all plugins.
    pub fn deinit(self: *Self) void {
        self.manager.deinit();
        self.registry.deinit();
        if (self.last_error) |err| {
            self.allocator.free(err);
        }
    }

    /// Enable or disable hook dispatch.
    pub fn setHooksEnabled(self: *Self, enabled: bool) void {
        self.hooks_enabled = enabled;
    }

    /// Get the plugin registry for direct access.
    pub fn getRegistry(self: *Self) *PluginRegistry {
        return &self.registry;
    }

    /// Get the plugin manager for direct access.
    pub fn getManager(self: *Self) *PluginManager {
        return &self.manager;
    }

    /// Dispatch a hook to all registered plugins.
    pub fn dispatchHook(self: *Self, hook_type: HookType, ctx: *HookContext) void {
        if (!self.hooks_enabled) return;

        self.registry.executeHooks(hook_type, ctx) catch |err| {
            self.recordError(err);
        };
    }

    /// Dispatch pre-command hook.
    pub fn preCommand(self: *Self, command: []const u8, cwd: []const u8) void {
        if (!self.hooks_enabled) return;

        var ctx = HookContext{
            .command = command,
            .cwd = cwd,
            .exit_code = null,
            .environment = null,
        };
        self.dispatchHook(.pre_command, &ctx);
    }

    /// Dispatch post-command hook.
    pub fn postCommand(self: *Self, command: []const u8, cwd: []const u8, exit_code: i32) void {
        if (!self.hooks_enabled) return;

        var ctx = HookContext{
            .command = command,
            .cwd = cwd,
            .exit_code = exit_code,
            .environment = null,
        };
        self.dispatchHook(.post_command, &ctx);
    }

    /// Dispatch pre-prompt hook.
    pub fn prePrompt(self: *Self, cwd: []const u8) void {
        if (!self.hooks_enabled) return;

        var ctx = HookContext{
            .command = null,
            .cwd = cwd,
            .exit_code = null,
            .environment = null,
        };
        self.dispatchHook(.pre_prompt, &ctx);
    }

    /// Dispatch shell init hook.
    pub fn shellInit(self: *Self) void {
        if (!self.hooks_enabled) return;

        var ctx = HookContext{
            .command = null,
            .cwd = null,
            .exit_code = null,
            .environment = null,
        };
        self.dispatchHook(.shell_init, &ctx);
    }

    /// Dispatch shell exit hook.
    pub fn shellExit(self: *Self, exit_code: i32) void {
        if (!self.hooks_enabled) return;

        var ctx = HookContext{
            .command = null,
            .cwd = null,
            .exit_code = exit_code,
            .environment = null,
        };
        self.dispatchHook(.shell_exit, &ctx);
    }

    /// Record a plugin error.
    fn recordError(self: *Self, err: anyerror) void {
        self.error_count += 1;

        // Store error message
        const err_msg = std.fmt.allocPrint(self.allocator, "Plugin error: {}", .{err}) catch return;
        if (self.last_error) |old| {
            self.allocator.free(old);
        }
        self.last_error = err_msg;
    }

    /// Get error statistics.
    pub fn getErrorCount(self: *const Self) usize {
        return self.error_count;
    }

    /// Get last error message.
    pub fn getLastError(self: *const Self) ?[]const u8 {
        return self.last_error;
    }

    /// Clear error statistics.
    pub fn clearErrors(self: *Self) void {
        self.error_count = 0;
        if (self.last_error) |err| {
            self.allocator.free(err);
            self.last_error = null;
        }
    }

    /// Check if any plugins are registered.
    pub fn hasPlugins(self: *const Self) bool {
        return self.registry.count() > 0;
    }

    /// Get count of registered plugins.
    pub fn pluginCount(self: *const Self) usize {
        return self.registry.count();
    }
};

// ========================================
// Tests
// ========================================

test "PluginAdapter init and deinit" {
    const allocator = std.testing.allocator;
    var adapter = PluginAdapter.init(allocator);
    defer adapter.deinit();

    try std.testing.expect(adapter.hooks_enabled);
    try std.testing.expectEqual(@as(usize, 0), adapter.error_count);
}

test "PluginAdapter setHooksEnabled" {
    const allocator = std.testing.allocator;
    var adapter = PluginAdapter.init(allocator);
    defer adapter.deinit();

    adapter.setHooksEnabled(false);
    try std.testing.expect(!adapter.hooks_enabled);
}

test "PluginAdapter clearErrors" {
    const allocator = std.testing.allocator;
    var adapter = PluginAdapter.init(allocator);
    defer adapter.deinit();

    adapter.error_count = 5;
    adapter.clearErrors();
    try std.testing.expectEqual(@as(usize, 0), adapter.error_count);
}
