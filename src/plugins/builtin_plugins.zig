const std = @import("std");
const plugin_mod = @import("plugin.zig");
const PluginConfig = plugin_mod.PluginConfig;
const PluginInterface = plugin_mod.PluginInterface;

/// Example plugin: Hello World
pub const hello_plugin = PluginInterface{
    .init_fn = helloInit,
    .start_fn = helloStart,
    .stop_fn = helloStop,
    .shutdown_fn = helloShutdown,
    .execute_fn = helloExecute,
};

fn helloInit(config: *PluginConfig) !void {
    std.debug.print("[hello] Initialized (version: {s})\n", .{config.version});
}

fn helloStart(config: *PluginConfig) !void {
    std.debug.print("[hello] Started (enabled: {})\n", .{config.enabled});
}

fn helloStop() !void {
    std.debug.print("[hello] Stopped\n", .{});
}

fn helloShutdown() !void {
    std.debug.print("[hello] Shutdown\n", .{});
}

fn helloExecute(args: []const []const u8) !i32 {
    std.debug.print("[hello] Executing with {} args\n", .{args.len});
    for (args, 0..) |arg, i| {
        std.debug.print("  arg[{}]: {s}\n", .{ i, arg });
    }
    return 0;
}

/// Example plugin: Counter
var counter_value: i32 = 0;

pub const counter_plugin = PluginInterface{
    .init_fn = counterInit,
    .start_fn = counterStart,
    .stop_fn = counterStop,
    .shutdown_fn = counterShutdown,
    .execute_fn = counterExecute,
};

fn counterInit(config: *PluginConfig) !void {
    _ = config;
    counter_value = 0;
    std.debug.print("[counter] Initialized (count: {})\n", .{counter_value});
}

fn counterStart(config: *PluginConfig) !void {
    // Read initial value from config if provided
    if (config.get("initial")) |initial_str| {
        counter_value = std.fmt.parseInt(i32, initial_str, 10) catch 0;
    }
    std.debug.print("[counter] Started (initial: {})\n", .{counter_value});
}

fn counterStop() !void {
    std.debug.print("[counter] Stopped (final: {})\n", .{counter_value});
}

fn counterShutdown() !void {
    std.debug.print("[counter] Shutdown\n", .{});
    counter_value = 0;
}

fn counterExecute(args: []const []const u8) !i32 {
    if (args.len == 0) {
        // No args: print current value
        std.debug.print("[counter] Current value: {}\n", .{counter_value});
    } else {
        const cmd = args[0];
        if (std.mem.eql(u8, cmd, "inc")) {
            counter_value += 1;
            std.debug.print("[counter] Incremented to {}\n", .{counter_value});
        } else if (std.mem.eql(u8, cmd, "dec")) {
            counter_value -= 1;
            std.debug.print("[counter] Decremented to {}\n", .{counter_value});
        } else if (std.mem.eql(u8, cmd, "reset")) {
            counter_value = 0;
            std.debug.print("[counter] Reset to 0\n", .{});
        } else if (std.mem.eql(u8, cmd, "set") and args.len > 1) {
            counter_value = std.fmt.parseInt(i32, args[1], 10) catch 0;
            std.debug.print("[counter] Set to {}\n", .{counter_value});
        } else {
            std.debug.print("[counter] Unknown command: {s}\n", .{cmd});
            return 1;
        }
    }
    return 0;
}

/// Example plugin: Echo (with error simulation)
var echo_fail_next = false;

pub const echo_plugin = PluginInterface{
    .init_fn = echoInit,
    .start_fn = echoStart,
    .stop_fn = echoStop,
    .shutdown_fn = echoShutdown,
    .execute_fn = echoExecute,
};

fn echoInit(config: *PluginConfig) !void {
    _ = config;
    echo_fail_next = false;
    std.debug.print("[echo] Initialized\n", .{});
}

fn echoStart(config: *PluginConfig) !void {
    _ = config;
    std.debug.print("[echo] Started\n", .{});
}

fn echoStop() !void {
    std.debug.print("[echo] Stopped\n", .{});
}

fn echoShutdown() !void {
    std.debug.print("[echo] Shutdown\n", .{});
    echo_fail_next = false;
}

fn echoExecute(args: []const []const u8) !i32 {
    // Simulate error if requested
    if (echo_fail_next) {
        echo_fail_next = false;
        std.debug.print("[echo] Simulated error!\n", .{});
        return error.SimulatedError;
    }

    // Echo all arguments
    std.debug.print("[echo] ", .{});
    for (args, 0..) |arg, i| {
        if (i > 0) std.debug.print(" ", .{});
        std.debug.print("{s}", .{arg});

        // Special command: fail next
        if (std.mem.eql(u8, arg, "--fail-next")) {
            echo_fail_next = true;
        }
    }
    std.debug.print("\n", .{});
    return 0;
}
