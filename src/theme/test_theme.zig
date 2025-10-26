const std = @import("std");
const types = @import("types.zig");
const color_mod = @import("color.zig");
const terminal_mod = @import("terminal.zig");
const manager_mod = @import("manager.zig");

const RGB = types.RGB;
const Color = types.Color;
const ThemeConfig = types.ThemeConfig;
const ColorRenderer = color_mod.ColorRenderer;
const ColorSupport = color_mod.ColorSupport;
const TerminalCapabilities = terminal_mod.TerminalCapabilities;
const ThemeManager = manager_mod.ThemeManager;
const ColorScheme = manager_mod.ColorScheme;

test "RGB - initialization" {
    const rgb = RGB.init(255, 128, 64);
    try std.testing.expectEqual(@as(u8, 255), rgb.r);
    try std.testing.expectEqual(@as(u8, 128), rgb.g);
    try std.testing.expectEqual(@as(u8, 64), rgb.b);
}

test "RGB - from hex with #" {
    const rgb = try RGB.fromHex("#FF8040");
    try std.testing.expectEqual(@as(u8, 255), rgb.r);
    try std.testing.expectEqual(@as(u8, 128), rgb.g);
    try std.testing.expectEqual(@as(u8, 64), rgb.b);
}

test "RGB - from hex without #" {
    const rgb = try RGB.fromHex("FF8040");
    try std.testing.expectEqual(@as(u8, 255), rgb.r);
    try std.testing.expectEqual(@as(u8, 128), rgb.g);
    try std.testing.expectEqual(@as(u8, 64), rgb.b);
}

test "RGB - to hex" {
    const allocator = std.testing.allocator;
    const rgb = RGB.init(255, 128, 64);
    const hex = try rgb.toHex(allocator);
    defer allocator.free(hex);

    try std.testing.expectEqualStrings("#ff8040", hex);
}

test "Color - from ANSI" {
    const color = Color.fromAnsi(42);
    try std.testing.expectEqual(@as(u8, 42), color.ansi);
}

test "Color - from RGB" {
    const color = Color.fromRgb(255, 128, 64);
    try std.testing.expectEqual(@as(u8, 255), color.rgb.r);
    try std.testing.expectEqual(@as(u8, 128), color.rgb.g);
    try std.testing.expectEqual(@as(u8, 64), color.rgb.b);
}

test "Color - from hex" {
    const color = try Color.fromHex("#FF8040");
    try std.testing.expectEqual(@as(u8, 255), color.rgb.r);
}

test "ThemeConfig - default initialization" {
    const allocator = std.testing.allocator;
    var theme = try ThemeConfig.initDefault(allocator, "test");
    defer theme.deinit();

    try std.testing.expectEqualStrings("test", theme.name);
    try std.testing.expect(theme.fonts.enable_bold);
}

test "ThemeConfig - fallback initialization" {
    const allocator = std.testing.allocator;
    var theme = try ThemeConfig.initFallback(allocator);
    defer theme.deinit();

    try std.testing.expectEqualStrings("fallback", theme.name);
    try std.testing.expect(!theme.fonts.enable_bold);
    try std.testing.expectEqualStrings(">", theme.symbols.prompt_success);
}

test "ColorRenderer - initialization" {
    const allocator = std.testing.allocator;
    const renderer = ColorRenderer.init(allocator, .truecolor);

    try std.testing.expectEqual(ColorSupport.truecolor, renderer.support);
    try std.testing.expect(renderer.enabled);
}

test "ColorRenderer - render foreground ANSI" {
    const allocator = std.testing.allocator;
    var renderer = ColorRenderer.init(allocator, .extended);

    const color = Color.fromAnsi(42);
    const result = try renderer.renderFg(color);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("\x1b[38;5;42m", result);
}

test "ColorRenderer - render foreground RGB truecolor" {
    const allocator = std.testing.allocator;
    var renderer = ColorRenderer.init(allocator, .truecolor);

    const color = Color.fromRgb(255, 128, 64);
    const result = try renderer.renderFg(color);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("\x1b[38;2;255;128;64m", result);
}

test "ColorRenderer - render background ANSI" {
    const allocator = std.testing.allocator;
    var renderer = ColorRenderer.init(allocator, .extended);

    const color = Color.fromAnsi(42);
    const result = try renderer.renderBg(color);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("\x1b[48;5;42m", result);
}

test "ColorRenderer - styled text" {
    const allocator = std.testing.allocator;
    var renderer = ColorRenderer.init(allocator, .basic);

    const color = Color.fromAnsi(10);
    const result = try renderer.styled("Hello", color);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[") != null);
}

test "ColorRenderer - bold text" {
    const allocator = std.testing.allocator;
    var renderer = ColorRenderer.init(allocator, .basic);

    const result = try renderer.bold("Hello");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("\x1b[1mHello\x1b[0m", result);
}

test "ColorRenderer - italic text" {
    const allocator = std.testing.allocator;
    var renderer = ColorRenderer.init(allocator, .basic);

    const result = try renderer.italic("Hello");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("\x1b[3mHello\x1b[0m", result);
}

test "ColorRenderer - underline text" {
    const allocator = std.testing.allocator;
    var renderer = ColorRenderer.init(allocator, .basic);

    const result = try renderer.underline("Hello");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("\x1b[4mHello\x1b[0m", result);
}

test "ColorRenderer - disabled rendering" {
    const allocator = std.testing.allocator;
    var renderer = ColorRenderer.init(allocator, .truecolor);
    renderer.setEnabled(false);

    const color = Color.fromAnsi(42);
    const result = try renderer.styled("Hello", color);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello", result);
}

test "ColorRenderer - RGB to 256" {
    const allocator = std.testing.allocator;
    var renderer = ColorRenderer.init(allocator, .extended);

    const rgb = RGB.init(255, 0, 0);
    const ansi = renderer.rgbTo256(rgb);

    // Red should map to one of the red values in 256-color palette
    try std.testing.expect(ansi >= 16);
    try std.testing.expect(ansi < 232);
}

test "stripAnsi - remove ANSI codes" {
    const allocator = std.testing.allocator;

    const text = "\x1b[31mRed\x1b[0m Text";
    const stripped = try color_mod.stripAnsi(allocator, text);
    defer allocator.free(stripped);

    try std.testing.expectEqualStrings("Red Text", stripped);
}

test "visibleWidth - calculate width without ANSI" {
    const text = "\x1b[31mHello\x1b[0m";
    const width = color_mod.visibleWidth(text);

    try std.testing.expectEqual(@as(usize, 5), width);
}

test "TerminalCapabilities - isTTY" {
    const is_tty = terminal_mod.isTTY();
    // Just ensure it doesn't crash
    _ = is_tty;
}

test "TerminalCapabilities - detectColorSupport" {
    const allocator = std.testing.allocator;
    const support = terminal_mod.detectColorSupport(allocator);

    // Should return one of the valid values
    try std.testing.expect(support == .none or
        support == .basic or
        support == .extended or
        support == .truecolor);
}

test "TerminalCapabilities - getTerminalSize" {
    const size = terminal_mod.getTerminalSize();

    // Should have some reasonable values
    try std.testing.expect(size.width > 0);
    try std.testing.expect(size.height > 0);
}

test "TerminalCapabilities - detectUnicodeSupport" {
    const allocator = std.testing.allocator;
    const supports_unicode = terminal_mod.detectUnicodeSupport(allocator);

    // Just ensure it returns a boolean
    _ = supports_unicode;
}

test "TerminalCapabilities - detect" {
    const allocator = std.testing.allocator;
    const caps = try TerminalCapabilities.detect(allocator);

    try std.testing.expect(caps.width > 0);
    try std.testing.expect(caps.height > 0);
}

test "ColorScheme - detect" {
    const allocator = std.testing.allocator;
    const scheme = ColorScheme.detect(allocator);

    try std.testing.expect(scheme == .dark or scheme == .light or scheme == .auto);
}

test "ThemeManager - initialization" {
    const allocator = std.testing.allocator;
    var manager = try ThemeManager.init(allocator);
    defer manager.deinit();

    try std.testing.expect(manager.getWidth() > 0);
}

test "ThemeManager - load theme" {
    const allocator = std.testing.allocator;
    var manager = try ThemeManager.init(allocator);
    defer manager.deinit();

    try manager.loadTheme("fallback");
    try std.testing.expectEqualStrings("fallback", manager.theme.name);
}

test "ThemeManager - get renderer" {
    const allocator = std.testing.allocator;
    var manager = try ThemeManager.init(allocator);
    defer manager.deinit();

    const renderer = manager.getRenderer();
    try std.testing.expect(renderer.allocator.ptr == allocator.ptr);
}

test "ThemeManager - supports color" {
    const allocator = std.testing.allocator;
    var manager = try ThemeManager.init(allocator);
    defer manager.deinit();

    // Just ensure it returns a boolean
    _ = manager.supportsColor();
}

test "ThemeManager - set colors enabled" {
    const allocator = std.testing.allocator;
    var manager = try ThemeManager.init(allocator);
    defer manager.deinit();

    manager.setColorsEnabled(false);
    try std.testing.expect(!manager.renderer.enabled);

    manager.setColorsEnabled(true);
    try std.testing.expect(manager.renderer.enabled);
}

test "ThemeManager - get symbol" {
    const allocator = std.testing.allocator;
    var manager = try ThemeManager.init(allocator);
    defer manager.deinit();

    const symbol = manager.getSymbol("prompt_success");
    try std.testing.expect(symbol.len > 0);
}
