const std = @import("std");

/// ANSI escape sequence utilities for terminal control
pub const Ansi = struct {
    /// Clear the entire screen
    pub const clear_screen = "\x1B[2J\x1B[H";

    /// Clear from cursor to end of line
    pub const clear_to_eol = "\x1B[K";

    /// Clear from cursor to end of screen
    pub const clear_to_eos = "\x1B[J";

    /// Move cursor up
    pub fn cursorUp(n: usize) [32]u8 {
        var buf: [32]u8 = undefined;
        return std.fmt.bufPrint(&buf, "\x1B[{d}A", .{n}) catch unreachable;
    }

    /// Move cursor down
    pub fn cursorDown(n: usize) [32]u8 {
        var buf: [32]u8 = undefined;
        return std.fmt.bufPrint(&buf, "\x1B[{d}B", .{n}) catch unreachable;
    }

    /// Move cursor forward (right)
    pub fn cursorForward(n: usize) [32]u8 {
        var buf: [32]u8 = undefined;
        return std.fmt.bufPrint(&buf, "\x1B[{d}C", .{n}) catch unreachable;
    }

    /// Move cursor backward (left)
    pub fn cursorBackward(n: usize) [32]u8 {
        var buf: [32]u8 = undefined;
        return std.fmt.bufPrint(&buf, "\x1B[{d}D", .{n}) catch unreachable;
    }

    /// Save cursor position
    pub const save_cursor = "\x1B[s";

    /// Restore cursor position
    pub const restore_cursor = "\x1B[u";

    /// Hide cursor
    pub const hide_cursor = "\x1B[?25l";

    /// Show cursor
    pub const show_cursor = "\x1B[?25h";

    /// Reset all text attributes
    pub const reset = "\x1B[0m";

    /// Text styles
    pub const bold = "\x1B[1m";
    pub const dim = "\x1B[2m";
    pub const italic = "\x1B[3m";
    pub const underline = "\x1B[4m";
    pub const blink = "\x1B[5m";
    pub const reverse = "\x1B[7m";
    pub const hidden = "\x1B[8m";
    pub const strikethrough = "\x1B[9m";

    /// Basic colors (foreground)
    pub const black = "\x1B[30m";
    pub const red = "\x1B[31m";
    pub const green = "\x1B[32m";
    pub const yellow = "\x1B[33m";
    pub const blue = "\x1B[34m";
    pub const magenta = "\x1B[35m";
    pub const cyan = "\x1B[36m";
    pub const white = "\x1B[37m";

    /// Bright colors (foreground)
    pub const bright_black = "\x1B[90m";
    pub const bright_red = "\x1B[91m";
    pub const bright_green = "\x1B[92m";
    pub const bright_yellow = "\x1B[93m";
    pub const bright_blue = "\x1B[94m";
    pub const bright_magenta = "\x1B[95m";
    pub const bright_cyan = "\x1B[96m";
    pub const bright_white = "\x1B[97m";

    /// Background colors
    pub const bg_black = "\x1B[40m";
    pub const bg_red = "\x1B[41m";
    pub const bg_green = "\x1B[42m";
    pub const bg_yellow = "\x1B[43m";
    pub const bg_blue = "\x1B[44m";
    pub const bg_magenta = "\x1B[45m";
    pub const bg_cyan = "\x1B[46m";
    pub const bg_white = "\x1B[47m";

    /// Create RGB color (24-bit true color)
    pub fn rgb(r: u8, g: u8, b: u8) ![32]u8 {
        var buf: [32]u8 = undefined;
        const result = try std.fmt.bufPrint(&buf, "\x1B[38;2;{d};{d};{d}m", .{ r, g, b });
        var output: [32]u8 = undefined;
        @memcpy(output[0..result.len], result);
        return output;
    }

    /// Create RGB background color
    pub fn rgbBg(r: u8, g: u8, b: u8) ![32]u8 {
        var buf: [32]u8 = undefined;
        const result = try std.fmt.bufPrint(&buf, "\x1B[48;2;{d};{d};{d}m", .{ r, g, b });
        var output: [32]u8 = undefined;
        @memcpy(output[0..result.len], result);
        return output;
    }

    /// Parse hex color to RGB
    pub fn parseHexColor(hex: []const u8) ![3]u8 {
        if (hex.len != 7 or hex[0] != '#') {
            return error.InvalidHexColor;
        }

        const r = try std.fmt.parseInt(u8, hex[1..3], 16);
        const g = try std.fmt.parseInt(u8, hex[3..5], 16);
        const b = try std.fmt.parseInt(u8, hex[5..7], 16);

        return [3]u8{ r, g, b };
    }
};

test "ANSI color parsing" {
    const rgb = try Ansi.parseHexColor("#00D9FF");
    try std.testing.expectEqual(@as(u8, 0x00), rgb[0]);
    try std.testing.expectEqual(@as(u8, 0xD9), rgb[1]);
    try std.testing.expectEqual(@as(u8, 0xFF), rgb[2]);
}
