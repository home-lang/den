// CPU optimization benchmarks for Den Shell
const std = @import("std");
const builtin = @import("builtin");
const profiling = @import("profiling");
const Benchmark = profiling.Benchmark;
const BenchmarkSuite = profiling.BenchmarkSuite;

const cpu_opt = @import("cpu_opt");
const optimized_parser = @import("optimized_parser");

// Benchmark LRU cache vs recomputation
fn benchmarkLRUCache(allocator: std.mem.Allocator) !void {
    var cache = cpu_opt.LRUCache(i32, i32, 16).init(allocator);

    // Simulate expensive computation with caching
    var i: i32 = 0;
    while (i < 100) : (i += 1) {
        const key = @rem(i, 20); // Repeat some keys
        if (cache.get(key)) |_| {
            // Cache hit
        } else {
            // Cache miss - compute and store
            const result = key * key; // Simple computation
            cache.put(key, result);
        }
    }
}

fn benchmarkNoCache(_: std.mem.Allocator) !void {
    // No caching - always recompute
    var i: i32 = 0;
    while (i < 100) : (i += 1) {
        const key = @rem(i, 20);
        _ = key * key; // Always compute
    }
}

// Benchmark fast string matcher vs std.mem.indexOf
fn benchmarkFastStringMatcher(_: std.mem.Allocator) !void {
    const pattern = "hello";
    const matcher = cpu_opt.FastStringMatcher.init(pattern);

    const texts = [_][]const u8{
        "hello world",
        "say hello there",
        "the quick brown fox",
        "hello again",
        "goodbye world",
    };

    for (texts) |text| {
        _ = matcher.find(text);
    }
}

fn benchmarkStdIndexOf(_: std.mem.Allocator) !void {
    const pattern = "hello";

    const texts = [_][]const u8{
        "hello world",
        "say hello there",
        "the quick brown fox",
        "hello again",
        "goodbye world",
    };

    for (texts) |text| {
        _ = std.mem.indexOf(u8, text, pattern);
    }
}

// Benchmark optimized prefix matching
fn benchmarkOptimizedPrefix(_: std.mem.Allocator) !void {
    const haystack = "hello_world_this_is_a_long_string";
    const needles = [_][]const u8{
        "hello",
        "hell",
        "h",
        "hello_world",
        "xyz",
    };

    for (needles) |needle| {
        _ = cpu_opt.hasPrefix(haystack, needle);
    }
}

fn benchmarkStdPrefix(_: std.mem.Allocator) !void {
    const haystack = "hello_world_this_is_a_long_string";
    const needles = [_][]const u8{
        "hello",
        "hell",
        "h",
        "hello_world",
        "xyz",
    };

    for (needles) |needle| {
        _ = std.mem.startsWith(u8, haystack, needle);
    }
}

// Benchmark fuzzy matching for completion
fn benchmarkFuzzyScore(_: std.mem.Allocator) !void {
    const candidates = [_][]const u8{
        "git-commit",
        "git-checkout",
        "git-clone",
        "git-status",
        "grep",
        "ls",
        "cat",
    };

    const query = "gc";

    for (candidates) |candidate| {
        _ = cpu_opt.fuzzyScore(candidate, query);
    }
}

// Benchmark history index vs linear search
fn benchmarkHistoryIndex(allocator: std.mem.Allocator) !void {
    var index = cpu_opt.HistoryIndex.init(allocator);
    defer index.deinit();

    // Add some history entries
    try index.add("git commit -m 'test'");
    try index.add("git push origin main");
    try index.add("ls -la");
    try index.add("cat file.txt");
    try index.add("grep 'pattern' file.txt");

    // Search multiple times
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = index.search("git");
        _ = index.prefixSearch("ls");
    }
}

fn benchmarkLinearHistorySearch(allocator: std.mem.Allocator) !void {
    // Simulate linear array search
    var history: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (history.items) |item| {
            allocator.free(item);
        }
        history.deinit(allocator);
    }

    // Add some history entries
    try history.append(allocator, try allocator.dupe(u8, "git commit -m 'test'"));
    try history.append(allocator, try allocator.dupe(u8, "git push origin main"));
    try history.append(allocator, try allocator.dupe(u8, "ls -la"));
    try history.append(allocator, try allocator.dupe(u8, "cat file.txt"));
    try history.append(allocator, try allocator.dupe(u8, "grep 'pattern' file.txt"));

    // Linear search multiple times
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        // Search for "git"
        for (history.items) |item| {
            if (std.mem.indexOf(u8, item, "git") != null) {
                break;
            }
        }

        // Prefix search for "ls"
        for (history.items) |item| {
            if (std.mem.startsWith(u8, item, "ls")) {
                break;
            }
        }
    }
}

// Benchmark optimized parser vs regular tokenizer
fn benchmarkOptimizedParser(allocator: std.mem.Allocator) !void {
    const inputs = [_][]const u8{
        "echo hello world",
        "ls -la /tmp",
        "cat file.txt",
        "grep pattern file.txt",
        "find . -name '*.zig'",
    };

    for (inputs) |input| {
        var parser = optimized_parser.OptimizedParser.init(allocator, input);
        _ = try parser.parseSimpleCommand();
    }
}

fn benchmarkStreamingTokenizer(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const inputs = [_][]const u8{
        "echo hello world",
        "ls -la /tmp",
        "cat file.txt",
        "grep pattern file.txt",
        "find . -name '*.zig'",
    };

    for (inputs) |input| {
        var tokenizer = optimized_parser.StreamingTokenizer.init(input);
        while (tokenizer.next()) |token| {
            if (token.type == .eof) break;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var suite = BenchmarkSuite.init(allocator, "CPU Optimization");
    defer suite.deinit();

    const stdout_file = if (builtin.os.tag == .windows) blk: {
        const handle = std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) orelse @panic("Failed to get stdout handle");
        break :blk std.Io.File{ .handle = handle, .flags = .{ .nonblocking = false } };
    } else std.Io.File{ .handle = std.posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } };
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(std.Options.debug_io, &stdout_buffer);

    try stdout_writer.interface.writeAll("Running CPU optimization benchmarks...\n\n");

    // LRU Cache vs No Cache
    {
        var bench = Benchmark.init(allocator, "LRU Cache (100 ops, 16 slots)", 10000);
        const result = try bench.run(benchmarkLRUCache, .{allocator});
        try suite.addResult(result);
    }

    {
        var bench = Benchmark.init(allocator, "No Cache (100 ops)", 10000);
        const result = try bench.run(benchmarkNoCache, .{allocator});
        try suite.addResult(result);
    }

    // Fast String Matcher vs std.mem.indexOf
    {
        var bench = Benchmark.init(allocator, "FastStringMatcher (5 searches)", 10000);
        const result = try bench.run(benchmarkFastStringMatcher, .{allocator});
        try suite.addResult(result);
    }

    {
        var bench = Benchmark.init(allocator, "std.mem.indexOf (5 searches)", 10000);
        const result = try bench.run(benchmarkStdIndexOf, .{allocator});
        try suite.addResult(result);
    }

    // Optimized Prefix vs std.mem.startsWith
    {
        var bench = Benchmark.init(allocator, "Optimized Prefix (5 checks)", 10000);
        const result = try bench.run(benchmarkOptimizedPrefix, .{allocator});
        try suite.addResult(result);
    }

    {
        var bench = Benchmark.init(allocator, "std.mem.startsWith (5 checks)", 10000);
        const result = try bench.run(benchmarkStdPrefix, .{allocator});
        try suite.addResult(result);
    }

    // Fuzzy Score
    {
        var bench = Benchmark.init(allocator, "Fuzzy Score (7 candidates)", 10000);
        const result = try bench.run(benchmarkFuzzyScore, .{allocator});
        try suite.addResult(result);
    }

    // History Index vs Linear Search
    {
        var bench = Benchmark.init(allocator, "History Index (20 searches)", 1000);
        const result = try bench.run(benchmarkHistoryIndex, .{allocator});
        try suite.addResult(result);
    }

    {
        var bench = Benchmark.init(allocator, "Linear Search (20 searches)", 1000);
        const result = try bench.run(benchmarkLinearHistorySearch, .{allocator});
        try suite.addResult(result);
    }

    // Optimized Parser vs Streaming Tokenizer
    {
        var bench = Benchmark.init(allocator, "Optimized Parser (5 commands)", 10000);
        const result = try bench.run(benchmarkOptimizedParser, .{allocator});
        try suite.addResult(result);
    }

    {
        var bench = Benchmark.init(allocator, "Streaming Tokenizer (5 commands)", 10000);
        const result = try bench.run(benchmarkStreamingTokenizer, .{allocator});
        try suite.addResult(result);
    }

    try suite.printSummary(&stdout_writer.interface);
    try stdout_writer.interface.flush();
}
