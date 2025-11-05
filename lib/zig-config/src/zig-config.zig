const std = @import("std");

pub fn ConfigResult(comptime T: type) type {
    return struct {
        value: T,

        pub fn deinit(_: @This(), _: std.mem.Allocator) void {
            // No-op for simple stub
        }
    };
}

pub const LoadConfigOptions = struct {
    name: []const u8,
    env_prefix: []const u8,
};

pub fn loadConfig(
    comptime T: type,
    allocator: std.mem.Allocator,
    options: LoadConfigOptions,
) !ConfigResult(T) {
    _ = allocator;
    _ = options;

    // Return default instance
    return ConfigResult(T){
        .value = T{},
    };
}
