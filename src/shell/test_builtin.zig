//! Test Builtin Implementation
//!
//! This module implements the test, [, and [[ builtin commands
//! for shell conditional expressions.

const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");
const regex = @import("../utils/regex.zig");
const matchRegexAt = regex.matchRegexAt;

// Forward declaration for Shell type
const Shell = @import("../shell.zig").Shell;

/// Builtin: test / [ / [[ - evaluate conditional expressions
pub fn builtinTest(shell: *Shell, cmd: *types.ParsedCommand) !void {
    // Simple test implementation supporting basic conditions
    if (cmd.args.len == 0) {
        shell.last_exit_code = 1;
        return;
    }

    // Handle [ command - must end with ]
    var args = cmd.args;
    if (std.mem.eql(u8, cmd.name, "[")) {
        if (args.len == 0 or !std.mem.eql(u8, args[args.len - 1], "]")) {
            try IO.eprint("den: [: missing ]\n", .{});
            shell.last_exit_code = 2;
            return;
        }
        args = args[0 .. args.len - 1]; // Remove trailing ]
    } else if (std.mem.eql(u8, cmd.name, "[[")) {
        if (args.len == 0 or !std.mem.eql(u8, args[args.len - 1], "]]")) {
            try IO.eprint("den: [[: missing ]]\n", .{});
            shell.last_exit_code = 2;
            return;
        }
        args = args[0 .. args.len - 1]; // Remove trailing ]]
    }

    if (args.len == 0) {
        shell.last_exit_code = 1;
        return;
    }

    // Handle negation: [ ! expr ]
    if (args.len >= 2 and std.mem.eql(u8, args[0], "!")) {
        // Create a temporary command with the remaining args
        var negated_cmd = cmd.*;
        negated_cmd.args = args[1..];
        builtinTest(shell, &negated_cmd) catch {};
        // Negate the result
        shell.last_exit_code = if (shell.last_exit_code == 0) @as(i32, 1) else @as(i32, 0);
        return;
    }

    // Unary operators
    if (args.len == 2) {
        const op = args[0];
        const arg = args[1];

        if (std.mem.eql(u8, op, "-z")) {
            // String is empty
            shell.last_exit_code = if (arg.len == 0) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-n")) {
            // String is not empty
            shell.last_exit_code = if (arg.len > 0) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-f")) {
            // File exists and is regular file
            const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, arg, .{}) catch {
                shell.last_exit_code = 1;
                return;
            };
            shell.last_exit_code = if (stat.kind == .file) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-d")) {
            // Directory exists
            const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, arg, .{}) catch {
                shell.last_exit_code = 1;
                return;
            };
            shell.last_exit_code = if (stat.kind == .directory) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-e")) {
            // File exists
            std.Io.Dir.cwd().access(std.Options.debug_io, arg, .{}) catch {
                shell.last_exit_code = 1;
                return;
            };
            shell.last_exit_code = 0;
            return;
        } else if (std.mem.eql(u8, op, "-v")) {
            // Variable is set - check environment, local vars, and arrays
            var is_set = shell.environment.get(arg) != null;
            if (!is_set) {
                // Check if it's an array
                is_set = shell.arrays.contains(arg) or shell.assoc_arrays.contains(arg);
            }
            if (!is_set) {
                // Check local vars in function scope
                if (shell.function_manager.currentFrame()) |frame| {
                    is_set = frame.local_vars.contains(arg);
                }
            }
            shell.last_exit_code = if (is_set) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-s")) {
            // File exists and is not empty
            const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, arg, .{}) catch {
                shell.last_exit_code = 1;
                return;
            };
            shell.last_exit_code = if (stat.size > 0) 0 else 1;
            return;
        }
    }

    // Binary operators
    if (args.len == 3) {
        const left = args[0];
        const op = args[1];
        const right = args[2];

        if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) {
            // String equality
            shell.last_exit_code = if (std.mem.eql(u8, left, right)) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "!=")) {
            // String inequality
            shell.last_exit_code = if (!std.mem.eql(u8, left, right)) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-eq")) {
            // Numeric equality
            const left_num = std.fmt.parseInt(i32, left, 10) catch {
                shell.last_exit_code = 2;
                return;
            };
            const right_num = std.fmt.parseInt(i32, right, 10) catch {
                shell.last_exit_code = 2;
                return;
            };
            shell.last_exit_code = if (left_num == right_num) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-ne")) {
            // Numeric inequality
            const left_num = std.fmt.parseInt(i32, left, 10) catch {
                shell.last_exit_code = 2;
                return;
            };
            const right_num = std.fmt.parseInt(i32, right, 10) catch {
                shell.last_exit_code = 2;
                return;
            };
            shell.last_exit_code = if (left_num != right_num) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-lt")) {
            // Less than
            const left_num = std.fmt.parseInt(i32, left, 10) catch {
                shell.last_exit_code = 2;
                return;
            };
            const right_num = std.fmt.parseInt(i32, right, 10) catch {
                shell.last_exit_code = 2;
                return;
            };
            shell.last_exit_code = if (left_num < right_num) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-gt")) {
            // Greater than
            const left_num = std.fmt.parseInt(i32, left, 10) catch {
                shell.last_exit_code = 2;
                return;
            };
            const right_num = std.fmt.parseInt(i32, right, 10) catch {
                shell.last_exit_code = 2;
                return;
            };
            shell.last_exit_code = if (left_num > right_num) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-le")) {
            // Less than or equal
            const left_num = std.fmt.parseInt(i32, left, 10) catch {
                shell.last_exit_code = 2;
                return;
            };
            const right_num = std.fmt.parseInt(i32, right, 10) catch {
                shell.last_exit_code = 2;
                return;
            };
            shell.last_exit_code = if (left_num <= right_num) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-ge")) {
            // Greater than or equal
            const left_num = std.fmt.parseInt(i32, left, 10) catch {
                shell.last_exit_code = 2;
                return;
            };
            const right_num = std.fmt.parseInt(i32, right, 10) catch {
                shell.last_exit_code = 2;
                return;
            };
            shell.last_exit_code = if (left_num >= right_num) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "=~")) {
            // Regex match (using basic pattern matching)
            const matches = matchRegex(left, right);
            shell.last_exit_code = if (matches) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "<")) {
            // String less than (lexicographic)
            shell.last_exit_code = if (std.mem.lessThan(u8, left, right)) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, ">")) {
            // String greater than (lexicographic)
            shell.last_exit_code = if (std.mem.lessThan(u8, right, left)) 0 else 1;
            return;
        }
    }

    // Default: non-empty string test
    if (args.len == 1) {
        shell.last_exit_code = if (args[0].len > 0) 0 else 1;
        return;
    }

    // Unknown test
    try IO.eprint("den: test: unknown condition\n", .{});
    shell.last_exit_code = 2;
}

/// Match string against a regex pattern (basic POSIX ERE)
/// Supports: . (any char), * (zero or more), + (one or more), ? (zero or one),
/// ^ (start anchor), $ (end anchor), [...] (character class), | (alternation)
pub fn matchRegex(string: []const u8, pattern: []const u8) bool {
    // Handle anchors
    var pat = pattern;
    var str = string;
    var anchored_start = false;
    var anchored_end = false;

    if (pat.len > 0 and pat[0] == '^') {
        anchored_start = true;
        pat = pat[1..];
    }
    if (pat.len > 0 and pat[pat.len - 1] == '$') {
        anchored_end = true;
        pat = pat[0 .. pat.len - 1];
    }

    // If anchored at start, try match from beginning
    if (anchored_start) {
        return matchRegexAt(str, pat, 0, anchored_end);
    }

    // Otherwise try match at each position
    var i: usize = 0;
    while (i <= str.len) : (i += 1) {
        if (matchRegexAt(str, pat, i, anchored_end)) {
            return true;
        }
    }
    return false;
}
