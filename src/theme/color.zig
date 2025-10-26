const std = @import("std");
const types = @import("types.zig");

const Color = types.Color;
const RGB = types.RGB;

/// Terminal color support level
pub const ColorSupport = enum {
    none,      // No color support
    basic,     // 16 colors (4-bit)
    extended,  // 256 colors (8-bit)
    truecolor, // 16 million colors (24-bit RGB)

    pub fn fromColorterm(colorterm: ?[]const u8) ColorSupport {
        if (colorterm) |ct| {
            if (std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit")) {
                return .truecolor;
            }
        }
        return .extended;
    }
};

/// ANSI escape codes
pub const Ansi = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const italic = "\x1b[3m";
    pub const underline = "\x1b[4m";
    pub const blink = "\x1b[5m";
    pub const reverse = "\x1b[7m";
    pub const hidden = "\x1b[8m";
    pub const strikethrough = "\x1b[9m";

    pub const clear_line = "\x1b[2K";
    pub const clear_screen = "\x1b[2J";
    pub const cursor_home = "\x1b[H";
};

/// Color renderer with terminal capability awareness
pub const ColorRenderer = struct {
    allocator: std.mem.Allocator,
    support: ColorSupport,
    enabled: bool,

    pub fn init(allocator: std.mem.Allocator, support: ColorSupport) ColorRenderer {
        return .{
            .allocator = allocator,
            .support = support,
            .enabled = true,
        };
    }

    /// Render foreground color escape sequence
    pub fn renderFg(self: *ColorRenderer, color: Color) ![]const u8 {
        if (!self.enabled) return try self.allocator.dupe(u8, "");

        return switch (color) {
            .none => try self.allocator.dupe(u8, ""),
            .ansi => |code| switch (self.support) {
                .none => try self.allocator.dupe(u8, ""),
                .basic => try self.renderBasicFg(code),
                .extended, .truecolor => try std.fmt.allocPrint(self.allocator, "\x1b[38;5;{d}m", .{code}),
            },
            .rgb => |rgb| switch (self.support) {
                .none => try self.allocator.dupe(u8, ""),
                .basic => try self.renderBasicFg(self.rgbToAnsi(rgb)),
                .extended => try std.fmt.allocPrint(self.allocator, "\x1b[38;5;{d}m", .{self.rgbTo256(rgb)}),
                .truecolor => try std.fmt.allocPrint(self.allocator, "\x1b[38;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b }),
            },
        };
    }

    /// Render background color escape sequence
    pub fn renderBg(self: *ColorRenderer, color: Color) ![]const u8 {
        if (!self.enabled) return try self.allocator.dupe(u8, "");

        return switch (color) {
            .none => try self.allocator.dupe(u8, ""),
            .ansi => |code| switch (self.support) {
                .none => try self.allocator.dupe(u8, ""),
                .basic => try self.renderBasicBg(code),
                .extended, .truecolor => try std.fmt.allocPrint(self.allocator, "\x1b[48;5;{d}m", .{code}),
            },
            .rgb => |rgb| switch (self.support) {
                .none => try self.allocator.dupe(u8, ""),
                .basic => try self.renderBasicBg(self.rgbToAnsi(rgb)),
                .extended => try std.fmt.allocPrint(self.allocator, "\x1b[48;5;{d}m", .{self.rgbTo256(rgb)}),
                .truecolor => try std.fmt.allocPrint(self.allocator, "\x1b[48;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b }),
            },
        };
    }

    /// Render styled text with foreground color
    pub fn styled(self: *ColorRenderer, text: []const u8, color: Color) ![]const u8 {
        if (!self.enabled) return try self.allocator.dupe(u8, text);

        const fg = try self.renderFg(color);
        defer self.allocator.free(fg);

        return try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ fg, text, Ansi.reset });
    }

    /// Render bold text
    pub fn bold(self: *ColorRenderer, text: []const u8) ![]const u8 {
        if (!self.enabled) return try self.allocator.dupe(u8, text);
        return try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ Ansi.bold, text, Ansi.reset });
    }

    /// Render dim text
    pub fn dim(self: *ColorRenderer, text: []const u8) ![]const u8 {
        if (!self.enabled) return try self.allocator.dupe(u8, text);
        return try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ Ansi.dim, text, Ansi.reset });
    }

    /// Render italic text
    pub fn italic(self: *ColorRenderer, text: []const u8) ![]const u8 {
        if (!self.enabled) return try self.allocator.dupe(u8, text);
        return try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ Ansi.italic, text, Ansi.reset });
    }

    /// Render underlined text
    pub fn underline(self: *ColorRenderer, text: []const u8) ![]const u8 {
        if (!self.enabled) return try self.allocator.dupe(u8, text);
        return try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ Ansi.underline, text, Ansi.reset });
    }

    /// Enable/disable color output
    pub fn setEnabled(self: *ColorRenderer, enabled: bool) void {
        self.enabled = enabled;
    }

    /// Convert RGB to 256-color ANSI code (8-bit)
    pub fn rgbTo256(self: *ColorRenderer, rgb: RGB) u8 {
        _ = self;

        // Use the 216-color cube (16-231)
        const r = @as(u8, @intCast(@divFloor(@as(u16, rgb.r) * 6, 256)));
        const g = @as(u8, @intCast(@divFloor(@as(u16, rgb.g) * 6, 256)));
        const b = @as(u8, @intCast(@divFloor(@as(u16, rgb.b) * 6, 256)));

        return 16 + (36 * r) + (6 * g) + b;
    }

    /// Convert RGB to basic 16-color ANSI code
    fn rgbToAnsi(self: *ColorRenderer, rgb: RGB) u8 {
        _ = self;

        // Calculate brightness
        const brightness = (@as(u16, rgb.r) + @as(u16, rgb.g) + @as(u16, rgb.b)) / 3;

        // Determine which component is dominant
        const r_dominant = rgb.r > rgb.g and rgb.r > rgb.b;
        const g_dominant = rgb.g > rgb.r and rgb.g > rgb.b;
        const b_dominant = rgb.b > rgb.r and rgb.b > rgb.g;

        // Map to basic colors
        if (brightness < 64) return 0; // Black
        if (brightness > 192) return 15; // White

        if (r_dominant) return if (brightness > 128) 9 else 1; // Red
        if (g_dominant) return if (brightness > 128) 10 else 2; // Green
        if (b_dominant) return if (brightness > 128) 12 else 4; // Blue

        // Cyan, Magenta, Yellow for mixed colors
        if (rgb.r > 128 and rgb.g > 128) return 11; // Yellow
        if (rgb.r > 128 and rgb.b > 128) return 13; // Magenta
        if (rgb.g > 128 and rgb.b > 128) return 14; // Cyan

        return 7; // White (fallback)
    }

    /// Render basic foreground color (16 colors)
    fn renderBasicFg(self: *ColorRenderer, code: u8) ![]const u8 {
        const ansi_code = if (code >= 8) 90 + (code - 8) else 30 + code;
        return try std.fmt.allocPrint(self.allocator, "\x1b[{d}m", .{ansi_code});
    }

    /// Render basic background color (16 colors)
    fn renderBasicBg(self: *ColorRenderer, code: u8) ![]const u8 {
        const ansi_code = if (code >= 8) 100 + (code - 8) else 40 + code;
        return try std.fmt.allocPrint(self.allocator, "\x1b[{d}m", .{ansi_code});
    }
};

/// Strip ANSI escape codes from text
pub fn stripAnsi(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .{
        .items = &[_]u8{},
        .capacity = 0,
    };
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\x1b' and i + 1 < text.len and text[i + 1] == '[') {
            // Skip ANSI escape sequence
            i += 2;
            while (i < text.len and text[i] != 'm') : (i += 1) {}
            i += 1;
        } else {
            try result.append(allocator, text[i]);
            i += 1;
        }
    }

    const slice = try result.toOwnedSlice(allocator);
    return slice;
}

/// Get visible width of text (without ANSI codes)
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
            width += 1;
            i += 1;
        }
    }

    return width;
}
