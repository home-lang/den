const std = @import("std");
const color_mod = @import("color.zig");

const ColorSupport = color_mod.ColorSupport;

/// Terminal capabilities
pub const TerminalCapabilities = struct {
    is_tty: bool,
    color_support: ColorSupport,
    width: usize,
    height: usize,
    supports_unicode: bool,
    supports_emoji: bool,

    pub fn detect(allocator: std.mem.Allocator) !TerminalCapabilities {
        const is_tty = isTTY();
        const color_support = detectColorSupport(allocator);
        const size = getTerminalSize();
        const supports_unicode = detectUnicodeSupport(allocator);

        return .{
            .is_tty = is_tty,
            .color_support = color_support,
            .width = size.width,
            .height = size.height,
            .supports_unicode = supports_unicode,
            .supports_emoji = supports_unicode and color_support != .none,
        };
    }

    pub fn shouldUseColor(self: *const TerminalCapabilities) bool {
        return self.is_tty and self.color_support != .none;
    }

    pub fn shouldUseFancySymbols(self: *const TerminalCapabilities) bool {
        return self.is_tty and self.supports_unicode;
    }
};

/// Terminal size
pub const TerminalSize = struct {
    width: usize,
    height: usize,
};

/// Check if stdout is a TTY
pub fn isTTY() bool {
    const posix = std.posix;
    return posix.isatty(posix.STDOUT_FILENO);
}

/// Detect color support level
pub fn detectColorSupport(allocator: std.mem.Allocator) ColorSupport {

    // Check NO_COLOR environment variable
    if (std.process.getEnvVarOwned(allocator, "NO_COLOR") catch null) |no_color| {
        defer allocator.free(no_color);
        if (no_color.len > 0) return .none;
    }

    // Check COLORTERM environment variable
    if (std.process.getEnvVarOwned(allocator, "COLORTERM") catch null) |colorterm| {
        defer allocator.free(colorterm);
        return ColorSupport.fromColorterm(colorterm);
    }

    // Check TERM environment variable
    if (std.process.getEnvVarOwned(allocator, "TERM") catch null) |term| {
        defer allocator.free(term);

        if (std.mem.indexOf(u8, term, "256color") != null) {
            return .extended;
        }

        if (std.mem.indexOf(u8, term, "color") != null) {
            return .basic;
        }

        if (std.mem.eql(u8, term, "dumb")) {
            return .none;
        }
    }

    // Default to basic color support
    return .basic;
}

/// Get terminal size
pub fn getTerminalSize() TerminalSize {
    // Try to get from environment first
    if (getTerminalSizeFromEnv()) |size| {
        return size;
    }

    // Try ioctl on Unix systems
    if (@import("builtin").os.tag != .windows) {
        if (getTerminalSizeUnix()) |size| {
            return size;
        }
    }

    // Fallback to default size
    return .{ .width = 80, .height = 24 };
}

/// Get terminal size from environment variables
fn getTerminalSizeFromEnv() ?TerminalSize {
    const allocator = std.heap.page_allocator;

    const columns = std.process.getEnvVarOwned(allocator, "COLUMNS") catch return null;
    defer allocator.free(columns);

    const lines = std.process.getEnvVarOwned(allocator, "LINES") catch return null;
    defer allocator.free(lines);

    const width = std.fmt.parseInt(usize, columns, 10) catch return null;
    const height = std.fmt.parseInt(usize, lines, 10) catch return null;

    return .{ .width = width, .height = height };
}

/// Get terminal size using ioctl (Unix)
fn getTerminalSizeUnix() ?TerminalSize {
    if (@import("builtin").os.tag == .windows) return null;

    const c = @cImport({
        @cInclude("sys/ioctl.h");
        @cInclude("unistd.h");
    });

    var ws: c.winsize = undefined;

    if (c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &ws) == -1) {
        return null;
    }

    return .{
        .width = @as(usize, @intCast(ws.ws_col)),
        .height = @as(usize, @intCast(ws.ws_row)),
    };
}

/// Detect Unicode support
pub fn detectUnicodeSupport(allocator: std.mem.Allocator) bool {
    // Check LANG environment variable
    if (std.process.getEnvVarOwned(allocator, "LANG") catch null) |lang| {
        defer allocator.free(lang);

        // Check for UTF-8 encoding
        if (std.mem.indexOf(u8, lang, "UTF-8") != null or
            std.mem.indexOf(u8, lang, "utf8") != null)
        {
            return true;
        }
    }

    // Check LC_ALL environment variable
    if (std.process.getEnvVarOwned(allocator, "LC_ALL") catch null) |lc_all| {
        defer allocator.free(lc_all);

        if (std.mem.indexOf(u8, lc_all, "UTF-8") != null or
            std.mem.indexOf(u8, lc_all, "utf8") != null)
        {
            return true;
        }
    }

    // Check TERM environment variable
    if (std.process.getEnvVarOwned(allocator, "TERM") catch null) |term| {
        defer allocator.free(term);

        // Some modern terminals
        if (std.mem.eql(u8, term, "xterm-256color") or
            std.mem.eql(u8, term, "screen-256color") or
            std.mem.indexOf(u8, term, "kitty") != null or
            std.mem.indexOf(u8, term, "alacritty") != null)
        {
            return true;
        }
    }

    // Default to false for safety
    return false;
}

/// Detect terminal emulator
pub fn detectTerminalEmulator(allocator: std.mem.Allocator) ?[]const u8 {
    // Check common terminal-specific environment variables
    const vars = [_][]const u8{
        "TERM_PROGRAM",     // macOS Terminal, iTerm2
        "KITTY_WINDOW_ID",  // Kitty
        "ALACRITTY_SOCKET", // Alacritty
        "WEZTERM_EXECUTABLE", // WezTerm
    };

    for (vars) |var_name| {
        if (std.process.getEnvVarOwned(allocator, var_name) catch null) |value| {
            return value;
        }
    }

    return null;
}

/// Detect if running in tmux or screen
pub fn isMultiplexer(allocator: std.mem.Allocator) bool {
    if (std.process.getEnvVarOwned(allocator, "TMUX") catch null) |tmux| {
        defer allocator.free(tmux);
        return true;
    }

    if (std.process.getEnvVarOwned(allocator, "TERM") catch null) |term| {
        defer allocator.free(term);
        return std.mem.startsWith(u8, term, "screen");
    }

    return false;
}
