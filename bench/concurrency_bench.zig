// Concurrency benchmarks for Den Shell
const std = @import("std");
const builtin = @import("builtin");
const profiling = @import("profiling");
const Benchmark = profiling.Benchmark;
const BenchmarkSuite = profiling.BenchmarkSuite;

const concurrency = @import("concurrency");
const parallel_discovery = @import("parallel_discovery");

// Benchmark thread pool vs sequential execution
fn benchmarkThreadPool(allocator: std.mem.Allocator) !void {
    var pool = try concurrency.ThreadPool.init(allocator, 4);
    defer pool.deinit();

    var counter = concurrency.AtomicCounter.init();

    const Args = struct { counter: *concurrency.AtomicCounter };
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try pool.submit(struct {
            fn work(args: Args) void {
                // Simulate some work
                var j: usize = 0;
                while (j < 100) : (j += 1) {
                    _ = args.counter.increment();
                    _ = args.counter.decrement();
                }
                _ = args.counter.increment();
            }
        }.work, Args{ .counter = &counter });
    }

    pool.waitIdle();
}

fn benchmarkSequential(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var counter = concurrency.AtomicCounter.init();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        // Same work as parallel version
        var j: usize = 0;
        while (j < 100) : (j += 1) {
            _ = counter.increment();
            _ = counter.decrement();
        }
        _ = counter.increment();
    }
}

// Benchmark SPSC queue
fn benchmarkSPSCQueue(_: std.mem.Allocator) !void {
    var queue = concurrency.SPSCQueue(i32, 1024).init();

    var i: i32 = 0;
    while (i < 500) : (i += 1) {
        _ = queue.push(i);
    }

    while (!queue.isEmpty()) {
        _ = queue.pop();
    }
}

fn benchmarkArrayList(allocator: std.mem.Allocator) !void {
    var list: std.ArrayListUnmanaged(i32) = .{};
    defer list.deinit(allocator);

    var i: i32 = 0;
    while (i < 500) : (i += 1) {
        try list.append(allocator, i);
    }

    while (list.items.len > 0) {
        _ = list.pop();
    }
}

// Benchmark concurrent hash map
fn benchmarkConcurrentHashMap(allocator: std.mem.Allocator) !void {
    var map = parallel_discovery.ConcurrentHashMap([]const u8, i32, 16).init(allocator);
    defer map.deinit();

    var i: i32 = 0;
    while (i < 100) : (i += 1) {
        var buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "key_{d}", .{i});
        const key_owned = try allocator.dupe(u8, key);
        try map.put(key_owned, i);
    }

    i = 0;
    while (i < 100) : (i += 1) {
        var buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "key_{d}", .{i});
        _ = map.get(key);
    }
}

fn benchmarkStdHashMap(allocator: std.mem.Allocator) !void {
    var map = std.StringHashMap(i32).init(allocator);
    defer map.deinit();

    var i: i32 = 0;
    while (i < 100) : (i += 1) {
        var buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "key_{d}", .{i});
        const key_owned = try allocator.dupe(u8, key);
        try map.put(key_owned, i);
    }

    i = 0;
    while (i < 100) : (i += 1) {
        var buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "key_{d}", .{i});
        _ = map.get(key);
    }
}

// Benchmark parallel file discovery
fn benchmarkParallelDiscovery(allocator: std.mem.Allocator) !void {
    var pool = try concurrency.ThreadPool.init(allocator, 4);
    defer pool.deinit();

    var scanner = parallel_discovery.ParallelScanner.init(allocator, &pool);
    defer scanner.deinit();

    const dirs = [_][]const u8{ "src", "bench" };
    _ = try scanner.scanDirectories(&dirs, ".zig");
}

fn benchmarkSequentialDiscovery(allocator: std.mem.Allocator) !void {
    var results: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (results.items) |path| {
            allocator.free(path);
        }
        results.deinit(allocator);
    }

    const dirs = [_][]const u8{ "src", "bench" };
    for (dirs) |dir_path| {
        var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(std.Options.debug_io);

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.endsWith(u8, entry.basename, ".zig")) {
                const full_path = try std.fs.path.join(
                    allocator,
                    &[_][]const u8{ dir_path, entry.path },
                );
                try results.append(allocator, full_path);
            }
        }
    }
}

// Benchmark RW lock
fn benchmarkRWLock(_: std.mem.Allocator) !void {
    var lock = concurrency.RWLock.init();
    var counter: usize = 0;
    var sum: usize = 0;

    // Simulate multiple readers
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        lock.lockRead();
        sum += counter;
        lock.unlockRead();
    }

    // Simulate writers
    i = 0;
    while (i < 10) : (i += 1) {
        lock.lockWrite();
        counter += 1;
        lock.unlockWrite();
    }

    // Use sum to avoid unused warning
    if (sum > 1000000) unreachable;
}

fn benchmarkMutex(_: std.mem.Allocator) !void {
    var mutex = std.Thread.Mutex{};
    var counter: usize = 0;
    var sum: usize = 0;

    // Same read operations but with mutex
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        mutex.lock();
        sum += counter;
        mutex.unlock();
    }

    // Write operations
    i = 0;
    while (i < 10) : (i += 1) {
        mutex.lock();
        counter += 1;
        mutex.unlock();
    }

    // Use sum to avoid unused warning
    if (sum > 1000000) unreachable;
}

// Benchmark atomic counter
fn benchmarkAtomicCounter(_: std.mem.Allocator) !void {
    var counter = concurrency.AtomicCounter.init();

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        _ = counter.increment();
    }

    i = 0;
    while (i < 500) : (i += 1) {
        _ = counter.decrement();
    }
}

fn benchmarkMutexCounter(_: std.mem.Allocator) !void {
    var mutex = std.Thread.Mutex{};
    var counter: usize = 0;

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        mutex.lock();
        counter += 1;
        mutex.unlock();
    }

    i = 0;
    while (i < 500) : (i += 1) {
        mutex.lock();
        counter -= 1;
        mutex.unlock();
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var suite = BenchmarkSuite.init(allocator, "Concurrency");
    defer suite.deinit();

    const stdout_file = if (builtin.os.tag == .windows) blk: {
        const handle = std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) orelse @panic("Failed to get stdout handle");
        break :blk std.Io.File{ .handle = handle, .flags = .{ .nonblocking = false } };
    } else std.Io.File{ .handle = std.posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } };
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(std.Options.debug_io, &stdout_buffer);

    try stdout_writer.interface.writeAll("Running concurrency benchmarks...\n\n");

    // Thread Pool vs Sequential
    {
        var bench = Benchmark.init(allocator, "Thread Pool (100 tasks)", 100);
        const result = try bench.run(benchmarkThreadPool, .{allocator});
        try suite.addResult(result);
    }

    {
        var bench = Benchmark.init(allocator, "Sequential (100 tasks)", 100);
        const result = try bench.run(benchmarkSequential, .{allocator});
        try suite.addResult(result);
    }

    // SPSC Queue vs ArrayList
    {
        var bench = Benchmark.init(allocator, "SPSC Queue (1000 ops)", 1000);
        const result = try bench.run(benchmarkSPSCQueue, .{allocator});
        try suite.addResult(result);
    }

    {
        var bench = Benchmark.init(allocator, "ArrayList (1000 ops)", 1000);
        const result = try bench.run(benchmarkArrayList, .{allocator});
        try suite.addResult(result);
    }

    // Concurrent HashMap vs Std HashMap
    {
        var bench = Benchmark.init(allocator, "Concurrent HashMap (200 ops)", 100);
        const result = try bench.run(benchmarkConcurrentHashMap, .{allocator});
        try suite.addResult(result);
    }

    {
        var bench = Benchmark.init(allocator, "Std HashMap (200 ops)", 100);
        const result = try bench.run(benchmarkStdHashMap, .{allocator});
        try suite.addResult(result);
    }

    // Parallel vs Sequential Discovery
    {
        var bench = Benchmark.init(allocator, "Parallel File Discovery", 10);
        const result = try bench.run(benchmarkParallelDiscovery, .{allocator});
        try suite.addResult(result);
    }

    {
        var bench = Benchmark.init(allocator, "Sequential File Discovery", 10);
        const result = try bench.run(benchmarkSequentialDiscovery, .{allocator});
        try suite.addResult(result);
    }

    // RW Lock vs Mutex
    {
        var bench = Benchmark.init(allocator, "RW Lock (50 reads, 10 writes)", 1000);
        const result = try bench.run(benchmarkRWLock, .{allocator});
        try suite.addResult(result);
    }

    {
        var bench = Benchmark.init(allocator, "Mutex (50 reads, 10 writes)", 1000);
        const result = try bench.run(benchmarkMutex, .{allocator});
        try suite.addResult(result);
    }

    // Atomic Counter vs Mutex Counter
    {
        var bench = Benchmark.init(allocator, "Atomic Counter (1500 ops)", 1000);
        const result = try bench.run(benchmarkAtomicCounter, .{allocator});
        try suite.addResult(result);
    }

    {
        var bench = Benchmark.init(allocator, "Mutex Counter (1500 ops)", 1000);
        const result = try bench.run(benchmarkMutexCounter, .{allocator});
        try suite.addResult(result);
    }

    try suite.printSummary(&stdout_writer.interface);
    try stdout_writer.interface.flush();
}
