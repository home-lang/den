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

/// Configuration validation error
pub const ConfigError = struct {
    field: []const u8,
    message: []const u8,
    severity: Severity,

    pub const Severity = enum {
        warning,
        err,
    };
};

/// Validation result with errors and warnings
pub const ValidationResult = struct {
    valid: bool,
    errors: []ConfigError,
    warnings: []ConfigError,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ValidationResult) void {
        self.allocator.free(self.errors);
        self.allocator.free(self.warnings);
    }

    pub fn format(self: *const ValidationResult, writer: anytype) !void {
        if (self.errors.len > 0) {
            try writer.writeAll("Configuration errors:\n");
            for (self.errors) |err| {
                try writer.print("  - {s}: {s}\n", .{ err.field, err.message });
            }
        }
        if (self.warnings.len > 0) {
            try writer.writeAll("Configuration warnings:\n");
            for (self.warnings) |warn| {
                try writer.print("  - {s}: {s}\n", .{ warn.field, warn.message });
            }
        }
    }
};

/// Validate configuration and return detailed error messages
pub fn validateConfig(allocator: std.mem.Allocator, config: DenConfig) !ValidationResult {
    var errors = std.ArrayList(ConfigError).empty;
    errdefer errors.deinit(allocator);

    var warnings = std.ArrayList(ConfigError).empty;
    errdefer warnings.deinit(allocator);

    // Validate history settings
    if (config.history.max_entries < 100) {
        try warnings.append(allocator, ConfigError{
            .field = "history.max_entries",
            .message = "Very small history size (<100) may limit usability",
            .severity = .warning,
        });
    }
    if (config.history.max_entries > 1000000) {
        try warnings.append(allocator, ConfigError{
            .field = "history.max_entries",
            .message = "Very large history size (>1M) may cause performance issues",
            .severity = .warning,
        });
    }

    // Validate completion settings
    if (config.completion.max_suggestions == 0) {
        try errors.append(allocator, ConfigError{
            .field = "completion.max_suggestions",
            .message = "Must be at least 1",
            .severity = .err,
        });
    }
    if (config.completion.max_suggestions > 100) {
        try warnings.append(allocator, ConfigError{
            .field = "completion.max_suggestions",
            .message = "Very large value (>100) may cause display issues",
            .severity = .warning,
        });
    }

    // Validate completion cache settings
    if (config.completion.cache.enabled and config.completion.cache.max_entries == 0) {
        try errors.append(allocator, ConfigError{
            .field = "completion.cache.max_entries",
            .message = "Cache is enabled but max_entries is 0",
            .severity = .err,
        });
    }

    // Validate theme color format (should be hex codes or named colors)
    if (!isValidColor(config.theme.colors.primary)) {
        try warnings.append(allocator, ConfigError{
            .field = "theme.colors.primary",
            .message = "Invalid color format (expected #RRGGBB or named color)",
            .severity = .warning,
        });
    }
    if (!isValidColor(config.theme.colors.secondary)) {
        try warnings.append(allocator, ConfigError{
            .field = "theme.colors.secondary",
            .message = "Invalid color format (expected #RRGGBB or named color)",
            .severity = .warning,
        });
    }

    // Validate prompt format
    if (config.prompt.format.len == 0) {
        try errors.append(allocator, ConfigError{
            .field = "prompt.format",
            .message = "Prompt format cannot be empty",
            .severity = .err,
        });
    }

    // Validate expansion cache limits
    if (config.expansion.cache_limits.glob > 10000) {
        try warnings.append(allocator, ConfigError{
            .field = "expansion.cache_limits.glob",
            .message = "Very large glob cache (>10000) may use excessive memory",
            .severity = .warning,
        });
    }

    return ValidationResult{
        .valid = errors.items.len == 0,
        .errors = try errors.toOwnedSlice(allocator),
        .warnings = try warnings.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Check if a color value is valid
fn isValidColor(color: []const u8) bool {
    if (color.len == 0) return false;

    // Check hex color format: #RGB, #RRGGBB, or #RRGGBBAA
    if (color[0] == '#') {
        const hex_part = color[1..];
        if (hex_part.len != 3 and hex_part.len != 6 and hex_part.len != 8) return false;
        for (hex_part) |c| {
            if (!std.ascii.isHex(c)) return false;
        }
        return true;
    }

    // Check named colors
    const named_colors = [_][]const u8{
        "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
        "gray", "grey", "orange", "pink", "purple", "brown", "silver", "gold",
    };
    for (named_colors) |name| {
        if (std.mem.eql(u8, color, name)) return true;
    }

    return false;
}

/// Load and validate config, returning both config and validation result
pub fn loadAndValidateConfig(allocator: std.mem.Allocator) !struct { config: DenConfig, validation: ValidationResult } {
    const config = try loadConfig(allocator);
    const validation = try validateConfig(allocator, config);
    return .{ .config = config, .validation = validation };
}

/// Load and validate config from custom path
pub fn loadAndValidateConfigWithPath(allocator: std.mem.Allocator, custom_path: ?[]const u8) !struct { config: DenConfig, validation: ValidationResult } {
    const config = try loadConfigWithPath(allocator, custom_path);
    const validation = try validateConfig(allocator, config);
    return .{ .config = config, .validation = validation };
}

test "loadConfig returns defaults when no file found" {
    const allocator = std.testing.allocator;
    const config = try loadConfig(allocator);
    try std.testing.expect(!config.verbose);
}

test "validateConfig - valid default config" {
    const allocator = std.testing.allocator;
    const config = DenConfig{};
    var result = try validateConfig(allocator, config);
    defer result.deinit();
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "validateConfig - invalid completion max_suggestions" {
    const allocator = std.testing.allocator;
    var config = DenConfig{};
    config.completion.max_suggestions = 0;
    var result = try validateConfig(allocator, config);
    defer result.deinit();
    try std.testing.expect(!result.valid);
    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
}

test "isValidColor - hex colors" {
    try std.testing.expect(isValidColor("#FFF"));
    try std.testing.expect(isValidColor("#FFFFFF"));
    try std.testing.expect(isValidColor("#00D9FF"));
    try std.testing.expect(isValidColor("#FFFFFFFF"));
    try std.testing.expect(!isValidColor("#GGG"));
    try std.testing.expect(!isValidColor("#"));
    try std.testing.expect(!isValidColor(""));
}

test "isValidColor - named colors" {
    try std.testing.expect(isValidColor("red"));
    try std.testing.expect(isValidColor("blue"));
    try std.testing.expect(isValidColor("green"));
    try std.testing.expect(!isValidColor("notacolor"));
}
