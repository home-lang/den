const std = @import("std");
const interface_mod = @import("interface.zig");
const HookContext = interface_mod.HookContext;
const HookType = interface_mod.HookType;

/// Example: Command counter plugin
/// Counts how many commands have been executed
var command_count: usize = 0;

pub fn counterPreCommand(ctx: *HookContext) !void {
    _ = ctx;
    command_count += 1;
}

pub fn counterPostCommand(ctx: *HookContext) !void {
    if (ctx.getCommand()) |cmd| {
        std.debug.print("[counter] Command #{}: {s}\n", .{ command_count, cmd });
    }
}

pub fn counterGetCount(args: []const []const u8) !i32 {
    _ = args;
    std.debug.print("Total commands executed: {}\n", .{command_count});
    return 0;
}

pub fn counterResetCount(args: []const []const u8) !i32 {
    _ = args;
    const old_count = command_count;
    command_count = 0;
    std.debug.print("Reset counter (was: {})\n", .{old_count});
    return 0;
}

/// Example: Logger plugin
/// Logs all commands to a buffer
var log_buffer: [100][]const u8 = undefined;
var log_count: usize = 0;
var log_allocator: std.mem.Allocator = undefined;
var log_initialized = false;

pub fn loggerInit(allocator: std.mem.Allocator) void {
    log_allocator = allocator;
    log_count = 0;
    log_initialized = true;
}

pub fn loggerPreCommand(ctx: *HookContext) !void {
    if (!log_initialized) return;

    if (ctx.getCommand()) |cmd| {
        if (log_count < log_buffer.len) {
            log_buffer[log_count] = try log_allocator.dupe(u8, cmd);
            log_count += 1;
        }
    }
}

pub fn loggerShowLog(args: []const []const u8) !i32 {
    _ = args;
    std.debug.print("Command log ({} entries):\n", .{log_count});
    for (log_buffer[0..log_count], 0..) |cmd, i| {
        std.debug.print("  [{}] {s}\n", .{ i + 1, cmd });
    }
    return 0;
}

pub fn loggerClearLog(args: []const []const u8) !i32 {
    _ = args;
    // Free allocated strings
    for (log_buffer[0..log_count]) |cmd| {
        log_allocator.free(cmd);
    }
    log_count = 0;
    std.debug.print("Log cleared\n", .{});
    return 0;
}

pub fn loggerShutdown() void {
    if (log_initialized) {
        for (log_buffer[0..log_count]) |cmd| {
            log_allocator.free(cmd);
        }
        log_count = 0;
        log_initialized = false;
    }
}

/// Example: Greeter plugin
/// Shows a message on shell init and exit
pub fn greeterInit(ctx: *HookContext) !void {
    _ = ctx;
    std.debug.print("Welcome to Den Shell! (greeter plugin active)\n", .{});
}

pub fn greeterExit(ctx: *HookContext) !void {
    _ = ctx;
    std.debug.print("Goodbye! Thanks for using Den Shell.\n", .{});
}

pub fn greeterSayHello(args: []const []const u8) !i32 {
    if (args.len > 0) {
        std.debug.print("Hello, {s}!\n", .{args[0]});
    } else {
        std.debug.print("Hello, stranger!\n", .{});
    }
    return 0;
}

/// Example: Completion plugin
/// Provides custom completions for "plugin:" prefix
pub fn pluginCompletion(input: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    const suggestions = [_][]const u8{
        "plugin:list",
        "plugin:info",
        "plugin:enable",
        "plugin:disable",
        "plugin:reload",
    };

    var matches_buffer: [10][]const u8 = undefined;
    var matches_count: usize = 0;

    for (suggestions) |suggestion| {
        if (std.mem.startsWith(u8, suggestion, input)) {
            if (matches_count < matches_buffer.len) {
                matches_buffer[matches_count] = try allocator.dupe(u8, suggestion);
                matches_count += 1;
            }
        }
    }

    const result = try allocator.alloc([]const u8, matches_count);
    @memcpy(result, matches_buffer[0..matches_count]);
    return result;
}

/// Example: Math plugin
/// Simple calculator commands
pub fn mathAdd(args: []const []const u8) !i32 {
    if (args.len < 2) {
        std.debug.print("Usage: add <num1> <num2>\n", .{});
        return 1;
    }

    const a = try std.fmt.parseInt(i32, args[0], 10);
    const b = try std.fmt.parseInt(i32, args[1], 10);
    std.debug.print("Result: {}\n", .{a + b});
    return 0;
}

pub fn mathSubtract(args: []const []const u8) !i32 {
    if (args.len < 2) {
        std.debug.print("Usage: subtract <num1> <num2>\n", .{});
        return 1;
    }

    const a = try std.fmt.parseInt(i32, args[0], 10);
    const b = try std.fmt.parseInt(i32, args[1], 10);
    std.debug.print("Result: {}\n", .{a - b});
    return 0;
}

pub fn mathMultiply(args: []const []const u8) !i32 {
    if (args.len < 2) {
        std.debug.print("Usage: multiply <num1> <num2>\n", .{});
        return 1;
    }

    const a = try std.fmt.parseInt(i32, args[0], 10);
    const b = try std.fmt.parseInt(i32, args[1], 10);
    std.debug.print("Result: {}\n", .{a * b});
    return 0;
}

/// Example: Timer plugin
/// Measures command execution time
var timer_start: i64 = 0;

pub fn timerPreCommand(ctx: *HookContext) !void {
    _ = ctx;
    timer_start = std.time.milliTimestamp();
}

pub fn timerPostCommand(ctx: *HookContext) !void {
    const elapsed = std.time.milliTimestamp() - timer_start;
    if (ctx.getCommand()) |cmd| {
        std.debug.print("[timer] '{s}' took {}ms\n", .{ cmd, elapsed });
    }
}
