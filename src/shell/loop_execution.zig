//! Loop Execution Module
//!
//! This module implements shell loop constructs:
//! - C-style for loops: for ((init; cond; update)); do body; done
//! - Select loops: select VAR in items; do body; done
//! - Arithmetic evaluation for loop conditions

const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const Expansion = @import("../utils/expansion.zig").Expansion;

// Forward declaration for Shell type
const Shell = @import("../shell.zig").Shell;

/// Execute a one-line C-style for loop: for ((init; cond; update)); do cmd1; cmd2; done
pub fn executeCStyleForLoopOneline(self: *Shell, input: []const u8) !void {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);

    // Find "for ((" and "))"
    if (!std.mem.startsWith(u8, trimmed, "for ((")) {
        try IO.eprint("den: syntax error: expected 'for ((...))\n", .{});
        self.last_exit_code = 1;
        return;
    }

    // Find the closing ))
    const expr_start = 6; // After "for (("
    const expr_end_rel = std.mem.indexOf(u8, trimmed[expr_start..], "))") orelse {
        try IO.eprint("den: syntax error: missing '))'n", .{});
        self.last_exit_code = 1;
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
        self.last_exit_code = 1;
        return;
    }
    body_start = std.mem.trim(u8, body_start[2..], &std.ascii.whitespace);

    // Find "done" keyword - it might be followed by more commands (done; echo $sum)
    const done_pos = std.mem.indexOf(u8, body_start, "done") orelse {
        try IO.eprint("den: syntax error: expected 'done'\n", .{});
        self.last_exit_code = 1;
        return;
    };
    const body_content = std.mem.trim(u8, body_start[0..done_pos], &std.ascii.whitespace);

    // Check if there's anything after 'done' that we need to execute later
    const after_done = body_start[done_pos + 4 ..];
    const remaining_commands = std.mem.trim(u8, after_done, &std.ascii.whitespace);

    // Split body by semicolons (respecting quotes)
    var body_cmds = std.ArrayList([]const u8).empty;
    defer body_cmds.deinit(self.allocator);

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
                try body_cmds.append(self.allocator, cmd);
            }
            cmd_start = i + 1;
        }
    }
    // Don't forget the last command
    const last_cmd = std.mem.trim(u8, body_content[cmd_start..], &std.ascii.whitespace);
    if (last_cmd.len > 0) {
        try body_cmds.append(self.allocator, last_cmd);
    }

    // Execute the C-style for loop inline
    // 1. Execute initialization
    if (parts[0]) |init_stmt| {
        executeArithmeticStatement(self, init_stmt);
    }

    // 2. Loop while condition is true
    var iteration_count: usize = 0;
    const max_iterations: usize = 100000; // Safety limit
    while (iteration_count < max_iterations) : (iteration_count += 1) {
        // Check condition
        if (parts[1]) |cond| {
            if (!evaluateArithmeticCondition(self, cond)) break;
        }

        // Execute body commands - directly using a simple method that avoids recursion
        for (body_cmds.items) |cmd| {
            executeCStyleLoopBodyCommand(self, cmd);
        }

        // Execute update
        if (parts[2]) |update| {
            executeArithmeticStatement(self, update);
        }
    }

    self.last_exit_code = 0;

    // Execute any remaining commands after "done"
    if (remaining_commands.len > 0) {
        // Strip leading semicolon if present
        var cmds_to_run = remaining_commands;
        if (cmds_to_run[0] == ';') {
            cmds_to_run = std.mem.trim(u8, cmds_to_run[1..], &std.ascii.whitespace);
        }
        if (cmds_to_run.len > 0) {
            // Execute the remaining commands using the simplified executor
            var iter = std.mem.splitScalar(u8, cmds_to_run, ';');
            while (iter.next()) |cmd| {
                const trimmed_cmd = std.mem.trim(u8, cmd, &std.ascii.whitespace);
                if (trimmed_cmd.len > 0) {
                    executeCStyleLoopBodyCommand(self, trimmed_cmd);
                }
            }
        }
    }
}

/// Execute a command in the body of a C-style for loop
/// Handles variable assignments directly, delegates other commands to executeCommand
pub fn executeCStyleLoopBodyCommand(self: *Shell, cmd: []const u8) void {
    const trimmed = std.mem.trim(u8, cmd, &std.ascii.whitespace);
    if (trimmed.len == 0) return;

    // First, expand variables in the command
    var positional_params_slice: [64][]const u8 = undefined;
    var param_count: usize = 0;
    for (self.positional_params) |maybe_param| {
        if (maybe_param) |param| {
            positional_params_slice[param_count] = param;
            param_count += 1;
        }
    }

    var expander = Expansion.initWithShell(
        self.allocator,
        &self.environment,
        self.last_exit_code,
        positional_params_slice[0..param_count],
        self.shell_name,
        if (@import("builtin").os.tag == .windows) 0 else @as(i32, @intCast(self.job_manager.getLastPid())),
        self.last_arg,
        self,
    );
    const shell_mod = @import("../shell.zig");
    expander.exec_command_fn = &shell_mod.execCommandCallback;
    expander.arrays = &self.arrays;
    expander.assoc_arrays = &self.assoc_arrays;
    expander.var_attributes = &self.var_attributes;
    const expanded = expander.expand(trimmed) catch {
        self.last_exit_code = 1;
        return;
    };
    defer self.allocator.free(expanded);

    // Handle variable assignment: VAR=value (simple form without command)
    if (std.mem.indexOf(u8, expanded, "=")) |eq_pos| {
        const potential_var = expanded[0..eq_pos];
        var is_valid_var = potential_var.len > 0;
        for (potential_var) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') {
                is_valid_var = false;
                break;
            }
        }
        if (is_valid_var) {
            if (std.mem.indexOf(u8, expanded[0..eq_pos], " ") == null) {
                const value = expanded[eq_pos + 1 ..];
                setArithVariable(self, potential_var, value);
                self.last_exit_code = 0;
                return;
            }
        }
    }

    // Use the full executeCommand for all other commands
    self.executeCommand(expanded) catch {
        self.last_exit_code = 1;
    };
}

/// Execute input that contains a C-style for loop with commands before and/or after
pub fn executeWithCStyleForLoop(self: *Shell, input: []const u8) !void {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);

    // Find the position of "for ((" in the input
    const for_pos = std.mem.indexOf(u8, trimmed, "for ((") orelse {
        executeCStyleLoopBodyCommand(self, input);
        return;
    };

    // Extract any commands before the for loop
    const before_for = std.mem.trim(u8, trimmed[0..for_pos], &std.ascii.whitespace);

    // Execute commands before the for loop
    if (before_for.len > 0) {
        var cmds = before_for;
        if (cmds.len > 0 and cmds[cmds.len - 1] == ';') {
            cmds = std.mem.trim(u8, cmds[0 .. cmds.len - 1], &std.ascii.whitespace);
        }
        if (cmds.len > 0) {
            executeCStyleLoopBodyCommand(self, cmds);
        }
    }

    // Now extract the for loop
    const for_content = trimmed[for_pos..];

    // Find "done" keyword with proper boundary checking
    var done_pos: ?usize = null;
    var search_pos: usize = 0;
    while (search_pos < for_content.len) {
        const maybe_done = std.mem.indexOf(u8, for_content[search_pos..], "done");
        if (maybe_done) |pos| {
            const actual_pos = search_pos + pos;
            const at_start = actual_pos == 0 or !std.ascii.isAlphanumeric(for_content[actual_pos - 1]);
            const at_end = actual_pos + 4 >= for_content.len or
                !std.ascii.isAlphanumeric(for_content[actual_pos + 4]);
            if (at_start and at_end) {
                done_pos = actual_pos;
                break;
            }
            search_pos = actual_pos + 1;
        } else {
            break;
        }
    }

    if (done_pos == null) {
        try IO.eprint("den: syntax error: expected 'done'\n", .{});
        self.last_exit_code = 1;
        return;
    }

    const for_loop_end = done_pos.? + 4;
    const for_loop = for_content[0..for_loop_end];

    // Execute the for loop
    try executeCStyleForLoopOneline(self, for_loop);

    // Extract any commands after the for loop
    if (for_loop_end < for_content.len) {
        var after_done = std.mem.trim(u8, for_content[for_loop_end..], &std.ascii.whitespace);
        if (after_done.len > 0 and after_done[0] == ';') {
            after_done = std.mem.trim(u8, after_done[1..], &std.ascii.whitespace);
        }
        if (after_done.len > 0) {
            executeCStyleLoopBodyCommand(self, after_done);
        }
    }
}

/// Execute a select loop: select VAR in ITEM1 ITEM2 ...; do BODY; done
pub fn executeSelectLoop(self: *Shell, input: []const u8) !void {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);

    if (!std.mem.startsWith(u8, trimmed, "select ")) {
        try IO.eprint("den: syntax error: expected 'select'\n", .{});
        self.last_exit_code = 1;
        return;
    }

    const after_select = trimmed[7..];

    const in_pos = std.mem.indexOf(u8, after_select, " in ") orelse {
        try IO.eprint("den: syntax error: expected 'in' in select\n", .{});
        self.last_exit_code = 1;
        return;
    };

    const variable = std.mem.trim(u8, after_select[0..in_pos], &std.ascii.whitespace);
    if (variable.len == 0) {
        try IO.eprint("den: syntax error: missing variable in select\n", .{});
        self.last_exit_code = 1;
        return;
    }

    const after_in = after_select[in_pos + 4 ..];
    const do_pos = std.mem.indexOf(u8, after_in, "; do") orelse
        std.mem.indexOf(u8, after_in, ";do") orelse {
        try IO.eprint("den: syntax error: expected 'do' in select\n", .{});
        self.last_exit_code = 1;
        return;
    };

    const items_str = std.mem.trim(u8, after_in[0..do_pos], &std.ascii.whitespace);
    if (items_str.len == 0) {
        try IO.eprint("den: syntax error: no items in select\n", .{});
        self.last_exit_code = 1;
        return;
    }

    var items_buf: [100][]const u8 = undefined;
    var items_count: usize = 0;
    var items_iter = std.mem.tokenizeAny(u8, items_str, " \t");
    while (items_iter.next()) |item| {
        if (items_count >= items_buf.len) break;
        items_buf[items_count] = item;
        items_count += 1;
    }

    if (items_count == 0) {
        try IO.eprint("den: syntax error: no items in select\n", .{});
        self.last_exit_code = 1;
        return;
    }

    const do_keyword_len: usize = if (std.mem.indexOf(u8, after_in, "; do") != null) 4 else 3;
    const body_start_offset = do_pos + do_keyword_len;
    const body_and_rest = after_in[body_start_offset..];

    const done_pos = std.mem.indexOf(u8, body_and_rest, "done") orelse {
        try IO.eprint("den: syntax error: expected 'done' in select\n", .{});
        self.last_exit_code = 1;
        return;
    };

    var body_str = std.mem.trim(u8, body_and_rest[0..done_pos], &std.ascii.whitespace);
    if (body_str.len > 0 and body_str[0] == ';') {
        body_str = std.mem.trim(u8, body_str[1..], &std.ascii.whitespace);
    }
    if (body_str.len > 0 and body_str[body_str.len - 1] == ';') {
        body_str = std.mem.trim(u8, body_str[0 .. body_str.len - 1], &std.ascii.whitespace);
    }

    const ps3 = self.environment.get("PS3") orelse "#? ";

    // Display menu
    try IO.print("\n", .{});
    for (items_buf[0..items_count], 1..) |item, idx| {
        try IO.print("{d}) {s}\n", .{ idx, item });
    }

    // Main select loop
    while (true) {
        try IO.print("{s}", .{ps3});

        var input_buf: [1024]u8 = undefined;
        const bytes_read = if (comptime @import("builtin").os.tag == .windows) blk: {
            var n: u32 = 0;
            const handle = std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) orelse break :blk @as(usize, 0);
            const success = std.os.windows.kernel32.ReadFile(handle, &input_buf, @intCast(input_buf.len), &n, null);
            break :blk if (success == 0) @as(usize, 0) else @as(usize, n);
        } else std.posix.read(std.posix.STDIN_FILENO, &input_buf) catch |err| {
            if (err == error.WouldBlock) continue;
            break;
        };

        if (bytes_read == 0) break;

        const user_input = std.mem.trim(u8, input_buf[0..bytes_read], &std.ascii.whitespace);

        if (user_input.len == 0) {
            try IO.print("\n", .{});
            for (items_buf[0..items_count], 1..) |item, idx| {
                try IO.print("{d}) {s}\n", .{ idx, item });
            }
            continue;
        }

        const selection = std.fmt.parseInt(usize, user_input, 10) catch {
            setArithVariable(self, variable, "");
            setArithVariable(self, "REPLY", user_input);
            executeSelectBody(self, body_str);
            if (self.break_levels > 0) {
                self.break_levels -= 1;
                if (self.break_levels > 0) return;
                break;
            }
            if (self.continue_levels > 0) {
                self.continue_levels -= 1;
                if (self.continue_levels > 0) return;
            }
            continue;
        };

        if (selection == 0 or selection > items_count) {
            setArithVariable(self, variable, "");
            var reply_buf: [32]u8 = undefined;
            const reply_str = std.fmt.bufPrint(&reply_buf, "{d}", .{selection}) catch continue;
            setArithVariable(self, "REPLY", reply_str);
            executeSelectBody(self, body_str);
            if (self.break_levels > 0) {
                self.break_levels -= 1;
                if (self.break_levels > 0) return;
                break;
            }
            if (self.continue_levels > 0) {
                self.continue_levels -= 1;
                if (self.continue_levels > 0) return;
            }
            continue;
        }

        const selected_item = items_buf[selection - 1];
        setArithVariable(self, variable, selected_item);
        var reply_buf: [32]u8 = undefined;
        const reply_str = std.fmt.bufPrint(&reply_buf, "{d}", .{selection}) catch continue;
        setArithVariable(self, "REPLY", reply_str);

        executeSelectBody(self, body_str);

        if (self.break_levels > 0) {
            self.break_levels -= 1;
            if (self.break_levels > 0) return;
            break;
        }
        if (self.continue_levels > 0) {
            self.continue_levels -= 1;
            if (self.continue_levels > 0) return;
        }
    }

    self.last_exit_code = 0;
}

/// Execute select loop body command (non-recursive helper)
pub fn executeSelectBody(self: *Shell, body: []const u8) void {
    var cmd_iter = std.mem.splitSequence(u8, body, ";");
    while (cmd_iter.next()) |cmd| {
        const trimmed_cmd = std.mem.trim(u8, cmd, &std.ascii.whitespace);
        if (trimmed_cmd.len == 0) continue;

        if (std.mem.eql(u8, trimmed_cmd, "break") or std.mem.startsWith(u8, trimmed_cmd, "break ")) {
            if (std.mem.startsWith(u8, trimmed_cmd, "break ")) {
                const level_str = std.mem.trim(u8, trimmed_cmd[6..], &std.ascii.whitespace);
                self.break_levels = std.fmt.parseInt(u32, level_str, 10) catch 1;
                if (self.break_levels == 0) self.break_levels = 1;
            } else {
                self.break_levels = 1;
            }
            return;
        }

        executeCStyleLoopBodyCommand(self, trimmed_cmd);

        if (self.break_levels > 0) return;
    }
}

/// Execute arithmetic statement (like i=0 or i++)
pub fn executeArithmeticStatement(self: *Shell, stmt: []const u8) void {
    const trimmed = std.mem.trim(u8, stmt, &std.ascii.whitespace);
    if (trimmed.len == 0) return;

    // Handle i++ and i--
    if (std.mem.endsWith(u8, trimmed, "++")) {
        const var_name = trimmed[0 .. trimmed.len - 2];
        const current = getVariableValueForArith(self, var_name);
        const num = std.fmt.parseInt(i64, current, 10) catch 0;
        var buf: [32]u8 = undefined;
        const new_val = std.fmt.bufPrint(&buf, "{d}", .{num + 1}) catch return;
        setArithVariable(self, var_name, new_val);
        return;
    }
    if (std.mem.endsWith(u8, trimmed, "--")) {
        const var_name = trimmed[0 .. trimmed.len - 2];
        const current = getVariableValueForArith(self, var_name);
        const num = std.fmt.parseInt(i64, current, 10) catch 0;
        var buf: [32]u8 = undefined;
        const new_val = std.fmt.bufPrint(&buf, "{d}", .{num - 1}) catch return;
        setArithVariable(self, var_name, new_val);
        return;
    }

    // Handle assignment: var=expr
    if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
        const var_name = std.mem.trim(u8, trimmed[0..eq_pos], &std.ascii.whitespace);
        const expr = std.mem.trim(u8, trimmed[eq_pos + 1 ..], &std.ascii.whitespace);

        const value = evaluateArithmeticExpr(self, expr);
        var buf: [32]u8 = undefined;
        const val_str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
        setArithVariable(self, var_name, val_str);
    }
}

/// Set a variable for arithmetic operations
pub fn setArithVariable(self: *Shell, name: []const u8, value: []const u8) void {
    const resolved_name = self.resolveNameref(name);

    // Apply case conversion if variable has lowercase/uppercase attribute
    var final_value = value;
    var case_buf: ?[]u8 = null;
    if (self.var_attributes.get(resolved_name)) |attrs| {
        if (attrs.lowercase) {
            const lower = self.allocator.alloc(u8, value.len) catch null;
            if (lower) |buf| {
                for (value, 0..) |c, i| buf[i] = std.ascii.toLower(c);
                case_buf = buf;
                final_value = buf;
            }
        } else if (attrs.uppercase) {
            const upper = self.allocator.alloc(u8, value.len) catch null;
            if (upper) |buf| {
                for (value, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
                case_buf = buf;
                final_value = buf;
            }
        }
    }

    // If inside a function and the variable exists as a local, update local instead
    if (self.function_manager.currentFrame()) |frame| {
        if (frame.local_vars.getKey(resolved_name)) |_| {
            const val = if (case_buf) |buf| buf else self.allocator.dupe(u8, final_value) catch return;
            const gop = frame.local_vars.getOrPut(resolved_name) catch {
                self.allocator.free(val);
                return;
            };
            if (gop.found_existing) {
                self.allocator.free(gop.value_ptr.*);
            }
            gop.value_ptr.* = val;
            return;
        }
    }

    const val = if (case_buf) |buf| buf else self.allocator.dupe(u8, final_value) catch return;

    const gop = self.environment.getOrPut(resolved_name) catch {
        self.allocator.free(val);
        return;
    };
    if (gop.found_existing) {
        self.allocator.free(gop.value_ptr.*);
        gop.value_ptr.* = val;
    } else {
        const key = self.allocator.dupe(u8, resolved_name) catch {
            self.allocator.free(val);
            _ = self.environment.remove(resolved_name);
            return;
        };
        gop.key_ptr.* = key;
        gop.value_ptr.* = val;
    }
}

/// Evaluate arithmetic condition (returns true if non-zero)
pub fn evaluateArithmeticCondition(self: *Shell, cond: []const u8) bool {
    const trimmed = std.mem.trim(u8, cond, &std.ascii.whitespace);
    if (trimmed.len == 0) return true;

    if (std.mem.indexOf(u8, trimmed, "<=")) |pos| {
        const left = evaluateArithmeticExpr(self, trimmed[0..pos]);
        const right = evaluateArithmeticExpr(self, trimmed[pos + 2 ..]);
        return left <= right;
    }
    if (std.mem.indexOf(u8, trimmed, ">=")) |pos| {
        const left = evaluateArithmeticExpr(self, trimmed[0..pos]);
        const right = evaluateArithmeticExpr(self, trimmed[pos + 2 ..]);
        return left >= right;
    }
    if (std.mem.indexOf(u8, trimmed, "!=")) |pos| {
        const left = evaluateArithmeticExpr(self, trimmed[0..pos]);
        const right = evaluateArithmeticExpr(self, trimmed[pos + 2 ..]);
        return left != right;
    }
    if (std.mem.indexOf(u8, trimmed, "==")) |pos| {
        const left = evaluateArithmeticExpr(self, trimmed[0..pos]);
        const right = evaluateArithmeticExpr(self, trimmed[pos + 2 ..]);
        return left == right;
    }
    if (std.mem.indexOf(u8, trimmed, "<")) |pos| {
        const left = evaluateArithmeticExpr(self, trimmed[0..pos]);
        const right = evaluateArithmeticExpr(self, trimmed[pos + 1 ..]);
        return left < right;
    }
    if (std.mem.indexOf(u8, trimmed, ">")) |pos| {
        const left = evaluateArithmeticExpr(self, trimmed[0..pos]);
        const right = evaluateArithmeticExpr(self, trimmed[pos + 1 ..]);
        return left > right;
    }

    return evaluateArithmeticExpr(self, trimmed) != 0;
}

/// Evaluate arithmetic expression
pub fn evaluateArithmeticExpr(self: *Shell, expr: []const u8) i64 {
    const trimmed = std.mem.trim(u8, expr, &std.ascii.whitespace);
    if (trimmed.len == 0) return 0;

    // Handle addition
    if (std.mem.lastIndexOf(u8, trimmed, "+")) |pos| {
        if (pos > 0 and pos < trimmed.len - 1) {
            const left = evaluateArithmeticExpr(self, trimmed[0..pos]);
            const right = evaluateArithmeticExpr(self, trimmed[pos + 1 ..]);
            return left + right;
        }
    }

    // Handle subtraction
    var i: usize = trimmed.len;
    while (i > 0) {
        i -= 1;
        if (trimmed[i] == '-' and i > 0) {
            const left = evaluateArithmeticExpr(self, trimmed[0..i]);
            const right = evaluateArithmeticExpr(self, trimmed[i + 1 ..]);
            return left - right;
        }
    }

    // Handle multiplication
    if (std.mem.lastIndexOf(u8, trimmed, "*")) |pos| {
        if (pos > 0 and pos < trimmed.len - 1) {
            const left = evaluateArithmeticExpr(self, trimmed[0..pos]);
            const right = evaluateArithmeticExpr(self, trimmed[pos + 1 ..]);
            return left * right;
        }
    }

    // Handle division
    if (std.mem.lastIndexOf(u8, trimmed, "/")) |pos| {
        if (pos > 0 and pos < trimmed.len - 1) {
            const left = evaluateArithmeticExpr(self, trimmed[0..pos]);
            const right = evaluateArithmeticExpr(self, trimmed[pos + 1 ..]);
            if (right == 0) return 0;
            return @divTrunc(left, right);
        }
    }

    // Try to parse as number
    if (std.fmt.parseInt(i64, trimmed, 10)) |num| {
        return num;
    } else |_| {}

    // Otherwise, treat as variable name
    const val = getVariableValueForArith(self, trimmed);
    return std.fmt.parseInt(i64, val, 10) catch 0;
}

/// Get variable value (helper for arithmetic)
pub fn getVariableValueForArith(self: *Shell, name: []const u8) []const u8 {
    if (self.environment.get(name)) |val| {
        return val;
    }
    return "0";
}
