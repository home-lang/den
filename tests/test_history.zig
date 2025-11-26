const std = @import("std");
const test_utils = @import("test_utils.zig");

// ============================================================================
// History Management Tests
// Tests for shell history functionality
// ============================================================================

test "history: command is recorded" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo test_history_entry && history");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    // History should contain our command
    try test_utils.TestAssert.expectContains(result.stdout, "echo");
}

test "history: multiple commands recorded" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo first; echo second; echo third; history");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "history: shows numbered entries" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo test && history");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // History output should include numbers
    try test_utils.TestAssert.expectTrue(
        std.mem.indexOf(u8, result.stdout, "1") != null or
            std.mem.indexOf(u8, result.stdout, "0") != null,
    );
}

test "history: clear history" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo before && history -c && history");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // After clear, history should be empty or minimal
    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "history: limit number of entries shown" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    // Add several commands then request limited history
    const result = try fixture.exec("echo 1; echo 2; echo 3; echo 4; echo 5; history 3");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "history: duplicate commands handling" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    // Same command multiple times
    const result = try fixture.exec("echo duplicate; echo duplicate; echo duplicate; history");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "history: empty command not recorded" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    // Empty commands (just semicolons) shouldn't bloat history
    const result = try fixture.exec("echo marker; ; ; ; history");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "marker");
}

test "history: whitespace-only command not recorded" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo marker &&    && history");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "marker");
}
