// Prompt rendering benchmarks for Den Shell
const std = @import("std");
const profiling = @import("profiling");
const Benchmark = profiling.Benchmark;
const BenchmarkSuite = profiling.BenchmarkSuite;

fn benchmarkSimplePromptRender(allocator: std.mem.Allocator) !void {
    // Simulate rendering a simple prompt: "$ "
    const prompt = try allocator.alloc(u8, 2);
    defer allocator.free(prompt);

    prompt[0] = '$';
    prompt[1] = ' ';
}

fn benchmarkComplexPromptRender(allocator: std.mem.Allocator) !void {
    // Simulate rendering complex prompt: user@host:path (git-branch) $
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try buffer.appendSlice("user@host:");
    try buffer.appendSlice("/home/user/project");
    try buffer.appendSlice(" (main)");
    try buffer.appendSlice(" $ ");
}

fn benchmarkGitStatusQuery(_: std.mem.Allocator) !void {
    // Simulate querying git status
    std.time.sleep(100_000); // 0.1ms - simulating git command
}

fn benchmarkColorFormatting(allocator: std.mem.Allocator) !void {
    // Simulate applying color codes
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    const text = "colored text";
    const color_start = "\x1b[32m"; // Green
    const color_end = "\x1b[0m"; // Reset

    try buffer.appendSlice(color_start);
    try buffer.appendSlice(text);
    try buffer.appendSlice(color_end);
}

fn benchmarkPathShortening(allocator: std.mem.Allocator) !void {
    // Simulate shortening a long path
    const path = "/home/user/very/long/path/to/current/directory";

    var parts = std.mem.splitScalar(u8, path, '/');
    var shortened = std.ArrayList(u8).init(allocator);
    defer shortened.deinit();

    var count: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0) continue;

        if (count > 0) {
            try shortened.append('/');
        }

        // Shorten all but last component
        if (parts.peek() != null) {
            try shortened.append(part[0]);
        } else {
            try shortened.appendSlice(part);
        }

        count += 1;
    }
}

fn benchmarkUsernameQuery(allocator: std.mem.Allocator) !void {
    // Simulate querying username
    const username = try allocator.dupe(u8, "testuser");
    defer allocator.free(username);
}

fn benchmarkHostnameQuery(allocator: std.mem.Allocator) !void {
    // Simulate querying hostname
    const hostname = try allocator.dupe(u8, "testhost");
    defer allocator.free(hostname);
}

fn benchmarkVariableExpansion(allocator: std.mem.Allocator) !void {
    // Simulate expanding prompt variables
    const template = "{user}@{host}:{cwd} $ ";

    var expanded = std.ArrayList(u8).init(allocator);
    defer expanded.deinit();

    var i: usize = 0;
    while (i < template.len) : (i += 1) {
        if (template[i] == '{') {
            const end = std.mem.indexOfScalarPos(u8, template, i, '}') orelse continue;
            const var_name = template[i + 1 .. end];

            if (std.mem.eql(u8, var_name, "user")) {
                try expanded.appendSlice("testuser");
            } else if (std.mem.eql(u8, var_name, "host")) {
                try expanded.appendSlice("testhost");
            } else if (std.mem.eql(u8, var_name, "cwd")) {
                try expanded.appendSlice("/home/user");
            }

            i = end;
        } else {
            try expanded.append(template[i]);
        }
    }
}

fn benchmarkRightPromptRender(allocator: std.mem.Allocator) !void {
    // Simulate rendering right-aligned prompt
    const terminal_width: usize = 80;
    const left_prompt = "$ ";
    const right_prompt = "12:34:56";

    const spaces_needed = terminal_width - left_prompt.len - right_prompt.len;

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try buffer.appendSlice(left_prompt);
    try buffer.appendNTimes(' ', spaces_needed);
    try buffer.appendSlice(right_prompt);
}

fn benchmarkTransientPrompt(allocator: std.mem.Allocator) !void {
    // Simulate converting complex prompt to simple one
    const simple = try allocator.dupe(u8, "$ ");
    defer allocator.free(simple);
}

fn benchmarkModuleDetection(allocator: std.mem.Allocator) !void {
    // Simulate detecting which modules to show
    const files = [_][]const u8{ "package.json", "Cargo.toml", ".python-version" };

    var modules = std.ArrayList([]const u8).init(allocator);
    defer modules.deinit();

    for (files) |file| {
        if (std.mem.eql(u8, file, "package.json")) {
            try modules.append("node");
        } else if (std.mem.eql(u8, file, "Cargo.toml")) {
            try modules.append("rust");
        } else if (std.mem.eql(u8, file, ".python-version")) {
            try modules.append("python");
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var suite = BenchmarkSuite.init(allocator, "Prompt Rendering");
    defer suite.deinit();

    const stdout = std.io.getStdOut().writer();

    try stdout.writeAll("Running prompt rendering benchmarks...\n\n");

    // Simple prompt
    {
        var bench = Benchmark.init(allocator, "Simple Prompt Render", 100000);
        const result = try bench.run(benchmarkSimplePromptRender, .{allocator});
        try suite.addResult(result);
    }

    // Complex prompt
    {
        var bench = Benchmark.init(allocator, "Complex Prompt Render", 10000);
        const result = try bench.run(benchmarkComplexPromptRender, .{allocator});
        try suite.addResult(result);
    }

    // Git status query
    {
        var bench = Benchmark.init(allocator, "Git Status Query", 100);
        const result = try bench.run(benchmarkGitStatusQuery, .{allocator});
        try suite.addResult(result);
    }

    // Color formatting
    {
        var bench = Benchmark.init(allocator, "Color Formatting", 10000);
        const result = try bench.run(benchmarkColorFormatting, .{allocator});
        try suite.addResult(result);
    }

    // Path shortening
    {
        var bench = Benchmark.init(allocator, "Path Shortening", 10000);
        const result = try bench.run(benchmarkPathShortening, .{allocator});
        try suite.addResult(result);
    }

    // Username query
    {
        var bench = Benchmark.init(allocator, "Username Query", 10000);
        const result = try bench.run(benchmarkUsernameQuery, .{allocator});
        try suite.addResult(result);
    }

    // Hostname query
    {
        var bench = Benchmark.init(allocator, "Hostname Query", 10000);
        const result = try bench.run(benchmarkHostnameQuery, .{allocator});
        try suite.addResult(result);
    }

    // Variable expansion
    {
        var bench = Benchmark.init(allocator, "Variable Expansion", 10000);
        const result = try bench.run(benchmarkVariableExpansion, .{allocator});
        try suite.addResult(result);
    }

    // Right prompt
    {
        var bench = Benchmark.init(allocator, "Right Prompt Render", 10000);
        const result = try bench.run(benchmarkRightPromptRender, .{allocator});
        try suite.addResult(result);
    }

    // Transient prompt
    {
        var bench = Benchmark.init(allocator, "Transient Prompt", 10000);
        const result = try bench.run(benchmarkTransientPrompt, .{allocator});
        try suite.addResult(result);
    }

    // Module detection
    {
        var bench = Benchmark.init(allocator, "Module Detection", 10000);
        const result = try bench.run(benchmarkModuleDetection, .{allocator});
        try suite.addResult(result);
    }

    try suite.printSummary(stdout);
}
