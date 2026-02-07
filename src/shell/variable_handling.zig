//! Variable Handling Module
//! Handles variable resolution, namerefs, and array assignments

const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const Shell = @import("../shell.zig").Shell;

/// Resolve nameref chain to get the actual variable name
pub fn resolveNameref(self: *Shell, name: []const u8) []const u8 {
    var current_name = name;
    var depth: u32 = 0;
    const max_depth = 10;

    while (depth < max_depth) : (depth += 1) {
        if (self.var_attributes.get(current_name)) |attrs| {
            if (attrs.nameref) {
                // This is a nameref, its value is the name of the referenced variable
                if (self.environment.get(current_name)) |ref_name| {
                    current_name = ref_name;
                    continue;
                }
            }
        }
        // Not a nameref or no more references to follow
        break;
    }
    return current_name;
}

/// Get variable value following namerefs
pub fn getVariableValue(self: *Shell, name: []const u8) ?[]const u8 {
    const resolved_name = resolveNameref(self, name);
    return self.environment.get(resolved_name);
}

/// Set variable value following namerefs
pub fn setVariableValue(self: *Shell, name: []const u8, value: []const u8) !void {
    const resolved_name = resolveNameref(self, name);

    // Check if readonly
    if (self.var_attributes.get(resolved_name)) |attrs| {
        if (attrs.readonly) {
            try IO.eprint("den: {s}: readonly variable\n", .{resolved_name});
            return error.ReadonlyVariable;
        }
    }

    // If inside a function and the variable exists as a local, update local instead
    if (self.function_manager.currentFrame()) |frame| {
        if (frame.local_vars.getKey(resolved_name)) |_| {
            const val = try self.allocator.dupe(u8, value);
            const gop = try frame.local_vars.getOrPut(resolved_name);
            if (gop.found_existing) {
                self.allocator.free(gop.value_ptr.*);
            }
            gop.value_ptr.* = val;
            return;
        }
    }

    // Set the value in global environment
    const gop = try self.environment.getOrPut(resolved_name);
    if (gop.found_existing) {
        self.allocator.free(gop.value_ptr.*);
    } else {
        gop.key_ptr.* = try self.allocator.dupe(u8, resolved_name);
    }
    gop.value_ptr.* = try self.allocator.dupe(u8, value);
}

/// Check if input is an array element assignment: name[index]=value
pub fn isArrayElementAssignment(input: []const u8) bool {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
    // Look for pattern: name[index]=value
    const bracket_pos = std.mem.indexOfScalar(u8, trimmed, '[') orelse return false;
    if (bracket_pos == 0) return false;
    // Verify name part is valid
    for (trimmed[0..bracket_pos]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    // Find closing bracket followed by =
    const close_bracket = std.mem.indexOfScalar(u8, trimmed[bracket_pos..], ']') orelse return false;
    const abs_close = bracket_pos + close_bracket;
    if (abs_close + 1 >= trimmed.len) return false;
    return trimmed[abs_close + 1] == '=';
}

/// Execute array element assignment: name[index]=value
pub fn executeArrayElementAssignment(self: *Shell, input: []const u8) !void {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
    const bracket_pos = std.mem.indexOfScalar(u8, trimmed, '[') orelse return;
    const name = trimmed[0..bracket_pos];

    const close_bracket = std.mem.indexOfScalar(u8, trimmed[bracket_pos..], ']') orelse return;
    const abs_close = bracket_pos + close_bracket;
    const index_str = trimmed[bracket_pos + 1 .. abs_close];
    const index = std.fmt.parseInt(usize, index_str, 10) catch return;

    // Value is everything after ]=
    var raw_value = trimmed[abs_close + 2 ..];
    // Strip quotes
    if (raw_value.len >= 2 and
        ((raw_value[0] == '"' and raw_value[raw_value.len - 1] == '"') or
        (raw_value[0] == '\'' and raw_value[raw_value.len - 1] == '\'')))
    {
        raw_value = raw_value[1 .. raw_value.len - 1];
    }

    // Get or create the array
    if (self.arrays.get(name)) |old_array| {
        // Extend if needed
        if (index < old_array.len) {
            // Replace existing element
            self.allocator.free(old_array[index]);
            old_array[index] = try self.allocator.dupe(u8, raw_value);
        } else {
            // Extend the array
            var new_array = try self.allocator.alloc([]const u8, index + 1);
            // Copy old elements
            var i: usize = 0;
            while (i < old_array.len) : (i += 1) {
                new_array[i] = old_array[i];
            }
            // Fill gaps with empty strings
            while (i < index) : (i += 1) {
                new_array[i] = try self.allocator.dupe(u8, "");
            }
            new_array[index] = try self.allocator.dupe(u8, raw_value);
            self.allocator.free(old_array);
            // Re-insert into map
            const key = self.arrays.getKey(name).?;
            self.arrays.putAssumeCapacity(key, new_array);
        }
    } else {
        // Create new array with this element
        var new_array = try self.allocator.alloc([]const u8, index + 1);
        var i: usize = 0;
        while (i < index) : (i += 1) {
            new_array[i] = try self.allocator.dupe(u8, "");
        }
        new_array[index] = try self.allocator.dupe(u8, raw_value);
        const key = try self.allocator.dupe(u8, name);
        try self.arrays.put(key, new_array);
    }
    self.last_exit_code = 0;
}

/// Check if input is an array assignment: name=(value1 value2 ...)
pub fn isArrayAssignment(input: []const u8) bool {
    // Look for pattern: name=(...) or name+=(...)
    const eq_pos = std.mem.indexOfScalar(u8, input, '=') orelse return false;
    if (eq_pos >= input.len - 1) return false;
    if (input[eq_pos + 1] != '(') return false;

    // Check for closing paren
    return std.mem.indexOfScalar(u8, input[eq_pos + 2 ..], ')') != null;
}

/// Parse and execute array assignment (or array append with +=)
pub fn executeArrayAssignment(self: *Shell, input: []const u8) !void {
    const eq_pos = std.mem.indexOfScalar(u8, input, '=') orelse return error.InvalidSyntax;
    const is_append = eq_pos > 0 and input[eq_pos - 1] == '+';
    const name_end = if (is_append) eq_pos - 1 else eq_pos;
    const name = std.mem.trim(u8, input[0..name_end], &std.ascii.whitespace);

    // Validate variable name
    if (name.len == 0) return error.InvalidVariableName;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') {
            return error.InvalidVariableName;
        }
    }

    // Find array content between ( and )
    const start_paren = eq_pos + 1;
    if (input[start_paren] != '(') return error.InvalidSyntax;

    const end_paren = std.mem.lastIndexOfScalar(u8, input, ')') orelse return error.InvalidSyntax;
    if (end_paren <= start_paren + 1) {
        // Empty array: name=()
        const key = try self.allocator.dupe(u8, name);
        const empty_array = try self.allocator.alloc([]const u8, 0);

        // Free old array if exists
        if (self.arrays.get(name)) |old_array| {
            for (old_array) |item| {
                self.allocator.free(item);
            }
            self.allocator.free(old_array);
            const old_key = self.arrays.getKey(name).?;
            self.allocator.free(old_key);
            _ = self.arrays.remove(name);
        }

        try self.arrays.put(key, empty_array);
        self.last_exit_code = 0;
        return;
    }

    // Parse array elements
    const content = std.mem.trim(u8, input[start_paren + 1 .. end_paren], &std.ascii.whitespace);

    // Count elements first
    var count: usize = 0;
    var count_iter = std.mem.tokenizeAny(u8, content, &std.ascii.whitespace);
    while (count_iter.next()) |_| {
        count += 1;
    }

    // Allocate array
    const array = try self.allocator.alloc([]const u8, count);
    errdefer self.allocator.free(array);

    // Fill array
    var i: usize = 0;
    var iter = std.mem.tokenizeAny(u8, content, &std.ascii.whitespace);
    while (iter.next()) |token| : (i += 1) {
        array[i] = try self.allocator.dupe(u8, token);
    }

    if (is_append) {
        // Append to existing array
        if (self.arrays.get(name)) |old_array| {
            const new_array = try self.allocator.alloc([]const u8, old_array.len + array.len);
            @memcpy(new_array[0..old_array.len], old_array);
            @memcpy(new_array[old_array.len..], array);
            // Free old array slice (but keep element strings since they're now in new_array)
            self.allocator.free(old_array);
            // Free new elements slice (elements are now in new_array)
            self.allocator.free(array);
            const gop = try self.arrays.getOrPut(name);
            gop.value_ptr.* = new_array;
        } else {
            // No existing array - just create new one
            const key = try self.allocator.dupe(u8, name);
            try self.arrays.put(key, array);
        }
    } else {
        // Store array (replace)
        const key = try self.allocator.dupe(u8, name);

        // Free old array if exists
        if (self.arrays.get(name)) |old_array| {
            for (old_array) |item| {
                self.allocator.free(item);
            }
            self.allocator.free(old_array);
            const old_key = self.arrays.getKey(name).?;
            self.allocator.free(old_key);
            _ = self.arrays.remove(name);
        }

        try self.arrays.put(key, array);
    }
    self.last_exit_code = 0;
}
