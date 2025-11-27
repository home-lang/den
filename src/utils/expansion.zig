const std = @import("std");
const Arithmetic = @import("arithmetic.zig").Arithmetic;
const env_utils = @import("env.zig");

/// Variable expansion utilities
pub const Expansion = struct {
    allocator: std.mem.Allocator,
    environment: *std.StringHashMap([]const u8),
    arrays: ?*std.StringHashMap([][]const u8), // Array variables
    local_vars: ?*std.StringHashMap([]const u8), // Function local variables (checked first)
    last_exit_code: i32,
    positional_params: []const []const u8, // $1, $2, etc.
    shell_name: []const u8, // $0
    last_background_pid: i32, // $!
    last_arg: []const u8, // $_
    shell: ?*anyopaque, // Optional shell reference for function local vars
    option_nounset: bool, // set -u: error on unset variable

    pub fn init(allocator: std.mem.Allocator, environment: *std.StringHashMap([]const u8), last_exit_code: i32) Expansion {
        return .{
            .allocator = allocator,
            .environment = environment,
            .arrays = null,
            .local_vars = null,
            .last_exit_code = last_exit_code,
            .positional_params = &[_][]const u8{},
            .shell_name = "den",
            .last_background_pid = 0,
            .last_arg = "",
            .shell = null,
            .option_nounset = false,
        };
    }

    pub fn initWithParams(
        allocator: std.mem.Allocator,
        environment: *std.StringHashMap([]const u8),
        last_exit_code: i32,
        positional_params: []const []const u8,
        shell_name: []const u8,
        last_background_pid: i32,
        last_arg: []const u8,
    ) Expansion {
        return .{
            .allocator = allocator,
            .environment = environment,
            .arrays = null,
            .local_vars = null,
            .last_exit_code = last_exit_code,
            .positional_params = positional_params,
            .shell_name = shell_name,
            .last_background_pid = last_background_pid,
            .last_arg = last_arg,
            .shell = null,
            .option_nounset = false,
        };
    }

    pub fn initWithShell(
        allocator: std.mem.Allocator,
        environment: *std.StringHashMap([]const u8),
        last_exit_code: i32,
        positional_params: []const []const u8,
        shell_name: []const u8,
        last_background_pid: i32,
        last_arg: []const u8,
        shell: *anyopaque,
    ) Expansion {
        return .{
            .allocator = allocator,
            .environment = environment,
            .arrays = null,
            .local_vars = null,
            .last_exit_code = last_exit_code,
            .positional_params = positional_params,
            .shell_name = shell_name,
            .last_background_pid = last_background_pid,
            .last_arg = last_arg,
            .shell = shell,
            .option_nounset = false,
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

            if (char == '`') {
                // Backtick command substitution
                const expansion_result = try self.expandBacktick(input[i..]);

                // Copy expansion result to buffer
                if (result_len + expansion_result.value.len > result_buffer.len) {
                    return error.ExpansionTooLong;
                }
                @memcpy(result_buffer[result_len..result_len + expansion_result.value.len], expansion_result.value);
                result_len += expansion_result.value.len;

                i += expansion_result.consumed;
            } else if (char == '$') {
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
            '#' => {
                // $# - number of positional parameters
                const value = try std.fmt.allocPrint(self.allocator, "{d}", .{self.positional_params.len});
                return ExpansionResult{ .value = value, .consumed = 2 };
            },
            '@' => {
                // $@ - all positional parameters as separate words
                if (self.positional_params.len == 0) {
                    return ExpansionResult{ .value = "", .consumed = 2 };
                }
                // Calculate total length needed
                var total_len: usize = 0;
                for (self.positional_params) |param| {
                    total_len += param.len;
                }
                if (self.positional_params.len > 1) {
                    total_len += self.positional_params.len - 1; // spaces
                }

                // Build result string
                var result = try self.allocator.alloc(u8, total_len);
                var pos: usize = 0;
                for (self.positional_params, 0..) |param, i| {
                    @memcpy(result[pos..pos + param.len], param);
                    pos += param.len;
                    if (i < self.positional_params.len - 1) {
                        result[pos] = ' ';
                        pos += 1;
                    }
                }
                return ExpansionResult{ .value = result, .consumed = 2 };
            },
            '*' => {
                // $* - all positional parameters as single word
                if (self.positional_params.len == 0) {
                    return ExpansionResult{ .value = "", .consumed = 2 };
                }
                // Calculate total length needed
                var total_len: usize = 0;
                for (self.positional_params) |param| {
                    total_len += param.len;
                }
                if (self.positional_params.len > 1) {
                    total_len += self.positional_params.len - 1; // spaces
                }

                // Build result string
                var result = try self.allocator.alloc(u8, total_len);
                var pos: usize = 0;
                for (self.positional_params, 0..) |param, i| {
                    @memcpy(result[pos..pos + param.len], param);
                    pos += param.len;
                    if (i < self.positional_params.len - 1) {
                        result[pos] = ' ';
                        pos += 1;
                    }
                }
                return ExpansionResult{ .value = result, .consumed = 2 };
            },
            '0' => {
                // $0 - shell name or script name
                const value = try self.allocator.dupe(u8, self.shell_name);
                return ExpansionResult{ .value = value, .consumed = 2 };
            },
            '1'...'9' => {
                // $1, $2, etc. - positional arguments
                const digit = next_char - '0';
                if (digit <= self.positional_params.len) {
                    const value = try self.allocator.dupe(u8, self.positional_params[digit - 1]);
                    return ExpansionResult{ .value = value, .consumed = 2 };
                }
                // Parameter not set - return empty string
                return ExpansionResult{ .value = "", .consumed = 2 };
            },
            '!' => {
                // $! - last background job PID
                const value = try std.fmt.allocPrint(self.allocator, "{d}", .{self.last_background_pid});
                return ExpansionResult{ .value = value, .consumed = 2 };
            },
            '_' => {
                // $_ - last argument of previous command
                const value = try self.allocator.dupe(u8, self.last_arg);
                return ExpansionResult{ .value = value, .consumed = 2 };
            },
            '(' => {
                // Check if it's $(( for arithmetic or $( for command substitution
                if (input.len > 2 and input[2] == '(') {
                    // $((expression)) - arithmetic expansion
                    return try self.expandArithmetic(input);
                } else {
                    // $(command) - command substitution
                    return try self.expandCommandSubstitution(input);
                }
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

        // Check for array expansion: ${arr[@]}, ${arr[*]}, ${arr[0]}, ${#arr}
        if (std.mem.indexOfScalar(u8, content, '[')) |bracket_pos| {
            const var_name = content[0..bracket_pos];
            const close_bracket = std.mem.indexOfScalar(u8, content[bracket_pos..], ']') orelse {
                // No closing bracket - treat as literal
                return ExpansionResult{ .value = "$", .consumed = 1 };
            };
            const index_part = content[bracket_pos + 1 .. bracket_pos + close_bracket];

            if (self.arrays) |arrays| {
                if (arrays.get(var_name)) |array| {
                    if (std.mem.eql(u8, index_part, "@") or std.mem.eql(u8, index_part, "*")) {
                        // ${arr[@]} or ${arr[*]} - all elements
                        if (array.len == 0) {
                            return ExpansionResult{ .value = "", .consumed = end + 1 };
                        }
                        var total_len: usize = 0;
                        for (array) |item| {
                            total_len += item.len;
                        }
                        if (array.len > 1) {
                            total_len += array.len - 1; // spaces
                        }

                        var result = try self.allocator.alloc(u8, total_len);
                        var pos: usize = 0;
                        for (array, 0..) |item, i| {
                            @memcpy(result[pos..pos + item.len], item);
                            pos += item.len;
                            if (i < array.len - 1) {
                                result[pos] = ' ';
                                pos += 1;
                            }
                        }
                        return ExpansionResult{ .value = result, .consumed = end + 1 };
                    } else {
                        // ${arr[index]} - specific index
                        const index = std.fmt.parseInt(usize, index_part, 10) catch {
                            return ExpansionResult{ .value = "", .consumed = end + 1 };
                        };
                        if (index < array.len) {
                            const value = try self.allocator.dupe(u8, array[index]);
                            return ExpansionResult{ .value = value, .consumed = end + 1 };
                        }
                        return ExpansionResult{ .value = "", .consumed = end + 1 };
                    }
                }
            }
        }

        // Check for array length: ${#arr}
        if (content.len > 0 and content[0] == '#') {
            const var_name = content[1..];
            if (self.arrays) |arrays| {
                if (arrays.get(var_name)) |array| {
                    const value = try std.fmt.allocPrint(self.allocator, "{d}", .{array.len});
                    return ExpansionResult{ .value = value, .consumed = end + 1 };
                }
            }
        }

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

        // Check for parameter expansion patterns
        // ${VAR##pattern} - remove longest prefix match (greedy)
        if (std.mem.indexOf(u8, content, "##")) |sep_pos| {
            if (sep_pos > 0 and sep_pos < content.len - 2) {
                const var_name = content[0..sep_pos];
                const pattern = content[sep_pos + 2 ..];

                if (self.environment.get(var_name)) |value| {
                    const result = try self.removePrefix(value, pattern, true);
                    return ExpansionResult{ .value = result, .consumed = end + 1 };
                }
                return ExpansionResult{ .value = "", .consumed = end + 1 };
            }
        }

        // ${VAR#pattern} - remove shortest prefix match
        if (std.mem.indexOf(u8, content, "#")) |sep_pos| {
            if (sep_pos > 0 and sep_pos < content.len - 1) {
                const var_name = content[0..sep_pos];
                const pattern = content[sep_pos + 1 ..];

                if (self.environment.get(var_name)) |value| {
                    const result = try self.removePrefix(value, pattern, false);
                    return ExpansionResult{ .value = result, .consumed = end + 1 };
                }
                return ExpansionResult{ .value = "", .consumed = end + 1 };
            }
        }

        // ${VAR%%pattern} - remove longest suffix match (greedy)
        if (std.mem.indexOf(u8, content, "%%")) |sep_pos| {
            if (sep_pos > 0 and sep_pos < content.len - 2) {
                const var_name = content[0..sep_pos];
                const pattern = content[sep_pos + 2 ..];

                if (self.environment.get(var_name)) |value| {
                    const result = try self.removeSuffix(value, pattern, true);
                    return ExpansionResult{ .value = result, .consumed = end + 1 };
                }
                return ExpansionResult{ .value = "", .consumed = end + 1 };
            }
        }

        // ${VAR%pattern} - remove shortest suffix match
        if (std.mem.indexOf(u8, content, "%")) |sep_pos| {
            if (sep_pos > 0 and sep_pos < content.len - 1) {
                const var_name = content[0..sep_pos];
                const pattern = content[sep_pos + 1 ..];

                if (self.environment.get(var_name)) |value| {
                    const result = try self.removeSuffix(value, pattern, false);
                    return ExpansionResult{ .value = result, .consumed = end + 1 };
                }
                return ExpansionResult{ .value = "", .consumed = end + 1 };
            }
        }

        // Simple braced variable
        if (self.environment.get(content)) |value| {
            const result = try self.allocator.dupe(u8, value);
            return ExpansionResult{ .value = result, .consumed = end + 1 };
        }

        // Variable not found - return empty string
        return ExpansionResult{ .value = "", .consumed = end + 1 };
    }

    /// Remove prefix pattern from string
    fn removePrefix(self: *Expansion, value: []const u8, pattern: []const u8, greedy: bool) ![]u8 {
        // For greedy (##), find longest match; for non-greedy (#), find shortest
        if (greedy) {
            // Find longest prefix match
            var longest_match: usize = 0;
            var i: usize = 0;
            while (i <= value.len) : (i += 1) {
                if (matchPattern(pattern, value[0..i])) {
                    longest_match = i;
                }
            }
            if (longest_match > 0) {
                return try self.allocator.dupe(u8, value[longest_match..]);
            }
        } else {
            // Find shortest prefix match
            var i: usize = 0;
            while (i <= value.len) : (i += 1) {
                if (matchPattern(pattern, value[0..i])) {
                    return try self.allocator.dupe(u8, value[i..]);
                }
            }
        }

        // Pattern not found, return original value
        return try self.allocator.dupe(u8, value);
    }

    /// Remove suffix pattern from string
    fn removeSuffix(self: *Expansion, value: []const u8, pattern: []const u8, greedy: bool) ![]u8 {
        // For greedy (%%), find longest match; for non-greedy (%), find shortest
        if (greedy) {
            // Find longest suffix match
            var longest_match: usize = 0;
            var i: usize = 0;
            while (i <= value.len) : (i += 1) {
                const start = value.len - i;
                if (matchPattern(pattern, value[start..])) {
                    longest_match = i;
                }
            }
            if (longest_match > 0) {
                return try self.allocator.dupe(u8, value[0 .. value.len - longest_match]);
            }
        } else {
            // Find shortest suffix match
            var i: usize = 0;
            while (i <= value.len) : (i += 1) {
                const start = value.len - i;
                if (matchPattern(pattern, value[start..])) {
                    return try self.allocator.dupe(u8, value[0..start]);
                }
            }
        }

        // Pattern not found, return original value
        return try self.allocator.dupe(u8, value);
    }

    /// Match a shell glob pattern against a string
    /// Supports: * (any chars), ? (one char), [abc] (char class)
    fn matchPattern(pattern: []const u8, str: []const u8) bool {
        var p_idx: usize = 0;
        var s_idx: usize = 0;

        while (p_idx < pattern.len and s_idx < str.len) {
            const p_char = pattern[p_idx];

            if (p_char == '*') {
                // Skip consecutive stars
                while (p_idx < pattern.len and pattern[p_idx] == '*') {
                    p_idx += 1;
                }

                // Star at end matches rest of string
                if (p_idx == pattern.len) return true;

                // Try matching rest of pattern at each position
                while (s_idx <= str.len) {
                    if (matchPattern(pattern[p_idx..], str[s_idx..])) {
                        return true;
                    }
                    s_idx += 1;
                }
                return false;
            } else if (p_char == '?') {
                // ? matches any single character
                p_idx += 1;
                s_idx += 1;
            } else if (p_char == '[') {
                // Character class [abc] or [a-z]
                p_idx += 1;
                if (p_idx >= pattern.len) return false;

                var matched = false;
                var negate = false;

                // Check for negation [!abc]
                if (pattern[p_idx] == '!') {
                    negate = true;
                    p_idx += 1;
                }

                while (p_idx < pattern.len and pattern[p_idx] != ']') {
                    if (p_idx + 2 < pattern.len and pattern[p_idx + 1] == '-') {
                        // Range: a-z
                        const range_start = pattern[p_idx];
                        const range_end = pattern[p_idx + 2];
                        if (str[s_idx] >= range_start and str[s_idx] <= range_end) {
                            matched = true;
                        }
                        p_idx += 3;
                    } else {
                        // Single character
                        if (str[s_idx] == pattern[p_idx]) {
                            matched = true;
                        }
                        p_idx += 1;
                    }
                }

                if (negate) matched = !matched;
                if (!matched) return false;

                // Skip closing ]
                if (p_idx < pattern.len and pattern[p_idx] == ']') {
                    p_idx += 1;
                }
                s_idx += 1;
            } else {
                // Exact character match
                if (p_char != str[s_idx]) return false;
                p_idx += 1;
                s_idx += 1;
            }
        }

        // Check if we consumed both pattern and string
        // Account for trailing stars
        while (p_idx < pattern.len and pattern[p_idx] == '*') {
            p_idx += 1;
        }

        return p_idx == pattern.len and s_idx == str.len;
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

        // Check local variables first (function scope)
        if (self.local_vars) |locals| {
            if (locals.get(var_name)) |value| {
                const result = try self.allocator.dupe(u8, value);
                return ExpansionResult{ .value = result, .consumed = end };
            }
        }

        // Then check environment variables
        if (self.environment.get(var_name)) |value| {
            const result = try self.allocator.dupe(u8, value);
            return ExpansionResult{ .value = result, .consumed = end };
        }

        // Variable not found
        // If nounset is enabled, return an error
        if (self.option_nounset) {
            // Print error message to stderr using posix write
            const posix = std.posix;
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "den: {s}: unbound variable\n", .{var_name}) catch "den: unbound variable\n";
            _ = posix.write(posix.STDERR_FILENO, msg) catch {};
            return error.UnboundVariable;
        }

        // Return empty string (default behavior)
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

    /// Expand backtick command substitution: `command`
    fn expandBacktick(self: *Expansion, input: []const u8) !ExpansionResult {
        if (input.len < 2 or input[0] != '`') {
            return ExpansionResult{ .value = "`", .consumed = 1 };
        }

        // Find matching closing backtick
        var end: usize = 1;
        while (end < input.len and input[end] != '`') {
            // Handle escaped backticks
            if (input[end] == '\\' and end + 1 < input.len and input[end + 1] == '`') {
                end += 2;
                continue;
            }
            end += 1;
        }

        if (end >= input.len) {
            // Unmatched backtick
            return ExpansionResult{ .value = "`", .consumed = 1 };
        }

        const command = input[1..end];

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
        const max_output: usize = 1024 * 1024; // Max 1MB output
        var output_buffer = std.ArrayList(u8).empty;

        var read_buf: [4096]u8 = undefined;
        while (true) {
            const bytes_read = stdout.read(&read_buf) catch break;
            if (bytes_read == 0) break;
            try output_buffer.appendSlice(self.allocator, read_buf[0..bytes_read]);
            if (output_buffer.items.len >= max_output) break;
        }
        const output = try output_buffer.toOwnedSlice(self.allocator);

        const term = try child.wait();
        _ = term;

        return output;
    }

    /// Expand $((expression)) - arithmetic expansion
    fn expandArithmetic(self: *Expansion, input: []const u8) !ExpansionResult {
        if (input.len < 4 or input[0] != '$' or input[1] != '(' or input[2] != '(') {
            return ExpansionResult{ .value = "$", .consumed = 1 };
        }

        // Find matching closing parentheses ))
        var depth: u32 = 2; // Start with depth 2 for ((
        var end: usize = 3;
        while (end < input.len and depth > 0) {
            if (input[end] == '(') {
                depth += 1;
            } else if (input[end] == ')') {
                depth -= 1;
            }
            if (depth > 0) end += 1;
        }

        if (depth != 0 or end >= input.len or input[end - 1] != ')') {
            // Unmatched parentheses
            return ExpansionResult{ .value = "$((", .consumed = 3 };
        }

        // Extract expression (between (( and ))
        const expr = input[3..end - 1];

        // Evaluate arithmetic expression with variable support
        var arith = Arithmetic.initWithVariables(self.allocator, self.environment);
        const result_value = arith.eval(expr) catch {
            // On error, return 0
            const value = try std.fmt.allocPrint(self.allocator, "0", .{});
            return ExpansionResult{ .value = value, .consumed = end + 1 };
        };

        // Format result as string
        const value = try std.fmt.allocPrint(self.allocator, "{d}", .{result_value});
        return ExpansionResult{ .value = value, .consumed = end + 1 };
    }

    /// Expand tilde (~) to home directory
    /// Supports: ~, ~user, ~+, ~-, ~+N, ~-N
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
            } else if (env_utils.getEnv("HOME")) |home| {
                break :blk try self.allocator.dupe(u8, home);
            } else {
                // Fallback - return tilde unchanged
                break :blk try self.allocator.dupe(u8, "~");
            }
        } else blk: {
            const suffix = input[1..end];

            // ~+ - current working directory (PWD)
            if (std.mem.eql(u8, suffix, "+")) {
                if (self.environment.get("PWD")) |pwd| {
                    break :blk try self.allocator.dupe(u8, pwd);
                } else if (env_utils.getEnv("PWD")) |pwd| {
                    break :blk try self.allocator.dupe(u8, pwd);
                } else {
                    // Try to get cwd as fallback
                    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
                    if (std.fs.cwd().realpath(".", &cwd_buf)) |path| {
                        break :blk try self.allocator.dupe(u8, path);
                    } else |_| {
                        break :blk try self.allocator.dupe(u8, "~+");
                    }
                }
            }

            // ~- - previous working directory (OLDPWD)
            if (std.mem.eql(u8, suffix, "-")) {
                if (self.environment.get("OLDPWD")) |oldpwd| {
                    break :blk try self.allocator.dupe(u8, oldpwd);
                } else if (env_utils.getEnv("OLDPWD")) |oldpwd| {
                    break :blk try self.allocator.dupe(u8, oldpwd);
                } else {
                    // OLDPWD not set
                    break :blk try self.allocator.dupe(u8, "~-");
                }
            }

            // ~username - expand to specified user's home directory
            const username = suffix;

            // First check if it's the current user
            if (self.environment.get("USER")) |current_user| {
                if (std.mem.eql(u8, username, current_user)) {
                    if (self.environment.get("HOME")) |home| {
                        break :blk try self.allocator.dupe(u8, home);
                    }
                }
            }

            // Try to look up user's home directory using getpwnam
            if (getUserHomeDir(username)) |home_dir| {
                break :blk try self.allocator.dupe(u8, home_dir);
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

/// Get user's home directory from passwd database
/// Uses POSIX getpwnam for lookup
fn getUserHomeDir(username: []const u8) ?[]const u8 {
    const builtin = @import("builtin");
    // Only available on POSIX systems
    if (builtin.os.tag == .windows) {
        return null;
    }

    // Create null-terminated username
    var name_buf: [256]u8 = undefined;
    if (username.len >= name_buf.len) return null;
    @memcpy(name_buf[0..username.len], username);
    name_buf[username.len] = 0;

    const passwd = std.c.getpwnam(@ptrCast(&name_buf));
    if (passwd) |pw| {
        // The field is 'dir' in Zig's std.c.passwd struct
        if (pw.dir) |dir| {
            return std.mem.span(dir);
        }
    }
    return null;
}

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

test "expand tilde home" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("HOME", "/home/testuser");

    var exp = Expansion.init(allocator, &env, 0);

    const result = try exp.expand("~/documents");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/home/testuser/documents", result);
}

test "expand tilde+ PWD" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("PWD", "/var/www");

    var exp = Expansion.init(allocator, &env, 0);

    const result = try exp.expand("~+/subdir");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/var/www/subdir", result);
}

test "expand tilde- OLDPWD" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("OLDPWD", "/tmp/previous");

    var exp = Expansion.init(allocator, &env, 0);

    const result = try exp.expand("~-/file.txt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/tmp/previous/file.txt", result);
}

test "expand tilde user" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("USER", "testuser");
    try env.put("HOME", "/home/testuser");

    var exp = Expansion.init(allocator, &env, 0);

    // Current user should expand to HOME
    const result = try exp.expand("~testuser/docs");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/home/testuser/docs", result);
}
