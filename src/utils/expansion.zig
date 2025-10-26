const std = @import("std");

/// Variable expansion utilities
pub const Expansion = struct {
    allocator: std.mem.Allocator,
    environment: *std.StringHashMap([]const u8),
    last_exit_code: i32,

    pub fn init(allocator: std.mem.Allocator, environment: *std.StringHashMap([]const u8), last_exit_code: i32) Expansion {
        return .{
            .allocator = allocator,
            .environment = environment,
            .last_exit_code = last_exit_code,
        };
    }

    /// Expand all variables in a string
    /// Returns a newly allocated string with variables expanded
    pub fn expand(self: *Expansion, input: []const u8) ![]u8 {
        // Use fixed buffer approach for Zig 0.15
        var result_buffer: [4096]u8 = undefined;
        var result_len: usize = 0;

        var i: usize = 0;
        while (i < input.len) {
            const char = input[i];

            if (char == '$') {
                // Check if this is an escape sequence
                if (i > 0 and input[i - 1] == '\\') {
                    // Remove the backslash, keep the $
                    if (result_len > 0) result_len -= 1;
                    if (result_len >= result_buffer.len) return error.ExpansionTooLong;
                    result_buffer[result_len] = '$';
                    result_len += 1;
                    i += 1;
                    continue;
                }

                // Try to expand variable
                const expansion_result = try self.expandVariable(input[i..]);

                // Copy expansion result to buffer
                if (result_len + expansion_result.value.len > result_buffer.len) {
                    return error.ExpansionTooLong;
                }
                @memcpy(result_buffer[result_len..result_len + expansion_result.value.len], expansion_result.value);
                result_len += expansion_result.value.len;

                i += expansion_result.consumed;
            } else {
                if (result_len >= result_buffer.len) return error.ExpansionTooLong;
                result_buffer[result_len] = char;
                result_len += 1;
                i += 1;
            }
        }

        // Allocate and return final result
        return try self.allocator.dupe(u8, result_buffer[0..result_len]);
    }

    const ExpansionResult = struct {
        value: []const u8,
        consumed: usize, // How many characters were consumed from input
    };

    /// Expand a single variable starting at $ character
    fn expandVariable(self: *Expansion, input: []const u8) !ExpansionResult {
        if (input.len < 2 or input[0] != '$') {
            return ExpansionResult{ .value = "$", .consumed = 1 };
        }

        // Check for special variables
        const next_char = input[1];
        switch (next_char) {
            '?' => {
                // $? - last exit code
                const value = try std.fmt.allocPrint(self.allocator, "{d}", .{self.last_exit_code});
                return ExpansionResult{ .value = value, .consumed = 2 };
            },
            '$' => {
                // $$ - current process ID
                const pid = std.c.getpid();
                const value = try std.fmt.allocPrint(self.allocator, "{d}", .{pid});
                return ExpansionResult{ .value = value, .consumed = 2 };
            },
            '0'...'9' => {
                // $0, $1, etc. - positional arguments (TODO: implement when we have functions)
                return ExpansionResult{ .value = "", .consumed = 2 };
            },
            '{' => {
                // ${VAR} - braced expansion
                return try self.expandBracedVariable(input);
            },
            else => {
                // $VAR - simple variable
                return try self.expandSimpleVariable(input);
            },
        }
    }

    /// Expand ${VAR} or ${VAR:-default} form
    fn expandBracedVariable(self: *Expansion, input: []const u8) !ExpansionResult {
        if (input.len < 3 or input[0] != '$' or input[1] != '{') {
            return ExpansionResult{ .value = "$", .consumed = 1 };
        }

        // Find closing brace
        var end: usize = 2;
        while (end < input.len and input[end] != '}') {
            end += 1;
        }

        if (end >= input.len) {
            // No closing brace found - treat as literal
            return ExpansionResult{ .value = "$", .consumed = 1 };
        }

        const content = input[2..end];

        // Check for default value syntax: ${VAR:-default}
        if (std.mem.indexOf(u8, content, ":-")) |sep_pos| {
            const var_name = content[0..sep_pos];
            const default_value = content[sep_pos + 2 ..];

            if (self.environment.get(var_name)) |value| {
                if (value.len > 0) {
                    const result = try self.allocator.dupe(u8, value);
                    return ExpansionResult{ .value = result, .consumed = end + 1 };
                }
            }

            // Use default value
            const result = try self.allocator.dupe(u8, default_value);
            return ExpansionResult{ .value = result, .consumed = end + 1 };
        }

        // Simple braced variable
        if (self.environment.get(content)) |value| {
            const result = try self.allocator.dupe(u8, value);
            return ExpansionResult{ .value = result, .consumed = end + 1 };
        }

        // Variable not found - return empty string
        return ExpansionResult{ .value = "", .consumed = end + 1 };
    }

    /// Expand $VAR form (unbraced)
    fn expandSimpleVariable(self: *Expansion, input: []const u8) !ExpansionResult {
        if (input.len < 2 or input[0] != '$') {
            return ExpansionResult{ .value = "$", .consumed = 1 };
        }

        // Find end of variable name (alphanumeric and underscore)
        var end: usize = 1;
        while (end < input.len) {
            const char = input[end];
            if (!std.ascii.isAlphanumeric(char) and char != '_') {
                break;
            }
            end += 1;
        }

        if (end == 1) {
            // No valid variable name after $
            return ExpansionResult{ .value = "$", .consumed = 1 };
        }

        const var_name = input[1..end];

        if (self.environment.get(var_name)) |value| {
            const result = try self.allocator.dupe(u8, value);
            return ExpansionResult{ .value = result, .consumed = end };
        }

        // Variable not found - return empty string
        return ExpansionResult{ .value = "", .consumed = end };
    }
};

test "expand simple variable" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("HOME", "/home/user");
    try env.put("USER", "testuser");

    var exp = Expansion.init(allocator, &env, 0);

    const result1 = try exp.expand("$HOME/documents");
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("/home/user/documents", result1);

    const result2 = try exp.expand("Hello $USER!");
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("Hello testuser!", result2);
}

test "expand braced variable" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("NAME", "Alice");

    var exp = Expansion.init(allocator, &env, 0);

    const result = try exp.expand("${NAME}_file.txt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Alice_file.txt", result);
}

test "expand with default value" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    var exp = Expansion.init(allocator, &env, 0);

    const result = try exp.expand("${MISSING:-default}");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("default", result);
}

test "expand special variables" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    var exp = Expansion.init(allocator, &env, 42);

    const result = try exp.expand("Exit code: $?");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Exit code: 42", result);
}
