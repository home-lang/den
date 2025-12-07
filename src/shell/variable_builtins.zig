//! Variable Builtins Implementation
//!
//! This module implements variable-related shell builtins:
//! - local: declare local variables in function scope
//! - declare/typeset: declare variables with attributes
//! - readonly: declare readonly variables
//! - let: evaluate arithmetic expressions

const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");
const arithmetic = @import("../utils/arithmetic.zig");

// Forward declaration for Shell type
const Shell = @import("../shell.zig").Shell;

/// Builtin: local - declare local variables in function scope
pub fn builtinLocal(shell: *Shell, cmd: *types.ParsedCommand) !void {
    // Check if we're inside a function
    if (shell.function_manager.currentFrame() == null) {
        // Outside function - use environment variables as fallback
        if (cmd.args.len == 0) {
            try IO.eprint("local: can only be used in a function\n", .{});
            shell.last_exit_code = 1;
            return;
        }

        // Still set variables for compatibility
        for (cmd.args) |arg| {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
                const var_name = arg[0..eq_pos];
                const var_value = arg[eq_pos + 1 ..];
                const value = try shell.allocator.dupe(u8, var_value);
                const gop = try shell.environment.getOrPut(var_name);
                if (gop.found_existing) {
                    shell.allocator.free(gop.value_ptr.*);
                    gop.value_ptr.* = value;
                } else {
                    const key = try shell.allocator.dupe(u8, var_name);
                    gop.key_ptr.* = key;
                    gop.value_ptr.* = value;
                }
            }
        }
        shell.last_exit_code = 0;
        return;
    }

    if (cmd.args.len == 0) {
        // List local variables in current function
        if (shell.function_manager.currentFrame()) |frame| {
            var iter = frame.local_vars.iterator();
            while (iter.next()) |entry| {
                try IO.print("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        }
        shell.last_exit_code = 0;
        return;
    }

    // Set local variables in function scope
    for (cmd.args) |arg| {
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
            const var_name = arg[0..eq_pos];
            const var_value = arg[eq_pos + 1 ..];
            shell.function_manager.setLocal(var_name, var_value) catch {
                try IO.eprint("local: {s}: failed to set variable\n", .{var_name});
                shell.last_exit_code = 1;
                return;
            };
        } else {
            // Declare empty variable
            shell.function_manager.setLocal(arg, "") catch {
                try IO.eprint("local: {s}: failed to set variable\n", .{arg});
                shell.last_exit_code = 1;
                return;
            };
        }
    }
    shell.last_exit_code = 0;
}

/// Builtin: declare/typeset - declare variables with attributes
/// Flags: -a (array), -A (assoc), -i (integer), -l (lowercase), -u (uppercase),
///        -r (readonly), -x (export), -n (nameref), -p (print), -f (functions)
pub fn builtinDeclare(shell: *Shell, cmd: *types.ParsedCommand) !void {
    var attrs = types.VarAttributes{};
    var print_mode = false;
    var function_mode = false;
    var remove_attrs = false;
    var arg_start: usize = 0;

    // Parse flags
    while (arg_start < cmd.args.len) {
        const arg = cmd.args[arg_start];
        if (arg.len > 0 and arg[0] == '-') {
            arg_start += 1;
            for (arg[1..]) |c| {
                switch (c) {
                    'a' => attrs.indexed_array = true,
                    'A' => attrs.assoc_array = true,
                    'i' => attrs.integer = true,
                    'l' => attrs.lowercase = true,
                    'u' => attrs.uppercase = true,
                    'r' => attrs.readonly = true,
                    'x' => attrs.exported = true,
                    'n' => attrs.nameref = true,
                    'p' => print_mode = true,
                    'f' => function_mode = true,
                    else => {},
                }
            }
        } else if (arg.len > 0 and arg[0] == '+') {
            // +attr removes the attribute
            arg_start += 1;
            remove_attrs = true;
            for (arg[1..]) |c| {
                switch (c) {
                    'a' => attrs.indexed_array = true,
                    'A' => attrs.assoc_array = true,
                    'i' => attrs.integer = true,
                    'l' => attrs.lowercase = true,
                    'u' => attrs.uppercase = true,
                    'r' => attrs.readonly = true,
                    'x' => attrs.exported = true,
                    'n' => attrs.nameref = true,
                    else => {},
                }
            }
        } else {
            break;
        }
    }

    // Print mode: show variables with their attributes
    if (print_mode and arg_start >= cmd.args.len) {
        // Print all variables with attributes
        var it = shell.var_attributes.iterator();
        while (it.next()) |entry| {
            try printDeclare(entry.key_ptr.*, entry.value_ptr.*);
        }
        shell.last_exit_code = 0;
        return;
    }

    // Function mode: show functions
    if (function_mode and arg_start >= cmd.args.len) {
        var it = shell.function_manager.functions.iterator();
        while (it.next()) |entry| {
            try IO.print("{s} ()\n{{\n", .{entry.key_ptr.*});
            for (entry.value_ptr.*.body) |line| {
                try IO.print("    {s}\n", .{line});
            }
            try IO.print("}}\n", .{});
        }
        shell.last_exit_code = 0;
        return;
    }

    // No arguments after flags - just declare with attributes
    if (arg_start >= cmd.args.len) {
        shell.last_exit_code = 0;
        return;
    }

    // Process variable declarations
    for (cmd.args[arg_start..]) |arg| {
        // Parse name[=value] or name[key]=value for assoc arrays
        var var_name: []const u8 = undefined;
        var var_value: ?[]const u8 = null;
        var assoc_key: ?[]const u8 = null;

        if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
            const name_part = arg[0..eq_pos];
            var_value = arg[eq_pos + 1 ..];

            // Check for array subscript: name[key]
            if (std.mem.indexOfScalar(u8, name_part, '[')) |bracket_pos| {
                if (std.mem.indexOfScalar(u8, name_part, ']')) |close_pos| {
                    if (close_pos > bracket_pos) {
                        var_name = name_part[0..bracket_pos];
                        assoc_key = name_part[bracket_pos + 1 .. close_pos];
                    } else {
                        var_name = name_part;
                    }
                } else {
                    var_name = name_part;
                }
            } else {
                var_name = name_part;
            }
        } else {
            var_name = arg;
        }

        // Check if readonly
        if (shell.var_attributes.get(var_name)) |existing| {
            if (existing.readonly and !remove_attrs) {
                try IO.eprint("den: {s}: readonly variable\n", .{var_name});
                shell.last_exit_code = 1;
                continue;
            }
        }

        // Handle associative array assignment
        if (attrs.assoc_array or assoc_key != null) {
            const gop = try shell.assoc_arrays.getOrPut(var_name);
            if (!gop.found_existing) {
                const key = try shell.allocator.dupe(u8, var_name);
                gop.key_ptr.* = key;
                gop.value_ptr.* = std.StringHashMap([]const u8).init(shell.allocator);
            }

            if (assoc_key) |key| {
                if (var_value) |value| {
                    const dup_key = try shell.allocator.dupe(u8, key);
                    const dup_value = try shell.allocator.dupe(u8, value);
                    const inner_gop = try gop.value_ptr.getOrPut(dup_key);
                    if (inner_gop.found_existing) {
                        shell.allocator.free(inner_gop.key_ptr.*);
                        shell.allocator.free(inner_gop.value_ptr.*);
                    }
                    inner_gop.key_ptr.* = dup_key;
                    inner_gop.value_ptr.* = dup_value;
                }
            }

            // Store attributes
            try setVarAttributes(shell, var_name, attrs, remove_attrs);
        } else if (attrs.indexed_array) {
            // Handle indexed array
            const gop = try shell.arrays.getOrPut(var_name);
            if (!gop.found_existing) {
                const key = try shell.allocator.dupe(u8, var_name);
                gop.key_ptr.* = key;
                gop.value_ptr.* = &[_][]const u8{};
            }
            try setVarAttributes(shell, var_name, attrs, remove_attrs);
        } else {
            // Regular variable
            if (var_value) |value| {
                var final_value = value;

                // Apply integer attribute
                if (attrs.integer) {
                    // Evaluate as arithmetic expression
                    var arith = arithmetic.Arithmetic.initWithVariables(shell.allocator, &shell.environment);
                    const result = arith.eval(value) catch 0;
                    var buf: [32]u8 = undefined;
                    const num_str = std.fmt.bufPrint(&buf, "{d}", .{result}) catch "0";
                    final_value = num_str;
                }

                // Apply case conversion
                if (attrs.lowercase) {
                    const lower = try shell.allocator.alloc(u8, final_value.len);
                    for (final_value, 0..) |c, i| {
                        lower[i] = std.ascii.toLower(c);
                    }
                    final_value = lower;
                } else if (attrs.uppercase) {
                    const upper = try shell.allocator.alloc(u8, final_value.len);
                    for (final_value, 0..) |c, i| {
                        upper[i] = std.ascii.toUpper(c);
                    }
                    final_value = upper;
                }

                // Set the variable
                const dup_value = try shell.allocator.dupe(u8, final_value);
                const gop = try shell.environment.getOrPut(var_name);
                if (gop.found_existing) {
                    shell.allocator.free(gop.value_ptr.*);
                    gop.value_ptr.* = dup_value;
                } else {
                    const key = try shell.allocator.dupe(u8, var_name);
                    gop.key_ptr.* = key;
                    gop.value_ptr.* = dup_value;
                }

                // Export if -x
                if (attrs.exported) {
                    // Variable is already in environment, which is exported
                }
            }

            try setVarAttributes(shell, var_name, attrs, remove_attrs);
        }
    }

    shell.last_exit_code = 0;
}

/// Helper to print declare output
pub fn printDeclare(name: []const u8, attrs: types.VarAttributes) !void {
    var flags_buf: [16]u8 = undefined;
    var flags_len: usize = 0;

    if (attrs.readonly) {
        flags_buf[flags_len] = 'r';
        flags_len += 1;
    }
    if (attrs.integer) {
        flags_buf[flags_len] = 'i';
        flags_len += 1;
    }
    if (attrs.exported) {
        flags_buf[flags_len] = 'x';
        flags_len += 1;
    }
    if (attrs.lowercase) {
        flags_buf[flags_len] = 'l';
        flags_len += 1;
    }
    if (attrs.uppercase) {
        flags_buf[flags_len] = 'u';
        flags_len += 1;
    }
    if (attrs.nameref) {
        flags_buf[flags_len] = 'n';
        flags_len += 1;
    }
    if (attrs.indexed_array) {
        flags_buf[flags_len] = 'a';
        flags_len += 1;
    }
    if (attrs.assoc_array) {
        flags_buf[flags_len] = 'A';
        flags_len += 1;
    }

    if (flags_len > 0) {
        try IO.print("declare -{s} {s}\n", .{ flags_buf[0..flags_len], name });
    } else {
        try IO.print("declare -- {s}\n", .{name});
    }
}

/// Helper to set variable attributes
pub fn setVarAttributes(shell: *Shell, name: []const u8, attrs: types.VarAttributes, remove: bool) !void {
    const gop = try shell.var_attributes.getOrPut(name);
    if (!gop.found_existing) {
        const key = try shell.allocator.dupe(u8, name);
        gop.key_ptr.* = key;
        gop.value_ptr.* = types.VarAttributes{};
    }

    if (remove) {
        // Remove specified attributes
        if (attrs.readonly) gop.value_ptr.*.readonly = false;
        if (attrs.integer) gop.value_ptr.*.integer = false;
        if (attrs.exported) gop.value_ptr.*.exported = false;
        if (attrs.lowercase) gop.value_ptr.*.lowercase = false;
        if (attrs.uppercase) gop.value_ptr.*.uppercase = false;
        if (attrs.nameref) gop.value_ptr.*.nameref = false;
        if (attrs.indexed_array) gop.value_ptr.*.indexed_array = false;
        if (attrs.assoc_array) gop.value_ptr.*.assoc_array = false;
    } else {
        // Add specified attributes
        if (attrs.readonly) gop.value_ptr.*.readonly = true;
        if (attrs.integer) gop.value_ptr.*.integer = true;
        if (attrs.exported) gop.value_ptr.*.exported = true;
        if (attrs.lowercase) gop.value_ptr.*.lowercase = true;
        if (attrs.uppercase) gop.value_ptr.*.uppercase = true;
        if (attrs.nameref) gop.value_ptr.*.nameref = true;
        if (attrs.indexed_array) gop.value_ptr.*.indexed_array = true;
        if (attrs.assoc_array) gop.value_ptr.*.assoc_array = true;
    }
}

/// Builtin: readonly - declare readonly variables
pub fn builtinReadonly(shell: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        // Print all readonly variables
        var it = shell.var_attributes.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.readonly) {
                if (shell.environment.get(entry.key_ptr.*)) |value| {
                    try IO.print("declare -r {s}=\"{s}\"\n", .{ entry.key_ptr.*, value });
                } else {
                    try IO.print("declare -r {s}\n", .{entry.key_ptr.*});
                }
            }
        }
        shell.last_exit_code = 0;
        return;
    }

    // Set variables as readonly
    for (cmd.args) |arg| {
        var var_name: []const u8 = undefined;
        var var_value: ?[]const u8 = null;

        if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
            var_name = arg[0..eq_pos];
            var_value = arg[eq_pos + 1 ..];
        } else {
            var_name = arg;
        }

        // Check if already readonly
        if (shell.var_attributes.get(var_name)) |existing| {
            if (existing.readonly) {
                try IO.eprint("den: {s}: readonly variable\n", .{var_name});
                shell.last_exit_code = 1;
                continue;
            }
        }

        // Set value if provided
        if (var_value) |value| {
            const dup_value = try shell.allocator.dupe(u8, value);
            const gop = try shell.environment.getOrPut(var_name);
            if (gop.found_existing) {
                shell.allocator.free(gop.value_ptr.*);
                gop.value_ptr.* = dup_value;
            } else {
                const key = try shell.allocator.dupe(u8, var_name);
                gop.key_ptr.* = key;
                gop.value_ptr.* = dup_value;
            }
        }

        // Mark as readonly
        const gop = try shell.var_attributes.getOrPut(var_name);
        if (!gop.found_existing) {
            const key = try shell.allocator.dupe(u8, var_name);
            gop.key_ptr.* = key;
            gop.value_ptr.* = types.VarAttributes{};
        }
        gop.value_ptr.*.readonly = true;
    }
    shell.last_exit_code = 0;
}

/// Builtin: typeset - alias for declare (bash compatibility)
pub fn builtinTypeset(shell: *Shell, cmd: *types.ParsedCommand) !void {
    try builtinDeclare(shell, cmd);
}

/// Builtin: let - evaluate arithmetic expressions
pub fn builtinLet(shell: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        try IO.eprint("den: let: usage: let expression [expression ...]\n", .{});
        shell.last_exit_code = 1;
        return;
    }

    var arith = arithmetic.Arithmetic.initWithVariables(shell.allocator, &shell.environment);
    var last_result: i64 = 0;

    for (cmd.args) |arg| {
        // Handle assignment: var=expr or var+=expr etc
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
            // Check for compound assignment operators
            var op_start = eq_pos;
            var compound_op: ?u8 = null;
            if (eq_pos > 0) {
                const before = arg[eq_pos - 1];
                if (before == '+' or before == '-' or before == '*' or before == '/' or before == '%') {
                    compound_op = before;
                    op_start = eq_pos - 1;
                }
            }

            const var_name = arg[0..op_start];
            const expr = arg[eq_pos + 1 ..];

            // Evaluate expression
            var result = arith.eval(expr) catch |err| {
                try IO.eprint("den: let: {s}: arithmetic error: {}\n", .{ expr, err });
                shell.last_exit_code = 1;
                return;
            };

            // Apply compound operator
            if (compound_op) |op| {
                const current_val: i64 = blk: {
                    if (shell.environment.get(var_name)) |val| {
                        break :blk std.fmt.parseInt(i64, val, 10) catch 0;
                    }
                    break :blk 0;
                };
                result = switch (op) {
                    '+' => current_val + result,
                    '-' => current_val - result,
                    '*' => current_val * result,
                    '/' => if (result != 0) @divTrunc(current_val, result) else 0,
                    '%' => if (result != 0) @mod(current_val, result) else 0,
                    else => result,
                };
            }

            // Store result
            var buf: [32]u8 = undefined;
            const result_str = std.fmt.bufPrint(&buf, "{d}", .{result}) catch "0";
            const dup_value = try shell.allocator.dupe(u8, result_str);
            const gop = try shell.environment.getOrPut(var_name);
            if (gop.found_existing) {
                shell.allocator.free(gop.value_ptr.*);
                gop.value_ptr.* = dup_value;
            } else {
                const key = try shell.allocator.dupe(u8, var_name);
                gop.key_ptr.* = key;
                gop.value_ptr.* = dup_value;
            }
            last_result = result;
        } else {
            // Just evaluate expression
            last_result = arith.eval(arg) catch |err| {
                try IO.eprint("den: let: {s}: arithmetic error: {}\n", .{ arg, err });
                shell.last_exit_code = 1;
                return;
            };
        }
    }

    // Return 1 if last result is 0, else 0 (bash behavior)
    shell.last_exit_code = if (last_result == 0) 1 else 0;
}
