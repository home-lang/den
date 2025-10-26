const std = @import("std");

/// Hook types that plugins can register
pub const HookType = enum {
    pre_command,   // Before command execution
    post_command,  // After command execution
    pre_prompt,    // Before showing prompt
    post_prompt,   // After prompt input
    shell_init,    // Shell initialization
    shell_exit,    // Shell exit
};

/// Hook function signature
pub const HookFn = *const fn (context: *HookContext) anyerror!void;

/// Hook context passed to hook functions
pub const HookContext = struct {
    hook_type: HookType,
    data: ?*anyopaque, // Hook-specific data
    user_data: ?*anyopaque, // Plugin-specific data
    allocator: std.mem.Allocator,

    /// Get command string (for pre/post_command hooks)
    pub fn getCommand(self: *HookContext) ?[]const u8 {
        if (self.data) |data| {
            // Cast to []const u8
            const cmd: *[]const u8 = @ptrCast(@alignCast(data));
            return cmd.*;
        }
        return null;
    }

    /// Set user data
    pub fn setUserData(self: *HookContext, data: *anyopaque) void {
        self.user_data = data;
    }

    /// Get user data
    pub fn getUserData(self: *HookContext) ?*anyopaque {
        return self.user_data;
    }
};

/// Registered hook
pub const Hook = struct {
    plugin_name: []const u8,
    hook_type: HookType,
    function: HookFn,
    priority: i32, // Lower numbers run first
    enabled: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Hook) void {
        self.allocator.free(self.plugin_name);
    }
};
