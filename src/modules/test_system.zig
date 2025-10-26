const std = @import("std");
const types = @import("types.zig");
const system = @import("system.zig");
const custom_mod = @import("custom.zig");

const ModuleInfo = types.ModuleInfo;
const ModuleConfig = types.ModuleConfig;
const CustomModule = custom_mod.CustomModule;
const FormatString = custom_mod.FormatString;

test "BatteryInfo - structure" {
    const battery = types.BatteryInfo{
        .percentage = 85,
        .is_charging = false,
    };

    try std.testing.expectEqual(@as(u8, 85), battery.percentage);
    try std.testing.expect(!battery.is_charging);
}

test "MemoryInfo - structure" {
    const memory = types.MemoryInfo{
        .used_bytes = 4 * 1024 * 1024 * 1024, // 4GB
        .total_bytes = 16 * 1024 * 1024 * 1024, // 16GB
        .percentage = 25,
    };

    try std.testing.expectEqual(@as(u8, 25), memory.percentage);
}

test "system - detectOS returns info" {
    const allocator = std.testing.allocator;

    const info = try system.detectOS(allocator, "/tmp");
    try std.testing.expect(info != null);
    defer if (info) |*i| i.deinit(allocator);

    if (info) |i| {
        try std.testing.expectEqualStrings("os", i.name);
        try std.testing.expect(i.version != null);
        try std.testing.expect(i.icon != null);
    }
}

test "system - detectTime returns formatted time" {
    const allocator = std.testing.allocator;

    const info = try system.detectTime(allocator, "/tmp");
    try std.testing.expect(info != null);
    defer if (info) |*i| i.deinit(allocator);

    if (info) |i| {
        try std.testing.expectEqualStrings("time", i.name);
        try std.testing.expect(i.version != null);
        try std.testing.expectEqualStrings("🕐", i.icon.?);

        // Version should be HH:MM:SS format
        const version = i.version.?;
        try std.testing.expect(version.len >= 8); // At least "00:00:00"
        try std.testing.expect(std.mem.indexOf(u8, version, ":") != null);
    }
}

test "CustomModule - initialization" {
    const allocator = std.testing.allocator;

    var module = try CustomModule.init(allocator, "test", "echo hello");
    defer module.deinit();

    try std.testing.expectEqualStrings("test", module.name);
    try std.testing.expectEqualStrings("echo hello", module.command);
    try std.testing.expect(module.format == null);
}

test "CustomModule - shouldShow with no condition" {
    const allocator = std.testing.allocator;

    var module = try CustomModule.init(allocator, "test", "echo hello");
    defer module.deinit();

    try std.testing.expect(module.shouldShow("/tmp"));
}

test "FormatString - render with symbol" {
    const allocator = std.testing.allocator;

    const format = try FormatString.init(allocator, "via {symbol} {version}");
    defer format.deinit();

    var info = ModuleInfo.init("test");
    info.icon = "🧪";
    info.version = try allocator.dupe(u8, "1.0.0");
    defer info.deinit(allocator);

    const rendered = try format.render(&info);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("via 🧪 1.0.0", rendered);
}

test "FormatString - render with name" {
    const allocator = std.testing.allocator;

    const format = try FormatString.init(allocator, "[{name}] {version}");
    defer format.deinit();

    var info = ModuleInfo.init("nodejs");
    info.version = try allocator.dupe(u8, "18.0.0");
    defer info.deinit(allocator);

    const rendered = try format.render(&info);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("[nodejs] 18.0.0", rendered);
}

test "FormatString - render without placeholders" {
    const allocator = std.testing.allocator;

    const format = try FormatString.init(allocator, "static text");
    defer format.deinit();

    var info = ModuleInfo.init("test");
    defer info.deinit(allocator);

    const rendered = try format.render(&info);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("static text", rendered);
}

test "FormatString - render with missing placeholders" {
    const allocator = std.testing.allocator;

    const format = try FormatString.init(allocator, "{symbol} {version}");
    defer format.deinit();

    var info = ModuleInfo.init("test");
    // No icon or version set
    defer info.deinit(allocator);

    const rendered = try format.render(&info);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(" ", rendered);
}

test "ModuleConfig - withFormat" {
    const config = ModuleConfig.withFormat("via {symbol} {version}");

    try std.testing.expect(config.enabled);
    try std.testing.expect(config.format != null);
    try std.testing.expectEqualStrings("via {symbol} {version}", config.format.?);
}

test "ModuleConfig - initDefault has no format" {
    const config = ModuleConfig.initDefault();

    try std.testing.expect(config.enabled);
    try std.testing.expect(config.format == null);
}
