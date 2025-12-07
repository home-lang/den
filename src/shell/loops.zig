//! Loop Execution Module
//!
//! This module contains implementations for special loop constructs:
//! - C-style for loops: for ((init; cond; update)); do ... done
//! - Select loops: select var in list; do ... done
//! - Arithmetic statements: ((expression))

const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");

// Forward declaration for Shell type
const Shell = @import("../shell.zig").Shell;

/// Execute a one-line C-style for loop: for ((init; cond; update)); do cmd1; cmd2; done
pub fn executeCStyleForLoopOneline(shell: *Shell, input: []const u8) !void {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);

    // Find "for ((" and "))"
    if (!std.mem.startsWith(u8, trimmed, "for ((")) {
        try IO.eprint("den: syntax error: expected 'for ((...))\n", .{});
        shell.last_exit_code = 1;
        return;
    }

    // Find the closing ))
    const expr_start = 6; // After "for (("
    const expr_end_rel = std.mem.indexOf(u8, trimmed[expr_start..], "))") orelse {
        try IO.eprint("den: syntax error: missing '))'n", .{});
        shell.last_exit_code = 1;
        return;
    };
    const expr = trimmed[expr_start..][0..expr_end_rel];

    // Parse init; condition; update
    var parts: [3]?[]const u8 = .{ null, null, null };
    var parts_count: usize = 0;
    var part_iter = std.mem.splitSequence(u8, expr, ";");
    while (part_iter.next()) |part| : (parts_count += 1) {
        if (parts_count >= 3) break;
        const trimmed_part = std.mem.trim(u8, part, &std.ascii.whitespace);
        if (trimmed_part.len > 0) {
            parts[parts_count] = trimmed_part;
        }
    }

    // Find "do" and "done" to extract body
    const after_parens = trimmed[expr_start + expr_end_rel + 2 ..];
    const trimmed_after = std.mem.trim(u8, after_parens, &std.ascii.whitespace);

    // Skip optional ';' after ))
    var body_start = trimmed_after;
    if (body_start.len > 0 and body_start[0] == ';') {
        body_start = std.mem.trim(u8, body_start[1..], &std.ascii.whitespace);
    }

    // Find "do" keyword
    if (!std.mem.startsWith(u8, body_start, "do")) {
        try IO.eprint("den: syntax error: expected 'do'\n", .{});
        shell.last_exit_code = 1;
        return;
    }
    body_start = std.mem.trim(u8, body_start[2..], &std.ascii.whitespace);

    // Find "done" keyword
    const done_pos = std.mem.indexOf(u8, body_start, "done") orelse {
        try IO.eprint("den: syntax error: expected 'done'\n", .{});
        shell.last_exit_code = 1;
        return;
    };
    const body_content = std.mem.trim(u8, body_start[0..done_pos], &std.ascii.whitespace);

    // Check if there's anything after 'done'
    const after_done = body_start[done_pos + 4 ..];
    const remaining_commands = std.mem.trim(u8, after_done, &std.ascii.whitespace);

    // Split body by semicolons (respecting quotes)
    var body_cmds = std.ArrayList([]const u8).init(shell.allocator);
    defer body_cmds.deinit();

    var cmd_start: usize = 0;
    var in_single_quote = false;
    var in_double_quote = false;
    var i: usize = 0;
    while (i < body_content.len) : (i += 1) {
        const c = body_content[i];
        if (c == '\'' and !in_double_quote) {
            in_single_quote = !in_single_quote;
        } else if (c == '"' and !in_single_quote) {
            in_double_quote = !in_double_quote;
        } else if (c == ';' and !in_single_quote and !in_double_quote) {
            const cmd = std.mem.trim(u8, body_content[cmd_start..i], &std.ascii.whitespace);
            if (cmd.len > 0) {
                try body_cmds.append(cmd);
            }
            cmd_start = i + 1;
        }
    }
    // Don't forget the last command
    const last_cmd = std.mem.trim(u8, body_content[cmd_start..], &std.ascii.whitespace);
    if (last_cmd.len > 0) {
        try body_cmds.append(last_cmd);
    }

    // Execute the C-style for loop inline
    // 1. Execute initialization
    if (parts[0]) |init_stmt| {
        executeArithmeticStatement(shell, init_stmt);
    }

    // 2. Loop while condition is true
    var iteration_count: usize = 0;
    const max_iterations: usize = 100000; // Safety limit
    while (iteration_count < max_iterations) : (iteration_count += 1) {
        // Check condition
        if (parts[1]) |cond| {
            if (!evaluateArithmeticCondition(shell, cond)) break;
        }

        // Execute body commands
        for (body_cmds.items) |cmd| {
            executeCStyleLoopBodyCommand(shell, cmd);
        }

        // Execute update
        if (parts[2]) |update| {
            executeArithmeticStatement(shell, update);
        }
    }

    shell.last_exit_code = 0;

    // Execute any remaining commands after "done"
    if (remaining_commands.len > 0) {
        var cmds_to_run = remaining_commands;
        if (cmds_to_run[0] == ';') {
            cmds_to_run = std.mem.trim(u8, cmds_to_run[1..], &std.ascii.whitespace);
        }
        if (cmds_to_run.len > 0) {
            var iter = std.mem.splitScalar(u8, cmds_to_run, ';');
            while (iter.next()) |cmd| {
                const trimmed_cmd = std.mem.trim(u8, cmd, &std.ascii.whitespace);
                if (trimmed_cmd.len > 0) {
                    executeCStyleLoopBodyCommand(shell, trimmed_cmd);
                }
            }
        }
    }
}

/// Execute a command in the body of a C-style for loop
pub fn executeCStyleLoopBodyCommand(shell: *Shell, cmd: []const u8) void {
    const trimmed = std.mem.trim(u8, cmd, &std.ascii.whitespace);
    if (trimmed.len == 0) return;

    // Handle arithmetic: ((expr))
    if (std.mem.startsWith(u8, trimmed, "((") and std.mem.endsWith(u8, trimmed, "))")) {
        const expr = trimmed[2 .. trimmed.len - 2];
        executeArithmeticStatement(shell, expr);
        return;
    }

    // Handle simple echo with variable substitution
    if (std.mem.startsWith(u8, trimmed, "echo ")) {
        const echo_args = trimmed[5..];
        var output_buf: [4096]u8 = undefined;
        var output_len: usize = 0;

        var i: usize = 0;
        while (i < echo_args.len) {
            if (echo_args[i] == '$' and i + 1 < echo_args.len) {
                // Variable substitution
                var var_end = i + 1;
                while (var_end < echo_args.len and (std.ascii.isAlphanumeric(echo_args[var_end]) or echo_args[var_end] == '_')) {
                    var_end += 1;
                }
                const var_name = echo_args[i + 1 .. var_end];
                const var_value = shell.environment.get(var_name) orelse "";
                if (output_len + var_value.len < output_buf.len) {
                    @memcpy(output_buf[output_len .. output_len + var_value.len], var_value);
                    output_len += var_value.len;
                }
                i = var_end;
            } else {
                if (output_len < output_buf.len) {
                    output_buf[output_len] = echo_args[i];
                    output_len += 1;
                }
                i += 1;
            }
        }

        IO.print("{s}\n", .{output_buf[0..output_len]}) catch {};
        return;
    }

    // For other commands, try to execute through shell
    shell.executeCommand(trimmed) catch {};
}

/// Execute an arithmetic statement (for C-style for loops)
pub fn executeArithmeticStatement(shell: *Shell, stmt: []const u8) void {
    const trimmed = std.mem.trim(u8, stmt, &std.ascii.whitespace);
    if (trimmed.len == 0) return;

    // Handle: i=0, i++, i+=1, i=i+1, etc.

    // Check for increment: i++
    if (std.mem.endsWith(u8, trimmed, "++")) {
        const var_name = trimmed[0 .. trimmed.len - 2];
        const current = shell.environment.get(var_name) orelse "0";
        const val = std.fmt.parseInt(i64, current, 10) catch 0;
        var buf: [32]u8 = undefined;
        const new_val = std.fmt.bufPrint(&buf, "{d}", .{val + 1}) catch return;
        shell.setVariableValue(var_name, new_val) catch {};
        return;
    }

    // Check for decrement: i--
    if (std.mem.endsWith(u8, trimmed, "--")) {
        const var_name = trimmed[0 .. trimmed.len - 2];
        const current = shell.environment.get(var_name) orelse "0";
        const val = std.fmt.parseInt(i64, current, 10) catch 0;
        var buf: [32]u8 = undefined;
        const new_val = std.fmt.bufPrint(&buf, "{d}", .{val - 1}) catch return;
        shell.setVariableValue(var_name, new_val) catch {};
        return;
    }

    // Check for compound assignment: i+=1
    if (std.mem.indexOf(u8, trimmed, "+=")) |pos| {
        const var_name = trimmed[0..pos];
        const add_val_str = trimmed[pos + 2 ..];
        const current = shell.environment.get(var_name) orelse "0";
        const current_val = std.fmt.parseInt(i64, current, 10) catch 0;
        const add_val = std.fmt.parseInt(i64, add_val_str, 10) catch 0;
        var buf: [32]u8 = undefined;
        const new_val = std.fmt.bufPrint(&buf, "{d}", .{current_val + add_val}) catch return;
        shell.setVariableValue(var_name, new_val) catch {};
        return;
    }

    // Simple assignment: i=0
    if (std.mem.indexOf(u8, trimmed, "=")) |pos| {
        const var_name = trimmed[0..pos];
        const value = trimmed[pos + 1 ..];

        // Check if value is an expression
        if (std.mem.indexOf(u8, value, "+") != null or std.mem.indexOf(u8, value, "-") != null or
            std.mem.indexOf(u8, value, "*") != null or std.mem.indexOf(u8, value, "/") != null)
        {
            // Evaluate arithmetic expression
            const result = evaluateArithmeticExpression(shell, value);
            var buf: [32]u8 = undefined;
            const result_str = std.fmt.bufPrint(&buf, "{d}", .{result}) catch return;
            shell.setVariableValue(var_name, result_str) catch {};
        } else {
            shell.setVariableValue(var_name, value) catch {};
        }
        return;
    }
}

/// Evaluate an arithmetic condition (returns true if non-zero)
pub fn evaluateArithmeticCondition(shell: *Shell, cond: []const u8) bool {
    const trimmed = std.mem.trim(u8, cond, &std.ascii.whitespace);
    if (trimmed.len == 0) return true; // Empty condition is always true

    // Handle comparisons: i<10, i<=10, i>0, i>=0, i==5, i!=5
    const ops = [_][]const u8{ "<=", ">=", "!=", "==", "<", ">" };

    for (ops) |op| {
        if (std.mem.indexOf(u8, trimmed, op)) |pos| {
            const left_str = std.mem.trim(u8, trimmed[0..pos], &std.ascii.whitespace);
            const right_str = std.mem.trim(u8, trimmed[pos + op.len ..], &std.ascii.whitespace);

            const left = evaluateArithmeticExpression(shell, left_str);
            const right = evaluateArithmeticExpression(shell, right_str);

            if (std.mem.eql(u8, op, "<=")) return left <= right;
            if (std.mem.eql(u8, op, ">=")) return left >= right;
            if (std.mem.eql(u8, op, "!=")) return left != right;
            if (std.mem.eql(u8, op, "==")) return left == right;
            if (std.mem.eql(u8, op, "<")) return left < right;
            if (std.mem.eql(u8, op, ">")) return left > right;
        }
    }

    // No comparison, evaluate as expression - non-zero is true
    return evaluateArithmeticExpression(shell, trimmed) != 0;
}

/// Evaluate a simple arithmetic expression
pub fn evaluateArithmeticExpression(shell: *Shell, expr: []const u8) i64 {
    const trimmed = std.mem.trim(u8, expr, &std.ascii.whitespace);
    if (trimmed.len == 0) return 0;

    // Try to parse as integer
    if (std.fmt.parseInt(i64, trimmed, 10)) |val| {
        return val;
    } else |_| {}

    // Try to get variable value
    if (shell.environment.get(trimmed)) |val| {
        return std.fmt.parseInt(i64, val, 10) catch 0;
    }

    // Handle simple binary operations: a+b, a-b, a*b, a/b
    if (std.mem.indexOf(u8, trimmed, "+")) |pos| {
        const left = evaluateArithmeticExpression(shell, trimmed[0..pos]);
        const right = evaluateArithmeticExpression(shell, trimmed[pos + 1 ..]);
        return left + right;
    }

    // Handle subtraction (but not negative numbers at start)
    if (trimmed.len > 1) {
        var i: usize = 1;
        while (i < trimmed.len) : (i += 1) {
            if (trimmed[i] == '-') {
                const left = evaluateArithmeticExpression(shell, trimmed[0..i]);
                const right = evaluateArithmeticExpression(shell, trimmed[i + 1 ..]);
                return left - right;
            }
        }
    }

    if (std.mem.indexOf(u8, trimmed, "*")) |pos| {
        const left = evaluateArithmeticExpression(shell, trimmed[0..pos]);
        const right = evaluateArithmeticExpression(shell, trimmed[pos + 1 ..]);
        return left * right;
    }

    if (std.mem.indexOf(u8, trimmed, "/")) |pos| {
        const left = evaluateArithmeticExpression(shell, trimmed[0..pos]);
        const right = evaluateArithmeticExpression(shell, trimmed[pos + 1 ..]);
        if (right == 0) return 0;
        return @divTrunc(left, right);
    }

    return 0;
}
