const std = @import("std");
const zig_config = @import("zig-config");
const types = @import("types/mod.zig");
const DenConfig = types.DenConfig;

/// Load Den shell configuration from multiple sources
/// Priority: env vars > local file > home directory > defaults
pub fn loadConfig(allocator: std.mem.Allocator) !DenConfig {
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

/// Try to load config, return null on error (no error output)
pub fn tryLoadConfig(allocator: std.mem.Allocator) ?DenConfig {
    return loadConfig(allocator) catch null;
}

test "loadConfig returns defaults when no file found" {
    const allocator = std.testing.allocator;
    const config = try loadConfig(allocator);
    try std.testing.expect(!config.verbose);
}
