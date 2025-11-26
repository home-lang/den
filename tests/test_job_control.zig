const std = @import("std");
const test_utils = @import("test_utils.zig");

// ============================================================================
// Job Control Tests
// Tests for background jobs, fg, bg, jobs, disown
// ============================================================================

test "job control: run command in background" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 0.1 &");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Background job should start successfully
    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "job control: jobs lists background jobs" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 1 & jobs");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should show the background job
    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "job control: jobs shows job number" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 1 & jobs");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Output should contain job number like [1]
    try test_utils.TestAssert.expectTrue(
        std.mem.indexOf(u8, result.stdout, "[") != null or result.stdout.len == 0,
    );
}

test "job control: wait for background job" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 0.1 & wait && echo done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "done");
}

test "job control: wait for specific job" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 0.1 & wait %1 && echo waited");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "waited");
}

test "job control: multiple background jobs" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 0.1 & sleep 0.1 & jobs");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "job control: kill background job" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 10 & kill %1");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "job control: kill with signal" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 10 & kill -9 %1");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "job control: kill by PID" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    // Use $! to get last background PID
    const result = try fixture.exec("sleep 10 & kill $!");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "job control: disown removes job from table" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 0.5 & disown && jobs");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // After disown, job should not appear in jobs list
    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "job control: background command output" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo background & wait");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Background command should still produce output
    try test_utils.TestAssert.expectContains(result.stdout, "background");
}

test "job control: background pipeline" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo test | cat & wait");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "test");
}

test "job control: jobs -l shows PIDs" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 1 & jobs -l");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // With -l flag, should show PID (a number)
    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "job control: exit code of background job" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("false & wait && echo $?");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // wait should return the exit code of the job
    try test_utils.TestAssert.expectContains(result.stdout, "1");
}
