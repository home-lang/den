// Startup time benchmarks for Den Shell
const std = @import("std");
const profiling = @import("profiling");
const Benchmark = profiling.Benchmark;
const BenchmarkSuite = profiling.BenchmarkSuite;

// Mock shell startup components for benchmarking
fn benchmarkMinimalStartup(_: std.mem.Allocator) !void {
    // Simulate minimal startup (no config, no plugins)
    std.posix.nanosleep(0, 100_000); // 0.1ms
}

fn benchmarkConfigLoad(allocator: std.mem.Allocator) !void {
    // Simulate config file loading
    const config = try allocator.alloc(u8, 1024);
    defer allocator.free(config);
    @memset(config, 0);
}

fn benchmarkHistoryLoad(allocator: std.mem.Allocator) !void {
    // Simulate loading 1000 history entries
    var list = std.ArrayList([]const u8){ };
    defer list.deinit(allocator);

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const entry = try allocator.dupe(u8, "echo hello");
        try list.append(allocator, entry);
    }

    for (list.items) |entry| {
        allocator.free(entry);
    }
}

fn benchmarkPluginDiscovery(_: std.mem.Allocator) !void {
    // Simulate plugin discovery
    std.posix.nanosleep(0, 500_000); // 0.5ms
}

fn benchmarkPromptInit(allocator: std.mem.Allocator) !void {
    // Simulate prompt initialization
    const prompt = try allocator.alloc(u8, 256);
    defer allocator.free(prompt);
    @memset(prompt, 0);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var suite = BenchmarkSuite.init(allocator, "Startup Time");
    defer suite.deinit();

    const stdout_file = std.fs.File{
        .handle = std.posix.STDOUT_FILENO,
    };
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buffer);

    try stdout_writer.interface.writeAll("Running startup benchmarks...\n\n");
    try stdout_writer.interface.flush();

    // Minimal startup
    {
        var bench = Benchmark.init(allocator, "Minimal Startup", 1000);
        const result = try bench.run(benchmarkMinimalStartup, .{allocator});
        try suite.addResult(result);
    }

    // Config loading
    {
        var bench = Benchmark.init(allocator, "Config Load", 1000);
        const result = try bench.run(benchmarkConfigLoad, .{allocator});
        try suite.addResult(result);
    }

    // History loading
    {
        var bench = Benchmark.init(allocator, "History Load (1000 entries)", 100);
        const result = try bench.run(benchmarkHistoryLoad, .{allocator});
        try suite.addResult(result);
    }

    // Plugin discovery
    {
        var bench = Benchmark.init(allocator, "Plugin Discovery", 1000);
        const result = try bench.run(benchmarkPluginDiscovery, .{allocator});
        try suite.addResult(result);
    }

    // Prompt initialization
    {
        var bench = Benchmark.init(allocator, "Prompt Init", 1000);
        const result = try bench.run(benchmarkPromptInit, .{allocator});
        try suite.addResult(result);
    }

    try suite.printSummary(&stdout_writer.interface);
    try stdout_writer.interface.flush();
}
