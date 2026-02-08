const std = @import("std");
const posix = std.posix;
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;

/// Read all stdin into a string
fn readAllStdin(allocator: std.mem.Allocator) ![]const u8 {
    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(posix.STDIN_FILENO, &buf) catch |err| {
            if (err == error.WouldBlock) break;
            return err;
        };
        if (n == 0) break;
        try result.appendSlice(allocator, buf[0..n]);
    }
    return try result.toOwnedSlice(allocator);
}

/// Read stdin as list of numbers
fn readStdinNumbers(allocator: std.mem.Allocator) ![]f64 {
    const input = readAllStdin(allocator) catch
        return try allocator.alloc(f64, 0);
    defer allocator.free(input);

    var nums = std.ArrayList(f64){};
    errdefer nums.deinit(allocator);
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        // Try each whitespace-separated token
        var tokens = std.mem.tokenizeAny(u8, trimmed, &std.ascii.whitespace);
        while (tokens.next()) |token| {
            if (std.fmt.parseFloat(f64, token)) |n| {
                try nums.append(allocator, n);
            } else |_| {}
        }
    }
    return try nums.toOwnedSlice(allocator);
}

/// Main math subcommand dispatcher
pub fn mathCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("Usage: math <subcommand> [args...]\n  Subcommands: sum, avg, min, max, product, median, mode,\n    stddev, variance, abs, ceil, floor, round, sqrt, log\n", .{});
        return 1;
    }
    const subcmd = command.args[0];
    const rest_args = if (command.args.len > 1) command.args[1..] else &[_][]const u8{};

    // Aggregation commands (read from stdin)
    if (std.mem.eql(u8, subcmd, "sum")) return mathSum(allocator);
    if (std.mem.eql(u8, subcmd, "avg")) return mathAvg(allocator);
    if (std.mem.eql(u8, subcmd, "min")) return mathMin(allocator);
    if (std.mem.eql(u8, subcmd, "max")) return mathMax(allocator);
    if (std.mem.eql(u8, subcmd, "product")) return mathProduct(allocator);
    if (std.mem.eql(u8, subcmd, "median")) return mathMedian(allocator);
    if (std.mem.eql(u8, subcmd, "mode")) return mathMode(allocator);
    if (std.mem.eql(u8, subcmd, "stddev")) return mathStddev(allocator);
    if (std.mem.eql(u8, subcmd, "variance")) return mathVariance(allocator);

    // Operation commands (take argument)
    if (std.mem.eql(u8, subcmd, "abs")) return mathAbs(rest_args);
    if (std.mem.eql(u8, subcmd, "ceil")) return mathCeil(rest_args);
    if (std.mem.eql(u8, subcmd, "floor")) return mathFloor(rest_args);
    if (std.mem.eql(u8, subcmd, "round")) return mathRound(rest_args);
    if (std.mem.eql(u8, subcmd, "sqrt")) return mathSqrt(rest_args);
    if (std.mem.eql(u8, subcmd, "log")) return mathLog(rest_args);

    try IO.eprint("Unknown math subcommand: {s}\n", .{subcmd});
    return 1;
}

fn mathSum(allocator: std.mem.Allocator) !i32 {
    const nums = try readStdinNumbers(allocator);
    defer allocator.free(nums);
    var sum: f64 = 0;
    for (nums) |n| sum += n;
    try printNumber(sum);
    return 0;
}

fn mathAvg(allocator: std.mem.Allocator) !i32 {
    const nums = try readStdinNumbers(allocator);
    defer allocator.free(nums);
    if (nums.len == 0) {
        try IO.print("0\n", .{});
        return 0;
    }
    var sum: f64 = 0;
    for (nums) |n| sum += n;
    try printNumber(sum / @as(f64, @floatFromInt(nums.len)));
    return 0;
}

fn mathMin(allocator: std.mem.Allocator) !i32 {
    const nums = try readStdinNumbers(allocator);
    defer allocator.free(nums);
    if (nums.len == 0) return 0;
    var min_val = nums[0];
    for (nums[1..]) |n| if (n < min_val) {
        min_val = n;
    };
    try printNumber(min_val);
    return 0;
}

fn mathMax(allocator: std.mem.Allocator) !i32 {
    const nums = try readStdinNumbers(allocator);
    defer allocator.free(nums);
    if (nums.len == 0) return 0;
    var max_val = nums[0];
    for (nums[1..]) |n| if (n > max_val) {
        max_val = n;
    };
    try printNumber(max_val);
    return 0;
}

fn mathProduct(allocator: std.mem.Allocator) !i32 {
    const nums = try readStdinNumbers(allocator);
    defer allocator.free(nums);
    if (nums.len == 0) {
        try IO.print("0\n", .{});
        return 0;
    }
    var prod: f64 = 1;
    for (nums) |n| prod *= n;
    try printNumber(prod);
    return 0;
}

fn mathMedian(allocator: std.mem.Allocator) !i32 {
    const nums = try readStdinNumbers(allocator);
    defer allocator.free(nums);
    if (nums.len == 0) return 0;
    std.mem.sort(f64, nums, {}, std.sort.asc(f64));
    const median = if (nums.len % 2 == 0)
        (nums[nums.len / 2 - 1] + nums[nums.len / 2]) / 2.0
    else
        nums[nums.len / 2];
    try printNumber(median);
    return 0;
}

fn mathMode(allocator: std.mem.Allocator) !i32 {
    const nums = try readStdinNumbers(allocator);
    defer allocator.free(nums);
    if (nums.len == 0) return 0;

    // Count occurrences (using string representation as key)
    var counts = std.StringHashMap(usize).init(allocator);
    defer counts.deinit();
    for (nums) |n| {
        const key = try std.fmt.allocPrint(allocator, "{d}", .{n});
        const gop = try counts.getOrPut(key);
        if (gop.found_existing) {
            gop.value_ptr.* += 1;
            allocator.free(key);
        } else {
            gop.value_ptr.* = 1;
        }
    }

    var max_count: usize = 0;
    var mode_key: []const u8 = "";
    var it = counts.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* > max_count) {
            max_count = entry.value_ptr.*;
            mode_key = entry.key_ptr.*;
        }
    }
    try IO.print("{s}\n", .{mode_key});

    // Free keys
    var it2 = counts.iterator();
    while (it2.next()) |entry| {
        allocator.free(entry.key_ptr.*);
    }
    return 0;
}

fn mathStddev(allocator: std.mem.Allocator) !i32 {
    const nums = try readStdinNumbers(allocator);
    defer allocator.free(nums);
    if (nums.len == 0) return 0;
    const v = variance(nums);
    try printNumber(@sqrt(v));
    return 0;
}

fn mathVariance(allocator: std.mem.Allocator) !i32 {
    const nums = try readStdinNumbers(allocator);
    defer allocator.free(nums);
    if (nums.len == 0) return 0;
    try printNumber(variance(nums));
    return 0;
}

fn variance(nums: []const f64) f64 {
    if (nums.len == 0) return 0;
    var sum: f64 = 0;
    for (nums) |n| sum += n;
    const mean = sum / @as(f64, @floatFromInt(nums.len));
    var sq_sum: f64 = 0;
    for (nums) |n| {
        const diff = n - mean;
        sq_sum += diff * diff;
    }
    return sq_sum / @as(f64, @floatFromInt(nums.len));
}

fn mathAbs(args: []const []const u8) !i32 {
    if (args.len == 0) {
        try IO.eprint("Usage: math abs <number>\n", .{});
        return 1;
    }
    const n = std.fmt.parseFloat(f64, args[0]) catch {
        try IO.eprint("Invalid number: {s}\n", .{args[0]});
        return 1;
    };
    try printNumber(@abs(n));
    return 0;
}

fn mathCeil(args: []const []const u8) !i32 {
    if (args.len == 0) {
        try IO.eprint("Usage: math ceil <number>\n", .{});
        return 1;
    }
    const n = std.fmt.parseFloat(f64, args[0]) catch {
        try IO.eprint("Invalid number: {s}\n", .{args[0]});
        return 1;
    };
    try printNumber(@ceil(n));
    return 0;
}

fn mathFloor(args: []const []const u8) !i32 {
    if (args.len == 0) {
        try IO.eprint("Usage: math floor <number>\n", .{});
        return 1;
    }
    const n = std.fmt.parseFloat(f64, args[0]) catch {
        try IO.eprint("Invalid number: {s}\n", .{args[0]});
        return 1;
    };
    try printNumber(@floor(n));
    return 0;
}

fn mathRound(args: []const []const u8) !i32 {
    if (args.len == 0) {
        try IO.eprint("Usage: math round <number>\n", .{});
        return 1;
    }
    const n = std.fmt.parseFloat(f64, args[0]) catch {
        try IO.eprint("Invalid number: {s}\n", .{args[0]});
        return 1;
    };
    try printNumber(@round(n));
    return 0;
}

fn mathSqrt(args: []const []const u8) !i32 {
    if (args.len == 0) {
        try IO.eprint("Usage: math sqrt <number>\n", .{});
        return 1;
    }
    const n = std.fmt.parseFloat(f64, args[0]) catch {
        try IO.eprint("Invalid number: {s}\n", .{args[0]});
        return 1;
    };
    if (n < 0) {
        try IO.eprint("Error: cannot take square root of negative number\n", .{});
        return 1;
    }
    try printNumber(@sqrt(n));
    return 0;
}

fn mathLog(args: []const []const u8) !i32 {
    if (args.len == 0) {
        try IO.eprint("Usage: math log <number> [base]\n", .{});
        return 1;
    }
    const n = std.fmt.parseFloat(f64, args[0]) catch {
        try IO.eprint("Invalid number: {s}\n", .{args[0]});
        return 1;
    };
    if (n <= 0) {
        try IO.eprint("Error: logarithm of non-positive number\n", .{});
        return 1;
    }
    if (args.len > 1) {
        const base = std.fmt.parseFloat(f64, args[1]) catch 10.0;
        try printNumber(@log(n) / @log(base));
    } else {
        try printNumber(@log(n));
    }
    return 0;
}

fn printNumber(n: f64) !void {
    // Print as integer if it's a whole number
    if (n == @floor(n) and @abs(n) < 1e15) {
        try IO.print("{d}\n", .{@as(i64, @intFromFloat(n))});
    } else {
        try IO.print("{d}\n", .{n});
    }
}
