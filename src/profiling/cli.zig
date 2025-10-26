// Profiling CLI tool for Den Shell
const std = @import("std");
const Profiler = @import("profiler.zig").Profiler;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printHelp();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printHelp();
    } else if (std.mem.eql(u8, command, "run")) {
        if (args.len < 3) {
            std.debug.print("Error: benchmark name required\n", .{});
            try printHelp();
            return error.InvalidArgs;
        }
        try runBenchmark(allocator, args[2]);
    } else if (std.mem.eql(u8, command, "list")) {
        try listBenchmarks();
    } else if (std.mem.eql(u8, command, "all")) {
        try runAllBenchmarks(allocator);
    } else {
        std.debug.print("Error: unknown command '{s}'\n", .{command});
        try printHelp();
        return error.UnknownCommand;
    }
}

fn printHelp() !void {
    const stdout_file = std.fs.File{
        .handle = std.posix.STDOUT_FILENO,
    };
    var buffer: [4096]u8 = undefined;
    var writer = stdout_file.writer(&buffer);
    defer writer.interface.flush() catch {};

    try writer.interface.writeAll(
        \\Den Shell Profiling Tool
        \\
        \\Usage: den-profile COMMAND [OPTIONS]
        \\
        \\Commands:
        \\  run NAME     Run a specific benchmark
        \\  list         List all available benchmarks
        \\  all          Run all benchmarks
        \\  help         Show this help message
        \\
        \\Available Benchmarks:
        \\  startup      Measure shell startup time
        \\  command      Measure command execution
        \\  completion   Measure completion generation
        \\  history      Measure history search
        \\  prompt       Measure prompt rendering
        \\
        \\Examples:
        \\  den-profile run startup
        \\  den-profile run completion
        \\  den-profile all
        \\
        \\Output:
        \\  Benchmarks report timing statistics including:
        \\  - Mean execution time
        \\  - Median execution time
        \\  - Min/Max times
        \\  - Standard deviation
        \\
    );
}

fn listBenchmarks() !void {
    const stdout_file = std.fs.File{
        .handle = std.posix.STDOUT_FILENO,
    };
    var buffer: [4096]u8 = undefined;
    var writer = stdout_file.writer(&buffer);
    defer writer.interface.flush() catch {};

    try writer.interface.writeAll(
        \\Available Benchmarks:
        \\
        \\  startup      - Shell startup time benchmarks
        \\                 Tests minimal startup, config load, history load,
        \\                 plugin discovery, and prompt initialization
        \\
        \\  command      - Command execution benchmarks
        \\                 Tests parsing, expansion, process spawn, pipes,
        \\                 and redirections
        \\
        \\  completion   - Completion generation benchmarks
        \\                 Tests command completion, file completion, PATH search,
        \\                 fuzzy matching, and completion ranking
        \\
        \\  history      - History search benchmarks
        \\                 Tests linear search, prefix search, substring search,
        \\                 duplicate removal, and persistence
        \\
        \\  prompt       - Prompt rendering benchmarks
        \\                 Tests simple/complex prompts, git status, color
        \\                 formatting, and module detection
        \\
        \\Run 'den-profile run NAME' to execute a specific benchmark.
        \\
    );
}

fn runBenchmark(allocator: std.mem.Allocator, name: []const u8) !void {
    const stdout_file = std.fs.File{
        .handle = std.posix.STDOUT_FILENO,
    };
    var buffer: [4096]u8 = undefined;
    var writer = stdout_file.writer(&buffer);
    defer writer.interface.flush() catch {};

    try writer.interface.print("Running {s} benchmark...\n\n", .{name});

    if (std.mem.eql(u8, name, "startup")) {
        try runExternalBenchmark(allocator, "startup_bench");
    } else if (std.mem.eql(u8, name, "command")) {
        try runExternalBenchmark(allocator, "command_exec_bench");
    } else if (std.mem.eql(u8, name, "completion")) {
        try runExternalBenchmark(allocator, "completion_bench");
    } else if (std.mem.eql(u8, name, "history")) {
        try runExternalBenchmark(allocator, "history_bench");
    } else if (std.mem.eql(u8, name, "prompt")) {
        try runExternalBenchmark(allocator, "prompt_bench");
    } else {
        std.debug.print("Error: unknown benchmark '{s}'\n", .{name});
        try listBenchmarks();
        return error.UnknownBenchmark;
    }
}

fn runExternalBenchmark(allocator: std.mem.Allocator, bench_name: []const u8) !void {
    const exe_path = try std.fmt.allocPrint(allocator, "./zig-out/bin/{s}", .{bench_name});
    defer allocator.free(exe_path);

    var child = std.process.Child.init(&[_][]const u8{exe_path}, allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    _ = try child.spawnAndWait();
}

fn runAllBenchmarks(allocator: std.mem.Allocator) !void {
    const benchmarks = [_][]const u8{
        "startup",
        "command",
        "completion",
        "history",
        "prompt",
    };

    for (benchmarks) |bench_name| {
        try runBenchmark(allocator, bench_name);
        std.debug.print("\n{'=':<80}\n\n", .{});
    }
}
