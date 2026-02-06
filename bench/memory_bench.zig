// Memory usage benchmarks for Den Shell
const std = @import("std");
const builtin = @import("builtin");
const profiling = @import("profiling");
const Benchmark = profiling.Benchmark;
const BenchmarkSuite = profiling.BenchmarkSuite;

// Import memory module - will be added to build
const memory = @import("memory");

// Track memory usage
const MemoryTracker = struct {
    allocations: usize,
    deallocations: usize,
    bytes_allocated: usize,
    bytes_freed: usize,
    peak_usage: usize,

    pub fn init() MemoryTracker {
        return .{
            .allocations = 0,
            .deallocations = 0,
            .bytes_allocated = 0,
            .bytes_freed = 0,
            .peak_usage = 0,
        };
    }

    pub fn currentUsage(self: *const MemoryTracker) usize {
        return self.bytes_allocated - self.bytes_freed;
    }

    pub fn updatePeak(self: *MemoryTracker) void {
        const current = self.currentUsage();
        if (current > self.peak_usage) {
            self.peak_usage = current;
        }
    }
};

// Benchmark object pool vs direct allocation
fn benchmarkObjectPoolVsAlloc(allocator: std.mem.Allocator) !void {
    const TestStruct = struct { value: i32, data: [32]u8 };
    var pool = memory.ObjectPool(TestStruct, 100).init(allocator);

    // Use object pool
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        if (pool.acquire()) |item| {
            item.value = @intCast(i);
            pool.release(item);
        }
    }
}

fn benchmarkDirectAlloc(allocator: std.mem.Allocator) !void {
    const TestStruct = struct { value: i32, data: [32]u8 };

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const item = try allocator.create(TestStruct);
        item.value = @intCast(i);
        allocator.destroy(item);
    }
}

// Benchmark stack buffer vs heap allocation
fn benchmarkStackBuffer(_: std.mem.Allocator) !void {
    var buf = memory.StackBuffer(1024).init();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = buf.alloc(64);
    }

    buf.reset();
}

fn benchmarkHeapAlloc(allocator: std.mem.Allocator) !void {
    var buffers: [10][]u8 = undefined;

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        buffers[i] = try allocator.alloc(u8, 64);
    }

    for (buffers) |buf| {
        allocator.free(buf);
    }
}

// Benchmark StringBuilder
fn benchmarkStringBuilder(allocator: std.mem.Allocator) !void {
    var sb = memory.StringBuilder.init(allocator);
    defer sb.deinit();

    try sb.append("Hello ");
    try sb.append("World!");
    _ = sb.toSlice();
}

fn benchmarkStringConcat(allocator: std.mem.Allocator) !void {
    var result: std.ArrayListUnmanaged(u8) = .{};
    defer result.deinit(allocator);

    try result.appendSlice(allocator, "Hello ");
    try result.appendSlice(allocator, "World!");
}

// Benchmark arena allocator
fn benchmarkArenaAllocator(allocator: std.mem.Allocator) !void {
    var arena = memory.ShellArena.init(allocator);
    defer arena.deinit();

    const arena_alloc = arena.allocator();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        _ = try arena_alloc.alloc(u8, 64);
    }
}

fn benchmarkIndividualAllocs(allocator: std.mem.Allocator) !void {
    var buffers: [100][]u8 = undefined;

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        buffers[i] = try allocator.alloc(u8, 64);
    }

    for (buffers) |buf| {
        allocator.free(buf);
    }
}

// Benchmark StackArrayList vs ArrayList
fn benchmarkStackArrayList(_: std.mem.Allocator) !void {
    var list = memory.StackArrayList(i32, 100).init();

    var i: i32 = 0;
    while (i < 50) : (i += 1) {
        try list.append(i);
    }

    _ = list.slice();
}

fn benchmarkHeapArrayList(allocator: std.mem.Allocator) !void {
    var list: std.ArrayListUnmanaged(i32) = .{};
    defer list.deinit(allocator);

    var i: i32 = 0;
    while (i < 50) : (i += 1) {
        try list.append(allocator, i);
    }
}

// Benchmark command memory pool
fn benchmarkCommandMemoryPool(allocator: std.mem.Allocator) !void {
    var pool = memory.CommandMemoryPool.init(allocator);
    defer pool.deinit();

    const arena_alloc = pool.getArenaAllocator();

    // Simulate command execution with multiple allocations
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        _ = try arena_alloc.alloc(u8, 128);
    }

    pool.reset(); // Reuse memory
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var suite = BenchmarkSuite.init(allocator, "Memory Optimization");
    defer suite.deinit();

    const stdout_file = if (builtin.os.tag == .windows) blk: {
        const handle = std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) orelse @panic("Failed to get stdout handle");
        break :blk std.Io.File{ .handle = handle, .flags = .{ .nonblocking = false } };
    } else std.Io.File{ .handle = std.posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } };
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(std.Options.debug_io, &stdout_buffer);

    try stdout_writer.interface.writeAll("Running memory optimization benchmarks...\n\n");

    // Object Pool vs Direct Allocation
    {
        var bench = Benchmark.init(allocator, "Object Pool (100 items)", 1000);
        const result = try bench.run(benchmarkObjectPoolVsAlloc, .{allocator});
        try suite.addResult(result);
    }

    {
        var bench = Benchmark.init(allocator, "Direct Allocation (100 items)", 1000);
        const result = try bench.run(benchmarkDirectAlloc, .{allocator});
        try suite.addResult(result);
    }

    // Stack Buffer vs Heap Allocation
    {
        var bench = Benchmark.init(allocator, "Stack Buffer (10x64 bytes)", 10000);
        const result = try bench.run(benchmarkStackBuffer, .{allocator});
        try suite.addResult(result);
    }

    {
        var bench = Benchmark.init(allocator, "Heap Allocation (10x64 bytes)", 10000);
        const result = try bench.run(benchmarkHeapAlloc, .{allocator});
        try suite.addResult(result);
    }

    // StringBuilder vs String Concatenation
    {
        var bench = Benchmark.init(allocator, "StringBuilder", 10000);
        const result = try bench.run(benchmarkStringBuilder, .{allocator});
        try suite.addResult(result);
    }

    {
        var bench = Benchmark.init(allocator, "String Concatenation", 10000);
        const result = try bench.run(benchmarkStringConcat, .{allocator});
        try suite.addResult(result);
    }

    // Arena Allocator vs Individual Allocations
    {
        var bench = Benchmark.init(allocator, "Arena Allocator (100x64 bytes)", 1000);
        const result = try bench.run(benchmarkArenaAllocator, .{allocator});
        try suite.addResult(result);
    }

    {
        var bench = Benchmark.init(allocator, "Individual Allocs (100x64 bytes)", 1000);
        const result = try bench.run(benchmarkIndividualAllocs, .{allocator});
        try suite.addResult(result);
    }

    // StackArrayList vs ArrayList
    {
        var bench = Benchmark.init(allocator, "StackArrayList (50 items)", 10000);
        const result = try bench.run(benchmarkStackArrayList, .{allocator});
        try suite.addResult(result);
    }

    {
        var bench = Benchmark.init(allocator, "Heap ArrayList (50 items)", 10000);
        const result = try bench.run(benchmarkHeapArrayList, .{allocator});
        try suite.addResult(result);
    }

    // Command Memory Pool
    {
        var bench = Benchmark.init(allocator, "Command Memory Pool", 1000);
        const result = try bench.run(benchmarkCommandMemoryPool, .{allocator});
        try suite.addResult(result);
    }

    try suite.printSummary(&stdout_writer.interface);
    try stdout_writer.interface.flush();
}
