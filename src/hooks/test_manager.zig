const std = @import("std");
const manager_mod = @import("manager.zig");
const interface_mod = manager_mod.interface_mod;
pub const interface = interface_mod;

const HookManager = manager_mod.HookManager;
const HookOptions = manager_mod.HookOptions;
const HookType = interface_mod.HookType;
const HookContext = interface_mod.HookContext;

// Test hook functions
var test_hook_called = false;
var test_hook_call_count: usize = 0;

fn testHook(ctx: *HookContext) !void {
    _ = ctx;
    test_hook_called = true;
    test_hook_call_count += 1;
}

fn slowHook(ctx: *HookContext) !void {
    _ = ctx;
    std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromNanoseconds(@as(i96, 100_000_000)), .awake) catch {}; // Sleep for 100ms
    test_hook_called = true;
}

fn errorHook(ctx: *HookContext) !void {
    _ = ctx;
    return error.TestError;
}

fn priorityHook1(ctx: *HookContext) !void {
    _ = ctx;
    test_hook_call_count = 1;
}

fn priorityHook2(ctx: *HookContext) !void {
    _ = ctx;
    test_hook_call_count = 2;
}

fn priorityHook3(ctx: *HookContext) !void {
    _ = ctx;
    test_hook_call_count = 3;
}

test "HookManager - initialization" {
    const allocator = std.testing.allocator;

    var manager = HookManager.init(allocator);
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 0), manager.getHookCount(.pre_command));
    try std.testing.expectEqual(@as(usize, 0), manager.getHookCount(.post_command));
}

test "HookManager - register hook" {
    const allocator = std.testing.allocator;

    var manager = HookManager.init(allocator);
    defer manager.deinit();

    try manager.registerHook("test-plugin", .pre_command, testHook, 0);

    try std.testing.expectEqual(@as(usize, 1), manager.getHookCount(.pre_command));
}

test "HookManager - register multiple hooks" {
    const allocator = std.testing.allocator;

    var manager = HookManager.init(allocator);
    defer manager.deinit();

    try manager.registerHook("plugin1", .pre_command, testHook, 0);
    try manager.registerHook("plugin2", .pre_command, testHook, 0);
    try manager.registerHook("plugin3", .post_command, testHook, 0);

    try std.testing.expectEqual(@as(usize, 2), manager.getHookCount(.pre_command));
    try std.testing.expectEqual(@as(usize, 1), manager.getHookCount(.post_command));
}

test "HookManager - unregister hooks" {
    const allocator = std.testing.allocator;

    var manager = HookManager.init(allocator);
    defer manager.deinit();

    try manager.registerHook("plugin1", .pre_command, testHook, 0);
    try manager.registerHook("plugin1", .post_command, testHook, 0);
    try manager.registerHook("plugin2", .pre_command, testHook, 0);

    try std.testing.expectEqual(@as(usize, 2), manager.getHookCount(.pre_command));

    manager.unregisterHooks("plugin1");

    try std.testing.expectEqual(@as(usize, 1), manager.getHookCount(.pre_command));
    try std.testing.expectEqual(@as(usize, 0), manager.getHookCount(.post_command));
}

test "HookManager - execute hooks" {
    const allocator = std.testing.allocator;

    var manager = HookManager.init(allocator);
    defer manager.deinit();

    test_hook_called = false;
    test_hook_call_count = 0;

    try manager.registerHook("test-plugin", .pre_command, testHook, 0);

    var context = HookContext{
        .hook_type = .pre_command,
        .data = null,
        .user_data = null,
        .allocator = allocator,
    };

    const options = HookOptions{
        .timeout_ms = 1000,
        .async_exec = false,
        .continue_on_error = true,
    };

    const results = try manager.executeHooks(.pre_command, &context, options);
    defer {
        for (results) |*result| {
            var r = result.*;
            r.deinit(allocator);
        }
        allocator.free(results);
    }

    try std.testing.expect(test_hook_called);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(results[0].success);
}

test "HookManager - hook priority ordering" {
    const allocator = std.testing.allocator;

    var manager = HookManager.init(allocator);
    defer manager.deinit();

    test_hook_call_count = 0;

    // Register hooks with different priorities (lower runs first)
    try manager.registerHook("plugin3", .pre_command, priorityHook3, 30);
    try manager.registerHook("plugin1", .pre_command, priorityHook1, 10);
    try manager.registerHook("plugin2", .pre_command, priorityHook2, 20);

    var context = HookContext{
        .hook_type = .pre_command,
        .data = null,
        .user_data = null,
        .allocator = allocator,
    };

    const options = HookOptions{
        .timeout_ms = 1000,
        .async_exec = false,
        .continue_on_error = true,
    };

    const results = try manager.executeHooks(.pre_command, &context, options);
    defer {
        for (results) |*result| {
            var r = result.*;
            r.deinit(allocator);
        }
        allocator.free(results);
    }

    // Last hook sets it to 3, but priority should ensure hook1 runs last
    try std.testing.expectEqual(@as(usize, 3), test_hook_call_count);
}

test "HookManager - hook error handling" {
    const allocator = std.testing.allocator;

    var manager = HookManager.init(allocator);
    defer manager.deinit();

    try manager.registerHook("error-plugin", .pre_command, errorHook, 0);

    var context = HookContext{
        .hook_type = .pre_command,
        .data = null,
        .user_data = null,
        .allocator = allocator,
    };

    const options = HookOptions{
        .timeout_ms = 1000,
        .async_exec = false,
        .continue_on_error = true,
    };

    const results = try manager.executeHooks(.pre_command, &context, options);
    defer {
        for (results) |*result| {
            var r = result.*;
            r.deinit(allocator);
        }
        allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(!results[0].success);
    try std.testing.expect(results[0].error_message != null);
}

test "HookManager - continue on error" {
    const allocator = std.testing.allocator;

    var manager = HookManager.init(allocator);
    defer manager.deinit();

    test_hook_called = false;

    try manager.registerHook("error-plugin", .pre_command, errorHook, 10);
    try manager.registerHook("good-plugin", .pre_command, testHook, 20);

    var context = HookContext{
        .hook_type = .pre_command,
        .data = null,
        .user_data = null,
        .allocator = allocator,
    };

    const options = HookOptions{
        .timeout_ms = 1000,
        .async_exec = false,
        .continue_on_error = true,
    };

    const results = try manager.executeHooks(.pre_command, &context, options);
    defer {
        for (results) |*result| {
            var r = result.*;
            r.deinit(allocator);
        }
        allocator.free(results);
    }

    // Both hooks should have executed
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expect(!results[0].success);
    try std.testing.expect(results[1].success);
    try std.testing.expect(test_hook_called);
}

test "HookManager - stop on error" {
    const allocator = std.testing.allocator;

    var manager = HookManager.init(allocator);
    defer manager.deinit();

    test_hook_called = false;

    try manager.registerHook("error-plugin", .pre_command, errorHook, 10);
    try manager.registerHook("good-plugin", .pre_command, testHook, 20);

    var context = HookContext{
        .hook_type = .pre_command,
        .data = null,
        .user_data = null,
        .allocator = allocator,
    };

    const options = HookOptions{
        .timeout_ms = 1000,
        .async_exec = false,
        .continue_on_error = false,
    };

    const results = try manager.executeHooks(.pre_command, &context, options);
    defer {
        for (results) |*result| {
            var r = result.*;
            r.deinit(allocator);
        }
        allocator.free(results);
    }

    // Only first hook should have executed
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(!results[0].success);
    try std.testing.expect(!test_hook_called);
}

test "HookManager - enable/disable hooks" {
    const allocator = std.testing.allocator;

    var manager = HookManager.init(allocator);
    defer manager.deinit();

    test_hook_called = false;

    try manager.registerHook("test-plugin", .pre_command, testHook, 0);

    // Disable the hook
    manager.setHookEnabled("test-plugin", .pre_command, false);

    var context = HookContext{
        .hook_type = .pre_command,
        .data = null,
        .user_data = null,
        .allocator = allocator,
    };

    const options = HookOptions{
        .timeout_ms = 1000,
        .async_exec = false,
        .continue_on_error = true,
    };

    const results = try manager.executeHooks(.pre_command, &context, options);
    defer allocator.free(results);

    // Hook should not have been called
    try std.testing.expect(!test_hook_called);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "HookManager - list hooks" {
    const allocator = std.testing.allocator;

    var manager = HookManager.init(allocator);
    defer manager.deinit();

    try manager.registerHook("plugin1", .pre_command, testHook, 10);
    try manager.registerHook("plugin2", .pre_command, testHook, 20);

    const hooks = manager.listHooks(.pre_command);

    try std.testing.expectEqual(@as(usize, 2), hooks.len);
    try std.testing.expectEqualStrings("plugin1", hooks[0].plugin_name);
    try std.testing.expectEqualStrings("plugin2", hooks[1].plugin_name);
}

test "HookManager - set default timeout" {
    const allocator = std.testing.allocator;

    var manager = HookManager.init(allocator);
    defer manager.deinit();

    try std.testing.expectEqual(@as(u64, 5000), manager.default_timeout_ms);

    manager.setDefaultTimeout(10000);

    try std.testing.expectEqual(@as(u64, 10000), manager.default_timeout_ms);
}

test "HookManager - execution timing" {
    const allocator = std.testing.allocator;

    var manager = HookManager.init(allocator);
    defer manager.deinit();

    try manager.registerHook("slow-plugin", .pre_command, slowHook, 0);

    var context = HookContext{
        .hook_type = .pre_command,
        .data = null,
        .user_data = null,
        .allocator = allocator,
    };

    const options = HookOptions{
        .timeout_ms = 1000,
        .async_exec = false,
        .continue_on_error = true,
    };

    const results = try manager.executeHooks(.pre_command, &context, options);
    defer {
        for (results) |*result| {
            var r = result.*;
            r.deinit(allocator);
        }
        allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(results[0].execution_time_ms >= 100);
}

test "HookManager - context passing" {
    const allocator = std.testing.allocator;

    var manager = HookManager.init(allocator);
    defer manager.deinit();

    const TestData = struct {
        value: i32,
    };

    var test_data = TestData{ .value = 42 };

    const testDataHook = struct {
        fn hook(ctx: *HookContext) !void {
            const data: *TestData = @ptrCast(@alignCast(ctx.data.?));
            data.value = 100;
        }
    }.hook;

    try manager.registerHook("data-plugin", .pre_command, testDataHook, 0);

    var context = HookContext{
        .hook_type = .pre_command,
        .data = @ptrCast(&test_data),
        .user_data = null,
        .allocator = allocator,
    };

    const options = HookOptions{
        .timeout_ms = 1000,
        .async_exec = false,
        .continue_on_error = true,
    };

    const results = try manager.executeHooks(.pre_command, &context, options);
    defer {
        for (results) |*result| {
            var r = result.*;
            r.deinit(allocator);
        }
        allocator.free(results);
    }

    try std.testing.expectEqual(@as(i32, 100), test_data.value);
}
