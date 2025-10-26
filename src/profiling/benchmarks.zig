// Benchmark suite for Den Shell performance testing
const std = @import("std");
const Profiler = @import("profiler.zig").Profiler;
const ProfileEvent = @import("profiler.zig").ProfileEvent;

pub const BenchmarkResult = struct {
    name: []const u8,
    iterations: usize,
    total_ns: i64,
    min_ns: i64,
    max_ns: i64,
    mean_ns: f64,
    median_ns: i64,
    stddev_ns: f64,

    pub fn print(self: BenchmarkResult, writer: anytype) !void {
        const mean_ms = self.mean_ns / 1_000_000.0;
        const median_ms = @as(f64, @floatFromInt(self.median_ns)) / 1_000_000.0;
        const min_ms = @as(f64, @floatFromInt(self.min_ns)) / 1_000_000.0;
        const max_ms = @as(f64, @floatFromInt(self.max_ns)) / 1_000_000.0;
        const stddev_ms = self.stddev_ns / 1_000_000.0;

        try writer.print("{s}:\n", .{self.name});
        try writer.print("  Iterations: {d}\n", .{self.iterations});
        try writer.print("  Mean:       {d:.3}ms\n", .{mean_ms});
        try writer.print("  Median:     {d:.3}ms\n", .{median_ms});
        try writer.print("  Min:        {d:.3}ms\n", .{min_ms});
        try writer.print("  Max:        {d:.3}ms\n", .{max_ms});
        try writer.print("  Std Dev:    {d:.3}ms\n", .{stddev_ms});
        try writer.writeAll("\n");
    }
};

pub const Benchmark = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    iterations: usize,
    warmup_iterations: usize,
    profiler: ?*Profiler,

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        iterations: usize,
    ) Benchmark {
        return .{
            .allocator = allocator,
            .name = name,
            .iterations = iterations,
            .warmup_iterations = @max(1, @divFloor(iterations, 10)),
            .profiler = null,
        };
    }

    pub fn setProfiler(self: *Benchmark, profiler: *Profiler) void {
        self.profiler = profiler;
    }

    pub fn run(
        self: *Benchmark,
        comptime func: anytype,
        args: anytype,
    ) !BenchmarkResult {
        // Warmup
        var i: usize = 0;
        while (i < self.warmup_iterations) : (i += 1) {
            _ = try @call(.auto, func, args);
        }

        // Actual benchmark
        var timings = try self.allocator.alloc(i64, self.iterations);
        defer self.allocator.free(timings);

        var total_ns: i64 = 0;
        var min_ns: i64 = std.math.maxInt(i64);
        var max_ns: i64 = 0;

        i = 0;
        while (i < self.iterations) : (i += 1) {
            const start = std.time.nanoTimestamp();
            _ = try @call(.auto, func, args);
            const duration = std.time.nanoTimestamp() - start;
            const duration_i64 = @as(i64, @intCast(duration));

            timings[i] = duration_i64;
            total_ns += duration_i64;
            min_ns = @min(min_ns, duration_i64);
            max_ns = @max(max_ns, duration_i64);
        }

        // Calculate statistics
        const mean_ns = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(self.iterations));

        // Calculate standard deviation
        var variance: f64 = 0;
        for (timings) |t| {
            const diff = @as(f64, @floatFromInt(t)) - mean_ns;
            variance += diff * diff;
        }
        variance /= @as(f64, @floatFromInt(self.iterations));
        const stddev_ns = @sqrt(variance);

        // Calculate median
        std.mem.sort(i64, timings, {}, comptime std.sort.asc(i64));
        const median_ns = if (self.iterations % 2 == 0)
            @divFloor(timings[self.iterations / 2 - 1] + timings[self.iterations / 2], 2)
        else
            timings[self.iterations / 2];

        // Record to profiler if available
        if (self.profiler) |profiler| {
            try profiler.recordEvent(self.name, .other, @as(i64, @intFromFloat(mean_ns)));
        }

        return BenchmarkResult{
            .name = self.name,
            .iterations = self.iterations,
            .total_ns = total_ns,
            .min_ns = min_ns,
            .max_ns = max_ns,
            .mean_ns = mean_ns,
            .median_ns = median_ns,
            .stddev_ns = stddev_ns,
        };
    }
};

pub const BenchmarkSuite = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    results: std.ArrayList(BenchmarkResult),
    profiler: ?*Profiler,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) BenchmarkSuite {
        return .{
            .allocator = allocator,
            .name = name,
            .results = .{},
            .profiler = null,
        };
    }

    pub fn deinit(self: *BenchmarkSuite) void {
        self.results.deinit(self.allocator);
    }

    pub fn setProfiler(self: *BenchmarkSuite, profiler: *Profiler) void {
        self.profiler = profiler;
    }

    pub fn addResult(self: *BenchmarkSuite, result: BenchmarkResult) !void {
        try self.results.append(self.allocator, result);
    }

    pub fn printSummary(self: *BenchmarkSuite, writer: anytype) !void {
        try writer.print("\n=== {s} Benchmark Results ===\n\n", .{self.name});

        for (self.results.items) |result| {
            try result.print(writer);
        }

        // Overall summary
        if (self.results.items.len > 0) {
            var total_mean: f64 = 0;
            for (self.results.items) |result| {
                total_mean += result.mean_ns;
            }

            try writer.writeAll("Overall Summary:\n");
            try writer.writeAll("----------------\n");
            try writer.print("Total benchmarks: {d}\n", .{self.results.items.len});
            try writer.print("Average time:     {d:.3}ms\n", .{total_mean / @as(f64, @floatFromInt(self.results.items.len)) / 1_000_000.0});
            try writer.writeAll("\n");
        }
    }
};

// Example benchmark functions for testing
fn exampleFunction(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const buffer = try allocator.alloc(u8, size);
    @memset(buffer, 0);
    return buffer;
}

// Tests
test "Benchmark basic usage" {
    const allocator = std.testing.allocator;

    var benchmark = Benchmark.init(allocator, "test_alloc", 100);

    const result = try benchmark.run(exampleFunction, .{ allocator, 1024 });

    try std.testing.expect(result.iterations == 100);
    try std.testing.expect(result.mean_ns > 0);
    try std.testing.expect(result.min_ns <= result.max_ns);
}

test "BenchmarkSuite usage" {
    const allocator = std.testing.allocator;

    var suite = BenchmarkSuite.init(allocator, "Test Suite");
    defer suite.deinit();

    var benchmark = Benchmark.init(allocator, "test_alloc", 10);
    const result = try benchmark.run(exampleFunction, .{ allocator, 1024 });

    try suite.addResult(result);

    var buffer: std.ArrayList(u8) = .{};
    defer buffer.deinit(allocator);

    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buffer);
    defer buffer = aw.toArrayList();

    try suite.printSummary(&aw.writer);

    const output = buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "Test Suite") != null);
}
