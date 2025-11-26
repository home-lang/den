const std = @import("std");
const zig_config = @import("zig-config");
const types = @import("types/mod.zig");
const DenConfig = types.DenConfig;

/// Load Den shell configuration from multiple sources
/// Priority: env vars > local file > home directory > defaults
pub fn loadConfig(allocator: std.mem.Allocator) !DenConfig {
    return loadConfigWithPath(allocator, null);
}

/// Load Den shell configuration from a custom path
/// If custom_path is provided, it takes priority over default search paths
pub fn loadConfigWithPath(allocator: std.mem.Allocator, custom_path: ?[]const u8) !DenConfig {
    if (custom_path) |path| {
        // Load from custom path directly
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            std.debug.print("Error: Failed to open config file '{s}': {any}\n", .{ path, err });
            return error.ConfigFileNotFound;
        };
        defer file.close();

        // Read file content
        var content = std.ArrayList(u8).empty;
        defer content.deinit(allocator);

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = file.read(&buf) catch break;
            if (n == 0) break;
            try content.appendSlice(allocator, buf[0..n]);
        }

        // Remove JSONC comments (same as zig-config does)
        const json = try removeJsoncComments(allocator, content.items);
        defer allocator.free(json);

        // Parse JSON
        const parsed = std.json.parseFromSlice(DenConfig, allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            std.debug.print("Error: Failed to parse config file '{s}': {any}\n", .{ path, err });
            return error.ConfigParseError;
        };

        return parsed.value;
    }

    // Use default config loading
    const config = zig_config.loadConfig(DenConfig, allocator, .{
        .name = "den",
        .env_prefix = "DEN",
    }) catch |err| {
        // If loading fails, use defaults
        std.debug.print("Warning: Failed to load config ({any}), using defaults\n", .{err});
        return DenConfig{};
    };
    // Note: We do NOT call config.deinit() here because the config value
    // contains slices that point to memory that would be freed.
    // The config memory lives for the lifetime of the shell.

    return config.value;
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

/// Try to load config, return null on error (no error output)
pub fn tryLoadConfig(allocator: std.mem.Allocator) ?DenConfig {
    return loadConfig(allocator) catch null;
}

/// Try to load config from custom path, return null on error (no error output)
pub fn tryLoadConfigWithPath(allocator: std.mem.Allocator, custom_path: ?[]const u8) ?DenConfig {
    return loadConfigWithPath(allocator, custom_path) catch null;
}

test "loadConfig returns defaults when no file found" {
    const allocator = std.testing.allocator;
    const config = try loadConfig(allocator);
    try std.testing.expect(!config.verbose);
}
