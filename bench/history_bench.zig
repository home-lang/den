// History search benchmarks for Den Shell
const std = @import("std");
const profiling = @import("profiling");
const Benchmark = profiling.Benchmark;
const BenchmarkSuite = profiling.BenchmarkSuite;

// Mock history entry
const HistoryEntry = struct {
    command: []const u8,
    timestamp: i64,
};

fn benchmarkLinearSearch(allocator: std.mem.Allocator) !void {
    // Create 10000 history entries
    var history = std.ArrayList(HistoryEntry).init(allocator);
    defer {
        for (history.items) |entry| {
            allocator.free(entry.command);
        }
        history.deinit();
    }

    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        const cmd = try std.fmt.allocPrint(allocator, "command {d}", .{i});
        try history.append(.{
            .command = cmd,
            .timestamp = @as(i64, @intCast(i)),
        });
    }

    // Search for pattern
    const pattern = "command 5000";
    for (history.items) |entry| {
        if (std.mem.eql(u8, entry.command, pattern)) {
            break;
        }
    }
}

fn benchmarkPrefixSearch(allocator: std.mem.Allocator) !void {
    // Create history entries
    var history = std.ArrayList(HistoryEntry).init(allocator);
    defer {
        for (history.items) |entry| {
            allocator.free(entry.command);
        }
        history.deinit();
    }

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const cmd = try std.fmt.allocPrint(allocator, "git command {d}", .{i});
        try history.append(.{
            .command = cmd,
            .timestamp = @as(i64, @intCast(i)),
        });
    }

    // Search for prefix
    const prefix = "git commit";
    var matches = std.ArrayList(*HistoryEntry).init(allocator);
    defer matches.deinit();

    for (history.items) |*entry| {
        if (std.mem.startsWith(u8, entry.command, prefix)) {
            try matches.append(entry);
        }
    }
}

fn benchmarkSubstringSearch(allocator: std.mem.Allocator) !void {
    // Create history entries
    var history = std.ArrayList(HistoryEntry).init(allocator);
    defer {
        for (history.items) |entry| {
            allocator.free(entry.command);
        }
        history.deinit();
    }

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const cmd = try std.fmt.allocPrint(allocator, "some long command with pattern {d}", .{i});
        try history.append(.{
            .command = cmd,
            .timestamp = @as(i64, @intCast(i)),
        });
    }

    // Search for substring
    const substring = "pattern";
    var matches = std.ArrayList(*HistoryEntry).init(allocator);
    defer matches.deinit();

    for (history.items) |*entry| {
        if (std.mem.indexOf(u8, entry.command, substring) != null) {
            try matches.append(entry);
        }
    }
}

fn benchmarkDuplicateRemoval(allocator: std.mem.Allocator) !void {
    // Create history with duplicates
    var history = std.ArrayList(HistoryEntry).init(allocator);
    defer {
        for (history.items) |entry| {
            allocator.free(entry.command);
        }
        history.deinit();
    }

    // Add some duplicates
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const cmd_num = i % 100; // Create duplicates
        const cmd = try std.fmt.allocPrint(allocator, "command {d}", .{cmd_num});
        try history.append(.{
            .command = cmd,
            .timestamp = @as(i64, @intCast(i)),
        });
    }

    // Remove duplicates using a hash set
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var unique = std.ArrayList(HistoryEntry).init(allocator);
    defer unique.deinit();

    for (history.items) |entry| {
        const result = try seen.getOrPut(entry.command);
        if (!result.found_existing) {
            try unique.append(entry);
        }
    }
}

fn benchmarkTimeRangeFilter(allocator: std.mem.Allocator) !void {
    // Create history entries
    var history = std.ArrayList(HistoryEntry).init(allocator);
    defer {
        for (history.items) |entry| {
            allocator.free(entry.command);
        }
        history.deinit();
    }

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const cmd = try std.fmt.allocPrint(allocator, "command {d}", .{i});
        try history.append(.{
            .command = cmd,
            .timestamp = @as(i64, @intCast(i * 1000)),
        });
    }

    // Filter by time range
    const start_time: i64 = 100000;
    const end_time: i64 = 500000;

    var filtered = std.ArrayList(*HistoryEntry).init(allocator);
    defer filtered.deinit();

    for (history.items) |*entry| {
        if (entry.timestamp >= start_time and entry.timestamp <= end_time) {
            try filtered.append(entry);
        }
    }
}

fn benchmarkHistoryPersistence(allocator: std.mem.Allocator) !void {
    // Simulate writing history to file
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const line = try std.fmt.allocPrint(allocator, "{d}:command {d}\n", .{ i * 1000, i });
        defer allocator.free(line);
        try buffer.appendSlice(line);
    }
}

fn benchmarkHistoryLoad(allocator: std.mem.Allocator) !void {
    // Simulate loading history from buffer
    const data = "1000:git commit\n2000:git push\n3000:ls -la\n4000:cd /tmp\n";

    var history = std.ArrayList(HistoryEntry).init(allocator);
    defer {
        for (history.items) |entry| {
            allocator.free(entry.command);
        }
        history.deinit();
    }

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        if (std.mem.indexOf(u8, line, ":")) |colon_idx| {
            const timestamp_str = line[0..colon_idx];
            const command = line[colon_idx + 1 ..];

            const timestamp = std.fmt.parseInt(i64, timestamp_str, 10) catch continue;
            const cmd_copy = try allocator.dupe(u8, command);

            try history.append(.{
                .command = cmd_copy,
                .timestamp = timestamp,
            });
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var suite = BenchmarkSuite.init(allocator, "History Search");
    defer suite.deinit();

    const stdout = std.io.getStdOut().writer();

    try stdout.writeAll("Running history search benchmarks...\n\n");

    // Linear search
    {
        var bench = Benchmark.init(allocator, "Linear Search (10k entries)", 100);
        const result = try bench.run(benchmarkLinearSearch, .{allocator});
        try suite.addResult(result);
    }

    // Prefix search
    {
        var bench = Benchmark.init(allocator, "Prefix Search (1k entries)", 1000);
        const result = try bench.run(benchmarkPrefixSearch, .{allocator});
        try suite.addResult(result);
    }

    // Substring search
    {
        var bench = Benchmark.init(allocator, "Substring Search (1k entries)", 1000);
        const result = try bench.run(benchmarkSubstringSearch, .{allocator});
        try suite.addResult(result);
    }

    // Duplicate removal
    {
        var bench = Benchmark.init(allocator, "Duplicate Removal (1k entries)", 1000);
        const result = try bench.run(benchmarkDuplicateRemoval, .{allocator});
        try suite.addResult(result);
    }

    // Time range filter
    {
        var bench = Benchmark.init(allocator, "Time Range Filter (1k entries)", 1000);
        const result = try bench.run(benchmarkTimeRangeFilter, .{allocator});
        try suite.addResult(result);
    }

    // History persistence
    {
        var bench = Benchmark.init(allocator, "History Write (100 entries)", 1000);
        const result = try bench.run(benchmarkHistoryPersistence, .{allocator});
        try suite.addResult(result);
    }

    // History load
    {
        var bench = Benchmark.init(allocator, "History Load", 10000);
        const result = try bench.run(benchmarkHistoryLoad, .{allocator});
        try suite.addResult(result);
    }

    try suite.printSummary(stdout);
}
