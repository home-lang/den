const std = @import("std");
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;
const builtin = @import("builtin");

/// Test builtins: test, [, [[
/// Extracted from executor/mod.zig for better modularity

pub fn testBuiltin(command: *types.ParsedCommand) !i32 {
    // Handle both 'test' and '[' syntax
    const args = if (std.mem.eql(u8, command.name, "[")) blk: {
        // For '[', last arg should be ']'
        if (command.args.len > 0 and std.mem.eql(u8, command.args[command.args.len - 1], "]")) {
            break :blk command.args[0 .. command.args.len - 1];
        }
        try IO.eprint("den: [: missing ']'\n", .{});
        return 2;
    } else command.args;

    return evaluateTestArgs(args);
}

fn evaluateTestArgs(args: []const []const u8) !i32 {
    if (args.len == 0) return 1; // Empty test is false

    // Handle negation: ! expr
    if (args.len >= 2 and std.mem.eql(u8, args[0], "!")) {
        const result = try evaluateTestArgs(args[1..]);
        return if (result == 0) 1 else 0;
    }

    // Single argument - test if non-empty string
    if (args.len == 1) {
        return if (args[0].len > 0) 0 else 1;
    }

    // Two arguments - unary operators
    if (args.len == 2) {
        const op = args[0];
        const arg = args[1];

        if (std.mem.eql(u8, op, "-z")) {
            return if (arg.len == 0) 0 else 1;
        } else if (std.mem.eql(u8, op, "-n")) {
            return if (arg.len > 0) 0 else 1;
        } else if (std.mem.eql(u8, op, "-f")) {
            const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, arg, .{}) catch return 1;
            return if (stat.kind == .file) 0 else 1;
        } else if (std.mem.eql(u8, op, "-d")) {
            const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, arg, .{}) catch return 1;
            return if (stat.kind == .directory) 0 else 1;
        } else if (std.mem.eql(u8, op, "-e")) {
            _ = std.Io.Dir.cwd().statFile(std.Options.debug_io, arg, .{}) catch return 1;
            return 0;
        } else if (std.mem.eql(u8, op, "-r")) {
            const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, arg, .{}) catch return 1;
            file.close(std.Options.debug_io);
            return 0;
        } else if (std.mem.eql(u8, op, "-w")) {
            const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, arg, .{ .mode = .write_only }) catch return 1;
            file.close(std.Options.debug_io);
            return 0;
        } else if (std.mem.eql(u8, op, "-x")) {
            if (builtin.os.tag == .windows) {
                std.Io.Dir.cwd().access(std.Options.debug_io, arg, .{}) catch return 1;
                return 0;
            }
            const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, arg, .{}) catch return 1;
            return if (stat.permissions.toMode() & 0o111 != 0) 0 else 1;
        }
    }

    // Three arguments - binary operators
    if (args.len == 3) {
        const left = args[0];
        const op = args[1];
        const right = args[2];

        if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) {
            return if (std.mem.eql(u8, left, right)) 0 else 1;
        } else if (std.mem.eql(u8, op, "!=")) {
            return if (!std.mem.eql(u8, left, right)) 0 else 1;
        } else if (std.mem.eql(u8, op, "-eq")) {
            const left_num = std.fmt.parseInt(i64, left, 10) catch return 2;
            const right_num = std.fmt.parseInt(i64, right, 10) catch return 2;
            return if (left_num == right_num) 0 else 1;
        } else if (std.mem.eql(u8, op, "-ne")) {
            const left_num = std.fmt.parseInt(i64, left, 10) catch return 2;
            const right_num = std.fmt.parseInt(i64, right, 10) catch return 2;
            return if (left_num != right_num) 0 else 1;
        } else if (std.mem.eql(u8, op, "-lt")) {
            const left_num = std.fmt.parseInt(i64, left, 10) catch return 2;
            const right_num = std.fmt.parseInt(i64, right, 10) catch return 2;
            return if (left_num < right_num) 0 else 1;
        } else if (std.mem.eql(u8, op, "-le")) {
            const left_num = std.fmt.parseInt(i64, left, 10) catch return 2;
            const right_num = std.fmt.parseInt(i64, right, 10) catch return 2;
            return if (left_num <= right_num) 0 else 1;
        } else if (std.mem.eql(u8, op, "-gt")) {
            const left_num = std.fmt.parseInt(i64, left, 10) catch return 2;
            const right_num = std.fmt.parseInt(i64, right, 10) catch return 2;
            return if (left_num > right_num) 0 else 1;
        } else if (std.mem.eql(u8, op, "-ge")) {
            const left_num = std.fmt.parseInt(i64, left, 10) catch return 2;
            const right_num = std.fmt.parseInt(i64, right, 10) catch return 2;
            return if (left_num >= right_num) 0 else 1;
        }
    }

    try IO.eprint("den: test: unsupported expression\n", .{});
    return 2;
}

/// Extended test builtin [[ ]] with pattern matching and regex support
pub fn extendedTest(command: *types.ParsedCommand) !i32 {
    // Remove trailing ]] if present
    var args = command.args;
    if (args.len > 0 and std.mem.eql(u8, args[args.len - 1], "]]")) {
        args = args[0 .. args.len - 1];
    }

    if (args.len == 0) return 1; // Empty test is false

    // Handle compound expressions with && and ||
    var i: usize = 0;
    var last_result: bool = true;
    var pending_op: ?enum { and_op, or_op } = null;

    while (i < args.len) {
        // Find the next && or || or end of args
        var expr_end = i;
        var paren_depth: u32 = 0;
        while (expr_end < args.len) {
            const arg = args[expr_end];
            if (std.mem.eql(u8, arg, "(")) {
                paren_depth += 1;
            } else if (std.mem.eql(u8, arg, ")")) {
                if (paren_depth > 0) paren_depth -= 1;
            } else if (paren_depth == 0) {
                if (std.mem.eql(u8, arg, "&&") or std.mem.eql(u8, arg, "||")) {
                    break;
                }
            }
            expr_end += 1;
        }

        // Evaluate the sub-expression
        const sub_result = try evaluateExtendedTestExpr(args[i..expr_end]);

        // Apply pending operator
        if (pending_op) |op| {
            switch (op) {
                .and_op => last_result = last_result and sub_result,
                .or_op => last_result = last_result or sub_result,
            }
        } else {
            last_result = sub_result;
        }

        // Short-circuit evaluation
        if (expr_end < args.len) {
            const op_str = args[expr_end];
            if (std.mem.eql(u8, op_str, "&&")) {
                if (!last_result) return 1;
                pending_op = .and_op;
            } else if (std.mem.eql(u8, op_str, "||")) {
                if (last_result) return 0;
                pending_op = .or_op;
            }
            i = expr_end + 1;
        } else {
            break;
        }
    }

    return if (last_result) 0 else 1;
}

/// Evaluate a single extended test expression (without && / ||)
fn evaluateExtendedTestExpr(args: [][]const u8) !bool {
    if (args.len == 0) return false;

    // Handle negation
    if (args.len >= 1 and std.mem.eql(u8, args[0], "!")) {
        return !(try evaluateExtendedTestExpr(args[1..]));
    }

    // Handle parentheses
    if (args.len >= 2 and std.mem.eql(u8, args[0], "(")) {
        var depth: u32 = 1;
        var close_idx: usize = 1;
        while (close_idx < args.len and depth > 0) {
            if (std.mem.eql(u8, args[close_idx], "(")) depth += 1;
            if (std.mem.eql(u8, args[close_idx], ")")) depth -= 1;
            if (depth > 0) close_idx += 1;
        }
        if (close_idx < args.len) {
            return try evaluateExtendedTestExpr(args[1..close_idx]);
        }
    }

    // Single argument - test if non-empty string
    if (args.len == 1) {
        return args[0].len > 0;
    }

    // Two arguments - unary operators
    if (args.len == 2) {
        const op = args[0];
        const arg = args[1];

        if (std.mem.eql(u8, op, "-z")) {
            return arg.len == 0;
        } else if (std.mem.eql(u8, op, "-n")) {
            return arg.len > 0;
        } else if (std.mem.eql(u8, op, "-f")) {
            const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, arg, .{}) catch return false;
            defer file.close(std.Options.debug_io);
            const stat = file.stat(std.Options.debug_io) catch return false;
            return stat.kind == .file;
        } else if (std.mem.eql(u8, op, "-d")) {
            var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, arg, .{}) catch return false;
            dir.close(std.Options.debug_io);
            return true;
        } else if (std.mem.eql(u8, op, "-e")) {
            std.Io.Dir.cwd().access(std.Options.debug_io, arg, .{}) catch return false;
            return true;
        } else if (std.mem.eql(u8, op, "-r")) {
            const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, arg, .{}) catch return false;
            file.close(std.Options.debug_io);
            return true;
        } else if (std.mem.eql(u8, op, "-w")) {
            const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, arg, .{ .mode = .write_only }) catch return false;
            file.close(std.Options.debug_io);
            return true;
        } else if (std.mem.eql(u8, op, "-x")) {
            if (builtin.os.tag == .windows) {
                std.Io.Dir.cwd().access(std.Options.debug_io, arg, .{}) catch return false;
                return true;
            }
            const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, arg, .{}) catch return false;
            defer file.close(std.Options.debug_io);
            const stat = file.stat(std.Options.debug_io) catch return false;
            return stat.permissions.toMode() & 0o111 != 0;
        } else if (std.mem.eql(u8, op, "-s")) {
            const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, arg, .{}) catch return false;
            defer file.close(std.Options.debug_io);
            const stat = file.stat(std.Options.debug_io) catch return false;
            return stat.size > 0;
        } else if (std.mem.eql(u8, op, "-L") or std.mem.eql(u8, op, "-h")) {
            const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, arg, .{}) catch return false;
            return stat.kind == .sym_link;
        }
    }

    // Three arguments - binary operators
    if (args.len == 3) {
        const left = args[0];
        const op = args[1];
        const right = args[2];

        if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "=")) {
            return globMatch(left, right);
        } else if (std.mem.eql(u8, op, "!=")) {
            return !globMatch(left, right);
        } else if (std.mem.eql(u8, op, "=~")) {
            return matchRegex(left, right);
        } else if (std.mem.eql(u8, op, "<")) {
            return std.mem.lessThan(u8, left, right);
        } else if (std.mem.eql(u8, op, ">")) {
            return std.mem.lessThan(u8, right, left);
        } else if (std.mem.eql(u8, op, "-eq")) {
            const left_num = std.fmt.parseInt(i64, left, 10) catch return false;
            const right_num = std.fmt.parseInt(i64, right, 10) catch return false;
            return left_num == right_num;
        } else if (std.mem.eql(u8, op, "-ne")) {
            const left_num = std.fmt.parseInt(i64, left, 10) catch return false;
            const right_num = std.fmt.parseInt(i64, right, 10) catch return false;
            return left_num != right_num;
        } else if (std.mem.eql(u8, op, "-lt")) {
            const left_num = std.fmt.parseInt(i64, left, 10) catch return false;
            const right_num = std.fmt.parseInt(i64, right, 10) catch return false;
            return left_num < right_num;
        } else if (std.mem.eql(u8, op, "-le")) {
            const left_num = std.fmt.parseInt(i64, left, 10) catch return false;
            const right_num = std.fmt.parseInt(i64, right, 10) catch return false;
            return left_num <= right_num;
        } else if (std.mem.eql(u8, op, "-gt")) {
            const left_num = std.fmt.parseInt(i64, left, 10) catch return false;
            const right_num = std.fmt.parseInt(i64, right, 10) catch return false;
            return left_num > right_num;
        } else if (std.mem.eql(u8, op, "-ge")) {
            const left_num = std.fmt.parseInt(i64, left, 10) catch return false;
            const right_num = std.fmt.parseInt(i64, right, 10) catch return false;
            return left_num >= right_num;
        } else if (std.mem.eql(u8, op, "-nt")) {
            const left_stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, left, .{}) catch return false;
            const right_stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, right, .{}) catch return false;
            return left_stat.mtime.nanoseconds > right_stat.mtime.nanoseconds;
        } else if (std.mem.eql(u8, op, "-ot")) {
            const left_stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, left, .{}) catch return false;
            const right_stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, right, .{}) catch return false;
            return left_stat.mtime.nanoseconds < right_stat.mtime.nanoseconds;
        } else if (std.mem.eql(u8, op, "-ef")) {
            const left_stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, left, .{}) catch return false;
            const right_stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, right, .{}) catch return false;
            return left_stat.inode == right_stat.inode;
        }
    }

    return false;
}

/// Simple glob pattern matching for [[ == ]]
pub fn globMatch(str: []const u8, pattern: []const u8) bool {
    var s_idx: usize = 0;
    var p_idx: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (s_idx < str.len) {
        if (p_idx < pattern.len and (pattern[p_idx] == '?' or pattern[p_idx] == str[s_idx])) {
            s_idx += 1;
            p_idx += 1;
        } else if (p_idx < pattern.len and pattern[p_idx] == '*') {
            star_idx = p_idx;
            match_idx = s_idx;
            p_idx += 1;
        } else if (star_idx) |si| {
            p_idx = si + 1;
            match_idx += 1;
            s_idx = match_idx;
        } else {
            return false;
        }
    }

    while (p_idx < pattern.len and pattern[p_idx] == '*') {
        p_idx += 1;
    }

    return p_idx == pattern.len;
}

/// Regex matching for [[ =~ ]]
/// Supports: ., *, +, ?, ^, $, [...], [^...], character ranges
fn matchRegex(str: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return true;

    const anchored_start = pattern[0] == '^';
    const anchored_end = pattern.len > 0 and pattern[pattern.len - 1] == '$';

    var actual_pattern = pattern;
    if (anchored_start) actual_pattern = actual_pattern[1..];
    if (anchored_end and actual_pattern.len > 0) actual_pattern = actual_pattern[0 .. actual_pattern.len - 1];

    if (actual_pattern.len == 0) {
        if (anchored_start and anchored_end) return str.len == 0;
        return true;
    }

    if (anchored_start) {
        return regexMatch(str, 0, actual_pattern, 0, anchored_end);
    } else {
        // Try matching at each position
        var i: usize = 0;
        while (i <= str.len) : (i += 1) {
            if (regexMatch(str, i, actual_pattern, 0, anchored_end)) {
                return true;
            }
        }
        return false;
    }
}

/// Recursive regex matching engine
fn regexMatch(str: []const u8, si: usize, pattern: []const u8, pi: usize, anchored_end: bool) bool {
    var s = si;
    var p = pi;

    while (p < pattern.len) {
        // Parse current pattern element
        const elem_start = p;
        var elem_end = p;

        if (pattern[p] == '[') {
            // Bracket expression - find closing ]
            elem_end = p + 1;
            if (elem_end < pattern.len and pattern[elem_end] == '^') elem_end += 1;
            if (elem_end < pattern.len and pattern[elem_end] == ']') elem_end += 1;
            while (elem_end < pattern.len and pattern[elem_end] != ']') : (elem_end += 1) {}
            if (elem_end < pattern.len) elem_end += 1; // include ]
        } else if (pattern[p] == '\\' and p + 1 < pattern.len) {
            elem_end = p + 2;
        } else {
            elem_end = p + 1;
        }

        // Check for quantifier
        const has_plus = elem_end < pattern.len and pattern[elem_end] == '+';
        const has_star = elem_end < pattern.len and pattern[elem_end] == '*';
        const has_question = elem_end < pattern.len and pattern[elem_end] == '?';

        const next_p = if (has_plus or has_star or has_question) elem_end + 1 else elem_end;

        if (has_star or has_plus) {
            // Greedy match: try matching as many as possible, then backtrack
            var count: usize = 0;
            while (s + count < str.len and matchElement(str[s + count], pattern[elem_start..elem_end])) {
                count += 1;
            }
            // For +, need at least 1
            const min_count: usize = if (has_plus) 1 else 0;
            // Try from max to min
            var try_count: usize = count;
            while (true) {
                if (try_count >= min_count) {
                    if (regexMatch(str, s + try_count, pattern, next_p, anchored_end)) {
                        return true;
                    }
                }
                if (try_count == 0) break;
                try_count -= 1;
            }
            return false;
        } else if (has_question) {
            // Optional: try with and without
            if (s < str.len and matchElement(str[s], pattern[elem_start..elem_end])) {
                if (regexMatch(str, s + 1, pattern, next_p, anchored_end)) return true;
            }
            return regexMatch(str, s, pattern, next_p, anchored_end);
        } else {
            // Exact match of one element
            if (s >= str.len) return false;
            if (!matchElement(str[s], pattern[elem_start..elem_end])) return false;
            s += 1;
            p = next_p;
        }
    }

    // Pattern exhausted
    if (anchored_end) return s == str.len;
    return true;
}

/// Match a single character against a pattern element
fn matchElement(ch: u8, elem: []const u8) bool {
    if (elem.len == 0) return false;

    if (elem[0] == '.') return true;
    if (elem[0] == '\\' and elem.len >= 2) {
        return switch (elem[1]) {
            'd' => ch >= '0' and ch <= '9',
            'w' => std.ascii.isAlphanumeric(ch) or ch == '_',
            's' => std.ascii.isWhitespace(ch),
            'D' => !(ch >= '0' and ch <= '9'),
            'W' => !std.ascii.isAlphanumeric(ch) and ch != '_',
            'S' => !std.ascii.isWhitespace(ch),
            else => ch == elem[1],
        };
    }
    if (elem[0] == '[') {
        // Bracket expression
        if (elem.len < 2) return false;
        const negate = elem[1] == '^';
        const start_idx: usize = if (negate) 2 else 1;
        const end_idx = if (elem.len > 0 and elem[elem.len - 1] == ']') elem.len - 1 else elem.len;
        var matched = false;
        var i: usize = start_idx;
        while (i < end_idx) {
            if (i + 2 < end_idx and elem[i + 1] == '-') {
                // Range: a-z
                if (ch >= elem[i] and ch <= elem[i + 2]) matched = true;
                i += 3;
            } else {
                if (ch == elem[i]) matched = true;
                i += 1;
            }
        }
        return if (negate) !matched else matched;
    }

    return ch == elem[0];
}
