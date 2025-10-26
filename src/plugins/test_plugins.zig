const std = @import("std");
const plugin_mod = @import("plugin.zig");
const manager_mod = @import("manager.zig");
const builtin_plugins = @import("builtin_plugins.zig");

const Plugin = plugin_mod.Plugin;
const PluginManager = manager_mod.PluginManager;
const PluginState = plugin_mod.PluginState;

test "Plugin Manager - initialization" {
    const allocator = std.testing.allocator;

    var manager = PluginManager.init(allocator);
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 0), manager.getPluginCount());
}

test "Plugin Manager - register built-in plugin" {
    const allocator = std.testing.allocator;

    var manager = PluginManager.init(allocator);
    defer manager.deinit();

    try manager.registerPlugin("hello", "1.0.0", "Hello plugin", builtin_plugins.hello_plugin);

    try std.testing.expectEqual(@as(usize, 1), manager.getPluginCount());

    const state = manager.getPluginState("hello");
    try std.testing.expect(state == .loaded);
}

test "Plugin Manager - plugin lifecycle" {
    const allocator = std.testing.allocator;

    var manager = PluginManager.init(allocator);
    defer manager.deinit();

    // Register plugin
    try manager.registerPlugin("hello", "1.0.0", "Hello plugin", builtin_plugins.hello_plugin);

    // Initial state: loaded
    try std.testing.expect(manager.getPluginState("hello") == .loaded);

    // Initialize
    try manager.initializePlugin("hello");
    try std.testing.expect(manager.getPluginState("hello") == .initialized);

    // Start
    try manager.startPlugin("hello");
    try std.testing.expect(manager.getPluginState("hello") == .started);

    // Execute
    const args = [_][]const u8{ "arg1", "arg2" };
    const exit_code = try manager.executePlugin("hello", &args);
    try std.testing.expectEqual(@as(i32, 0), exit_code);

    // Stop
    try manager.stopPlugin("hello");
    try std.testing.expect(manager.getPluginState("hello") == .stopped);
}

test "Plugin Manager - enable/disable" {
    const allocator = std.testing.allocator;

    var manager = PluginManager.init(allocator);
    defer manager.deinit();

    try manager.registerPlugin("hello", "1.0.0", "Hello plugin", builtin_plugins.hello_plugin);
    try manager.initializePlugin("hello");

    // Should be enabled by default
    const config = manager.getPluginConfig("hello").?;
    try std.testing.expect(config.enabled);

    // Start should work
    try manager.startPlugin("hello");
    try std.testing.expect(manager.getPluginState("hello") == .started);

    // Disable (should stop the plugin)
    try manager.disablePlugin("hello");
    try std.testing.expect(!config.enabled);
    try std.testing.expect(manager.getPluginState("hello") == .stopped);

    // Enable again
    try manager.enablePlugin("hello");
    try std.testing.expect(config.enabled);
}

test "Plugin Manager - configuration" {
    const allocator = std.testing.allocator;

    var manager = PluginManager.init(allocator);
    defer manager.deinit();

    try manager.registerPlugin("counter", "1.0.0", "Counter plugin", builtin_plugins.counter_plugin);

    // Set config before starting
    try manager.setPluginConfig("counter", "initial", "100");

    try manager.initializePlugin("counter");
    try manager.startPlugin("counter");

    // Config should be accessible
    const config = manager.getPluginConfig("counter").?;
    const initial = config.get("initial");
    try std.testing.expect(initial != null);
    try std.testing.expectEqualStrings("100", initial.?);
}

test "Plugin Manager - multiple plugins" {
    const allocator = std.testing.allocator;

    var manager = PluginManager.init(allocator);
    defer manager.deinit();

    // Register multiple plugins
    try manager.registerPlugin("hello", "1.0.0", "Hello plugin", builtin_plugins.hello_plugin);
    try manager.registerPlugin("counter", "1.0.0", "Counter plugin", builtin_plugins.counter_plugin);
    try manager.registerPlugin("echo", "1.0.0", "Echo plugin", builtin_plugins.echo_plugin);

    try std.testing.expectEqual(@as(usize, 3), manager.getPluginCount());

    // Initialize all
    try manager.initializeAll();

    // Start all
    try manager.startAll();

    try std.testing.expectEqual(@as(usize, 3), manager.getRunningCount());

    // Stop all
    try manager.stopAll();

    try std.testing.expectEqual(@as(usize, 0), manager.getRunningCount());
}

test "Plugin Manager - list plugins" {
    const allocator = std.testing.allocator;

    var manager = PluginManager.init(allocator);
    defer manager.deinit();

    try manager.registerPlugin("hello", "1.0.0", "Hello", builtin_plugins.hello_plugin);
    try manager.registerPlugin("counter", "1.0.0", "Counter", builtin_plugins.counter_plugin);

    const names = try manager.listPlugins();
    defer allocator.free(names);

    try std.testing.expectEqual(@as(usize, 2), names.len);
}

test "Plugin Manager - error handling" {
    const allocator = std.testing.allocator;

    var manager = PluginManager.init(allocator);
    defer manager.deinit();

    // Try to start non-existent plugin
    const result = manager.startPlugin("nonexistent");
    try std.testing.expectError(error.PluginNotFound, result);
}

test "Plugin Manager - unload plugin" {
    const allocator = std.testing.allocator;

    var manager = PluginManager.init(allocator);
    defer manager.deinit();

    try manager.registerPlugin("hello", "1.0.0", "Hello", builtin_plugins.hello_plugin);
    try std.testing.expectEqual(@as(usize, 1), manager.getPluginCount());

    try manager.unloadPlugin("hello");
    try std.testing.expectEqual(@as(usize, 0), manager.getPluginCount());
}

test "Plugin - config get/set" {
    const allocator = std.testing.allocator;

    var config = plugin_mod.PluginConfig.init(allocator, "test", "1.0.0");
    defer config.deinit();

    try config.set("key1", "value1");
    try config.set("key2", "value2");

    const val1 = config.get("key1");
    const val2 = config.get("key2");
    const val3 = config.get("key3");

    try std.testing.expect(val1 != null);
    try std.testing.expect(val2 != null);
    try std.testing.expect(val3 == null);

    try std.testing.expectEqualStrings("value1", val1.?);
    try std.testing.expectEqualStrings("value2", val2.?);
}
