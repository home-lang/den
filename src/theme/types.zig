const std = @import("std");

/// RGB color representation
pub const RGB = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn init(r: u8, g: u8, b: u8) RGB {
        return .{ .r = r, .g = g, .b = b };
    }

    pub fn fromHex(hex: []const u8) !RGB {
        if (hex.len != 6 and hex.len != 7) return error.InvalidHexColor;

        const start: usize = if (hex[0] == '#') 1 else 0;
        const r = try std.fmt.parseInt(u8, hex[start .. start + 2], 16);
        const g = try std.fmt.parseInt(u8, hex[start + 2 .. start + 4], 16);
        const b = try std.fmt.parseInt(u8, hex[start + 4 .. start + 6], 16);

        return RGB.init(r, g, b);
    }

    pub fn toHex(self: RGB, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "#{x:0>2}{x:0>2}{x:0>2}", .{ self.r, self.g, self.b });
    }
};

/// Color definition with multiple formats
pub const Color = union(enum) {
    none: void,
    ansi: u8, // 0-255 (8-bit color)
    rgb: RGB, // 24-bit RGB

    pub fn fromAnsi(code: u8) Color {
        return .{ .ansi = code };
    }

    pub fn fromRgb(r: u8, g: u8, b: u8) Color {
        return .{ .rgb = RGB.init(r, g, b) };
    }

    pub fn fromHex(hex: []const u8) !Color {
        const rgb = try RGB.fromHex(hex);
        return .{ .rgb = rgb };
    }
};

/// Color configuration for different UI elements
pub const ColorConfig = struct {
    // Basic colors
    foreground: Color,
    background: Color,

    // Status colors
    success: Color,
    err: Color,
    warning: Color,
    info: Color,

    // Prompt colors
    prompt_symbol: Color,
    prompt_path: Color,
    prompt_git: Color,

    // Syntax colors
    command: Color,
    argument: Color,
    option: Color,
    string: Color,
    number: Color,
    operator: Color,
    comment: Color,

    allocator: std.mem.Allocator,

    pub fn initDefault(allocator: std.mem.Allocator) ColorConfig {
        return .{
            .foreground = Color.fromAnsi(15), // White
            .background = Color.fromAnsi(0),  // Black
            .success = Color.fromAnsi(10),    // Bright green
            .err = Color.fromAnsi(9),         // Bright red
            .warning = Color.fromAnsi(11),    // Bright yellow
            .info = Color.fromAnsi(14),       // Bright cyan
            .prompt_symbol = Color.fromAnsi(12), // Bright blue
            .prompt_path = Color.fromAnsi(14),   // Bright cyan
            .prompt_git = Color.fromAnsi(11),    // Bright yellow
            .command = Color.fromAnsi(13),    // Bright magenta
            .argument = Color.fromAnsi(15),   // White
            .option = Color.fromAnsi(10),     // Bright green
            .string = Color.fromAnsi(11),     // Bright yellow
            .number = Color.fromAnsi(13),     // Bright magenta
            .operator = Color.fromAnsi(9),    // Bright red
            .comment = Color.fromAnsi(8),     // Bright black (gray)
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ColorConfig) void {
        _ = self;
        // No allocations in default config
    }
};

/// Symbol configuration for UI elements
pub const SymbolConfig = struct {
    // Prompt symbols
    prompt_success: []const u8,
    prompt_error: []const u8,
    prompt_root: []const u8,

    // Git symbols
    git_branch: []const u8,
    git_clean: []const u8,
    git_dirty: []const u8,
    git_staged: []const u8,
    git_untracked: []const u8,

    // Separators
    path_separator: []const u8,
    line_separator: []const u8,

    allocator: std.mem.Allocator,

    pub fn initDefault(allocator: std.mem.Allocator) SymbolConfig {
        return .{
            .prompt_success = "❯",
            .prompt_error = "✗",
            .prompt_root = "#",
            .git_branch = "",
            .git_clean = "✓",
            .git_dirty = "✗",
            .git_staged = "●",
            .git_untracked = "?",
            .path_separator = "/",
            .line_separator = "─",
            .allocator = allocator,
        };
    }

    pub fn initFallback(allocator: std.mem.Allocator) SymbolConfig {
        return .{
            .prompt_success = ">",
            .prompt_error = "x",
            .prompt_root = "#",
            .git_branch = "git:",
            .git_clean = "ok",
            .git_dirty = "x",
            .git_staged = "*",
            .git_untracked = "?",
            .path_separator = "/",
            .line_separator = "-",
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SymbolConfig) void {
        _ = self;
        // No allocations in default configs
    }
};

/// Font configuration
pub const FontConfig = struct {
    enable_bold: bool,
    enable_italic: bool,
    enable_underline: bool,
    enable_dim: bool,

    pub fn initDefault() FontConfig {
        return .{
            .enable_bold = true,
            .enable_italic = true,
            .enable_underline = true,
            .enable_dim = true,
        };
    }

    pub fn initFallback() FontConfig {
        return .{
            .enable_bold = false,
            .enable_italic = false,
            .enable_underline = false,
            .enable_dim = false,
        };
    }
};

/// Git status configuration
pub const GitStatusConfig = struct {
    show_branch: bool,
    show_status: bool,
    show_ahead_behind: bool,

    pub fn initDefault() GitStatusConfig {
        return .{
            .show_branch = true,
            .show_status = true,
            .show_ahead_behind = true,
        };
    }
};

/// Complete theme configuration
pub const ThemeConfig = struct {
    name: []const u8,
    colors: ColorConfig,
    symbols: SymbolConfig,
    fonts: FontConfig,
    git: GitStatusConfig,
    allocator: std.mem.Allocator,

    pub fn initDefault(allocator: std.mem.Allocator, name: []const u8) !ThemeConfig {
        return .{
            .name = try allocator.dupe(u8, name),
            .colors = ColorConfig.initDefault(allocator),
            .symbols = SymbolConfig.initDefault(allocator),
            .fonts = FontConfig.initDefault(),
            .git = GitStatusConfig.initDefault(),
            .allocator = allocator,
        };
    }

    pub fn initFallback(allocator: std.mem.Allocator) !ThemeConfig {
        return .{
            .name = try allocator.dupe(u8, "fallback"),
            .colors = ColorConfig.initDefault(allocator),
            .symbols = SymbolConfig.initFallback(allocator),
            .fonts = FontConfig.initFallback(),
            .git = GitStatusConfig.initDefault(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ThemeConfig) void {
        self.allocator.free(self.name);
        self.colors.deinit();
        self.symbols.deinit();
    }
};
