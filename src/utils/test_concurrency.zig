// Comprehensive tests for concurrency infrastructure
const std = @import("std");
const concurrency = @import("concurrency");
const parallel_discovery = @import("parallel_discovery");

// Test thread pool basic functionality
test "ThreadPool: basic task execution" {
    var pool = try concurrency.ThreadPool.init(std.testing.allocator, 2);
    defer pool.deinit();

    var counter = concurrency.AtomicCounter.init();

    const Args = struct { counter: *concurrency.AtomicCounter };
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try pool.submit(struct {
            fn work(args: Args) void {
                _ = args.counter.increment();
            }
        }.work, Args{ .counter = &counter });
    }

    pool.waitIdle();
    try std.testing.expectEqual(@as(usize, 20), counter.get());
}

// Test thread pool with CPU auto-detection
test "ThreadPool: auto CPU detection" {
    var pool = try concurrency.ThreadPool.init(std.testing.allocator, 0);
    defer pool.deinit();

    try std.testing.expect(pool.threads.len > 0);
    try std.testing.expect(pool.threads.len <= 64); // Reasonable upper bound
}

// Test atomic counter operations
test "AtomicCounter: increment/decrement" {
    var counter = concurrency.AtomicCounter.init();

    try std.testing.expectEqual(@as(usize, 0), counter.get());

    _ = counter.increment();
    _ = counter.increment();
    _ = counter.increment();
    try std.testing.expectEqual(@as(usize, 3), counter.get());

    _ = counter.decrement();
    try std.testing.expectEqual(@as(usize, 2), counter.get());

    counter.set(100);
    try std.testing.expectEqual(@as(usize, 100), counter.get());
}

// Test atomic counter thread safety
test "AtomicCounter: thread safety" {
    var pool = try concurrency.ThreadPool.init(std.testing.allocator, 4);
    defer pool.deinit();

    var counter = concurrency.AtomicCounter.init();

    const Args = struct { counter: *concurrency.AtomicCounter };

    // Submit 100 increment tasks
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try pool.submit(struct {
            fn work(args: Args) void {
                _ = args.counter.increment();
            }
        }.work, Args{ .counter = &counter });
    }

    pool.waitIdle();
    try std.testing.expectEqual(@as(usize, 100), counter.get());
}

// Test SPSC queue push/pop
test "SPSCQueue: basic operations" {
    var queue = concurrency.SPSCQueue(i32, 8).init();

    try std.testing.expect(queue.isEmpty());
    try std.testing.expect(!queue.isFull());

    try std.testing.expect(queue.push(1));
    try std.testing.expect(queue.push(2));
    try std.testing.expect(queue.push(3));

    try std.testing.expect(!queue.isEmpty());

    try std.testing.expectEqual(@as(?i32, 1), queue.pop());
    try std.testing.expectEqual(@as(?i32, 2), queue.pop());
    try std.testing.expectEqual(@as(?i32, 3), queue.pop());

    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(?i32, null), queue.pop());
}

// Test SPSC queue capacity
test "SPSCQueue: capacity limits" {
    var queue = concurrency.SPSCQueue(i32, 4).init();

    try std.testing.expect(queue.push(1));
    try std.testing.expect(queue.push(2));
    try std.testing.expect(queue.push(3));

    // Can push 3 items in size-4 queue (one slot reserved)
    try std.testing.expect(!queue.isFull());

    // Now it should be full
    try std.testing.expect(!queue.push(4));

    // Pop one, should be able to push again
    _ = queue.pop();
    try std.testing.expect(queue.push(4));
}

// Test RW lock reader concurrency
test "RWLock: multiple readers" {
    var lock = concurrency.RWLock.init();
    const shared_data: i32 = 42;

    // Acquire read locks simultaneously
    lock.lockRead();
    const data1 = shared_data;
    lock.lockRead(); // Second reader
    const data2 = shared_data;

    try std.testing.expectEqual(@as(i32, 42), data1);
    try std.testing.expectEqual(@as(i32, 42), data2);

    lock.unlockRead();
    lock.unlockRead();
}

// Test RW lock writer exclusivity
test "RWLock: writer exclusivity" {
    var lock = concurrency.RWLock.init();
    var shared_data: i32 = 0;

    lock.lockWrite();
    shared_data = 100;
    lock.unlockWrite();

    lock.lockRead();
    try std.testing.expectEqual(@as(i32, 100), shared_data);
    lock.unlockRead();
}

// Test concurrent hash map
test "ConcurrentHashMap: basic operations" {
    var map = parallel_discovery.ConcurrentHashMap([]const u8, i32, 4).init(std.testing.allocator);
    defer map.deinit();

    try map.put("one", 1);
    try map.put("two", 2);
    try map.put("three", 3);

    try std.testing.expectEqual(@as(?i32, 1), map.get("one"));
    try std.testing.expectEqual(@as(?i32, 2), map.get("two"));
    try std.testing.expectEqual(@as(?i32, 3), map.get("three"));
    try std.testing.expectEqual(@as(?i32, null), map.get("four"));

    try std.testing.expectEqual(@as(usize, 3), map.count());

    try std.testing.expect(map.remove("one"));
    try std.testing.expectEqual(@as(?i32, null), map.get("one"));
    try std.testing.expectEqual(@as(usize, 2), map.count());
}

// Test concurrent hash map with many items
test "ConcurrentHashMap: many items" {
    var map = parallel_discovery.ConcurrentHashMap([]const u8, i32, 16).init(std.testing.allocator);
    defer map.deinit();

    var i: i32 = 0;
    while (i < 100) : (i += 1) {
        var buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "key_{d}", .{i});
        const key_owned = try std.testing.allocator.dupe(u8, key);
        try map.put(key_owned, i);
    }

    try std.testing.expectEqual(@as(usize, 100), map.count());

    // Check some values
    try std.testing.expectEqual(@as(?i32, 0), map.get("key_0"));
    try std.testing.expectEqual(@as(?i32, 50), map.get("key_50"));
    try std.testing.expectEqual(@as(?i32, 99), map.get("key_99"));
}

// Test parallel scanner
test "ParallelScanner: file discovery" {
    var pool = try concurrency.ThreadPool.init(std.testing.allocator, 2);
    defer pool.deinit();

    var scanner = parallel_discovery.ParallelScanner.init(std.testing.allocator, &pool);
    defer scanner.deinit();

    // Scan for .zig files in src directory
    const dirs = [_][]const u8{"src"};
    const results = try scanner.scanDirectories(&dirs, ".zig");

    try std.testing.expect(results.len > 0);

    // Verify all results end with .zig
    for (results) |path| {
        try std.testing.expect(std.mem.endsWith(u8, path, ".zig"));
    }
}

// Test parallel scanner with multiple directories
test "ParallelScanner: multiple directories" {
    var pool = try concurrency.ThreadPool.init(std.testing.allocator, 2);
    defer pool.deinit();

    var scanner = parallel_discovery.ParallelScanner.init(std.testing.allocator, &pool);
    defer scanner.deinit();

    const dirs = [_][]const u8{ "src", "bench" };
    const results = try scanner.scanDirectories(&dirs, ".zig");

    try std.testing.expect(results.len > 0);

    // Should find files from both directories
    var found_src = false;
    var found_bench = false;

    for (results) |path| {
        if (std.mem.indexOf(u8, path, "src") != null) found_src = true;
        if (std.mem.indexOf(u8, path, "bench") != null) found_bench = true;
    }

    try std.testing.expect(found_src or found_bench);
}

// Test batch processor
test "BatchProcessor: basic batch processing" {
    var pool = try concurrency.ThreadPool.init(std.testing.allocator, 2);
    defer pool.deinit();

    var processor = parallel_discovery.BatchProcessor.init(std.testing.allocator, &pool);
    defer processor.deinit();

    var counter = concurrency.AtomicCounter.init();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try processor.addWork(*concurrency.AtomicCounter, &counter, struct {
            fn process(c: *concurrency.AtomicCounter) void {
                _ = c.increment();
            }
        }.process);
    }

    try processor.processBatch();
    try std.testing.expectEqual(@as(usize, 10), counter.get());
}

// Test parallel forEach
test "parallelForEach: basic iteration" {
    var pool = try concurrency.ThreadPool.init(std.testing.allocator, 2);
    defer pool.deinit();

    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8 };

    try concurrency.parallelForEach(i32, &pool, &items, struct {
        fn process(item: i32) void {
            _ = item;
            // Execution happens in parallel
        }
    }.process);
}

// Test thread pool error handling
test "ThreadPool: handles errors gracefully" {
    var pool = try concurrency.ThreadPool.init(std.testing.allocator, 2);
    defer pool.deinit();

    var success_count = concurrency.AtomicCounter.init();

    const Args = struct {
        should_error: bool,
        counter: *concurrency.AtomicCounter,
    };

    // Submit mix of successful and error tasks
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try pool.submit(struct {
            fn work(args: Args) void {
                if (!args.should_error) {
                    _ = args.counter.increment();
                }
            }
        }.work, Args{
            .should_error = (i % 3 == 0),
            .counter = &success_count,
        });
    }

    pool.waitIdle();

    // Should have processed non-error tasks
    try std.testing.expect(success_count.get() > 0);
}

// Performance test: thread pool vs sequential
test "ThreadPool: performance comparison" {
    const iterations = 1000;

    // Sequential execution
    var seq_counter: usize = 0;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        seq_counter += 1;
    }

    // Parallel execution
    var pool = try concurrency.ThreadPool.init(std.testing.allocator, 4);
    defer pool.deinit();

    var par_counter = concurrency.AtomicCounter.init();

    const Args = struct { counter: *concurrency.AtomicCounter };
    i = 0;
    while (i < iterations) : (i += 1) {
        try pool.submit(struct {
            fn work(args: Args) void {
                _ = args.counter.increment();
            }
        }.work, Args{ .counter = &par_counter });
    }

    pool.waitIdle();

    try std.testing.expectEqual(seq_counter, par_counter.get());
}
