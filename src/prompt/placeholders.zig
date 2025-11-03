const std = @import("std");
const types = @import("types.zig");

const PromptContext = types.PromptContext;
const SegmentStyle = types.SegmentStyle;

/// Placeholder expander function signature
pub const ExpanderFn = *const fn (ctx: *const PromptContext, allocator: std.mem.Allocator) anyerror![]const u8;

/// Registry of placeholder expanders
pub const PlaceholderRegistry = struct {
    expanders: std.StringHashMap(ExpanderFn),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PlaceholderRegistry {
        return .{
            .expanders = std.StringHashMap(ExpanderFn).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PlaceholderRegistry) void {
        var iter = self.expanders.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.expanders.deinit();
    }

    pub fn register(self: *PlaceholderRegistry, name: []const u8, expander: ExpanderFn) !void {
        const key = try self.allocator.dupe(u8, name);
        try self.expanders.put(key, expander);
    }

    pub fn expand(self: *PlaceholderRegistry, name: []const u8, ctx: *const PromptContext) !?[]const u8 {
        const expander = self.expanders.get(name) orelse return null;
        return try expander(ctx, self.allocator);
    }

    /// Register all standard placeholders
    pub fn registerStandard(self: *PlaceholderRegistry) !void {
        try self.register("path", expandPath);
        try self.register("git", expandGit);
        try self.register("user", expandUser);
        try self.register("host", expandHost);
        try self.register("symbol", expandSymbol);
        try self.register("time", expandTime);
        try self.register("duration", expandDuration);
        try self.register("exitcode", expandExitCode);
        try self.register("modules", expandModules);
        try self.register("pkg", expandPackage);
        try self.register("bun", expandBun);
        try self.register("zig", expandZig);
    }
};

// Standard placeholder expanders

fn expandPath(ctx: *const PromptContext, allocator: std.mem.Allocator) ![]const u8 {
    const cwd = ctx.current_dir;

    // Replace home directory with ~
    if (ctx.home_dir) |home| {
        if (std.mem.startsWith(u8, cwd, home)) {
            const rest = cwd[home.len..];
            return try std.fmt.allocPrint(allocator, "~{s}", .{rest});
        }
    }

    return try allocator.dupe(u8, cwd);
}

fn expandGit(ctx: *const PromptContext, allocator: std.mem.Allocator) ![]const u8 {
    if (ctx.git_branch) |branch| {
        var parts: std.ArrayList(u8) = .{
            .items = &[_]u8{},
            .capacity = 0,
        };
        defer parts.deinit(allocator);

        // " on 🌱 main" in bold purple
        try parts.appendSlice(allocator, " on \xF0\x9F\x8C\xB1 "); // " on 🌱 "
        try parts.appendSlice(allocator, "\x1b[1;35m"); // Bold magenta
        try parts.appendSlice(allocator, branch);
        try parts.appendSlice(allocator, "\x1b[0m"); // Reset

        // [📝] if dirty
        if (ctx.git_dirty) {
            try parts.appendSlice(allocator, " [\xF0\x9F\x93\x9D]"); // [📝]
        }

        // Ahead/behind indicators
        if (ctx.git_ahead > 0) {
            const ahead_str = try std.fmt.allocPrint(allocator, " ↑{d}", .{ctx.git_ahead});
            defer allocator.free(ahead_str);
            try parts.appendSlice(allocator, ahead_str);
        }
        if (ctx.git_behind > 0) {
            const behind_str = try std.fmt.allocPrint(allocator, " ↓{d}", .{ctx.git_behind});
            defer allocator.free(behind_str);
            try parts.appendSlice(allocator, behind_str);
        }

        return try parts.toOwnedSlice(allocator);
    }

    return try allocator.dupe(u8, "");
}

fn expandUser(ctx: *const PromptContext, allocator: std.mem.Allocator) ![]const u8 {
    return try allocator.dupe(u8, ctx.username);
}

fn expandHost(ctx: *const PromptContext, allocator: std.mem.Allocator) ![]const u8 {
    return try allocator.dupe(u8, ctx.hostname);
}

fn expandSymbol(ctx: *const PromptContext, allocator: std.mem.Allocator) ![]const u8 {
    if (ctx.is_root) {
        // Red # for root
        return try allocator.dupe(u8, "\x1b[91m#\x1b[0m");
    }

    if (ctx.last_exit_code != 0) {
        // Red > for error
        return try allocator.dupe(u8, "\x1b[91m>\x1b[0m");
    }

    // Green > for success
    return try allocator.dupe(u8, "\x1b[92m>\x1b[0m");
}

fn expandTime(ctx: *const PromptContext, allocator: std.mem.Allocator) ![]const u8 {
    const timestamp = ctx.current_time;

    // Convert to local time (simplified - just show HH:MM:SS)
    const seconds_in_day = @mod(timestamp, 86400);
    const hours = @divFloor(seconds_in_day, 3600);
    const minutes = @divFloor(@mod(seconds_in_day, 3600), 60);
    const seconds = @mod(seconds_in_day, 60);

    return try std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds });
}

fn expandDuration(ctx: *const PromptContext, allocator: std.mem.Allocator) ![]const u8 {
    if (ctx.last_duration_ms) |duration_ms| {
        if (duration_ms < 1000) {
            return try std.fmt.allocPrint(allocator, "{d}ms", .{duration_ms});
        } else if (duration_ms < 60000) {
            const seconds = @as(f64, @floatFromInt(duration_ms)) / 1000.0;
            return try std.fmt.allocPrint(allocator, "{d:.1}s", .{seconds});
        } else {
            const minutes = @divFloor(duration_ms, 60000);
            const seconds = @divFloor(@mod(duration_ms, 60000), 1000);
            return try std.fmt.allocPrint(allocator, "{d}m{d}s", .{ minutes, seconds });
        }
    }

    return try allocator.dupe(u8, "");
}

fn expandExitCode(ctx: *const PromptContext, allocator: std.mem.Allocator) ![]const u8 {
    if (ctx.last_exit_code != 0) {
        return try std.fmt.allocPrint(allocator, "[{d}]", .{ctx.last_exit_code});
    }

    return try allocator.dupe(u8, "");
}

fn expandModules(ctx: *const PromptContext, allocator: std.mem.Allocator) ![]const u8 {
    var modules: std.ArrayList(u8) = .{
        .items = &[_]u8{},
        .capacity = 0,
    };
    defer modules.deinit(allocator);

    var has_any = false;

    if (ctx.node_version) |version| {
        try modules.appendSlice(allocator, "⬢ ");
        try modules.appendSlice(allocator, version);
        has_any = true;
    }

    if (ctx.bun_version) |version| {
        if (has_any) try modules.appendSlice(allocator, " ");
        try modules.appendSlice(allocator, "🥟 ");
        try modules.appendSlice(allocator, version);
        has_any = true;
    }

    if (ctx.deno_version) |version| {
        if (has_any) try modules.appendSlice(allocator, " ");
        try modules.appendSlice(allocator, "🦕 ");
        try modules.appendSlice(allocator, version);
        has_any = true;
    }

    if (has_any) {
        return try modules.toOwnedSlice(allocator);
    }

    return try allocator.dupe(u8, "");
}

fn expandPackage(ctx: *const PromptContext, allocator: std.mem.Allocator) ![]const u8 {
    if (ctx.package_version) |version| {
        // 📦 v0.1.0 in bold orange
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        try result.appendSlice(" \xF0\x9F\x93\xA6 "); // 📦
        try result.appendSlice("\x1b[1;33m"); // Bold yellow/orange (33 is yellow, closest to orange in basic colors)
        try result.appendSlice("v");
        try result.appendSlice(version);
        try result.appendSlice("\x1b[0m"); // Reset

        return try result.toOwnedSlice();
    }

    return try allocator.dupe(u8, "");
}

fn expandBun(ctx: *const PromptContext, allocator: std.mem.Allocator) ![]const u8 {
    if (ctx.bun_version) |version| {
        // via 🐰 v1.3.1 in bold red
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        try result.appendSlice(" via \xF0\x9F\x90\xB0 "); // 🐰
        try result.appendSlice("\x1b[1;31m"); // Bold red
        try result.appendSlice("v");
        try result.appendSlice(version);
        try result.appendSlice("\x1b[0m"); // Reset

        return try result.toOwnedSlice();
    }

    return try allocator.dupe(u8, "");
}

fn expandZig(ctx: *const PromptContext, allocator: std.mem.Allocator) ![]const u8 {
    if (ctx.zig_version) |version| {
        // via ↯ v0.15.1 in bold yellow
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        try result.appendSlice(" via \xE2\x86\xAF "); // ↯
        try result.appendSlice("\x1b[1;93m"); // Bold bright yellow
        try result.appendSlice("v");
        try result.appendSlice(version);
        try result.appendSlice("\x1b[0m"); // Reset

        return try result.toOwnedSlice();
    }

    return try allocator.dupe(u8, "");
}
