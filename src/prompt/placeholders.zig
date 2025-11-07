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
        try self.register("node", expandNode);
        try self.register("bun", expandBun);
        try self.register("python", expandPython);
        try self.register("ruby", expandRuby);
        try self.register("go", expandGo);
        try self.register("rust", expandRust);
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

        // Detailed status indicators
        var has_status = false;

        // Staged files (green +)
        if (ctx.git_staged > 0) {
            const staged_str = try std.fmt.allocPrint(allocator, " \x1b[32m+{d}\x1b[0m", .{ctx.git_staged});
            defer allocator.free(staged_str);
            try parts.appendSlice(allocator, staged_str);
            has_status = true;
        }

        // Unstaged files (yellow !)
        if (ctx.git_unstaged > 0) {
            const unstaged_str = try std.fmt.allocPrint(allocator, " \x1b[33m!{d}\x1b[0m", .{ctx.git_unstaged});
            defer allocator.free(unstaged_str);
            try parts.appendSlice(allocator, unstaged_str);
            has_status = true;
        }

        // Untracked files (red ?)
        if (ctx.git_untracked > 0) {
            const untracked_str = try std.fmt.allocPrint(allocator, " \x1b[31m?{d}\x1b[0m", .{ctx.git_untracked});
            defer allocator.free(untracked_str);
            try parts.appendSlice(allocator, untracked_str);
            has_status = true;
        }

        // Stash indicator (cyan $)
        if (ctx.git_stash > 0) {
            const stash_str = try std.fmt.allocPrint(allocator, " \x1b[36m${d}\x1b[0m", .{ctx.git_stash});
            defer allocator.free(stash_str);
            try parts.appendSlice(allocator, stash_str);
        }

        // Ahead/behind indicators (white)
        if (ctx.git_ahead > 0) {
            const ahead_str = try std.fmt.allocPrint(allocator, " \x1b[37m↑{d}\x1b[0m", .{ctx.git_ahead});
            defer allocator.free(ahead_str);
            try parts.appendSlice(allocator, ahead_str);
        }
        if (ctx.git_behind > 0) {
            const behind_str = try std.fmt.allocPrint(allocator, " \x1b[37m↓{d}\x1b[0m", .{ctx.git_behind});
            defer allocator.free(behind_str);
            try parts.appendSlice(allocator, behind_str);
        }

        // If no changes, show clean indicator (green ✓)
        if (!has_status) {
            try parts.appendSlice(allocator, " \x1b[32m✓\x1b[0m");
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
        return try allocator.dupe(u8, "\x1b[91m#\x1b[0m ");
    }

    if (ctx.last_exit_code != 0) {
        // Red ❯ for error
        return try allocator.dupe(u8, "\x1b[91m\xE2\x9D\xAF\x1b[0m ");
    }

    // Green ❯ for success
    return try allocator.dupe(u8, "\x1b[92m\xE2\x9D\xAF\x1b[0m ");
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
        var result: std.ArrayList(u8) = .{
            .items = &[_]u8{},
            .capacity = 0,
        };
        defer result.deinit(allocator);

        try result.appendSlice(allocator, " \xF0\x9F\x93\xA6 "); // 📦
        try result.appendSlice(allocator, "\x1b[1;38;5;208m"); // Bold orange
        try result.appendSlice(allocator, "v");
        try result.appendSlice(allocator, version);
        try result.appendSlice(allocator, "\x1b[0m"); // Reset

        return try result.toOwnedSlice(allocator);
    }

    return try allocator.dupe(u8, "");
}

fn expandBun(ctx: *const PromptContext, allocator: std.mem.Allocator) ![]const u8 {
    if (ctx.bun_version) |version| {
        // via 🐰 v1.3.1 in bold red
        var result: std.ArrayList(u8) = .{
            .items = &[_]u8{},
            .capacity = 0,
        };
        defer result.deinit(allocator);

        try result.appendSlice(allocator, " via \xF0\x9F\x90\xB0 "); // 🐰
        try result.appendSlice(allocator, "\x1b[1;31m"); // Bold red
        try result.appendSlice(allocator, "v");
        try result.appendSlice(allocator, version);
        try result.appendSlice(allocator, "\x1b[0m"); // Reset

        return try result.toOwnedSlice(allocator);
    }

    return try allocator.dupe(u8, "");
}

fn expandNode(ctx: *const PromptContext, allocator: std.mem.Allocator) ![]const u8 {
    if (ctx.node_version) |version| {
        // via ⬢ v20.0.0 in bold green
        var result: std.ArrayList(u8) = .{
            .items = &[_]u8{},
            .capacity = 0,
        };
        defer result.deinit(allocator);

        try result.appendSlice(allocator, " via \xE2\xAC\xA2 "); // ⬢
        try result.appendSlice(allocator, "\x1b[1;32m"); // Bold green
        try result.appendSlice(allocator, "v");
        try result.appendSlice(allocator, version);
        try result.appendSlice(allocator, "\x1b[0m"); // Reset

        return try result.toOwnedSlice(allocator);
    }

    return try allocator.dupe(u8, "");
}

fn expandPython(ctx: *const PromptContext, allocator: std.mem.Allocator) ![]const u8 {
    if (ctx.python_version) |version| {
        // via 🐍 v3.12.0 in bold blue
        var result: std.ArrayList(u8) = .{
            .items = &[_]u8{},
            .capacity = 0,
        };
        defer result.deinit(allocator);

        try result.appendSlice(allocator, " via \xF0\x9F\x90\x8D "); // 🐍
        try result.appendSlice(allocator, "\x1b[1;34m"); // Bold blue
        try result.appendSlice(allocator, "v");
        try result.appendSlice(allocator, version);
        try result.appendSlice(allocator, "\x1b[0m"); // Reset

        return try result.toOwnedSlice(allocator);
    }

    return try allocator.dupe(u8, "");
}

fn expandRuby(ctx: *const PromptContext, allocator: std.mem.Allocator) ![]const u8 {
    if (ctx.ruby_version) |version| {
        // via 💎 v3.3.0 in bold red
        var result: std.ArrayList(u8) = .{
            .items = &[_]u8{},
            .capacity = 0,
        };
        defer result.deinit(allocator);

        try result.appendSlice(allocator, " via \xF0\x9F\x92\x8E "); // 💎
        try result.appendSlice(allocator, "\x1b[1;31m"); // Bold red
        try result.appendSlice(allocator, "v");
        try result.appendSlice(allocator, version);
        try result.appendSlice(allocator, "\x1b[0m"); // Reset

        return try result.toOwnedSlice(allocator);
    }

    return try allocator.dupe(u8, "");
}

fn expandGo(ctx: *const PromptContext, allocator: std.mem.Allocator) ![]const u8 {
    if (ctx.go_version) |version| {
        // via 🐹 v1.22.0 in bold cyan
        var result: std.ArrayList(u8) = .{
            .items = &[_]u8{},
            .capacity = 0,
        };
        defer result.deinit(allocator);

        try result.appendSlice(allocator, " via \xF0\x9F\x90\xB9 "); // 🐹
        try result.appendSlice(allocator, "\x1b[1;36m"); // Bold cyan
        try result.appendSlice(allocator, "v");
        try result.appendSlice(allocator, version);
        try result.appendSlice(allocator, "\x1b[0m"); // Reset

        return try result.toOwnedSlice(allocator);
    }

    return try allocator.dupe(u8, "");
}

fn expandRust(ctx: *const PromptContext, allocator: std.mem.Allocator) ![]const u8 {
    if (ctx.rust_version) |version| {
        // via 🦀 v1.75.0 in bold orange
        var result: std.ArrayList(u8) = .{
            .items = &[_]u8{},
            .capacity = 0,
        };
        defer result.deinit(allocator);

        try result.appendSlice(allocator, " via \xF0\x9F\xA6\x80 "); // 🦀
        try result.appendSlice(allocator, "\x1b[1;33m"); // Bold yellow/orange
        try result.appendSlice(allocator, "v");
        try result.appendSlice(allocator, version);
        try result.appendSlice(allocator, "\x1b[0m"); // Reset

        return try result.toOwnedSlice(allocator);
    }

    return try allocator.dupe(u8, "");
}

fn expandZig(ctx: *const PromptContext, allocator: std.mem.Allocator) ![]const u8 {
    if (ctx.zig_version) |version| {
        // via ↯ v0.15.1 in bold yellow
        var result: std.ArrayList(u8) = .{
            .items = &[_]u8{},
            .capacity = 0,
        };
        defer result.deinit(allocator);

        try result.appendSlice(allocator, " via \xE2\x86\xAF "); // ↯
        try result.appendSlice(allocator, "\x1b[1;93m"); // Bold bright yellow
        try result.appendSlice(allocator, "v");
        try result.appendSlice(allocator, version);
        try result.appendSlice(allocator, "\x1b[0m"); // Reset

        return try result.toOwnedSlice(allocator);
    }

    return try allocator.dupe(u8, "");
}
