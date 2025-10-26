const std = @import("std");

/// Variable expansion utilities
pub const Expansion = struct {
    allocator: std.mem.Allocator,
    environment: *std.StringHashMap([]const u8),
    last_exit_code: i32,
    positional_params: []const []const u8, // $1, $2, etc.
    shell_name: []const u8, // $0

    pub fn init(allocator: std.mem.Allocator, environment: *std.StringHashMap([]const u8), last_exit_code: i32) Expansion {
        return .{
            .allocator = allocator,
            .environment = environment,
            .last_exit_code = last_exit_code,
            .positional_params = &[_][]const u8{},
            .shell_name = "den",
        };
    }

    pub fn initWithParams(
        allocator: std.mem.Allocator,
        environment: *std.StringHashMap([]const u8),
        last_exit_code: i32,
        positional_params: []const []const u8,
        shell_name: []const u8,
    ) Expansion {
        return .{
            .allocator = allocator,
            .environment = environment,
            .last_exit_code = last_exit_code,
            .positional_params = positional_params,
            .shell_name = shell_name,
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

            // Handle tilde expansion at start of word or after : =
            if (char == '~') {
                const should_expand = i == 0 or
                    (i > 0 and (input[i - 1] == ':' or input[i - 1] == '='));

                if (should_expand) {
                    const expansion_result = try self.expandTilde(input[i..]);

                    // Copy expansion result to buffer
                    if (result_len + expansion_result.value.len > result_buffer.len) {
                        return error.ExpansionTooLong;
                    }
                    @memcpy(result_buffer[result_len..result_len + expansion_result.value.len], expansion_result.value);
                    result_len += expansion_result.value.len;

                    i += expansion_result.consumed;
                    continue;
                }
            }

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
            '(' => {
                // $(command) - command substitution
                return try self.expandCommandSubstitution(input);
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

    /// Expand $(command) - command substitution
    fn expandCommandSubstitution(self: *Expansion, input: []const u8) !ExpansionResult {
        if (input.len < 3 or input[0] != '$' or input[1] != '(') {
            return ExpansionResult{ .value = "$", .consumed = 1 };
        }

        // Find matching closing parenthesis
        var depth: u32 = 1;
        var end: usize = 2;
        while (end < input.len and depth > 0) {
            if (input[end] == '(') {
                depth += 1;
            } else if (input[end] == ')') {
                depth -= 1;
            }
            if (depth > 0) end += 1;
        }

        if (depth != 0) {
            // Unmatched parenthesis
            return ExpansionResult{ .value = "$(", .consumed = 2 };
        }

        const command = input[2..end];

        // Execute the command and capture output
        const output = self.executeCommandForSubstitution(command) catch {
            // On error, return empty string
            return ExpansionResult{ .value = "", .consumed = end + 1 };
        };

        // Trim trailing newlines (bash behavior)
        var trimmed_len = output.len;
        while (trimmed_len > 0 and output[trimmed_len - 1] == '\n') {
            trimmed_len -= 1;
        }

        const result = try self.allocator.dupe(u8, output[0..trimmed_len]);
        return ExpansionResult{ .value = result, .consumed = end + 1 };
    }

    /// Execute a command and return its output
    fn executeCommandForSubstitution(self: *Expansion, command: []const u8) ![]const u8 {
        // Create a child process to execute the command
        const argv = [_][]const u8{ "sh", "-c", command };

        var child = std.process.Child.init(&argv, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        // Read stdout
        const stdout = child.stdout.?;
        const output = try stdout.readToEndAlloc(self.allocator, 1024 * 1024); // Max 1MB output

        const term = try child.wait();
        _ = term;

        return output;
    }

    /// Expand tilde (~) to home directory
    fn expandTilde(self: *Expansion, input: []const u8) !ExpansionResult {
        if (input.len < 1 or input[0] != '~') {
            return ExpansionResult{ .value = "~", .consumed = 1 };
        }

        // Find end of username (or tilde alone)
        var end: usize = 1;
        while (end < input.len) {
            const c = input[end];
            if (c == '/' or c == ':' or std.ascii.isWhitespace(c)) {
                break;
            }
            end += 1;
        }

        const expanded_path = if (end == 1) blk: {
            // ~ alone - expand to current user's home
            if (self.environment.get("HOME")) |home| {
                break :blk try self.allocator.dupe(u8, home);
            } else if (std.posix.getenv("HOME")) |home| {
                break :blk try self.allocator.dupe(u8, home);
            } else {
                // Fallback - return tilde unchanged
                break :blk try self.allocator.dupe(u8, "~");
            }
        } else blk: {
            // ~username - expand to specified user's home
            const username = input[1..end];

            // Try to get user's home directory (simplified - would need pwd.h for full implementation)
            // For now, just handle current user
            if (self.environment.get("USER")) |current_user| {
                if (std.mem.eql(u8, username, current_user)) {
                    if (self.environment.get("HOME")) |home| {
                        break :blk try self.allocator.dupe(u8, home);
                    }
                }
            }

            // If we can't resolve, return unchanged
            break :blk try self.allocator.dupe(u8, input[0..end]);
        };

        return ExpansionResult{
            .value = expanded_path,
            .consumed = end,
        };
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
