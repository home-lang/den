const std = @import("std");

/// Result wrapper for loaded configuration
pub fn ConfigResult(comptime T: type) type {
    return struct {
        value: T,
        allocator: std.mem.Allocator,
        json_source: ?[]const u8 = null,

        pub fn deinit(self: @This(), _: std.mem.Allocator) void {
            if (self.json_source) |src| {
                self.allocator.free(src);
            }
        }
    };
}

pub const LoadConfigOptions = struct {
    name: []const u8,
    env_prefix: []const u8,
};

/// Load configuration from JSONC files
/// Search order: ./name.jsonc, ./config/name.jsonc, ./.config/name.jsonc, ~/.config/name.jsonc
pub fn loadConfig(
    comptime T: type,
    allocator: std.mem.Allocator,
    options: LoadConfigOptions,
) !ConfigResult(T) {
    var path_buf: [1024]u8 = undefined;

    // Try local paths first
    // 1. ./name.jsonc
    const path1 = std.fmt.bufPrint(&path_buf, "{s}.jsonc", .{options.name}) catch {
        return ConfigResult(T){ .value = T{}, .allocator = allocator };
    };
    if (tryLoadFromPath(T, allocator, path1)) |result| {
        return result;
    }

    // 2. ./config/name.jsonc
    const path2 = std.fmt.bufPrint(&path_buf, "config/{s}.jsonc", .{options.name}) catch {
        return ConfigResult(T){ .value = T{}, .allocator = allocator };
    };
    if (tryLoadFromPath(T, allocator, path2)) |result| {
        return result;
    }

    // 3. ./.config/name.jsonc
    const path3 = std.fmt.bufPrint(&path_buf, ".config/{s}.jsonc", .{options.name}) catch {
        return ConfigResult(T){ .value = T{}, .allocator = allocator };
    };
    if (tryLoadFromPath(T, allocator, path3)) |result| {
        return result;
    }

    // Try home directory
    if (std.posix.getenv("HOME")) |home| {
        const home_config_path = std.fmt.bufPrint(&path_buf, "{s}/.config/{s}.jsonc", .{ home, options.name }) catch {
            return ConfigResult(T){ .value = T{}, .allocator = allocator };
        };

        if (tryLoadFromPath(T, allocator, home_config_path)) |result| {
            return result;
        }
    }

    // Return defaults if no config found
    return ConfigResult(T){ .value = T{}, .allocator = allocator };
}

fn tryLoadFromPath(comptime T: type, allocator: std.mem.Allocator, path: []const u8) ?ConfigResult(T) {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    // Read file content
    var content = std.ArrayList(u8).empty;
    defer content.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch return null;
        if (n == 0) break;
        content.appendSlice(allocator, buf[0..n]) catch return null;
    }

    // Remove JSONC comments
    const json = removeJsoncComments(allocator, content.items) catch return null;

    // Parse JSON
    const parsed = std.json.parseFromSlice(T, allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        allocator.free(json);
        return null;
    };
    // Note: We do NOT call parsed.deinit() here because the value
    // contains slices that point to memory owned by the parsed arena.
    // The caller must keep the config result alive for the duration of use.
    // The json_source is freed by ConfigResult.deinit().
    // TODO: Consider deep-copying all slice fields to avoid this lifetime issue.

    return ConfigResult(T){
        .value = parsed.value,
        .allocator = allocator,
        .json_source = json,
    };
}

/// Remove JSONC comments (// and /* */) and trailing commas
fn removeJsoncComments(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var i: usize = 0;
    var in_string = false;
    var escape_next = false;

    while (i < input.len) {
        const c = input[i];

        if (escape_next) {
            try output.append(allocator, c);
            escape_next = false;
            i += 1;
            continue;
        }

        if (c == '\\' and in_string) {
            try output.append(allocator, c);
            escape_next = true;
            i += 1;
            continue;
        }

        if (c == '"') {
            in_string = !in_string;
            try output.append(allocator, c);
            i += 1;
            continue;
        }

        if (in_string) {
            try output.append(allocator, c);
            i += 1;
            continue;
        }

        // Check for // comment
        if (c == '/' and i + 1 < input.len and input[i + 1] == '/') {
            // Skip until end of line
            while (i < input.len and input[i] != '\n') {
                i += 1;
            }
            continue;
        }

        // Check for /* */ comment
        if (c == '/' and i + 1 < input.len and input[i + 1] == '*') {
            i += 2;
            while (i + 1 < input.len) {
                if (input[i] == '*' and input[i + 1] == '/') {
                    i += 2;
                    break;
                }
                i += 1;
            }
            continue;
        }

        // Handle trailing commas before } or ]
        if (c == ',') {
            // Look ahead for } or ] (skipping whitespace)
            var j = i + 1;
            while (j < input.len and (input[j] == ' ' or input[j] == '\t' or input[j] == '\n' or input[j] == '\r')) {
                j += 1;
            }
            if (j < input.len and (input[j] == '}' or input[j] == ']')) {
                // Skip the trailing comma
                i += 1;
                continue;
            }
        }

        try output.append(allocator, c);
        i += 1;
    }

    return try output.toOwnedSlice(allocator);
}

// Tests
test "removeJsoncComments: line comments" {
    const allocator = std.testing.allocator;
    const input = "{\n  // comment\n  \"key\": \"value\"\n}";
    const result = try removeJsoncComments(allocator, input);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "comment") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"key\"") != null);
}

test "removeJsoncComments: block comments" {
    const allocator = std.testing.allocator;
    const input = "{ /* block comment */ \"key\": \"value\" }";
    const result = try removeJsoncComments(allocator, input);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "block") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"key\"") != null);
}

test "removeJsoncComments: trailing commas" {
    const allocator = std.testing.allocator;
    const input = "{ \"key\": \"value\", }";
    const result = try removeJsoncComments(allocator, input);
    defer allocator.free(result);

    // Should not have comma before }
    var found_trailing = false;
    for (0..result.len) |i| {
        if (result[i] == ',') {
            var j = i + 1;
            while (j < result.len and (result[j] == ' ' or result[j] == '\n')) j += 1;
            if (j < result.len and result[j] == '}') {
                found_trailing = true;
            }
        }
    }
    try std.testing.expect(!found_trailing);
}

test "removeJsoncComments: preserves strings with slashes" {
    const allocator = std.testing.allocator;
    const input = "{ \"url\": \"http://example.com\" }";
    const result = try removeJsoncComments(allocator, input);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "http://example.com") != null);
}

test "loadConfig returns defaults when no file" {
    const TestConfig = struct {
        value: bool = true,
    };

    const allocator = std.testing.allocator;
    const result = try loadConfig(TestConfig, allocator, .{
        .name = "nonexistent_config_12345",
        .env_prefix = "TEST",
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.value.value == true);
}
