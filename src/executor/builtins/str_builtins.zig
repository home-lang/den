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

/// Main str subcommand dispatcher
pub fn strCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("Usage: str <subcommand> [args...]\n  Subcommands: trim, upcase, downcase, capitalize, replace, split, join,\n    starts-with, ends-with, contains, length, substring, reverse,\n    pad-left, pad-right, distance\n", .{});
        return 1;
    }
    const subcmd = command.args[0];
    const rest_args = if (command.args.len > 1) command.args[1..] else &[_][]const u8{};

    if (std.mem.eql(u8, subcmd, "trim")) return strTrim(allocator, rest_args);
    if (std.mem.eql(u8, subcmd, "upcase")) return strUpcase(allocator, rest_args);
    if (std.mem.eql(u8, subcmd, "downcase")) return strDowncase(allocator, rest_args);
    if (std.mem.eql(u8, subcmd, "capitalize")) return strCapitalize(allocator, rest_args);
    if (std.mem.eql(u8, subcmd, "replace")) return strReplace(allocator, rest_args);
    if (std.mem.eql(u8, subcmd, "split")) return strSplit(allocator, rest_args);
    if (std.mem.eql(u8, subcmd, "join")) return strJoin(allocator, rest_args);
    if (std.mem.eql(u8, subcmd, "starts-with")) return strStartsWith(allocator, rest_args);
    if (std.mem.eql(u8, subcmd, "ends-with")) return strEndsWith(allocator, rest_args);
    if (std.mem.eql(u8, subcmd, "contains")) return strContains(allocator, rest_args);
    if (std.mem.eql(u8, subcmd, "length")) return strLength(allocator, rest_args);
    if (std.mem.eql(u8, subcmd, "substring")) return strSubstring(allocator, rest_args);
    if (std.mem.eql(u8, subcmd, "reverse")) return strReverse(allocator, rest_args);
    if (std.mem.eql(u8, subcmd, "pad-left")) return strPadLeft(allocator, rest_args);
    if (std.mem.eql(u8, subcmd, "pad-right")) return strPadRight(allocator, rest_args);
    if (std.mem.eql(u8, subcmd, "distance")) return strDistance(allocator, rest_args);

    try IO.eprint("Unknown str subcommand: {s}\n", .{subcmd});
    return 1;
}

fn getInput(allocator: std.mem.Allocator, args: []const []const u8, arg_offset: usize) ![]const u8 {
    if (args.len > arg_offset) {
        return try allocator.dupe(u8, args[arg_offset]);
    }
    const raw = try readAllStdin(allocator);
    // Trim trailing newline from stdin
    const trimmed = std.mem.trimEnd(u8, raw, "\n");
    if (trimmed.len < raw.len) {
        const result = try allocator.dupe(u8, trimmed);
        allocator.free(raw);
        return result;
    }
    return raw;
}

fn strTrim(allocator: std.mem.Allocator, args: []const []const u8) !i32 {
    const input = try getInput(allocator, args, 0);
    defer allocator.free(input);
    const result = std.mem.trim(u8, input, &std.ascii.whitespace);
    try IO.print("{s}\n", .{result});
    return 0;
}

fn strUpcase(allocator: std.mem.Allocator, args: []const []const u8) !i32 {
    const input = try getInput(allocator, args, 0);
    defer allocator.free(input);
    const result = try allocator.alloc(u8, input.len);
    defer allocator.free(result);
    for (input, 0..) |ch, i| {
        result[i] = std.ascii.toUpper(ch);
    }
    try IO.print("{s}\n", .{result});
    return 0;
}

fn strDowncase(allocator: std.mem.Allocator, args: []const []const u8) !i32 {
    const input = try getInput(allocator, args, 0);
    defer allocator.free(input);
    const result = try allocator.alloc(u8, input.len);
    defer allocator.free(result);
    for (input, 0..) |ch, i| {
        result[i] = std.ascii.toLower(ch);
    }
    try IO.print("{s}\n", .{result});
    return 0;
}

fn strCapitalize(allocator: std.mem.Allocator, args: []const []const u8) !i32 {
    const input = try getInput(allocator, args, 0);
    defer allocator.free(input);
    if (input.len == 0) {
        try IO.print("\n", .{});
        return 0;
    }
    const result = try allocator.alloc(u8, input.len);
    defer allocator.free(result);
    result[0] = std.ascii.toUpper(input[0]);
    if (input.len > 1) @memcpy(result[1..], input[1..]);
    try IO.print("{s}\n", .{result});
    return 0;
}

fn strReplace(allocator: std.mem.Allocator, args: []const []const u8) !i32 {
    if (args.len < 2) {
        try IO.eprint("Usage: str replace <old> <new> [input]\n", .{});
        return 1;
    }
    const old = args[0];
    const new = args[1];
    const input = try getInput(allocator, args, 2);
    defer allocator.free(input);

    const result = try replaceAlloc(allocator, input, old, new);
    defer allocator.free(result);
    try IO.print("{s}\n", .{result});
    return 0;
}

fn strSplit(allocator: std.mem.Allocator, args: []const []const u8) !i32 {
    if (args.len < 1) {
        try IO.eprint("Usage: str split <delimiter> [input]\n", .{});
        return 1;
    }
    const delim = args[0];
    const input = try getInput(allocator, args, 1);
    defer allocator.free(input);

    if (delim.len == 1) {
        var it = std.mem.splitScalar(u8, input, delim[0]);
        while (it.next()) |part| {
            try IO.print("{s}\n", .{part});
        }
    } else {
        var it = std.mem.splitSequence(u8, input, delim);
        while (it.next()) |part| {
            try IO.print("{s}\n", .{part});
        }
    }
    return 0;
}

fn strJoin(allocator: std.mem.Allocator, args: []const []const u8) !i32 {
    const delim = if (args.len > 0) args[0] else "";
    const input = try readAllStdin(allocator);
    defer allocator.free(input);

    var result = std.ArrayList(u8){};
    defer result.deinit(allocator);
    var lines = std.mem.splitScalar(u8, input, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!first) try result.appendSlice(allocator, delim);
        first = false;
        try result.appendSlice(allocator, line);
    }
    const output = try result.toOwnedSlice(allocator);
    defer allocator.free(output);
    try IO.print("{s}\n", .{output});
    return 0;
}

fn strStartsWith(allocator: std.mem.Allocator, args: []const []const u8) !i32 {
    if (args.len < 1) {
        try IO.eprint("Usage: str starts-with <prefix> [input]\n", .{});
        return 1;
    }
    const prefix = args[0];
    const input = try getInput(allocator, args, 1);
    defer allocator.free(input);
    try IO.print("{s}\n", .{if (std.mem.startsWith(u8, input, prefix)) "true" else "false"});
    return if (std.mem.startsWith(u8, input, prefix)) 0 else 1;
}

fn strEndsWith(allocator: std.mem.Allocator, args: []const []const u8) !i32 {
    if (args.len < 1) {
        try IO.eprint("Usage: str ends-with <suffix> [input]\n", .{});
        return 1;
    }
    const suffix = args[0];
    const input = try getInput(allocator, args, 1);
    defer allocator.free(input);
    try IO.print("{s}\n", .{if (std.mem.endsWith(u8, input, suffix)) "true" else "false"});
    return if (std.mem.endsWith(u8, input, suffix)) 0 else 1;
}

fn strContains(allocator: std.mem.Allocator, args: []const []const u8) !i32 {
    if (args.len < 1) {
        try IO.eprint("Usage: str contains <substring> [input]\n", .{});
        return 1;
    }
    const substr = args[0];
    const input = try getInput(allocator, args, 1);
    defer allocator.free(input);
    const found = std.mem.indexOf(u8, input, substr) != null;
    try IO.print("{s}\n", .{if (found) "true" else "false"});
    return if (found) 0 else 1;
}

fn strLength(allocator: std.mem.Allocator, args: []const []const u8) !i32 {
    const input = try getInput(allocator, args, 0);
    defer allocator.free(input);
    try IO.print("{d}\n", .{input.len});
    return 0;
}

fn strSubstring(allocator: std.mem.Allocator, args: []const []const u8) !i32 {
    if (args.len < 2) {
        try IO.eprint("Usage: str substring <start> <end> [input]\n", .{});
        return 1;
    }
    const start = std.fmt.parseInt(usize, args[0], 10) catch 0;
    const end = std.fmt.parseInt(usize, args[1], 10) catch 0;
    const input = try getInput(allocator, args, 2);
    defer allocator.free(input);
    const s = @min(start, input.len);
    const e = @min(end, input.len);
    if (s <= e) {
        try IO.print("{s}\n", .{input[s..e]});
    }
    return 0;
}

fn strReverse(allocator: std.mem.Allocator, args: []const []const u8) !i32 {
    const input = try getInput(allocator, args, 0);
    defer allocator.free(input);
    const result = try allocator.alloc(u8, input.len);
    defer allocator.free(result);
    for (input, 0..) |ch, i| {
        result[input.len - 1 - i] = ch;
    }
    try IO.print("{s}\n", .{result});
    return 0;
}

fn strPadLeft(allocator: std.mem.Allocator, args: []const []const u8) !i32 {
    if (args.len < 1) {
        try IO.eprint("Usage: str pad-left <width> [char] [input]\n", .{});
        return 1;
    }
    const width = std.fmt.parseInt(usize, args[0], 10) catch 0;
    const pad_char: u8 = if (args.len > 1 and args[1].len > 0) args[1][0] else ' ';
    const input = try getInput(allocator, args, if (args.len > 2) 2 else 1);
    defer allocator.free(input);
    if (input.len >= width) {
        try IO.print("{s}\n", .{input});
    } else {
        const pad_len = width - input.len;
        const result = try allocator.alloc(u8, width);
        defer allocator.free(result);
        @memset(result[0..pad_len], pad_char);
        @memcpy(result[pad_len..], input);
        try IO.print("{s}\n", .{result});
    }
    return 0;
}

fn strPadRight(allocator: std.mem.Allocator, args: []const []const u8) !i32 {
    if (args.len < 1) {
        try IO.eprint("Usage: str pad-right <width> [char] [input]\n", .{});
        return 1;
    }
    const width = std.fmt.parseInt(usize, args[0], 10) catch 0;
    const pad_char: u8 = if (args.len > 1 and args[1].len > 0) args[1][0] else ' ';
    const input = try getInput(allocator, args, if (args.len > 2) 2 else 1);
    defer allocator.free(input);
    if (input.len >= width) {
        try IO.print("{s}\n", .{input});
    } else {
        const result = try allocator.alloc(u8, width);
        defer allocator.free(result);
        @memcpy(result[0..input.len], input);
        @memset(result[input.len..], pad_char);
        try IO.print("{s}\n", .{result});
    }
    return 0;
}

fn strDistance(allocator: std.mem.Allocator, args: []const []const u8) !i32 {
    if (args.len < 2) {
        try IO.eprint("Usage: str distance <string1> <string2>\n", .{});
        return 1;
    }
    const a = args[0];
    const b = args[1];
    const dist = levenshteinDistance(a, b, allocator) catch 0;
    try IO.print("{d}\n", .{dist});
    return 0;
}

/// Replace all occurrences of `needle` with `replacement` in `haystack`, returning a new allocation.
fn replaceAlloc(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    if (needle.len == 0) return try allocator.dupe(u8, haystack);
    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);
    var i: usize = 0;
    while (i <= haystack.len) {
        if (i + needle.len <= haystack.len and std.mem.eql(u8, haystack[i..][0..needle.len], needle)) {
            try result.appendSlice(allocator, replacement);
            i += needle.len;
        } else if (i < haystack.len) {
            try result.append(allocator, haystack[i]);
            i += 1;
        } else {
            break;
        }
    }
    return try result.toOwnedSlice(allocator);
}

fn levenshteinDistance(a: []const u8, b: []const u8, allocator: std.mem.Allocator) !usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;

    const prev = try allocator.alloc(usize, b.len + 1);
    defer allocator.free(prev);
    const curr = try allocator.alloc(usize, b.len + 1);
    defer allocator.free(curr);

    for (0..b.len + 1) |j| prev[j] = j;

    for (a, 0..) |ca, i| {
        curr[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            curr[j + 1] = @min(@min(curr[j] + 1, prev[j + 1] + 1), prev[j] + cost);
        }
        @memcpy(prev, curr);
    }
    return prev[b.len];
}
