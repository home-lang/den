// Example Plugin: Desktop Notifications for Long-Running Commands
// Place in ~/.config/den/plugins/notify.zig
//
// This plugin sends desktop notifications when commands take longer than
// a specified threshold to complete.

const std = @import("std");
const Plugin = @import("../../src/plugins/interface.zig").Plugin;
const HookType = @import("../../src/plugins/interface.zig").HookType;
const HookContext = @import("../../src/plugins/interface.zig").HookContext;

pub const NotifyPlugin = struct {
    allocator: std.mem.Allocator,
    threshold_seconds: u64,
    enabled: bool,

    pub fn init(allocator: std.mem.Allocator) !*NotifyPlugin {
        var plugin = try allocator.create(NotifyPlugin);
        plugin.* = NotifyPlugin{
            .allocator = allocator,
            .threshold_seconds = 10, // Default: 10 seconds
            .enabled = true,
        };
        return plugin;
    }

    pub fn deinit(self: *NotifyPlugin) void {
        self.allocator.destroy(self);
    }

    pub fn getName(self: *NotifyPlugin) []const u8 {
        _ = self;
        return "notify";
    }

    pub fn getVersion(self: *NotifyPlugin) []const u8 {
        _ = self;
        return "1.0.0";
    }

    pub fn getDescription(self: *NotifyPlugin) []const u8 {
        _ = self;
        return "Send desktop notifications for long-running commands";
    }

    pub fn onHook(self: *NotifyPlugin, hook_type: HookType, context: *HookContext) !void {
        if (!self.enabled) return;

        if (hook_type == .post_command) {
            // Get command duration from context
            if (context.user_data) |data| {
                const duration_ptr: *u64 = @ptrCast(@alignCast(data));
                const duration = duration_ptr.*;

                if (duration >= self.threshold_seconds) {
                    try self.sendNotification(duration);
                }
            }
        }
    }

    fn sendNotification(self: *NotifyPlugin, duration: u64) !void {
        // Use notify-send on Linux, osascript on macOS
        var cmd_buf: [256]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&cmd_buf,
            "notify-send 'Command Completed' 'Duration: {d}s'",
            .{duration}
        );

        var child = std.process.Child.init(&[_][]const u8{ "sh", "-c", cmd }, self.allocator);
        _ = try child.spawnAndWait();
    }

    pub fn configure(self: *NotifyPlugin, key: []const u8, value: []const u8) !void {
        if (std.mem.eql(u8, key, "threshold")) {
            self.threshold_seconds = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, key, "enabled")) {
            self.enabled = std.mem.eql(u8, value, "true");
        }
    }
};

// Plugin entry point
pub fn create(allocator: std.mem.Allocator) !*Plugin {
    var notify = try NotifyPlugin.init(allocator);
    var plugin = try allocator.create(Plugin);
    plugin.* = Plugin{
        .impl = notify,
        .getName = @ptrCast(&NotifyPlugin.getName),
        .getVersion = @ptrCast(&NotifyPlugin.getVersion),
        .getDescription = @ptrCast(&NotifyPlugin.getDescription),
        .onHook = @ptrCast(&NotifyPlugin.onHook),
        .deinit = @ptrCast(&NotifyPlugin.deinit),
    };
    return plugin;
}
