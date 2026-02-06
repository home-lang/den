const std = @import("std");
const types = @import("types.zig");
const color_mod = @import("color.zig");
const terminal_mod = @import("terminal.zig");

const ThemeConfig = types.ThemeConfig;
const ColorRenderer = color_mod.ColorRenderer;
const TerminalCapabilities = terminal_mod.TerminalCapabilities;
const ColorSupport = color_mod.ColorSupport;

/// Color scheme (light or dark)
pub const ColorScheme = enum {
    dark,
    light,
    auto,

    pub fn detect(allocator: std.mem.Allocator) ColorScheme {
        // Check COLORFGBG environment variable (format: "foreground;background")
        if (std.process.getEnvVarOwned(allocator, "COLORFGBG") catch null) |colorfgbg| {
            defer allocator.free(colorfgbg);

            // Parse background color number
            if (std.mem.lastIndexOf(u8, colorfgbg, ";")) |sep_pos| {
                const bg_str = colorfgbg[sep_pos + 1 ..];
                const bg_num = std.fmt.parseInt(u8, bg_str, 10) catch return .dark;

                // Background colors 0-7 are dark, 8-15 are light
                return if (bg_num >= 8) .light else .dark;
            }
        }

        // Check for macOS dark mode
        if (detectMacOSDarkMode(allocator)) |is_dark| {
            return if (is_dark) .dark else .light;
        }

        // Default to dark theme
        return .dark;
    }
};

/// Theme manager
pub const ThemeManager = struct {
    allocator: std.mem.Allocator,
    theme: ThemeConfig,
    renderer: ColorRenderer,
    capabilities: TerminalCapabilities,
    color_scheme: ColorScheme,

    pub fn init(allocator: std.mem.Allocator) !ThemeManager {
        const capabilities = try TerminalCapabilities.detect(allocator);
        const color_scheme = ColorScheme.detect(allocator);

        // Choose theme based on capabilities
        const theme = if (capabilities.shouldUseColor())
            try ThemeConfig.initDefault(allocator, "default")
        else
            try ThemeConfig.initFallback(allocator);

        const renderer = ColorRenderer.init(allocator, capabilities.color_support);

        return .{
            .allocator = allocator,
            .theme = theme,
            .renderer = renderer,
            .capabilities = capabilities,
            .color_scheme = color_scheme,
        };
    }

    pub fn deinit(self: *ThemeManager) void {
        self.theme.deinit();
    }

    /// Load theme from configuration
    pub fn loadTheme(self: *ThemeManager, theme_name: []const u8) !void {
        // Free existing theme
        self.theme.deinit();

        // Load new theme (for now, just use default or fallback)
        if (std.mem.eql(u8, theme_name, "fallback")) {
            self.theme = try ThemeConfig.initFallback(self.allocator);
        } else {
            self.theme = try ThemeConfig.initDefault(self.allocator, theme_name);
        }
    }

    /// Apply color scheme adjustments
    pub fn applyColorScheme(self: *ThemeManager, scheme: ColorScheme) void {
        self.color_scheme = scheme;

        // Adjust colors based on scheme
        if (scheme == .light) {
            // Swap foreground/background for light theme
            const temp = self.theme.colors.foreground;
            self.theme.colors.foreground = self.theme.colors.background;
            self.theme.colors.background = temp;
        }
    }

    /// Get renderer
    pub fn getRenderer(self: *ThemeManager) *ColorRenderer {
        return &self.renderer;
    }

    /// Get theme config
    pub fn getTheme(self: *ThemeManager) *ThemeConfig {
        return &self.theme;
    }

    /// Check if color is supported
    pub fn supportsColor(self: *ThemeManager) bool {
        return self.capabilities.shouldUseColor();
    }

    /// Check if Unicode is supported
    pub fn supportsUnicode(self: *ThemeManager) bool {
        return self.capabilities.supports_unicode;
    }

    /// Get terminal width
    pub fn getWidth(self: *ThemeManager) usize {
        return self.capabilities.width;
    }

    /// Get terminal height
    pub fn getHeight(self: *ThemeManager) usize {
        return self.capabilities.height;
    }

    /// Enable/disable colors
    pub fn setColorsEnabled(self: *ThemeManager, enabled: bool) void {
        self.renderer.setEnabled(enabled);
    }

    /// Reload terminal capabilities
    pub fn reloadCapabilities(self: *ThemeManager) !void {
        self.capabilities = try TerminalCapabilities.detect(self.allocator);
        self.renderer.support = self.capabilities.color_support;
        self.renderer.enabled = self.capabilities.shouldUseColor();
    }

    /// Get symbol based on capability
    pub fn getSymbol(self: *ThemeManager, comptime symbol_name: []const u8) []const u8 {
        if (!self.capabilities.supports_unicode) {
            // Return ASCII fallback based on symbol name
            if (std.mem.eql(u8, symbol_name, "prompt_success")) return ">";
            if (std.mem.eql(u8, symbol_name, "prompt_error")) return "x";
            if (std.mem.eql(u8, symbol_name, "prompt_root")) return "#";
            if (std.mem.eql(u8, symbol_name, "git_branch")) return "git:";
            if (std.mem.eql(u8, symbol_name, "git_clean")) return "ok";
            if (std.mem.eql(u8, symbol_name, "git_dirty")) return "x";
            if (std.mem.eql(u8, symbol_name, "git_staged")) return "*";
            if (std.mem.eql(u8, symbol_name, "git_untracked")) return "?";
            return "";
        }

        // Return Unicode symbol
        return @field(self.theme.symbols, symbol_name);
    }
};

/// Detect macOS dark mode
fn detectMacOSDarkMode(allocator: std.mem.Allocator) ?bool {
    if (@import("builtin").os.tag != .macos) return null;

    // Try to execute: defaults read -g AppleInterfaceStyle
    var child = std.process.spawn(std.Options.debug_io, .{
        .argv = &[_][]const u8{ "defaults", "read", "-g", "AppleInterfaceStyle" },
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;

    // Read stdout
    var stdout_read_buf: [1024]u8 = undefined;
    var stdout_reader = child.stdout.?.readerStreaming(std.Options.debug_io, &stdout_read_buf);
    const stdout_data = stdout_reader.interface.allocRemaining(allocator, .limited(1024)) catch return null;
    defer allocator.free(stdout_data);

    _ = child.wait(std.Options.debug_io) catch return null;

    return std.mem.indexOf(u8, stdout_data, "Dark") != null;
}
