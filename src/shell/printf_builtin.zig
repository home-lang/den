//! Printf Builtin Implementation
//!
//! This module implements the printf builtin command with full format string support.

const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");

// Forward declaration for Shell type
const Shell = @import("../shell.zig").Shell;

/// Builtin: printf - formatted output with full format string support
pub fn builtinPrintf(shell: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        return;
    }

    // Handle -v flag: printf -v varname format args...
    var var_name: ?[]const u8 = null;
    var format_idx: usize = 0;
    if (cmd.args.len >= 3 and std.mem.eql(u8, cmd.args[0], "-v")) {
        var_name = cmd.args[1];
        format_idx = 2;
    }

    const format = cmd.args[format_idx];
    var arg_idx: usize = format_idx + 1;

    // For -v flag: redirect stdout to a pipe to capture output
    var saved_stdout: c_int = -1;
    var pipe_fds: [2]c_int = .{ -1, -1 };
    if (var_name != null) {
        if (std.c.pipe(&pipe_fds) == 0) {
            saved_stdout = std.c.dup(std.posix.STDOUT_FILENO);
            _ = std.c.dup2(pipe_fds[1], std.posix.STDOUT_FILENO);
            std.posix.close(@intCast(pipe_fds[1]));
            pipe_fds[1] = -1;
        }
    }

    // In bash, printf reuses the format string for remaining arguments
    // e.g., printf "%s\n" a b c prints a\nb\nc
    var did_consume_arg = true;
    while (did_consume_arg) {
        did_consume_arg = false;
        if (arg_idx >= cmd.args.len and arg_idx > 1) break;

    var i: usize = 0;
    while (i < format.len) {
        if (format[i] == '%' and i + 1 < format.len) {
            // Parse optional flags, width, and precision
            var j = i + 1;
            var left_justify = false;
            var zero_pad = false;
            var width: usize = 0;
            var precision: usize = 6; // Default precision for floats
            var has_precision = false;

            // Parse flags
            while (j < format.len) {
                if (format[j] == '-') {
                    left_justify = true;
                    j += 1;
                } else if (format[j] == '0') {
                    zero_pad = true;
                    j += 1;
                } else if (format[j] == '+' or format[j] == ' ' or format[j] == '#') {
                    j += 1; // Skip unsupported flags
                } else {
                    break;
                }
            }

            // Parse width
            while (j < format.len and format[j] >= '0' and format[j] <= '9') {
                width = width * 10 + (format[j] - '0');
                j += 1;
            }

            // Parse precision
            if (j < format.len and format[j] == '.') {
                j += 1;
                precision = 0;
                has_precision = true;
                while (j < format.len and format[j] >= '0' and format[j] <= '9') {
                    precision = precision * 10 + (format[j] - '0');
                    j += 1;
                }
            }

            if (j >= format.len) {
                try IO.print("{c}", .{format[i]});
                i += 1;
                continue;
            }

            const spec = format[j];
            if (spec == 's') {
                // String format
                if (arg_idx < cmd.args.len) {
                    var str = cmd.args[arg_idx];
                    // Apply precision (truncate)
                    if (has_precision and str.len > precision) {
                        str = str[0..precision];
                    }
                    // Apply width (padding)
                    if (width > 0 and str.len < width) {
                        const pad = width - str.len;
                        if (left_justify) {
                            try IO.print("{s}", .{str});
                            var p: usize = 0;
                            while (p < pad) : (p += 1) try IO.print(" ", .{});
                        } else {
                            var p: usize = 0;
                            while (p < pad) : (p += 1) try IO.print(" ", .{});
                            try IO.print("{s}", .{str});
                        }
                    } else {
                        try IO.print("{s}", .{str});
                    }
                    arg_idx += 1;
                    did_consume_arg = true;
                }
                i = j + 1;
            } else if (spec == 'd' or spec == 'i') {
                // Integer format
                if (arg_idx < cmd.args.len) {
                    const num = std.fmt.parseInt(i64, cmd.args[arg_idx], 10) catch 0;
                    try printfInt(num, width, zero_pad, left_justify);
                    arg_idx += 1;
                    did_consume_arg = true;
                }
                i = j + 1;
            } else if (spec == 'u') {
                // Unsigned integer format
                if (arg_idx < cmd.args.len) {
                    const num = std.fmt.parseInt(u64, cmd.args[arg_idx], 10) catch 0;
                    try printfUint(num, width, zero_pad, left_justify, 10, false);
                    arg_idx += 1;
                    did_consume_arg = true;
                }
                i = j + 1;
            } else if (spec == 'x') {
                // Hex lowercase
                if (arg_idx < cmd.args.len) {
                    const num = std.fmt.parseInt(u64, cmd.args[arg_idx], 10) catch 0;
                    try printfUint(num, width, zero_pad, left_justify, 16, false);
                    arg_idx += 1;
                    did_consume_arg = true;
                }
                i = j + 1;
            } else if (spec == 'X') {
                // Hex uppercase
                if (arg_idx < cmd.args.len) {
                    const num = std.fmt.parseInt(u64, cmd.args[arg_idx], 10) catch 0;
                    try printfUint(num, width, zero_pad, left_justify, 16, true);
                    arg_idx += 1;
                    did_consume_arg = true;
                }
                i = j + 1;
            } else if (spec == 'o') {
                // Octal format
                if (arg_idx < cmd.args.len) {
                    const num = std.fmt.parseInt(u64, cmd.args[arg_idx], 10) catch 0;
                    try printfUint(num, width, zero_pad, left_justify, 8, false);
                    arg_idx += 1;
                    did_consume_arg = true;
                }
                i = j + 1;
            } else if (spec == 'c') {
                // Character format
                if (arg_idx < cmd.args.len) {
                    const arg = cmd.args[arg_idx];
                    if (arg.len > 0) {
                        try IO.print("{c}", .{arg[0]});
                    }
                    arg_idx += 1;
                    did_consume_arg = true;
                }
                i = j + 1;
            } else if (spec == 'f' or spec == 'F') {
                // Float format
                if (arg_idx < cmd.args.len) {
                    const num = std.fmt.parseFloat(f64, cmd.args[arg_idx]) catch 0.0;
                    try printfFloat(num, width, precision, left_justify);
                    arg_idx += 1;
                    did_consume_arg = true;
                }
                i = j + 1;
            } else if (spec == '%') {
                // Escaped %
                try IO.print("%", .{});
                i = j + 1;
            } else if (spec == 'b') {
                // String with escape interpretation (bash extension)
                if (arg_idx < cmd.args.len) {
                    try printWithEscapes(cmd.args[arg_idx]);
                    arg_idx += 1;
                    did_consume_arg = true;
                }
                i = j + 1;
            } else if (spec == 'q') {
                // Shell-quoted string (bash extension)
                if (arg_idx < cmd.args.len) {
                    try IO.print("'{s}'", .{cmd.args[arg_idx]});
                    arg_idx += 1;
                    did_consume_arg = true;
                }
                i = j + 1;
            } else {
                // Unknown format, just print it
                try IO.print("{c}", .{format[i]});
                i += 1;
            }
        } else if (format[i] == '\\' and i + 1 < format.len) {
            const esc = format[i + 1];
            switch (esc) {
                'n' => try IO.print("\n", .{}),
                't' => try IO.print("\t", .{}),
                'r' => try IO.print("\r", .{}),
                '\\' => try IO.print("\\", .{}),
                'a' => try IO.print("\x07", .{}),
                'b' => try IO.print("\x08", .{}),
                'f' => try IO.print("\x0c", .{}),
                'v' => try IO.print("\x0b", .{}),
                'e' => try IO.print("\x1b", .{}),
                '0' => {
                    // Octal escape
                    var val: u8 = 0;
                    var k: usize = i + 2;
                    var count: usize = 0;
                    while (k < format.len and count < 3) : (k += 1) {
                        if (format[k] >= '0' and format[k] <= '7') {
                            val = val * 8 + (format[k] - '0');
                            count += 1;
                        } else break;
                    }
                    try IO.print("{c}", .{val});
                    i = k;
                    continue;
                },
                'x' => {
                    // Hex escape \xNN
                    if (i + 3 < format.len) {
                        const hex = format[i + 2 .. i + 4];
                        const val = std.fmt.parseInt(u8, hex, 16) catch {
                            try IO.print("{c}", .{format[i]});
                            i += 1;
                            continue;
                        };
                        try IO.print("{c}", .{val});
                        i += 4;
                        continue;
                    } else {
                        try IO.print("{c}", .{format[i]});
                        i += 1;
                        continue;
                    }
                },
                else => try IO.print("{c}", .{format[i]}),
            }
            i += 2;
        } else {
            try IO.print("{c}", .{format[i]});
            i += 1;
        }
    }
    } // end outer while (did_consume_arg) loop for format reuse

    // For -v flag: read captured output and store in variable
    if (var_name) |vname| {
        if (saved_stdout >= 0) {
            // Restore stdout
            _ = std.c.dup2(saved_stdout, std.posix.STDOUT_FILENO);
            std.posix.close(@intCast(saved_stdout));

            // Read captured output from pipe
            if (pipe_fds[0] >= 0) {
                var result_buf: [4096]u8 = undefined;
                const n = std.c.read(pipe_fds[0], &result_buf, result_buf.len);
                std.posix.close(@intCast(pipe_fds[0]));
                if (n > 0) {
                    const output = result_buf[0..@intCast(n)];
                    // Store in shell variable
                    const val = shell.allocator.dupe(u8, output) catch return;
                    const gop = shell.environment.getOrPut(vname) catch {
                        shell.allocator.free(val);
                        return;
                    };
                    if (gop.found_existing) {
                        shell.allocator.free(gop.value_ptr.*);
                    } else {
                        gop.key_ptr.* = shell.allocator.dupe(u8, vname) catch {
                            shell.allocator.free(val);
                            return;
                        };
                    }
                    gop.value_ptr.* = val;
                }
            }
        }
    }
}

/// Helper for printf - format signed integer with width/padding
pub fn printfInt(num: i64, width: usize, zero_pad: bool, left_justify: bool) !void {
    var buf: [32]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}", .{num}) catch return;
    if (width > 0 and str.len < width) {
        const pad = width - str.len;
        const pad_char: u8 = if (zero_pad and !left_justify) '0' else ' ';
        if (left_justify) {
            try IO.print("{s}", .{str});
            var p: usize = 0;
            while (p < pad) : (p += 1) try IO.print(" ", .{});
        } else {
            var p: usize = 0;
            while (p < pad) : (p += 1) try IO.print("{c}", .{pad_char});
            try IO.print("{s}", .{str});
        }
    } else {
        try IO.print("{s}", .{str});
    }
}

/// Helper for printf - format unsigned integer with base and width
pub fn printfUint(num: u64, width: usize, zero_pad: bool, left_justify: bool, base: u8, uppercase: bool) !void {
    var buf: [32]u8 = undefined;
    const str = if (base == 16)
        if (uppercase)
            std.fmt.bufPrint(&buf, "{X}", .{num}) catch return
        else
            std.fmt.bufPrint(&buf, "{x}", .{num}) catch return
    else if (base == 8)
        std.fmt.bufPrint(&buf, "{o}", .{num}) catch return
    else
        std.fmt.bufPrint(&buf, "{d}", .{num}) catch return;

    if (width > 0 and str.len < width) {
        const pad = width - str.len;
        const pad_char: u8 = if (zero_pad and !left_justify) '0' else ' ';
        if (left_justify) {
            try IO.print("{s}", .{str});
            var p: usize = 0;
            while (p < pad) : (p += 1) try IO.print(" ", .{});
        } else {
            var p: usize = 0;
            while (p < pad) : (p += 1) try IO.print("{c}", .{pad_char});
            try IO.print("{s}", .{str});
        }
    } else {
        try IO.print("{s}", .{str});
    }
}

/// Helper for printf - format float with precision and width
pub fn printfFloat(num: f64, width: usize, precision: usize, left_justify: bool) !void {
    var buf: [64]u8 = undefined;
    // Zig doesn't support runtime precision, so use fixed cases
    const str = switch (precision) {
        0 => std.fmt.bufPrint(&buf, "{d:.0}", .{num}) catch return,
        1 => std.fmt.bufPrint(&buf, "{d:.1}", .{num}) catch return,
        2 => std.fmt.bufPrint(&buf, "{d:.2}", .{num}) catch return,
        3 => std.fmt.bufPrint(&buf, "{d:.3}", .{num}) catch return,
        4 => std.fmt.bufPrint(&buf, "{d:.4}", .{num}) catch return,
        5 => std.fmt.bufPrint(&buf, "{d:.5}", .{num}) catch return,
        else => std.fmt.bufPrint(&buf, "{d:.6}", .{num}) catch return,
    };

    if (width > 0 and str.len < width) {
        const pad = width - str.len;
        if (left_justify) {
            try IO.print("{s}", .{str});
            var p: usize = 0;
            while (p < pad) : (p += 1) try IO.print(" ", .{});
        } else {
            var p: usize = 0;
            while (p < pad) : (p += 1) try IO.print(" ", .{});
            try IO.print("{s}", .{str});
        }
    } else {
        try IO.print("{s}", .{str});
    }
}

/// Helper for printf %b - print string with escape interpretation
pub fn printWithEscapes(str: []const u8) !void {
    var i: usize = 0;
    while (i < str.len) {
        if (str[i] == '\\' and i + 1 < str.len) {
            switch (str[i + 1]) {
                'n' => try IO.print("\n", .{}),
                't' => try IO.print("\t", .{}),
                'r' => try IO.print("\r", .{}),
                '\\' => try IO.print("\\", .{}),
                'a' => try IO.print("\x07", .{}),
                'b' => try IO.print("\x08", .{}),
                'f' => try IO.print("\x0c", .{}),
                'v' => try IO.print("\x0b", .{}),
                'e' => try IO.print("\x1b", .{}),
                else => {
                    try IO.print("{c}", .{str[i]});
                    i += 1;
                    continue;
                },
            }
            i += 2;
        } else {
            try IO.print("{c}", .{str[i]});
            i += 1;
        }
    }
}
