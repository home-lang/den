const std = @import("std");

/// Prompt segment alignment
pub const Alignment = enum {
    left,
    right,
};

/// Prompt segment style
pub const SegmentStyle = struct {
    foreground: ?[]const u8, // Color name or hex
    background: ?[]const u8,
    bold: bool,
    italic: bool,
    underline: bool,

    pub fn initDefault() SegmentStyle {
        return .{
            .foreground = null,
            .background = null,
            .bold = false,
            .italic = false,
            .underline = false,
        };
    }
};

/// Prompt segment
pub const Segment = struct {
    content: []const u8,
    style: SegmentStyle,
    alignment: Alignment,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, content: []const u8, style: SegmentStyle, alignment: Alignment) !Segment {
        return .{
            .content = try allocator.dupe(u8, content),
            .style = style,
            .alignment = alignment,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Segment) void {
        self.allocator.free(self.content);
    }
};

/// Prompt context data
pub const PromptContext = struct {
    // Path info
    current_dir: []const u8,
    home_dir: ?[]const u8,

    // Git info
    git_branch: ?[]const u8,
    git_dirty: bool,
    git_ahead: usize,
    git_behind: usize,

    // User info
    username: []const u8,
    hostname: []const u8,
    is_root: bool,

    // Command info
    last_exit_code: i32,
    last_duration_ms: ?u64,

    // Runtime info
    node_version: ?[]const u8,
    bun_version: ?[]const u8,
    deno_version: ?[]const u8,

    // Time
    current_time: i64,

    // Custom data
    custom_data: std.StringHashMap([]const u8),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PromptContext {
        return .{
            .current_dir = "",
            .home_dir = null,
            .git_branch = null,
            .git_dirty = false,
            .git_ahead = 0,
            .git_behind = 0,
            .username = "",
            .hostname = "",
            .is_root = false,
            .last_exit_code = 0,
            .last_duration_ms = null,
            .node_version = null,
            .bun_version = null,
            .deno_version = null,
            .current_time = std.time.timestamp(),
            .custom_data = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PromptContext) void {
        var iter = self.custom_data.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.custom_data.deinit();
    }

    pub fn setCustom(self: *PromptContext, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.custom_data.put(key_copy, value_copy);
    }

    pub fn getCustom(self: *const PromptContext, key: []const u8) ?[]const u8 {
        return self.custom_data.get(key);
    }
};

/// Prompt template configuration
pub const PromptTemplate = struct {
    left_format: []const u8,
    right_format: ?[]const u8,
    transient_enabled: bool,
    transient_format: ?[]const u8,

    pub fn initDefault(allocator: std.mem.Allocator) !PromptTemplate {
        return .{
            .left_format = try allocator.dupe(u8, "{user}@{host} {path} {git}{symbol} "),
            .right_format = null,
            .transient_enabled = false,
            .transient_format = null,
        };
    }

    pub fn initSimple(allocator: std.mem.Allocator) !PromptTemplate {
        return .{
            .left_format = try allocator.dupe(u8, "{symbol} "),
            .right_format = null,
            .transient_enabled = false,
            .transient_format = null,
        };
    }

    pub fn deinit(self: *PromptTemplate, allocator: std.mem.Allocator) void {
        allocator.free(self.left_format);
        if (self.right_format) |rf| allocator.free(rf);
        if (self.transient_format) |tf| allocator.free(tf);
    }
};
