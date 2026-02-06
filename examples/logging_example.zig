const std = @import("std");
const utils = @import("utils");

const log = utils.log;
const structured_log = utils.structured_log;
const debug = utils.debug;
const error_format = utils.error_format;
const stack_trace = utils.stack_trace;
const assert = utils.assert;
const timer = utils.timer;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Initialize the logger
    try log.init(allocator, .{
        .level = .debug,
        .use_color = true,
        .show_timestamp = true,
        .show_file = true,
        .show_line = true,
    });
    defer log.deinit();

    std.debug.print("\n=== Logging Examples ===\n\n", .{});

    // Basic logging
    log.debug("This is a debug message", .{});
    log.info("Application started", .{});
    log.warn("This is a warning", .{});
    log.err("This is an error message", .{});

    std.debug.print("\n=== Structured Logging Examples ===\n\n", .{});

    // Structured logging
    var slog = structured_log.StructuredLogger.init(allocator);
    defer slog.deinit();

    try slog.withString("user", "alice");
    try slog.withInt("age", 30);
    try slog.withDuration("response_time", 1_234_567); // nanoseconds
    try slog.withBytes("memory_used", 1024 * 1024 * 15); // bytes
    slog.info(@src(), "User request processed");

    std.debug.print("\n=== Debug Utilities Examples ===\n\n", .{});

    // Debug utilities (only in debug mode)
    debug.enabled = true;
    debug.print("Debug output: value = {d}", .{42});

    const data = "Hello, World!";
    debug.hexDump("Sample Data", data);

    debug.inspect("sample_string", data);
    debug.trace(@src(), "exampleFunction");

    std.debug.print("\n=== Error Formatting Examples ===\n\n", .{});

    // Error formatting
    const err = error.OutOfMemory;
    const context = error_format.ErrorContext.init(
        "example.zig",
        42,
        10,
        "processData",
        "Failed to allocate memory for buffer",
    );
    error_format.printError(err, context, true);

    std.debug.print("\n=== Assertion Examples ===\n\n", .{});

    // Assertions (only active in Debug/ReleaseSafe mode)
    assert.assertEquals(i32, 42, 42, "Values should be equal");
    assert.assertStringEquals("hello", "hello", "Strings should match");
    assert.assertInRange(i32, 50, 0, 100, "Value should be in range");

    std.debug.print("All assertions passed!\n", .{});

    std.debug.print("\n=== Timing Examples ===\n\n", .{});

    // Basic timer
    var t = timer.Timer.start("operation");
    std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromNanoseconds(@as(i96, 0) * 1_000_000_000 + @as(i96, 10_000_000)), .awake) catch {}; // Sleep for 10ms
    t.print();

    // Scoped timer
    {
        var scoped = timer.ScopedTimer.init("scoped_operation");
        defer scoped.deinit();
        std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromNanoseconds(@as(i96, 0) * 1_000_000_000 + @as(i96, 5_000_000)), .awake) catch {}; // Sleep for 5ms
    }

    // Timing statistics
    var stats = timer.TimingStats.init(allocator, "repeated_operation");
    defer stats.deinit();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var operation_timer = timer.Timer.start("iteration");
        // Simulate work
        std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromNanoseconds(@as(i96, 0) * 1_000_000_000 + @as(i96, @intCast(1_000_000 * (1 + i % 3)))), .awake) catch {};
        try stats.addSample(operation_timer.elapsed());
    }
    stats.print();

    // Profiler
    var profiler = timer.Profiler.init(allocator);
    defer profiler.deinit();

    i = 0;
    while (i < 5) : (i += 1) {
        var prof_timer = profiler.startTimer("task_a");
        std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromNanoseconds(@as(i96, 0) * 1_000_000_000 + @as(i96, 2_000_000)), .awake) catch {};
        try profiler.recordTiming("task_a", prof_timer.elapsed());

        prof_timer = profiler.startTimer("task_b");
        std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromNanoseconds(@as(i96, 0) * 1_000_000_000 + @as(i96, 3_000_000)), .awake) catch {};
        try profiler.recordTiming("task_b", prof_timer.elapsed());
    }

    std.debug.print("\n=== Profiler Results ===\n", .{});
    profiler.printAll();

    std.debug.print("\n=== Stack Trace Example ===\n\n", .{});

    // Stack trace
    stack_trace.printCurrentStackTrace(.{
        .use_color = true,
        .show_addresses = true,
        .max_depth = 10,
    });

    std.debug.print("\n=== Memory Tracking Example ===\n\n", .{});

    // Memory tracking with debug allocator
    var debug_alloc = debug.DebugAllocator.init(allocator);
    const tracked = debug_alloc.allocator();

    debug.enabled = true;
    const mem1 = try tracked.alloc(u8, 100);
    const mem2 = try tracked.alloc(u8, 200);
    tracked.free(mem1);
    const mem3 = try tracked.alloc(u8, 50);
    tracked.free(mem2);
    tracked.free(mem3);

    debug_alloc.tracker.printStats();

    std.debug.print("\n=== All examples completed successfully! ===\n\n", .{});
}
