const std = @import("std");

// ============================================================================
// Performance Tests for Den Shell
// Benchmarks key shell operations: tokenizing, parsing, history, completion
// ============================================================================

const BENCHMARK_ITERATIONS = 1000;
const WARMUP_ITERATIONS = 100;

/// Timer utility for benchmarking
const Timer = struct {
    start_time: std.time.Instant,

    pub fn start() Timer {
        return .{
            .start_time = std.time.Instant.now() catch unreachable,
        };
    }

    pub fn elapsed(self: Timer) u64 {
        const end = std.time.Instant.now() catch unreachable;
        return end.since(self.start_time);
    }
};

/// Benchmark result structure
const BenchmarkResult = struct {
    name: []const u8,
    iterations: usize,
    total_ns: u64,
    min_ns: u64,
    max_ns: u64,
    mean_ns: f64,
    ops_per_sec: f64,

    pub fn print(self: BenchmarkResult) void {
        std.debug.print("\n{s}:\n", .{self.name});
        std.debug.print("  Iterations: {d}\n", .{self.iterations});
        std.debug.print("  Mean:       {d:.3} us\n", .{self.mean_ns / 1000.0});
        std.debug.print("  Min:        {d:.3} us\n", .{@as(f64, @floatFromInt(self.min_ns)) / 1000.0});
        std.debug.print("  Max:        {d:.3} us\n", .{@as(f64, @floatFromInt(self.max_ns)) / 1000.0});
        std.debug.print("  Ops/sec:    {d:.0}\n", .{self.ops_per_sec});
    }
};

/// Run a benchmark with the given function
fn runBenchmark(
    name: []const u8,
    comptime func: anytype,
    args: anytype,
    iterations: usize,
) BenchmarkResult {
    // Warmup
    for (0..WARMUP_ITERATIONS) |_| {
        _ = @call(.auto, func, args);
    }

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    for (0..iterations) |_| {
        const timer = Timer.start();
        _ = @call(.auto, func, args);
        const elapsed = timer.elapsed();

        total_ns += elapsed;
        min_ns = @min(min_ns, elapsed);
        max_ns = @max(max_ns, elapsed);
    }

    const mean_ns = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iterations));
    const ops_per_sec = 1_000_000_000.0 / mean_ns;

    return .{
        .name = name,
        .iterations = iterations,
        .total_ns = total_ns,
        .min_ns = min_ns,
        .max_ns = max_ns,
        .mean_ns = mean_ns,
        .ops_per_sec = ops_per_sec,
    };
}

// ============================================================================
// Tokenizer Performance Tests
// ============================================================================

/// Simple tokenizer benchmark - tokenize a command string
fn tokenizeSimple(input: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    var in_word = false;

    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c == ' ' or c == '\t') {
            if (in_word) {
                count += 1;
                in_word = false;
            }
        } else if (c == '|' or c == '&' or c == ';' or c == '>' or c == '<') {
            if (in_word) count += 1;
            count += 1;
            in_word = false;
        } else {
            in_word = true;
        }
    }
    if (in_word) count += 1;
    return count;
}

test "perf: tokenize simple command" {
    const result = runBenchmark(
        "Tokenize 'echo hello world'",
        tokenizeSimple,
        .{"echo hello world"},
        BENCHMARK_ITERATIONS,
    );
    result.print();
    try std.testing.expect(result.mean_ns < 10_000_000); // < 10ms
}

test "perf: tokenize pipeline" {
    const result = runBenchmark(
        "Tokenize 'ls -la | grep foo | sort | head -10'",
        tokenizeSimple,
        .{"ls -la | grep foo | sort | head -10"},
        BENCHMARK_ITERATIONS,
    );
    result.print();
    try std.testing.expect(result.mean_ns < 10_000_000);
}

test "perf: tokenize complex command" {
    const complex_cmd = "for i in $(seq 1 10); do echo $i && sleep 0.1; done | tee output.log 2>&1";
    const result = runBenchmark(
        "Tokenize complex for loop",
        tokenizeSimple,
        .{complex_cmd},
        BENCHMARK_ITERATIONS,
    );
    result.print();
    try std.testing.expect(result.mean_ns < 10_000_000);
}

// ============================================================================
// String Operations Performance Tests
// ============================================================================

/// Variable expansion simulation
fn expandVariables(allocator: std.mem.Allocator, input: []const u8, vars: *const std.StringHashMap([]const u8)) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '$' and i + 1 < input.len) {
            // Find variable name
            var end = i + 1;
            while (end < input.len and (std.ascii.isAlphanumeric(input[end]) or input[end] == '_')) {
                end += 1;
            }
            const var_name = input[i + 1 .. end];
            if (vars.get(var_name)) |value| {
                try result.appendSlice(allocator, value);
            }
            i = end;
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

test "perf: variable expansion" {
    const allocator = std.testing.allocator;

    var vars = std.StringHashMap([]const u8).init(allocator);
    defer vars.deinit();
    try vars.put("HOME", "/home/user");
    try vars.put("USER", "testuser");
    try vars.put("PATH", "/usr/bin:/bin:/usr/local/bin");

    const input = "echo $HOME/$USER and $PATH";

    // Warmup
    for (0..WARMUP_ITERATIONS) |_| {
        const result = try expandVariables(allocator, input, &vars);
        allocator.free(result);
    }

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    for (0..BENCHMARK_ITERATIONS) |_| {
        const timer = Timer.start();
        const result = try expandVariables(allocator, input, &vars);
        const elapsed = timer.elapsed();
        allocator.free(result);

        total_ns += elapsed;
        min_ns = @min(min_ns, elapsed);
        max_ns = @max(max_ns, elapsed);
    }

    const mean_ns = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(BENCHMARK_ITERATIONS));

    std.debug.print("\nVariable expansion:\n", .{});
    std.debug.print("  Mean: {d:.3} us\n", .{mean_ns / 1000.0});
    std.debug.print("  Min:  {d:.3} us\n", .{@as(f64, @floatFromInt(min_ns)) / 1000.0});
    std.debug.print("  Max:  {d:.3} us\n", .{@as(f64, @floatFromInt(max_ns)) / 1000.0});

    try std.testing.expect(mean_ns < 10_000_000);
}

// ============================================================================
// History Operations Performance Tests
// ============================================================================

/// Simulated history search
fn searchHistory(history: []const []const u8, pattern: []const u8) ?[]const u8 {
    var i = history.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.indexOf(u8, history[i], pattern) != null) {
            return history[i];
        }
    }
    return null;
}

test "perf: history search" {
    // Create simulated history
    const history = [_][]const u8{
        "cd /home/user",
        "ls -la",
        "git status",
        "vim config.zig",
        "zig build",
        "./zig-out/bin/den",
        "grep -r 'function' src/",
        "make clean",
        "cargo build --release",
        "npm install",
        "docker ps",
        "kubectl get pods",
        "ssh user@server",
        "scp file.txt remote:/tmp/",
        "tar -xzf archive.tar.gz",
        "find . -name '*.zig'",
        "cat /etc/passwd",
        "echo $HOME",
        "export PATH=$PATH:/new/path",
        "history | grep git",
    };

    const result = runBenchmark(
        "History search (20 entries)",
        searchHistory,
        .{ &history, "git" },
        BENCHMARK_ITERATIONS,
    );
    result.print();
    try std.testing.expect(result.mean_ns < 1_000_000); // < 1ms
}

test "perf: history search large" {
    const allocator = std.testing.allocator;

    // Create larger history
    const history = try allocator.alloc([]const u8, 1000);
    defer allocator.free(history);

    for (history, 0..) |*entry, i| {
        entry.* = if (i % 10 == 0) "git commit -m 'update'" else "echo hello";
    }

    const timer = Timer.start();
    for (0..BENCHMARK_ITERATIONS) |_| {
        _ = searchHistory(history, "commit");
    }
    const elapsed = timer.elapsed();

    const mean_ns = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(BENCHMARK_ITERATIONS));

    std.debug.print("\nHistory search (1000 entries):\n", .{});
    std.debug.print("  Mean: {d:.3} us\n", .{mean_ns / 1000.0});

    try std.testing.expect(mean_ns < 10_000_000);
}

// ============================================================================
// Completion Performance Tests
// ============================================================================

/// Simulated prefix completion matching
fn findCompletions(allocator: std.mem.Allocator, candidates: []const []const u8, prefix: []const u8) ![][]const u8 {
    var matches = std.ArrayList([]const u8).empty;
    errdefer matches.deinit(allocator);

    for (candidates) |candidate| {
        if (std.mem.startsWith(u8, candidate, prefix)) {
            try matches.append(allocator, candidate);
        }
    }

    return matches.toOwnedSlice(allocator);
}

test "perf: completion matching" {
    const allocator = std.testing.allocator;

    const candidates = [_][]const u8{
        "build", "build.zig", "builtin", "bundle",
        "cat", "cd", "chmod", "chown", "clear", "cp", "curl",
        "diff", "docker", "du",
        "echo", "env", "exit", "export",
        "find", "fg",
        "git", "grep", "gzip",
        "head", "history", "htop",
    };

    // Warmup
    for (0..WARMUP_ITERATIONS) |_| {
        const result = try findCompletions(allocator, &candidates, "gi");
        allocator.free(result);
    }

    var total_ns: u64 = 0;

    for (0..BENCHMARK_ITERATIONS) |_| {
        const timer = Timer.start();
        const result = try findCompletions(allocator, &candidates, "gi");
        total_ns += timer.elapsed();
        allocator.free(result);
    }

    const mean_ns = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(BENCHMARK_ITERATIONS));

    std.debug.print("\nCompletion matching ({d} candidates):\n", .{candidates.len});
    std.debug.print("  Mean: {d:.3} us\n", .{mean_ns / 1000.0});

    try std.testing.expect(mean_ns < 1_000_000);
}

// ============================================================================
// Memory Allocation Performance Tests
// ============================================================================

test "perf: arena allocator throughput" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const timer = Timer.start();

    for (0..BENCHMARK_ITERATIONS) |_| {
        // Simulate typical shell operation allocations
        const cmd = try allocator.alloc(u8, 256);
        _ = cmd;
        const args = try allocator.alloc([]const u8, 16);
        _ = args;
        const env = try allocator.alloc(u8, 1024);
        _ = env;
    }

    const elapsed = timer.elapsed();
    const mean_ns = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(BENCHMARK_ITERATIONS));

    std.debug.print("\nArena allocator (3 allocs/iter):\n", .{});
    std.debug.print("  Mean: {d:.3} us\n", .{mean_ns / 1000.0});
    std.debug.print("  Allocs/sec: {d:.0}\n", .{3_000_000_000.0 / mean_ns});

    try std.testing.expect(mean_ns < 10_000_000);
}

// ============================================================================
// String Manipulation Performance Tests
// ============================================================================

test "perf: string splitting" {
    const allocator = std.testing.allocator;
    const input = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin";

    var total_ns: u64 = 0;

    for (0..BENCHMARK_ITERATIONS) |_| {
        const timer = Timer.start();

        var parts = std.ArrayList([]const u8).empty;
        defer parts.deinit(allocator);

        var iter = std.mem.splitScalar(u8, input, ':');
        while (iter.next()) |part| {
            try parts.append(allocator, part);
        }

        total_ns += timer.elapsed();
    }

    const mean_ns = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(BENCHMARK_ITERATIONS));

    std.debug.print("\nPATH string splitting:\n", .{});
    std.debug.print("  Mean: {d:.3} us\n", .{mean_ns / 1000.0});

    try std.testing.expect(mean_ns < 1_000_000);
}

// ============================================================================
// Glob Pattern Matching Performance Tests
// ============================================================================

/// Simple glob pattern matching
fn globMatch(pattern: []const u8, text: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    var star_pi: ?usize = null;
    var star_ti: usize = 0;

    while (ti < text.len) {
        if (pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == text[ti])) {
            pi += 1;
            ti += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_ti = ti;
            pi += 1;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_ti += 1;
            ti = star_ti;
        } else {
            return false;
        }
    }

    while (pi < pattern.len and pattern[pi] == '*') {
        pi += 1;
    }

    return pi == pattern.len;
}

test "perf: glob pattern matching" {
    const patterns = [_]struct { pattern: []const u8, text: []const u8 }{
        .{ .pattern = "*.zig", .text = "build.zig" },
        .{ .pattern = "test_*.zig", .text = "test_performance.zig" },
        .{ .pattern = "src/**/mod.zig", .text = "src/parser/mod.zig" },
        .{ .pattern = "*.?", .text = "file.c" },
        .{ .pattern = "hello*world", .text = "hello_beautiful_world" },
    };

    const timer = Timer.start();

    for (0..BENCHMARK_ITERATIONS) |_| {
        for (patterns) |p| {
            _ = globMatch(p.pattern, p.text);
        }
    }

    const elapsed = timer.elapsed();
    const mean_ns = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(BENCHMARK_ITERATIONS * patterns.len));

    std.debug.print("\nGlob pattern matching:\n", .{});
    std.debug.print("  Mean per match: {d:.3} us\n", .{mean_ns / 1000.0});
    std.debug.print("  Matches/sec: {d:.0}\n", .{1_000_000_000.0 / mean_ns});

    try std.testing.expect(mean_ns < 100_000); // < 100us per match
}

// ============================================================================
// Summary Test
// ============================================================================

test "perf: summary" {
    std.debug.print("\n", .{});
    std.debug.print("=" ** 60 ++ "\n", .{});
    std.debug.print("Performance Test Summary\n", .{});
    std.debug.print("=" ** 60 ++ "\n", .{});
    std.debug.print("All performance benchmarks completed.\n", .{});
    std.debug.print("Iterations per test: {d}\n", .{BENCHMARK_ITERATIONS});
    std.debug.print("Warmup iterations: {d}\n", .{WARMUP_ITERATIONS});
    std.debug.print("=" ** 60 ++ "\n\n", .{});
}
