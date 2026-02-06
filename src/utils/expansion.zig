const std = @import("std");
const builtin = @import("builtin");
const Arithmetic = @import("arithmetic.zig").Arithmetic;
const env_utils = @import("env.zig");

/// LRU cache for variable expansion results
pub const ExpansionCache = struct {
    const CacheEntry = struct {
        value: []const u8,
        age: u64,
    };

    allocator: std.mem.Allocator,
    entries: std.StringHashMap(CacheEntry),
    max_entries: u32,
    access_counter: u64,

    pub fn init(allocator: std.mem.Allocator, max_entries: u32) ExpansionCache {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(CacheEntry).init(allocator),
            .max_entries = max_entries,
            .access_counter = 0,
        };
    }

    pub fn deinit(self: *ExpansionCache) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.value);
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit();
    }

    pub fn get(self: *ExpansionCache, key: []const u8) ?[]const u8 {
        if (self.entries.getPtr(key)) |entry| {
            // Update access time
            self.access_counter += 1;
            entry.age = self.access_counter;
            return entry.value;
        }
        return null;
    }

    pub fn put(self: *ExpansionCache, key: []const u8, value: []const u8) !void {
        // Check if we need to evict
        if (self.entries.count() >= self.max_entries) {
            self.evictOldest();
        }

        // Remove existing entry if present
        if (self.entries.fetchRemove(key)) |old| {
            self.allocator.free(old.value.value);
            self.allocator.free(old.key);
        }

        // Duplicate key and value
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);

        self.access_counter += 1;
        try self.entries.put(key_copy, .{
            .value = value_copy,
            .age = self.access_counter,
        });
    }

    fn evictOldest(self: *ExpansionCache) void {
        var oldest_key: ?[]const u8 = null;
        var oldest_age: u64 = std.math.maxInt(u64);

        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.age < oldest_age) {
                oldest_age = entry.value_ptr.age;
                oldest_key = entry.key_ptr.*;
            }
        }

        if (oldest_key) |key| {
            if (self.entries.fetchRemove(key)) |removed| {
                self.allocator.free(removed.value.value);
                self.allocator.free(removed.key);
            }
        }
    }

    pub fn clear(self: *ExpansionCache) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.value);
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.clearRetainingCapacity();
    }

    pub fn count(self: *ExpansionCache) usize {
        return self.entries.count();
    }
};

// Import VarAttributes type
const types = @import("../types/mod.zig");

/// Variable expansion utilities
pub const Expansion = struct {
    allocator: std.mem.Allocator,
    environment: *std.StringHashMap([]const u8),
    arrays: ?*std.StringHashMap([][]const u8), // Indexed array variables
    assoc_arrays: ?*std.StringHashMap(std.StringHashMap([]const u8)), // Associative array variables
    local_vars: ?*std.StringHashMap([]const u8), // Function local variables (checked first)
    var_attributes: ?*std.StringHashMap(types.VarAttributes), // Variable attributes for namerefs
    last_exit_code: i32,
    positional_params: []const []const u8, // $1, $2, etc.
    shell_name: []const u8, // $0
    last_background_pid: i32, // $!
    last_arg: []const u8, // $_
    shell: ?*anyopaque, // Optional shell reference for function local vars
    option_nounset: bool, // set -u: error on unset variable
    cmd_cache: ?*ExpansionCache, // Optional cache for command substitution results

    pub fn init(allocator: std.mem.Allocator, environment: *std.StringHashMap([]const u8), last_exit_code: i32) Expansion {
        return .{
            .allocator = allocator,
            .environment = environment,
            .arrays = null,
            .assoc_arrays = null,
            .local_vars = null,
            .var_attributes = null,
            .last_exit_code = last_exit_code,
            .positional_params = &[_][]const u8{},
            .shell_name = "den",
            .last_background_pid = 0,
            .last_arg = "",
            .shell = null,
            .option_nounset = false,
            .cmd_cache = null,
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
            .assoc_arrays = null,
            .local_vars = null,
            .var_attributes = null,
            .last_exit_code = last_exit_code,
            .positional_params = positional_params,
            .shell_name = shell_name,
            .last_background_pid = last_background_pid,
            .last_arg = last_arg,
            .shell = null,
            .option_nounset = false,
            .cmd_cache = null,
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
            .assoc_arrays = null,
            .local_vars = null,
            .var_attributes = null,
            .last_exit_code = last_exit_code,
            .positional_params = positional_params,
            .shell_name = shell_name,
            .last_background_pid = last_background_pid,
            .last_arg = last_arg,
            .shell = shell,
            .option_nounset = false,
            .cmd_cache = null,
        };
    }

    /// Set the command substitution cache
    pub fn setCommandCache(self: *Expansion, cache: *ExpansionCache) void {
        self.cmd_cache = cache;
    }

    /// Set variable attributes for nameref resolution
    pub fn setVarAttributes(self: *Expansion, attrs: *std.StringHashMap(types.VarAttributes)) void {
        self.var_attributes = attrs;
    }

    /// Set associative arrays for expansion
    pub fn setAssocArrays(self: *Expansion, assoc: *std.StringHashMap(std.StringHashMap([]const u8))) void {
        self.assoc_arrays = assoc;
    }

    /// Resolve a nameref chain - follow the reference to get the actual variable name
    /// Returns the final variable name after following all nameref chains
    /// Limits depth to prevent infinite loops
    fn resolveNameref(self: *Expansion, name: []const u8) []const u8 {
        const attrs = self.var_attributes orelse return name;

        var current_name = name;
        var depth: u32 = 0;
        const max_depth = 10;

        while (depth < max_depth) : (depth += 1) {
            if (attrs.get(current_name)) |attr| {
                if (attr.nameref) {
                    // Get the value of the current nameref which contains the target variable name
                    if (self.environment.get(current_name)) |ref_name| {
                        current_name = ref_name;
                        continue;
                    }
                }
            }
            break;
        }

        return current_name;
    }

    /// Get variable value, resolving namerefs if applicable
    fn getVariableValue(self: *Expansion, name: []const u8) ?[]const u8 {
        // First check local variables
        if (self.local_vars) |locals| {
            if (locals.get(name)) |value| {
                return value;
            }
        }

        // Resolve any nameref chain
        const resolved_name = self.resolveNameref(name);

        // Return value from environment
        return self.environment.get(resolved_name);
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
                // Don't expand if this is the =~ regex operator (~ followed by space or end)
                const is_regex_op = i > 0 and input[i - 1] == '=' and
                    (i + 1 >= input.len or input[i + 1] == ' ' or input[i + 1] == '\t');

                const should_expand = !is_regex_op and (i == 0 or
                    (i > 0 and (input[i - 1] == ':' or input[i - 1] == '=')));

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

            if (char == '<' or char == '>') {
                // Check for process substitution: <(cmd) or >(cmd)
                if (i + 1 < input.len and input[i + 1] == '(') {
                    const expansion_result = try self.expandProcessSubstitution(input[i..], char == '<');

                    // Copy expansion result to buffer
                    if (result_len + expansion_result.value.len > result_buffer.len) {
                        return error.ExpansionTooLong;
                    }
                    @memcpy(result_buffer[result_len..result_len + expansion_result.value.len], expansion_result.value);
                    result_len += expansion_result.value.len;

                    i += expansion_result.consumed;
                    continue;
                }
                // Not process substitution - treat as literal
                if (result_len >= result_buffer.len) return error.ExpansionTooLong;
                result_buffer[result_len] = char;
                result_len += 1;
                i += 1;
            } else if (char == '`') {
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
                defer if (expansion_result.owned) self.allocator.free(@constCast(expansion_result.value));

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
        owned: bool, // Whether value needs to be freed
    };

    /// Expand a single variable starting at $ character
    fn expandVariable(self: *Expansion, input: []const u8) !ExpansionResult {
        if (input.len < 2 or input[0] != '$') {
            return ExpansionResult{ .value = "$", .consumed = 1, .owned = false };
        }

        // Check for special variables
        const next_char = input[1];
        switch (next_char) {
            '?' => {
                // $? - last exit code
                const value = try std.fmt.allocPrint(self.allocator, "{d}", .{self.last_exit_code});
                return ExpansionResult{ .value = value, .consumed = 2, .owned = true };
            },
            '$' => {
                // $$ - current process ID
                const pid = std.c.getpid();
                const value = try std.fmt.allocPrint(self.allocator, "{d}", .{pid});
                return ExpansionResult{ .value = value, .consumed = 2, .owned = true };
            },
            '#' => {
                // $# - number of positional parameters
                const value = try std.fmt.allocPrint(self.allocator, "{d}", .{self.positional_params.len});
                return ExpansionResult{ .value = value, .consumed = 2, .owned = true };
            },
            '@' => {
                // $@ - all positional parameters as separate words
                if (self.positional_params.len == 0) {
                    return ExpansionResult{ .value = "", .consumed = 2, .owned = false };
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
                return ExpansionResult{ .value = result, .consumed = 2, .owned = true };
            },
            '*' => {
                // $* - all positional parameters as single word
                if (self.positional_params.len == 0) {
                    return ExpansionResult{ .value = "", .consumed = 2, .owned = false };
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
                return ExpansionResult{ .value = result, .consumed = 2, .owned = true };
            },
            '0' => {
                // $0 - shell name or script name
                const value = try self.allocator.dupe(u8, self.shell_name);
                return ExpansionResult{ .value = value, .consumed = 2, .owned = true };
            },
            '1'...'9' => {
                // $1, $2, etc. - positional arguments
                const digit = next_char - '0';
                if (digit <= self.positional_params.len) {
                    const value = try self.allocator.dupe(u8, self.positional_params[digit - 1]);
                    return ExpansionResult{ .value = value, .consumed = 2, .owned = true };
                }
                // Parameter not set - return empty string
                return ExpansionResult{ .value = "", .consumed = 2, .owned = false };
            },
            '!' => {
                // $! - last background job PID
                const value = try std.fmt.allocPrint(self.allocator, "{d}", .{self.last_background_pid});
                return ExpansionResult{ .value = value, .consumed = 2, .owned = true };
            },
            '_' => {
                // $_ - last argument of previous command
                const value = try self.allocator.dupe(u8, self.last_arg);
                return ExpansionResult{ .value = value, .consumed = 2, .owned = true };
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
            return ExpansionResult{ .value = "$", .consumed = 1, .owned = false };
        }

        // Find closing brace
        var end: usize = 2;
        while (end < input.len and input[end] != '}') {
            end += 1;
        }

        if (end >= input.len) {
            // No closing brace found - treat as literal
            return ExpansionResult{ .value = "$", .consumed = 1, .owned = false };
        }

        const content = input[2..end];

        // Check for array expansion: ${arr[@]}, ${arr[*]}, ${arr[0]}, ${assoc[key]}, ${#arr}
        if (std.mem.indexOfScalar(u8, content, '[')) |bracket_pos| {
            const var_name = content[0..bracket_pos];
            const close_bracket = std.mem.indexOfScalar(u8, content[bracket_pos..], ']') orelse {
                // No closing bracket - treat as literal
                return ExpansionResult{ .value = "$", .consumed = 1, .owned = false };
            };
            const index_part = content[bracket_pos + 1 .. bracket_pos + close_bracket];

            // First try indexed arrays
            if (self.arrays) |arrays| {
                if (arrays.get(var_name)) |array| {
                    if (std.mem.eql(u8, index_part, "@") or std.mem.eql(u8, index_part, "*")) {
                        // ${arr[@]} or ${arr[*]} - all elements
                        if (array.len == 0) {
                            return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
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
                        return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                    } else {
                        // ${arr[index]} - specific index
                        const index = std.fmt.parseInt(usize, index_part, 10) catch {
                            return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                        };
                        if (index < array.len) {
                            const value = try self.allocator.dupe(u8, array[index]);
                            return ExpansionResult{ .value = value, .consumed = end + 1, .owned = true };
                        }
                        return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                    }
                }
            }

            // Try associative arrays
            if (self.assoc_arrays) |assoc_arrays| {
                if (assoc_arrays.get(var_name)) |assoc| {
                    if (std.mem.eql(u8, index_part, "@") or std.mem.eql(u8, index_part, "*")) {
                        // ${assoc[@]} or ${assoc[*]} - all values
                        if (assoc.count() == 0) {
                            return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                        }

                        // Collect all values
                        var values = std.ArrayList([]const u8).empty;
                        defer values.deinit(self.allocator);

                        var iter = assoc.iterator();
                        while (iter.next()) |entry| {
                            try values.append(self.allocator, entry.value_ptr.*);
                        }

                        // Calculate total length
                        var total_len: usize = 0;
                        for (values.items) |item| {
                            total_len += item.len;
                        }
                        if (values.items.len > 1) {
                            total_len += values.items.len - 1; // spaces
                        }

                        var result = try self.allocator.alloc(u8, total_len);
                        var pos: usize = 0;
                        for (values.items, 0..) |item, i| {
                            @memcpy(result[pos..pos + item.len], item);
                            pos += item.len;
                            if (i < values.items.len - 1) {
                                result[pos] = ' ';
                                pos += 1;
                            }
                        }
                        return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                    } else {
                        // ${assoc[key]} - specific key lookup
                        if (assoc.get(index_part)) |value| {
                            const result = try self.allocator.dupe(u8, value);
                            return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                        }
                        return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                    }
                }
            }
        }

        // Check for string/array length: ${#VAR}
        if (content.len > 0 and content[0] == '#') {
            const var_name = content[1..];
            // First check indexed arrays
            if (self.arrays) |arrays| {
                if (arrays.get(var_name)) |array| {
                    const value = try std.fmt.allocPrint(self.allocator, "{d}", .{array.len});
                    return ExpansionResult{ .value = value, .consumed = end + 1, .owned = true };
                }
            }
            // Then check associative arrays
            if (self.assoc_arrays) |assoc_arrays| {
                if (assoc_arrays.get(var_name)) |assoc| {
                    const value = try std.fmt.allocPrint(self.allocator, "{d}", .{assoc.count()});
                    return ExpansionResult{ .value = value, .consumed = end + 1, .owned = true };
                }
            }
            // Then check scalar variables for string length
            if (self.environment.get(var_name)) |value| {
                const len_str = try std.fmt.allocPrint(self.allocator, "{d}", .{value.len});
                return ExpansionResult{ .value = len_str, .consumed = end + 1, .owned = true };
            }
            // Variable not found - length is 0
            const zero = try self.allocator.dupe(u8, "0");
            return ExpansionResult{ .value = zero, .consumed = end + 1, .owned = true };
        }

        // Check for variable name prefix expansion: ${!prefix@} or ${!prefix*}
        // Also handles ${!arr[@]} for array keys
        if (content.len > 1 and content[0] == '!') {
            const last_char = content[content.len - 1];
            if (last_char == '@' or last_char == '*') {
                const inner = content[1 .. content.len - 1];

                // Check for ${!arr[@]} or ${!arr[*]} - get array indices/keys
                if (inner.len > 2 and inner[inner.len - 1] == '[') {
                    const var_name = inner[0 .. inner.len - 1];

                    // Try indexed arrays first
                    if (self.arrays) |arrays| {
                        if (arrays.get(var_name)) |array| {
                            // Return indices 0, 1, 2, ...
                            if (array.len == 0) {
                                return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                            }

                            // Calculate space needed
                            var total_len: usize = 0;
                            for (0..array.len) |i| {
                                var buf: [20]u8 = undefined;
                                const num_str = std.fmt.bufPrint(&buf, "{d}", .{i}) catch continue;
                                total_len += num_str.len;
                            }
                            total_len += array.len - 1; // spaces

                            var result = try self.allocator.alloc(u8, total_len);
                            var pos: usize = 0;
                            for (0..array.len) |i| {
                                var buf: [20]u8 = undefined;
                                const num_str = std.fmt.bufPrint(&buf, "{d}", .{i}) catch continue;
                                @memcpy(result[pos..][0..num_str.len], num_str);
                                pos += num_str.len;
                                if (i < array.len - 1) {
                                    result[pos] = ' ';
                                    pos += 1;
                                }
                            }
                            return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                        }
                    }

                    // Try associative arrays
                    if (self.assoc_arrays) |assoc_arrays| {
                        if (assoc_arrays.get(var_name)) |assoc| {
                            if (assoc.count() == 0) {
                                return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                            }

                            // Collect all keys
                            var keys = std.ArrayList([]const u8).empty;
                            defer keys.deinit(self.allocator);

                            var iter = assoc.iterator();
                            while (iter.next()) |entry| {
                                try keys.append(self.allocator, entry.key_ptr.*);
                            }

                            // Sort keys for consistent output
                            std.mem.sort([]const u8, keys.items, {}, struct {
                                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                                    return std.mem.order(u8, a, b) == .lt;
                                }
                            }.lessThan);

                            // Calculate total length
                            var total_len: usize = 0;
                            for (keys.items) |key| {
                                total_len += key.len;
                            }
                            total_len += keys.items.len - 1; // spaces

                            var result = try self.allocator.alloc(u8, total_len);
                            var pos: usize = 0;
                            for (keys.items, 0..) |key, i| {
                                @memcpy(result[pos..][0..key.len], key);
                                pos += key.len;
                                if (i < keys.items.len - 1) {
                                    result[pos] = ' ';
                                    pos += 1;
                                }
                            }
                            return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                        }
                    }
                }

                // ${!prefix@} or ${!prefix*} - expand to variable names with prefix
                const prefix = inner;

                // Collect all variable names that start with prefix
                var names = std.ArrayList([]const u8).empty;
                defer names.deinit(self.allocator);

                var env_iter = self.environment.iterator();
                while (env_iter.next()) |entry| {
                    if (std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
                        try names.append(self.allocator, entry.key_ptr.*);
                    }
                }

                // Sort the names for consistent output
                std.mem.sort([]const u8, names.items, {}, struct {
                    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                        return std.mem.order(u8, a, b) == .lt;
                    }
                }.lessThan);

                if (names.items.len == 0) {
                    return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                }

                // Join with spaces
                var total_len: usize = 0;
                for (names.items) |name| {
                    total_len += name.len;
                }
                total_len += names.items.len - 1; // spaces between names

                var result = try self.allocator.alloc(u8, total_len);
                var pos: usize = 0;
                for (names.items, 0..) |name, i| {
                    @memcpy(result[pos..][0..name.len], name);
                    pos += name.len;
                    if (i < names.items.len - 1) {
                        result[pos] = ' ';
                        pos += 1;
                    }
                }
                return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
            }

            // Check for indirect expansion: ${!VAR}
            const indirect_name = content[1..];
            // Get the value of the named variable, then use that as a variable name
            if (self.environment.get(indirect_name)) |ref_name| {
                if (self.environment.get(ref_name)) |value| {
                    const result = try self.allocator.dupe(u8, value);
                    return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                }
            }
            return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
        }

        // Check for substring extraction: ${VAR:offset} or ${VAR:offset:length}
        if (std.mem.indexOf(u8, content, ":")) |colon_pos| {
            // Make sure this isn't :- := :? :+ operators
            if (colon_pos + 1 < content.len) {
                const after_colon = content[colon_pos + 1];
                if (after_colon != '-' and after_colon != '=' and after_colon != '?' and after_colon != '+') {
                    // This is substring extraction
                    const var_name = content[0..colon_pos];
                    const params = content[colon_pos + 1 ..];

                    if (self.environment.get(var_name)) |value| {
                        // Parse offset and optional length
                        var offset: i64 = 0;
                        var length: ?usize = null;

                        if (std.mem.indexOf(u8, params, ":")) |second_colon| {
                            // ${VAR:offset:length}
                            offset = std.fmt.parseInt(i64, params[0..second_colon], 10) catch 0;
                            length = std.fmt.parseInt(usize, params[second_colon + 1 ..], 10) catch null;
                        } else {
                            // ${VAR:offset}
                            offset = std.fmt.parseInt(i64, params, 10) catch 0;
                        }

                        // Handle negative offset (from end of string)
                        var start: usize = 0;
                        if (offset < 0) {
                            const abs_offset: usize = @intCast(-offset);
                            if (abs_offset <= value.len) {
                                start = value.len - abs_offset;
                            }
                        } else {
                            start = @min(@as(usize, @intCast(offset)), value.len);
                        }

                        // Calculate end position
                        const end_pos = if (length) |len| @min(start + len, value.len) else value.len;

                        if (start <= end_pos and start <= value.len) {
                            const result = try self.allocator.dupe(u8, value[start..end_pos]);
                            return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                        }
                        return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                    }
                    return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                }
            }
        }

        // Check for replacement: ${VAR/pattern/replacement} or ${VAR//pattern/replacement}
        if (std.mem.indexOf(u8, content, "/")) |slash_pos| {
            if (slash_pos > 0) {
                const var_name = content[0..slash_pos];
                const rest = content[slash_pos..];

                // Check if it's // (replace all) or / (replace first)
                const replace_all = rest.len > 1 and rest[1] == '/';
                const pattern_start: usize = if (replace_all) 2 else 1;

                // Find the second slash for the replacement
                if (std.mem.indexOf(u8, rest[pattern_start..], "/")) |second_slash| {
                    const pattern = rest[pattern_start .. pattern_start + second_slash];
                    const replacement = rest[pattern_start + second_slash + 1 ..];

                    if (self.environment.get(var_name)) |value| {
                        const result = try self.replaceInString(value, pattern, replacement, replace_all);
                        return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                    }
                } else {
                    // No second slash - replacement is empty string (deletion)
                    const pattern = rest[pattern_start..];

                    if (self.environment.get(var_name)) |value| {
                        const result = try self.replaceInString(value, pattern, "", replace_all);
                        return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                    }
                }
                return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
            }
        }

        // Check for default value syntax: ${VAR:-default}
        if (std.mem.indexOf(u8, content, ":-")) |sep_pos| {
            const var_name = content[0..sep_pos];
            const default_value = content[sep_pos + 2 ..];

            if (self.environment.get(var_name)) |value| {
                if (value.len > 0) {
                    const result = try self.allocator.dupe(u8, value);
                    return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                }
            }

            // Use default value
            const result = try self.allocator.dupe(u8, default_value);
            return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
        }

        // Check for assign default syntax: ${VAR:=default}
        if (std.mem.indexOf(u8, content, ":=")) |sep_pos| {
            const var_name = content[0..sep_pos];
            const default_value = content[sep_pos + 2 ..];

            if (self.environment.get(var_name)) |value| {
                if (value.len > 0) {
                    const result = try self.allocator.dupe(u8, value);
                    return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                }
            }

            // Assign and use default value
            const value_copy = try self.allocator.dupe(u8, default_value);
            const name_copy = try self.allocator.dupe(u8, var_name);
            self.environment.put(name_copy, value_copy) catch {};
            const result = try self.allocator.dupe(u8, default_value);
            return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
        }

        // Check for error if unset syntax: ${VAR:?message}
        if (std.mem.indexOf(u8, content, ":?")) |sep_pos| {
            const var_name = content[0..sep_pos];
            const error_msg = content[sep_pos + 2 ..];

            if (self.environment.get(var_name)) |value| {
                if (value.len > 0) {
                    const result = try self.allocator.dupe(u8, value);
                    return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                }
            }

            // Print error message and return empty (shell should exit)
            const posix = std.posix;
            var buf: [512]u8 = undefined;
            const msg = if (error_msg.len > 0)
                std.fmt.bufPrint(&buf, "den: {s}: {s}\n", .{ var_name, error_msg }) catch "den: parameter null or not set\n"
            else
                std.fmt.bufPrint(&buf, "den: {s}: parameter null or not set\n", .{var_name}) catch "den: parameter null or not set\n";
            _ = posix.write(posix.STDERR_FILENO, msg) catch {};
            return error.ParameterNullOrNotSet;
        }

        // Check for use alternative value syntax: ${VAR:+value}
        if (std.mem.indexOf(u8, content, ":+")) |sep_pos| {
            const var_name = content[0..sep_pos];
            const alt_value = content[sep_pos + 2 ..];

            if (self.environment.get(var_name)) |value| {
                if (value.len > 0) {
                    // Variable is set and non-empty, use alternative value
                    const result = try self.allocator.dupe(u8, alt_value);
                    return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                }
            }

            // Variable is unset or empty, return empty string
            return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
        }

        // Check for parameter expansion patterns
        // ${VAR##pattern} - remove longest prefix match (greedy)
        if (std.mem.indexOf(u8, content, "##")) |sep_pos| {
            if (sep_pos > 0 and sep_pos < content.len - 2) {
                const var_name = content[0..sep_pos];
                const pattern = content[sep_pos + 2 ..];

                if (self.environment.get(var_name)) |value| {
                    const result = try self.removePrefix(value, pattern, true);
                    return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                }
                return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
            }
        }

        // ${VAR#pattern} - remove shortest prefix match
        if (std.mem.indexOf(u8, content, "#")) |sep_pos| {
            if (sep_pos > 0 and sep_pos < content.len - 1) {
                const var_name = content[0..sep_pos];
                const pattern = content[sep_pos + 1 ..];

                if (self.environment.get(var_name)) |value| {
                    const result = try self.removePrefix(value, pattern, false);
                    return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                }
                return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
            }
        }

        // ${VAR%%pattern} - remove longest suffix match (greedy)
        if (std.mem.indexOf(u8, content, "%%")) |sep_pos| {
            if (sep_pos > 0 and sep_pos < content.len - 2) {
                const var_name = content[0..sep_pos];
                const pattern = content[sep_pos + 2 ..];

                if (self.environment.get(var_name)) |value| {
                    const result = try self.removeSuffix(value, pattern, true);
                    return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                }
                return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
            }
        }

        // ${VAR%pattern} - remove shortest suffix match
        if (std.mem.indexOf(u8, content, "%")) |sep_pos| {
            if (sep_pos > 0 and sep_pos < content.len - 1) {
                const var_name = content[0..sep_pos];
                const pattern = content[sep_pos + 1 ..];

                if (self.environment.get(var_name)) |value| {
                    const result = try self.removeSuffix(value, pattern, false);
                    return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                }
                return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
            }
        }

        // Simple braced variable - use getVariableValue for nameref resolution
        if (self.getVariableValue(content)) |value| {
            const result = try self.allocator.dupe(u8, value);
            return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
        }

        // Variable not found - return empty string
        return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
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

    /// Replace pattern in string with replacement
    /// If replace_all is true, replace all occurrences; otherwise just first
    fn replaceInString(self: *Expansion, value: []const u8, pattern: []const u8, replacement: []const u8, replace_all: bool) ![]u8 {
        if (pattern.len == 0) {
            return try self.allocator.dupe(u8, value);
        }

        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        var replaced = false;

        while (i < value.len) {
            // Check if pattern matches at current position
            var match_len: usize = 0;
            if (self.findPatternMatch(value[i..], pattern)) |len| {
                match_len = len;
            }

            if (match_len > 0 and (replace_all or !replaced)) {
                // Pattern matches - add replacement instead
                try result.appendSlice(self.allocator, replacement);
                i += match_len;
                replaced = true;
            } else {
                // No match - copy character
                try result.append(self.allocator, value[i]);
                i += 1;
            }
        }

        return try result.toOwnedSlice(self.allocator);
    }

    /// Find pattern match at start of string, return length of match or null
    fn findPatternMatch(self: *Expansion, str: []const u8, pattern: []const u8) ?usize {
        _ = self;
        // Try matching pattern at different lengths
        var len: usize = 1;
        while (len <= str.len) : (len += 1) {
            if (matchPattern(pattern, str[0..len])) {
                return len;
            }
        }
        return null;
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
            return ExpansionResult{ .value = "$", .consumed = 1, .owned = false };
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
            return ExpansionResult{ .value = "$", .consumed = 1, .owned = false };
        }

        const var_name = input[1..end];

        // Use getVariableValue which handles local vars and nameref resolution
        if (self.getVariableValue(var_name)) |value| {
            const result = try self.allocator.dupe(u8, value);
            return ExpansionResult{ .value = result, .consumed = end, .owned = true };
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
        return ExpansionResult{ .value = "", .consumed = end, .owned = false };
    }

    /// Expand $(command) - command substitution
    fn expandCommandSubstitution(self: *Expansion, input: []const u8) !ExpansionResult {
        if (input.len < 3 or input[0] != '$' or input[1] != '(') {
            return ExpansionResult{ .value = "$", .consumed = 1, .owned = false };
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
            return ExpansionResult{ .value = "$(", .consumed = 2, .owned = false };
        }

        const command = input[2..end];

        // Check cache first (if available)
        if (self.cmd_cache) |cache| {
            if (cache.get(command)) |cached| {
                const result = try self.allocator.dupe(u8, cached);
                return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
            }
        }

        // Execute the command and capture output
        const output = self.executeCommandForSubstitution(command) catch {
            // On error, return empty string
            return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
        };

        // Trim trailing newlines (bash behavior)
        var trimmed_len = output.len;
        while (trimmed_len > 0 and output[trimmed_len - 1] == '\n') {
            trimmed_len -= 1;
        }

        const result = try self.allocator.dupe(u8, output[0..trimmed_len]);

        // Cache the result (if cache is available)
        if (self.cmd_cache) |cache| {
            cache.put(command, result) catch {
                // Caching failed, but that's okay - we have the result
            };
        }

        return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
    }

    /// Expand backtick command substitution: `command`
    fn expandBacktick(self: *Expansion, input: []const u8) !ExpansionResult {
        if (input.len < 2 or input[0] != '`') {
            return ExpansionResult{ .value = "`", .consumed = 1, .owned = false };
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
            return ExpansionResult{ .value = "`", .consumed = 1, .owned = false };
        }

        const command = input[1..end];

        // Check cache first (if available)
        if (self.cmd_cache) |cache| {
            if (cache.get(command)) |cached| {
                const result = try self.allocator.dupe(u8, cached);
                return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
            }
        }

        // Execute the command and capture output
        const output = self.executeCommandForSubstitution(command) catch {
            // On error, return empty string
            return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
        };

        // Trim trailing newlines (bash behavior)
        var trimmed_len = output.len;
        while (trimmed_len > 0 and output[trimmed_len - 1] == '\n') {
            trimmed_len -= 1;
        }

        const result = try self.allocator.dupe(u8, output[0..trimmed_len]);

        // Cache the result (if cache is available)
        if (self.cmd_cache) |cache| {
            cache.put(command, result) catch {
                // Caching failed, but that's okay - we have the result
            };
        }

        return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
    }

    /// Execute a command and return its output
    fn executeCommandForSubstitution(self: *Expansion, command: []const u8) ![]const u8 {
        // Create a child process to execute the command
        const argv = [_][]const u8{ "sh", "-c", command };

        var child = std.process.spawn(std.Options.debug_io, .{
            .argv = &argv,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch |err| return err;

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

        const term = try child.wait(std.Options.debug_io);
        _ = term;

        return output;
    }

    /// Expand $((expression)) - arithmetic expansion
    fn expandArithmetic(self: *Expansion, input: []const u8) !ExpansionResult {
        if (input.len < 4 or input[0] != '$' or input[1] != '(' or input[2] != '(') {
            return ExpansionResult{ .value = "$", .consumed = 1, .owned = false };
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
            return ExpansionResult{ .value = "$((", .consumed = 3, .owned = false };
        }

        // Extract expression (between (( and ))
        const expr = input[3..end - 1];

        // Evaluate arithmetic expression with variable support
        var arith = Arithmetic.initWithVariables(self.allocator, self.environment);
        const result_value = arith.eval(expr) catch {
            // On error, return 0
            const value = try std.fmt.allocPrint(self.allocator, "0", .{});
            return ExpansionResult{ .value = value, .consumed = end + 1, .owned = true };
        };

        // Format result as string
        const value = try std.fmt.allocPrint(self.allocator, "{d}", .{result_value});
        return ExpansionResult{ .value = value, .consumed = end + 1, .owned = true };
    }

    /// Expand tilde (~) to home directory
    /// Supports: ~, ~user, ~+, ~-, ~+N, ~-N
    fn expandTilde(self: *Expansion, input: []const u8) !ExpansionResult {
        if (input.len < 1 or input[0] != '~') {
            return ExpansionResult{ .value = "~", .consumed = 1, .owned = false };
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
                    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                    if (std.Io.Dir.cwd().realpath(".", &cwd_buf)) |path| {
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
            .owned = true,
        };
    }

    /// Expand process substitution: <(cmd) or >(cmd)
    /// Creates a pipe, forks a process to run the command, and returns /dev/fd/N
    fn expandProcessSubstitution(self: *Expansion, input: []const u8, is_input: bool) !ExpansionResult {
        // Process substitution is not available on Windows
        if (builtin.os.tag == .windows) {
            // Return the literal text on Windows
            if (input.len < 2) {
                return ExpansionResult{ .value = if (is_input) "<" else ">", .consumed = 1, .owned = false };
            }
            // Find closing paren and return as literal
            var end: usize = 2;
            var depth: u32 = 1;
            while (end < input.len and depth > 0) {
                if (input[end] == '(') depth += 1 else if (input[end] == ')') depth -= 1;
                if (depth > 0) end += 1;
            }
            const literal = try self.allocator.dupe(u8, input[0 .. end + 1]);
            return ExpansionResult{ .value = literal, .consumed = end + 1, .owned = true };
        }

        // Parse: <(cmd) or >(cmd)
        if (input.len < 3 or input[1] != '(') {
            return ExpansionResult{ .value = if (is_input) "<" else ">", .consumed = 1, .owned = false };
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
            // Unmatched parenthesis - return literal
            return ExpansionResult{ .value = if (is_input) "<(" else ">(", .consumed = 2, .owned = false };
        }

        const command = input[2..end];

        // Create a pipe
        const pipe_fds = std.posix.pipe() catch {
            return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
        };

        // Fork a child process
        const fork_result = std.posix.fork() catch {
            std.posix.close(pipe_fds[0]);
            std.posix.close(pipe_fds[1]);
            return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
        };

        if (fork_result == 0) {
            // Child process
            if (is_input) {
                // <(cmd) - child writes to pipe, parent reads
                // Close read end
                std.posix.close(pipe_fds[0]);
                // Redirect stdout to write end of pipe
                std.posix.dup2(pipe_fds[1], std.posix.STDOUT_FILENO) catch {
                    std.process.exit(1);
                };
                std.posix.close(pipe_fds[1]);
            } else {
                // >(cmd) - child reads from pipe, parent writes
                // Close write end
                std.posix.close(pipe_fds[1]);
                // Redirect stdin to read end of pipe
                std.posix.dup2(pipe_fds[0], std.posix.STDIN_FILENO) catch {
                    std.process.exit(1);
                };
                std.posix.close(pipe_fds[0]);
            }

            // Execute the command via sh -c
            // Create null-terminated command string
            var cmd_buf: [4096]u8 = undefined;
            if (command.len >= cmd_buf.len) {
                std.process.exit(1);
            }
            @memcpy(cmd_buf[0..command.len], command);
            cmd_buf[command.len] = 0;

            const argv = [_:null]?[*:0]const u8{
                "/bin/sh",
                "-c",
                @ptrCast(&cmd_buf),
                null,
            };
            std.posix.execveZ("/bin/sh", &argv, @ptrCast(std.os.environ.ptr)) catch {};
            std.process.exit(127);
        }

        // Parent process
        // Determine which fd the parent will use
        const parent_fd = if (is_input) pipe_fds[0] else pipe_fds[1];
        const child_fd = if (is_input) pipe_fds[1] else pipe_fds[0];

        // Close the fd the child is using
        std.posix.close(child_fd);

        // Format the /dev/fd/N path
        const fd_path = std.fmt.allocPrint(self.allocator, "/dev/fd/{d}", .{parent_fd}) catch {
            std.posix.close(parent_fd);
            return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
        };

        return ExpansionResult{ .value = fd_path, .consumed = end + 1, .owned = true };
    }
};

/// Get user's home directory from passwd database
/// Uses POSIX getpwnam for lookup
fn getUserHomeDir(username: []const u8) ?[]const u8 {
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

/// IFS-based word splitting utilities
/// Default IFS is space, tab, and newline
pub const WordSplitter = struct {
    allocator: std.mem.Allocator,
    ifs: []const u8,

    /// Default IFS value (space, tab, newline)
    pub const default_ifs = " \t\n";

    /// Initialize with environment lookup for IFS
    pub fn init(allocator: std.mem.Allocator, environment: ?*std.StringHashMap([]const u8)) WordSplitter {
        const ifs = if (environment) |env| env.get("IFS") orelse default_ifs else default_ifs;
        return .{
            .allocator = allocator,
            .ifs = ifs,
        };
    }

    /// Initialize with custom IFS value
    pub fn initWithIfs(allocator: std.mem.Allocator, ifs: []const u8) WordSplitter {
        return .{
            .allocator = allocator,
            .ifs = ifs,
        };
    }

    /// Split a string into words based on IFS
    /// Respects quoting: single quotes, double quotes preserve content
    /// Empty IFS means no splitting
    /// Returns array of word slices (caller must free the array)
    pub fn split(self: *const WordSplitter, input: []const u8) ![][]const u8 {
        // Empty IFS means no splitting - return entire input as one word
        if (self.ifs.len == 0) {
            var result = try self.allocator.alloc([]const u8, 1);
            result[0] = input;
            return result;
        }

        var words = std.ArrayList([]const u8).empty;
        errdefer words.deinit(self.allocator);

        var i: usize = 0;
        while (i < input.len) {
            // Skip leading IFS whitespace characters (space, tab, newline)
            while (i < input.len and self.isIfsWhitespace(input[i])) {
                i += 1;
            }

            if (i >= input.len) break;

            // Check for non-whitespace IFS character (acts as delimiter)
            if (self.isIfsNonWhitespace(input[i])) {
                // Non-whitespace IFS chars create empty fields
                try words.append(self.allocator, "");
                i += 1;
                continue;
            }

            // Start of a word
            const word_start = i;
            var in_single_quote = false;
            var in_double_quote = false;

            while (i < input.len) {
                const c = input[i];

                // Handle quoting
                if (c == '\'' and !in_double_quote) {
                    in_single_quote = !in_single_quote;
                    i += 1;
                    continue;
                }
                if (c == '"' and !in_single_quote) {
                    in_double_quote = !in_double_quote;
                    i += 1;
                    continue;
                }

                // If not in quotes, check for IFS
                if (!in_single_quote and !in_double_quote) {
                    if (self.isIfsChar(c)) {
                        break;
                    }
                }

                i += 1;
            }

            // Add the word if non-empty
            if (i > word_start) {
                try words.append(self.allocator, input[word_start..i]);
            }
        }

        return try words.toOwnedSlice(self.allocator);
    }

    /// Split and remove quotes from words
    /// Returns newly allocated strings (caller must free each string and the array)
    pub fn splitAndUnquote(self: *const WordSplitter, input: []const u8) ![][]const u8 {
        const raw_words = try self.split(input);
        defer self.allocator.free(raw_words);

        var result = try self.allocator.alloc([]const u8, raw_words.len);
        errdefer {
            for (result) |word| {
                if (word.len > 0) self.allocator.free(word);
            }
            self.allocator.free(result);
        }

        for (raw_words, 0..) |word, idx| {
            result[idx] = try removeQuotes(self.allocator, word);
        }

        return result;
    }

    /// Check if character is an IFS character
    fn isIfsChar(self: *const WordSplitter, c: u8) bool {
        for (self.ifs) |ifs_char| {
            if (c == ifs_char) return true;
        }
        return false;
    }

    /// Check if character is an IFS whitespace (space, tab, newline)
    fn isIfsWhitespace(self: *const WordSplitter, c: u8) bool {
        if (!self.isIfsChar(c)) return false;
        return c == ' ' or c == '\t' or c == '\n';
    }

    /// Check if character is a non-whitespace IFS character
    fn isIfsNonWhitespace(self: *const WordSplitter, c: u8) bool {
        if (!self.isIfsChar(c)) return false;
        return c != ' ' and c != '\t' and c != '\n';
    }
};

/// Remove single and double quotes from a string
/// Preserves content inside quotes, handles escape sequences in double quotes
pub fn removeQuotes(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (input.len == 0) {
        return try allocator.dupe(u8, "");
    }

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    var in_single_quote = false;
    var in_double_quote = false;

    while (i < input.len) {
        const c = input[i];

        if (c == '\'' and !in_double_quote) {
            // Toggle single quote mode, don't output the quote
            in_single_quote = !in_single_quote;
            i += 1;
            continue;
        }

        if (c == '"' and !in_single_quote) {
            // Toggle double quote mode, don't output the quote
            in_double_quote = !in_double_quote;
            i += 1;
            continue;
        }

        // Handle escape sequences in double quotes
        if (c == '\\' and in_double_quote and i + 1 < input.len) {
            const next = input[i + 1];
            // Only these characters are escaped in double quotes: $ ` " \ newline
            if (next == '$' or next == '`' or next == '"' or next == '\\' or next == '\n') {
                if (next != '\n') { // Escaped newline is removed entirely
                    try result.append(allocator, next);
                }
                i += 2;
                continue;
            }
        }

        // Regular character
        try result.append(allocator, c);
        i += 1;
    }

    return try result.toOwnedSlice(allocator);
}

/// Split expanded value into words using IFS and apply to positional parameters
/// This is the full POSIX field splitting algorithm
pub fn splitFieldsIfs(allocator: std.mem.Allocator, value: []const u8, ifs: []const u8) ![][]const u8 {
    var splitter = WordSplitter.initWithIfs(allocator, ifs);
    return try splitter.split(value);
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

test "IFS word splitting - default IFS" {
    const allocator = std.testing.allocator;

    var splitter = WordSplitter.initWithIfs(allocator, WordSplitter.default_ifs);

    const words = try splitter.split("one  two\tthree\nfour");
    defer allocator.free(words);

    try std.testing.expectEqual(@as(usize, 4), words.len);
    try std.testing.expectEqualStrings("one", words[0]);
    try std.testing.expectEqualStrings("two", words[1]);
    try std.testing.expectEqualStrings("three", words[2]);
    try std.testing.expectEqualStrings("four", words[3]);
}

test "IFS word splitting - custom IFS" {
    const allocator = std.testing.allocator;

    var splitter = WordSplitter.initWithIfs(allocator, ":");

    const words = try splitter.split("/usr/local/bin:/usr/bin:/bin");
    defer allocator.free(words);

    try std.testing.expectEqual(@as(usize, 3), words.len);
    try std.testing.expectEqualStrings("/usr/local/bin", words[0]);
    try std.testing.expectEqualStrings("/usr/bin", words[1]);
    try std.testing.expectEqualStrings("/bin", words[2]);
}

test "IFS word splitting - empty IFS" {
    const allocator = std.testing.allocator;

    var splitter = WordSplitter.initWithIfs(allocator, "");

    const words = try splitter.split("one two three");
    defer allocator.free(words);

    // Empty IFS means no splitting
    try std.testing.expectEqual(@as(usize, 1), words.len);
    try std.testing.expectEqualStrings("one two three", words[0]);
}

test "IFS word splitting - quoted content preserved" {
    const allocator = std.testing.allocator;

    var splitter = WordSplitter.initWithIfs(allocator, WordSplitter.default_ifs);

    const words = try splitter.split("one 'two three' four");
    defer allocator.free(words);

    try std.testing.expectEqual(@as(usize, 3), words.len);
    try std.testing.expectEqualStrings("one", words[0]);
    try std.testing.expectEqualStrings("'two three'", words[1]);
    try std.testing.expectEqualStrings("four", words[2]);
}

test "IFS word splitting - double quoted content preserved" {
    const allocator = std.testing.allocator;

    var splitter = WordSplitter.initWithIfs(allocator, WordSplitter.default_ifs);

    const words = try splitter.split("one \"two three\" four");
    defer allocator.free(words);

    try std.testing.expectEqual(@as(usize, 3), words.len);
    try std.testing.expectEqualStrings("one", words[0]);
    try std.testing.expectEqualStrings("\"two three\"", words[1]);
    try std.testing.expectEqualStrings("four", words[2]);
}

test "removeQuotes - single quotes" {
    const allocator = std.testing.allocator;

    const result = try removeQuotes(allocator, "'hello world'");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "removeQuotes - double quotes" {
    const allocator = std.testing.allocator;

    const result = try removeQuotes(allocator, "\"hello world\"");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "removeQuotes - mixed quotes" {
    const allocator = std.testing.allocator;

    const result = try removeQuotes(allocator, "hello 'single' and \"double\" world");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello single and double world", result);
}

test "removeQuotes - escape in double quotes" {
    const allocator = std.testing.allocator;

    const result = try removeQuotes(allocator, "\"hello \\\"world\\\"\"");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello \"world\"", result);
}
