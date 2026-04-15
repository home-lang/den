const std = @import("std");
const plugin_mod = @import("plugin.zig");
const IO = @import("../utils/io.zig").IO;
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
    IO.print("[hello] Initialized (version: {s})\n", .{config.version}) catch {};
}

fn helloStart(config: *PluginConfig) !void {
    IO.print("[hello] Started (enabled: {})\n", .{config.enabled}) catch {};
}

fn helloStop() !void {
    IO.print("[hello] Stopped\n", .{}) catch {};
}

fn helloShutdown() !void {
    IO.print("[hello] Shutdown\n", .{}) catch {};
}

fn helloExecute(args: []const []const u8) !i32 {
    IO.print("[hello] Executing with {} args\n", .{args.len}) catch {};
    for (args, 0..) |arg, i| {
        IO.print("  arg[{}]: {s}\n", .{ i, arg }) catch {};
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
    IO.print("[counter] Initialized (count: {})\n", .{counter_value}) catch {};
}

fn counterStart(config: *PluginConfig) !void {
    // Read initial value from config if provided
    if (config.get("initial")) |initial_str| {
        counter_value = std.fmt.parseInt(i32, initial_str, 10) catch 0;
    }
    IO.print("[counter] Started (initial: {})\n", .{counter_value}) catch {};
}

fn counterStop() !void {
    IO.print("[counter] Stopped (final: {})\n", .{counter_value}) catch {};
}

fn counterShutdown() !void {
    IO.print("[counter] Shutdown\n", .{}) catch {};
    counter_value = 0;
}

fn counterExecute(args: []const []const u8) !i32 {
    if (args.len == 0) {
        // No args: print current value
        IO.print("[counter] Current value: {}\n", .{counter_value}) catch {};
    } else {
        const cmd = args[0];
        if (std.mem.eql(u8, cmd, "inc")) {
            counter_value += 1;
            IO.print("[counter] Incremented to {}\n", .{counter_value}) catch {};
        } else if (std.mem.eql(u8, cmd, "dec")) {
            counter_value -= 1;
            IO.print("[counter] Decremented to {}\n", .{counter_value}) catch {};
        } else if (std.mem.eql(u8, cmd, "reset")) {
            counter_value = 0;
            IO.print("[counter] Reset to 0\n", .{}) catch {};
        } else if (std.mem.eql(u8, cmd, "set") and args.len > 1) {
            counter_value = std.fmt.parseInt(i32, args[1], 10) catch 0;
            IO.print("[counter] Set to {}\n", .{counter_value}) catch {};
        } else {
            IO.print("[counter] Unknown command: {s}\n", .{cmd}) catch {};
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
    IO.print("[echo] Initialized\n", .{}) catch {};
}

fn echoStart(config: *PluginConfig) !void {
    _ = config;
    IO.print("[echo] Started\n", .{}) catch {};
}

fn echoStop() !void {
    IO.print("[echo] Stopped\n", .{}) catch {};
}

fn echoShutdown() !void {
    IO.print("[echo] Shutdown\n", .{}) catch {};
    echo_fail_next = false;
}

fn echoExecute(args: []const []const u8) !i32 {
    // Simulate error if requested
    if (echo_fail_next) {
        echo_fail_next = false;
        IO.print("[echo] Simulated error!\n", .{}) catch {};
        return error.SimulatedError;
    }

    // Echo all arguments
    IO.print("[echo] ", .{}) catch {};
    for (args, 0..) |arg, i| {
        if (i > 0) IO.print(" ", .{}) catch {};
        IO.print("{s}", .{arg}) catch {};

        // Special command: fail next
        if (std.mem.eql(u8, arg, "--fail-next")) {
            echo_fail_next = true;
        }
    }
    IO.print("\n", .{}) catch {};
    return 0;
}
