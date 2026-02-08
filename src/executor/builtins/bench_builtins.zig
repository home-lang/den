const std = @import("std");
const posix = std.posix;
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;
const common = @import("common.zig");

/// Benchmark a command: bench <rounds> <command...>
pub fn bench(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("Usage: bench [--rounds N] <command...>\n", .{});
        return 1;
    }

    var rounds: u32 = 10;
    var cmd_start: usize = 0;

    // Parse --rounds flag
    var i: usize = 0;
    while (i < command.args.len) : (i += 1) {
        if (std.mem.eql(u8, command.args[i], "--rounds") or std.mem.eql(u8, command.args[i], "-n")) {
            if (i + 1 < command.args.len) {
                rounds = std.fmt.parseInt(u32, command.args[i + 1], 10) catch 10;
                i += 1;
                cmd_start = i + 1;
            }
        } else {
            cmd_start = i;
            break;
        }
    }

    if (cmd_start >= command.args.len) {
        try IO.eprint("bench: missing command to benchmark\n", .{});
        return 1;
    }

    // Build the command string
    var cmd_buf = std.ArrayList(u8).empty;
    defer cmd_buf.deinit(allocator);
    for (command.args[cmd_start..], 0..) |arg, idx| {
        if (idx > 0) try cmd_buf.append(allocator, ' ');
        try cmd_buf.appendSlice(allocator, arg);
    }
    const cmd_str = try cmd_buf.toOwnedSlice(allocator);
    defer allocator.free(cmd_str);

    // Create null-terminated version for exec
    const cmd_z = try allocator.dupeZ(u8, cmd_str);
    defer allocator.free(cmd_z);

    try IO.print("Benchmarking: {s}\n", .{cmd_str});
    try IO.print("Rounds: {d}\n\n", .{rounds});

    var times = try allocator.alloc(u64, rounds);
    defer allocator.free(times);

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    for (0..rounds) |round| {
        const start = std.time.Instant.now() catch {
            try IO.eprint("bench: timer not available\n", .{});
            return 1;
        };

        // Run the command using fork/exec via /bin/sh
        const fork_ret = std.c.fork();
        if (fork_ret < 0) {
            try IO.eprint("bench: failed to fork\n", .{});
            return 1;
        }
        const pid: posix.pid_t = @intCast(fork_ret);

        if (pid == 0) {
            // Child process
            // Redirect stdout and stderr to /dev/null
            const dev_null = std.Io.Dir.openFileAbsolute(std.Options.debug_io, "/dev/null", .{ .mode = .write_only }) catch std.c._exit(127);
            _ = std.c.dup2(dev_null.handle, posix.STDOUT_FILENO);
            _ = std.c.dup2(dev_null.handle, posix.STDERR_FILENO);

            const argv = [_:null]?[*:0]const u8{
                "/bin/sh",
                "-c",
                cmd_z.ptr,
                null,
            };
            _ = common.c_exec.execvp("/bin/sh", &argv);
            // If execvp returns, it failed
            std.c._exit(127);
            unreachable;
        } else {
            // Parent process - wait for child
            var wait_status: c_int = 0;
            _ = std.c.waitpid(pid, &wait_status, 0);
        }

        const end = std.time.Instant.now() catch {
            try IO.eprint("bench: timer not available\n", .{});
            return 1;
        };

        const elapsed = end.since(start);
        times[round] = elapsed;
        total_ns += elapsed;
        if (elapsed < min_ns) min_ns = elapsed;
        if (elapsed > max_ns) max_ns = elapsed;
    }

    // Calculate statistics
    const avg_ns = total_ns / rounds;

    // Sort for median
    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    const median_ns = if (rounds % 2 == 0)
        (times[rounds / 2 - 1] + times[rounds / 2]) / 2
    else
        times[rounds / 2];

    // Calculate stddev
    var variance: f64 = 0;
    for (times) |t| {
        const diff = @as(f64, @floatFromInt(t)) - @as(f64, @floatFromInt(avg_ns));
        variance += diff * diff;
    }
    variance /= @as(f64, @floatFromInt(rounds));
    const stddev = @sqrt(variance);

    try IO.print("Results:\n", .{});
    try IO.print("  avg:    {s}\n", .{try formatNs(allocator, avg_ns)});
    try IO.print("  min:    {s}\n", .{try formatNs(allocator, min_ns)});
    try IO.print("  max:    {s}\n", .{try formatNs(allocator, max_ns)});
    try IO.print("  median: {s}\n", .{try formatNs(allocator, median_ns)});
    try IO.print("  stddev: {d:.2}ms\n", .{stddev / 1_000_000.0});
    try IO.print("  total:  {s}\n", .{try formatNs(allocator, total_ns)});

    return 0;
}

fn formatNs(allocator: std.mem.Allocator, ns: u64) ![]const u8 {
    if (ns < 1_000) return std.fmt.allocPrint(allocator, "{d}ns", .{ns});
    if (ns < 1_000_000) return std.fmt.allocPrint(allocator, "{d:.2}us", .{@as(f64, @floatFromInt(ns)) / 1_000.0});
    if (ns < 1_000_000_000) return std.fmt.allocPrint(allocator, "{d:.2}ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0});
    return std.fmt.allocPrint(allocator, "{d:.2}s", .{@as(f64, @floatFromInt(ns)) / 1_000_000_000.0});
}
