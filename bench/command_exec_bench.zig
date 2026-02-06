// Command execution benchmarks for Den Shell
const std = @import("std");
const builtin = @import("builtin");
const profiling = @import("profiling");
const Benchmark = profiling.Benchmark;
const BenchmarkSuite = profiling.BenchmarkSuite;

// Mock command execution stages
fn benchmarkParsing(allocator: std.mem.Allocator) !void {
    // Simulate parsing a simple command
    const tokens = try allocator.alloc([]const u8, 3);
    defer allocator.free(tokens);

    tokens[0] = "echo";
    tokens[1] = "hello";
    tokens[2] = "world";
}

fn benchmarkComplexParsing(allocator: std.mem.Allocator) !void {
    // Simulate parsing a complex command with pipes and redirections
    const tokens = try allocator.alloc([]const u8, 12);
    defer allocator.free(tokens);

    var i: usize = 0;
    while (i < 12) : (i += 1) {
        tokens[i] = "token";
    }
}

fn benchmarkVariableExpansion(allocator: std.mem.Allocator) !void {
    // Simulate variable expansion
    var map = std.StringHashMap([]const u8).init(allocator);
    defer map.deinit();

    try map.put("PATH", "/usr/bin:/bin");
    try map.put("HOME", "/home/user");
    try map.put("USER", "testuser");

    const value = map.get("PATH");
    _ = value;
}

fn benchmarkGlobExpansion(allocator: std.mem.Allocator) !void {
    // Simulate glob pattern expansion
    var matches = std.ArrayList([]const u8){ };
    defer {
        for (matches.items) |match| {
            allocator.free(match);
        }
        matches.deinit(allocator);
    }

    // Simulate finding 10 matches
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const match = try std.fmt.allocPrint(allocator, "file{d}.txt", .{i});
        try matches.append(allocator, match);
    }
}

fn benchmarkProcessSpawn(_: std.mem.Allocator) !void {
    // Simulate process spawn overhead
    std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromNanoseconds(@as(i96, 50_000)), .awake) catch {}; // 0.05ms
}

fn benchmarkPipeSetup(allocator: std.mem.Allocator) !void {
    // Simulate pipe setup
    if (builtin.os.tag == .windows) {
        // Windows: just allocate placeholder
        const pipes = try allocator.alloc([2]usize, 2);
        defer allocator.free(pipes);
        var i: usize = 0;
        while (i < 2) : (i += 1) {
            pipes[i] = .{ 0, 1 };
        }
    } else {
        // POSIX: use fd_t
        const pipes = try allocator.alloc([2]std.posix.fd_t, 2);
        defer allocator.free(pipes);
        var i: usize = 0;
        while (i < 2) : (i += 1) {
            pipes[i] = .{ 0, 1 };
        }
    }
}

fn benchmarkRedirection(allocator: std.mem.Allocator) !void {
    // Simulate file redirection setup
    const redirects = try allocator.alloc([]const u8, 2);
    defer allocator.free(redirects);

    redirects[0] = "input.txt";
    redirects[1] = "output.txt";
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var suite = BenchmarkSuite.init(allocator, "Command Execution");
    defer suite.deinit();

    const stdout_file = if (builtin.os.tag == .windows) blk: {
        const handle = std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) orelse @panic("Failed to get stdout handle");
        break :blk std.Io.File{ .handle = handle, .flags = .{ .nonblocking = false } };
    } else std.Io.File{ .handle = std.posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } };
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(std.Options.debug_io, &stdout_buffer);

    try stdout_writer.interface.writeAll("Running command execution benchmarks...\n\n");

    // Simple parsing
    {
        var bench = Benchmark.init(allocator, "Simple Command Parsing", 10000);
        const result = try bench.run(benchmarkParsing, .{allocator});
        try suite.addResult(result);
    }

    // Complex parsing
    {
        var bench = Benchmark.init(allocator, "Complex Command Parsing", 10000);
        const result = try bench.run(benchmarkComplexParsing, .{allocator});
        try suite.addResult(result);
    }

    // Variable expansion
    {
        var bench = Benchmark.init(allocator, "Variable Expansion", 10000);
        const result = try bench.run(benchmarkVariableExpansion, .{allocator});
        try suite.addResult(result);
    }

    // Glob expansion
    {
        var bench = Benchmark.init(allocator, "Glob Expansion (10 matches)", 1000);
        const result = try bench.run(benchmarkGlobExpansion, .{allocator});
        try suite.addResult(result);
    }

    // Process spawn
    {
        var bench = Benchmark.init(allocator, "Process Spawn", 1000);
        const result = try bench.run(benchmarkProcessSpawn, .{allocator});
        try suite.addResult(result);
    }

    // Pipe setup
    {
        var bench = Benchmark.init(allocator, "Pipe Setup", 10000);
        const result = try bench.run(benchmarkPipeSetup, .{allocator});
        try suite.addResult(result);
    }

    // Redirection
    {
        var bench = Benchmark.init(allocator, "Redirection Setup", 10000);
        const result = try bench.run(benchmarkRedirection, .{allocator});
        try suite.addResult(result);
    }

    try suite.printSummary(&stdout_writer.interface);
    try stdout_writer.interface.flush();
}
