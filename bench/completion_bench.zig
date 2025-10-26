// Completion generation benchmarks for Den Shell
const std = @import("std");
const profiling = @import("profiling");
const Benchmark = profiling.Benchmark;
const BenchmarkSuite = profiling.BenchmarkSuite;

// Mock completion generation
fn benchmarkCommandCompletion(allocator: std.mem.Allocator) !void {
    // Simulate completing from 100 available commands
    var completions = std.ArrayList([]const u8){ };
    defer {
        for (completions.items) |completion| {
            allocator.free(completion);
        }
        completions.deinit(allocator);
    }

    const prefix = "ec";
    const commands = [_][]const u8{ "echo", "ed", "egrep", "env", "export" };

    for (commands) |cmd| {
        if (std.mem.startsWith(u8, cmd, prefix)) {
            const completion = try allocator.dupe(u8, cmd);
            try completions.append(allocator, completion);
        }
    }
}

fn benchmarkFileCompletion(allocator: std.mem.Allocator) !void {
    // Simulate file path completion with 50 files
    var completions = std.ArrayList([]const u8){ };
    defer {
        for (completions.items) |completion| {
            allocator.free(completion);
        }
        completions.deinit(allocator);
    }

    const prefix = "test";
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const filename = try std.fmt.allocPrint(allocator, "testfile{d}.txt", .{i});
        if (std.mem.startsWith(u8, filename, prefix)) {
            try completions.append(allocator, filename);
        } else {
            allocator.free(filename);
        }
    }
}

fn benchmarkPathSearch(allocator: std.mem.Allocator) !void {
    // Simulate PATH search for executables
    var executables = std.ArrayList([]const u8){ };
    defer {
        for (executables.items) |exe| {
            allocator.free(exe);
        }
        executables.deinit(allocator);
    }

    // Simulate scanning 10 PATH directories with 50 executables each
    var dir: usize = 0;
    while (dir < 10) : (dir += 1) {
        var file: usize = 0;
        while (file < 50) : (file += 1) {
            const exe = try std.fmt.allocPrint(allocator, "cmd{d}", .{file});
            try executables.append(allocator, exe);
        }
    }
}

fn benchmarkFuzzyMatch(allocator: std.mem.Allocator) !void {
    // Simulate fuzzy matching algorithm
    const input = "gc";
    const candidates = [_][]const u8{
        "git-commit",
        "git-checkout",
        "git-clone",
        "gcc",
        "grep-color",
    };

    var matches = std.ArrayList([]const u8){ };
    defer {
        for (matches.items) |match| {
            allocator.free(match);
        }
        matches.deinit(allocator);
    }

    for (candidates) |candidate| {
        // Simple fuzzy match: check if all characters appear in order
        var input_idx: usize = 0;

        for (candidate) |c| {
            if (input_idx < input.len and c == input[input_idx]) {
                input_idx += 1;
            }
        }

        if (input_idx == input.len) {
            const match = try allocator.dupe(u8, candidate);
            try matches.append(allocator, match);
        }
    }
}

fn benchmarkCompletionRanking(allocator: std.mem.Allocator) !void {
    // Simulate ranking completion results
    const Completion = struct {
        text: []const u8,
        score: i32,
    };

    var completions: std.ArrayList(Completion) = .{};
    defer completions.deinit(allocator);

    // Add 100 completions with random scores
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try completions.append(allocator, .{
            .text = "completion",
            .score = @as(i32, @intCast(i % 50)),
        });
    }

    // Sort by score
    std.mem.sort(Completion, completions.items, {}, struct {
        fn compare(_: void, a: Completion, b: Completion) bool {
            return a.score > b.score;
        }
    }.compare);
}

fn benchmarkAliasExpansion(allocator: std.mem.Allocator) !void {
    // Simulate alias expansion in completion
    var aliases = std.StringHashMap([]const u8).init(allocator);
    defer aliases.deinit();

    try aliases.put("ll", "ls -lah");
    try aliases.put("gs", "git status");
    try aliases.put("gc", "git commit");
    try aliases.put("gp", "git push");

    const input = "gs";
    const expanded = aliases.get(input);
    _ = expanded;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var suite = BenchmarkSuite.init(allocator, "Completion Generation");
    defer suite.deinit();

    const stdout_file = std.fs.File{
        .handle = std.posix.STDOUT_FILENO,
    };
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buffer);

    try stdout_writer.interface.writeAll("Running completion generation benchmarks...\n\n");

    // Command completion
    {
        var bench = Benchmark.init(allocator, "Command Completion", 10000);
        const result = try bench.run(benchmarkCommandCompletion, .{allocator});
        try suite.addResult(result);
    }

    // File completion
    {
        var bench = Benchmark.init(allocator, "File Completion (50 files)", 1000);
        const result = try bench.run(benchmarkFileCompletion, .{allocator});
        try suite.addResult(result);
    }

    // PATH search
    {
        var bench = Benchmark.init(allocator, "PATH Search (500 executables)", 1000);
        const result = try bench.run(benchmarkPathSearch, .{allocator});
        try suite.addResult(result);
    }

    // Fuzzy matching
    {
        var bench = Benchmark.init(allocator, "Fuzzy Match", 10000);
        const result = try bench.run(benchmarkFuzzyMatch, .{allocator});
        try suite.addResult(result);
    }

    // Completion ranking
    {
        var bench = Benchmark.init(allocator, "Completion Ranking (100 items)", 1000);
        const result = try bench.run(benchmarkCompletionRanking, .{allocator});
        try suite.addResult(result);
    }

    // Alias expansion
    {
        var bench = Benchmark.init(allocator, "Alias Expansion", 10000);
        const result = try bench.run(benchmarkAliasExpansion, .{allocator});
        try suite.addResult(result);
    }

    try suite.printSummary(&stdout_writer.interface);
    try stdout_writer.interface.flush();
}
