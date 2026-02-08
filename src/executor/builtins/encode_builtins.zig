const std = @import("std");
const posix = std.posix;
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;
const common = @import("common.zig");

/// Main encode subcommand dispatcher
pub fn encodeCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("Usage: encode <format> [input]\n  Formats: base64, hex, url\n", .{});
        return 1;
    }
    const format = command.args[0];
    const input_arg = if (command.args.len > 1) command.args[1] else null;

    const input = if (input_arg) |arg|
        try allocator.dupe(u8, arg)
    else
        try common.readAllStdin(allocator);
    defer allocator.free(input);
    const trimmed = std.mem.trimEnd(u8, input, "\n");

    if (std.mem.eql(u8, format, "base64")) return encodeBase64(allocator, trimmed);
    if (std.mem.eql(u8, format, "hex")) return encodeHex(allocator, trimmed);
    if (std.mem.eql(u8, format, "url")) return encodeUrl(allocator, trimmed);

    try IO.eprint("Unknown encoding: {s}\n", .{format});
    return 1;
}

/// Main decode subcommand dispatcher
pub fn decodeCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("Usage: decode <format> [input]\n  Formats: base64, hex, url\n", .{});
        return 1;
    }
    const format = command.args[0];
    const input_arg = if (command.args.len > 1) command.args[1] else null;

    const input = if (input_arg) |arg|
        try allocator.dupe(u8, arg)
    else
        try common.readAllStdin(allocator);
    defer allocator.free(input);
    const trimmed = std.mem.trimEnd(u8, input, "\n");

    if (std.mem.eql(u8, format, "base64")) return decodeBase64(allocator, trimmed);
    if (std.mem.eql(u8, format, "hex")) return decodeHex(allocator, trimmed);
    if (std.mem.eql(u8, format, "url")) return decodeUrl(allocator, trimmed);

    try IO.eprint("Unknown encoding: {s}\n", .{format});
    return 1;
}

fn encodeBase64(allocator: std.mem.Allocator, input: []const u8) !i32 {
    const encoder = std.base64.standard;
    const encoded_len = encoder.Encoder.calcSize(input.len);
    const result = try allocator.alloc(u8, encoded_len);
    defer allocator.free(result);
    _ = encoder.Encoder.encode(result, input);
    try IO.print("{s}\n", .{result});
    return 0;
}

fn decodeBase64(allocator: std.mem.Allocator, input: []const u8) !i32 {
    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(input) catch {
        try IO.eprint("Error: invalid base64 input\n", .{});
        return 1;
    };
    const result = try allocator.alloc(u8, decoded_len);
    defer allocator.free(result);
    decoder.decode(result, input) catch {
        try IO.eprint("Error: invalid base64 input\n", .{});
        return 1;
    };
    try IO.print("{s}\n", .{result});
    return 0;
}

fn encodeHex(allocator: std.mem.Allocator, input: []const u8) !i32 {
    const result = try allocator.alloc(u8, input.len * 2);
    defer allocator.free(result);
    for (input, 0..) |byte, i| {
        const hex = "0123456789abcdef";
        result[i * 2] = hex[byte >> 4];
        result[i * 2 + 1] = hex[byte & 0x0f];
    }
    try IO.print("{s}\n", .{result});
    return 0;
}

fn decodeHex(allocator: std.mem.Allocator, input: []const u8) !i32 {
    if (input.len % 2 != 0) {
        try IO.eprint("Error: hex string must have even length\n", .{});
        return 1;
    }
    const result = try allocator.alloc(u8, input.len / 2);
    defer allocator.free(result);
    var i: usize = 0;
    while (i < input.len) : (i += 2) {
        const hi = hexDigit(input[i]) orelse {
            try IO.eprint("Error: invalid hex character\n", .{});
            return 1;
        };
        const lo = hexDigit(input[i + 1]) orelse {
            try IO.eprint("Error: invalid hex character\n", .{});
            return 1;
        };
        result[i / 2] = (hi << 4) | lo;
    }
    try IO.print("{s}\n", .{result});
    return 0;
}

fn hexDigit(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn encodeUrl(allocator: std.mem.Allocator, input: []const u8) !i32 {
    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try result.append(allocator, c);
        } else {
            const hex = "0123456789ABCDEF";
            try result.append(allocator, '%');
            try result.append(allocator, hex[c >> 4]);
            try result.append(allocator, hex[c & 0x0f]);
        }
    }
    const output = try result.toOwnedSlice(allocator);
    defer allocator.free(output);
    try IO.print("{s}\n", .{output});
    return 0;
}

fn decodeUrl(allocator: std.mem.Allocator, input: []const u8) !i32 {
    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = hexDigit(input[i + 1]) orelse {
                try result.append(allocator, input[i]);
                i += 1;
                continue;
            };
            const lo = hexDigit(input[i + 2]) orelse {
                try result.append(allocator, input[i]);
                i += 1;
                continue;
            };
            try result.append(allocator, (hi << 4) | lo);
            i += 3;
        } else if (input[i] == '+') {
            try result.append(allocator, ' ');
            i += 1;
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }
    const output = try result.toOwnedSlice(allocator);
    defer allocator.free(output);
    try IO.print("{s}\n", .{output});
    return 0;
}
