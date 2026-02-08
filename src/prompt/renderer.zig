const std = @import("std");
const types = @import("types.zig");
const placeholders_mod = @import("placeholders.zig");

const PromptContext = types.PromptContext;
const PromptTemplate = types.PromptTemplate;
const Segment = types.Segment;
const Alignment = types.Alignment;
const SegmentStyle = types.SegmentStyle;
const PlaceholderRegistry = placeholders_mod.PlaceholderRegistry;

/// Prompt renderer
pub const PromptRenderer = struct {
    allocator: std.mem.Allocator,
    registry: PlaceholderRegistry,
    template: PromptTemplate,
    simple_mode: bool,
    transient_mode: bool,

    pub fn init(allocator: std.mem.Allocator, template: PromptTemplate) !PromptRenderer {
        var registry = PlaceholderRegistry.init(allocator);
        try registry.registerStandard();

        return .{
            .allocator = allocator,
            .registry = registry,
            .template = template,
            .simple_mode = false,
            .transient_mode = false,
        };
    }

    pub fn deinit(self: *PromptRenderer) void {
        self.registry.deinit();
    }

    /// Set simple mode (for non-TTY or NO_COLOR)
    pub fn setSimpleMode(self: *PromptRenderer, enabled: bool) void {
        self.simple_mode = enabled;
    }

    /// Set transient mode
    pub fn setTransientMode(self: *PromptRenderer, enabled: bool) void {
        self.transient_mode = enabled;
    }

    /// Render a minimal transient prompt (used to replace the full prompt after command execution)
    /// If a transient_format is configured, it renders that template; otherwise returns a simple "❯ ".
    pub fn renderTransient(self: *PromptRenderer, ctx: *const PromptContext) ![]const u8 {
        if (self.template.transient_format) |transient_fmt| {
            return try self.expandTemplate(transient_fmt, ctx);
        }
        // Default minimal transient prompt
        return try self.allocator.dupe(u8, "\x1b[32m❯\x1b[0m ");
    }

    /// Render the complete prompt
    pub fn render(self: *PromptRenderer, ctx: *const PromptContext, terminal_width: usize) ![]const u8 {
        // Choose format based on mode
        const format = if (self.transient_mode and self.template.transient_format != null)
            self.template.transient_format.?
        else
            self.template.left_format;

        // Parse and expand left prompt
        const left = try self.expandTemplate(format, ctx);
        defer self.allocator.free(left);

        // If we have a right prompt and enough space, render it
        if (self.template.right_format) |right_format| {
            const right = try self.expandTemplate(right_format, ctx);
            defer self.allocator.free(right);

            return try self.renderWithRight(left, right, terminal_width);
        }

        return try self.allocator.dupe(u8, left);
    }

    /// Expand template string with placeholders
    fn expandTemplate(self: *PromptRenderer, template_str: []const u8, ctx: *const PromptContext) ![]const u8 {
        var result: std.array_list.Managed(u8) = .{
            .allocator = self.allocator,
            .items = &[_]u8{},
            .capacity = 0,
        };
        defer result.deinit();

        var i: usize = 0;
        while (i < template_str.len) {
            if (template_str[i] == '{') {
                // Find closing brace
                const start = i + 1;
                var end = start;
                while (end < template_str.len and template_str[end] != '}') : (end += 1) {}

                if (end < template_str.len) {
                    const placeholder_name = template_str[start..end];

                    // Expand placeholder
                    if (try self.registry.expand(placeholder_name, ctx)) |value| {
                        defer self.allocator.free(value);
                        try result.appendSlice(value);
                    } else if (ctx.getCustom(placeholder_name)) |custom_value| {
                        try result.appendSlice(custom_value);
                    }

                    i = end + 1;
                } else {
                    // No closing brace, treat as literal
                    try result.append('{');
                    i += 1;
                }
            } else {
                try result.append(template_str[i]);
                i += 1;
            }
        }

        return try result.toOwnedSlice();
    }

    /// Render left and right prompts with proper spacing
    fn renderWithRight(self: *PromptRenderer, left: []const u8, right: []const u8, terminal_width: usize) ![]const u8 {
        // Calculate visible widths (without ANSI codes)
        const left_width = visibleWidth(left);
        const right_width = visibleWidth(right);

        // Calculate spacing needed
        const total_width = left_width + right_width;

        if (total_width >= terminal_width) {
            // Not enough space, just return left
            return try self.allocator.dupe(u8, left);
        }

        const spaces_needed = terminal_width - total_width;

        // Build result with spacing
        var result: std.array_list.Managed(u8) = .{
            .allocator = self.allocator,
            .items = &[_]u8{},
            .capacity = 0,
        };
        defer result.deinit();

        try result.appendSlice(left);

        // Add spaces
        var i: usize = 0;
        while (i < spaces_needed) : (i += 1) {
            try result.append(' ');
        }

        try result.appendSlice(right);

        return try result.toOwnedSlice();
    }

    /// Register a custom placeholder
    pub fn registerPlaceholder(self: *PromptRenderer, name: []const u8, expander: placeholders_mod.ExpanderFn) !void {
        try self.registry.register(name, expander);
    }
};

/// Calculate visible width of string (without ANSI escape codes)
pub fn visibleWidth(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;

    while (i < text.len) {
        if (text[i] == '\x1b' and i + 1 < text.len and text[i + 1] == '[') {
            // Skip ANSI escape sequence
            i += 2;
            while (i < text.len and text[i] != 'm') : (i += 1) {}
            i += 1;
        } else {
            // Count visible character
            width += 1;
            i += 1;
        }
    }

    return width;
}

/// Parse prompt segments from rendered text
pub fn parseSegments(allocator: std.mem.Allocator, text: []const u8) ![]Segment {
    var segments = std.array_list.Managed(Segment).init(allocator);
    defer segments.deinit();

    // For now, treat the entire text as a single left-aligned segment
    const style = SegmentStyle.initDefault();
    const segment = try Segment.init(allocator, text, style, .left);
    try segments.append(segment);

    return try segments.toOwnedSlice();
}
