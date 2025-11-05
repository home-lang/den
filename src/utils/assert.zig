const std = @import("std");
const builtin = @import("builtin");
const stack_trace = @import("stack_trace.zig");

/// Assertion failure handler
fn assertionFailed(
    comptime src: std.builtin.SourceLocation,
    comptime message: []const u8,
    args: anytype,
) noreturn {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    // Format the assertion message
    writer.print("\n\x1b[1m\x1b[31mASSERTION FAILED:\x1b[0m ", .{}) catch {};
    writer.print(message, args) catch {};
    writer.print("\n  at {s}:{d}\n", .{ src.file, src.line }) catch {};
    if (src.fn_name.len > 0) {
        writer.print("  in function: {s}\n", .{src.fn_name}) catch {};
    }

    writeStderr(fbs.getWritten());

    // Print stack trace
    stack_trace.printCurrentStackTrace(.{
        .use_color = true,
        .show_addresses = true,
    });

    std.process.abort();
}

/// Helper to write to stderr
fn writeStderr(msg: []const u8) void {
    if (builtin.os.tag == .windows) {
        const handle = std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) orelse return;
        const stderr = std.fs.File{ .handle = handle };
        _ = stderr.write(msg) catch {};
    } else {
        _ = std.posix.write(std.posix.STDERR_FILENO, msg) catch {};
    }
}

/// Assert that a condition is true
pub fn assert(condition: bool, comptime message: []const u8, args: anytype) void {
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        if (!condition) {
            assertionFailed(@src(), message, args);
        }
    }
}

/// Assert equality
pub fn assertEquals(comptime T: type, expected: T, actual: T, comptime message: []const u8) void {
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        if (!std.meta.eql(expected, actual)) {
            var buf: [2048]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            const writer = fbs.writer();

            writer.print("{s}\n  Expected: {any}\n  Actual:   {any}", .{
                message,
                expected,
                actual,
            }) catch {};

            assertionFailed(@src(), "{s}", .{fbs.getWritten()});
        }
    }
}

/// Assert not equal
pub fn assertNotEquals(comptime T: type, not_expected: T, actual: T, comptime message: []const u8) void {
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        if (std.meta.eql(not_expected, actual)) {
            var buf: [2048]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            const writer = fbs.writer();

            writer.print("{s}\n  Did not expect: {any}\n  But got:        {any}", .{
                message,
                not_expected,
                actual,
            }) catch {};

            assertionFailed(@src(), "{s}", .{fbs.getWritten()});
        }
    }
}

/// Assert null
pub fn assertNull(value: anytype, comptime message: []const u8) void {
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        if (value != null) {
            var buf: [1024]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            const writer = fbs.writer();

            writer.print("{s}\n  Expected null, but got: {any}", .{
                message,
                value,
            }) catch {};

            assertionFailed(@src(), "{s}", .{fbs.getWritten()});
        }
    }
}

/// Assert not null
pub fn assertNotNull(value: anytype, comptime message: []const u8) void {
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        if (value == null) {
            assertionFailed(@src(), "{s}\n  Expected non-null value, but got null", .{message});
        }
    }
}

/// Assert string equality
pub fn assertStringEquals(expected: []const u8, actual: []const u8, comptime message: []const u8) void {
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        if (!std.mem.eql(u8, expected, actual)) {
            var buf: [2048]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            const writer = fbs.writer();

            writer.print("{s}\n  Expected: \"{s}\"\n  Actual:   \"{s}\"", .{
                message,
                expected,
                actual,
            }) catch {};

            assertionFailed(@src(), "{s}", .{fbs.getWritten()});
        }
    }
}

/// Assert string contains substring
pub fn assertStringContains(haystack: []const u8, needle: []const u8, comptime message: []const u8) void {
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        if (std.mem.indexOf(u8, haystack, needle) == null) {
            var buf: [2048]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            const writer = fbs.writer();

            writer.print("{s}\n  String: \"{s}\"\n  Does not contain: \"{s}\"", .{
                message,
                haystack,
                needle,
            }) catch {};

            assertionFailed(@src(), "{s}", .{fbs.getWritten()});
        }
    }
}

/// Assert greater than
pub fn assertGreaterThan(comptime T: type, value: T, threshold: T, comptime message: []const u8) void {
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        if (value <= threshold) {
            var buf: [1024]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            const writer = fbs.writer();

            writer.print("{s}\n  Expected {any} > {any}, but {any} <= {any}", .{
                message,
                value,
                threshold,
                value,
                threshold,
            }) catch {};

            assertionFailed(@src(), "{s}", .{fbs.getWritten()});
        }
    }
}

/// Assert less than
pub fn assertLessThan(comptime T: type, value: T, threshold: T, comptime message: []const u8) void {
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        if (value >= threshold) {
            var buf: [1024]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            const writer = fbs.writer();

            writer.print("{s}\n  Expected {any} < {any}, but {any} >= {any}", .{
                message,
                value,
                threshold,
                value,
                threshold,
            }) catch {};

            assertionFailed(@src(), "{s}", .{fbs.getWritten()});
        }
    }
}

/// Assert array/slice length
pub fn assertLength(comptime T: type, slice: []const T, expected_len: usize, comptime message: []const u8) void {
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        if (slice.len != expected_len) {
            var buf: [1024]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            const writer = fbs.writer();

            writer.print("{s}\n  Expected length: {d}\n  Actual length:   {d}", .{
                message,
                expected_len,
                slice.len,
            }) catch {};

            assertionFailed(@src(), "{s}", .{fbs.getWritten()});
        }
    }
}

/// Assert that a value is in a range
pub fn assertInRange(comptime T: type, value: T, min: T, max: T, comptime message: []const u8) void {
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        if (value < min or value > max) {
            var buf: [1024]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            const writer = fbs.writer();

            writer.print("{s}\n  Expected {any} to be in range [{any}, {any}]", .{
                message,
                value,
                min,
                max,
            }) catch {};

            assertionFailed(@src(), "{s}", .{fbs.getWritten()});
        }
    }
}

/// Assert error
pub fn assertError(comptime E: type, result: anytype, expected_error: E, comptime message: []const u8) void {
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        if (result) |_| {
            assertionFailed(@src(), "{s}\n  Expected error {s}, but got success", .{ message, @errorName(expected_error) });
        } else |err| {
            if (err != expected_error) {
                var buf: [1024]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&buf);
                const writer = fbs.writer();

                writer.print("{s}\n  Expected error: {s}\n  Actual error:   {s}", .{
                    message,
                    @errorName(expected_error),
                    @errorName(err),
                }) catch {};

                assertionFailed(@src(), "{s}", .{fbs.getWritten()});
            }
        }
    }
}

/// Unreachable with message
pub fn assertUnreachable(comptime message: []const u8, args: anytype) noreturn {
    assertionFailed(@src(), "Reached unreachable code: " ++ message, args);
}
