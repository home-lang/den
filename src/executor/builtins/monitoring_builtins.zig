const std = @import("std");
const builtin = @import("builtin");
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;
const c_exec = struct {
    extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
};

/// Monitoring builtins: sys-stats, netstats, net-check, log-tail, proc-monitor, log-parse

// Get environ from C - returns the current environment pointer
fn getCEnviron() [*:null]const ?[*:0]const u8 {
    if (builtin.os.tag == .macos) {
        const NSGetEnviron = @extern(*const fn () callconv(.c) *[*:null]?[*:0]u8, .{ .name = "_NSGetEnviron" });
        return @ptrCast(NSGetEnviron().*);
    } else {
        const c_environ = @extern(*[*:null]?[*:0]u8, .{ .name = "environ" });
        return @ptrCast(c_environ.*);
    }
}

pub fn sysStats(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = allocator;

    // Check for help
    for (command.args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try IO.print("sys-stats - display system statistics\n", .{});
            try IO.print("Usage: sys-stats [options]\n", .{});
            try IO.print("Options:\n", .{});
            try IO.print("  -c, --cpu     Show CPU info only\n", .{});
            try IO.print("  -m, --memory  Show memory info only\n", .{});
            try IO.print("  -d, --disk    Show disk info only\n", .{});
            try IO.print("  -u, --uptime  Show uptime only\n", .{});
            try IO.print("  -a, --all     Show all stats (default)\n", .{});
            return 0;
        }
    }

    var show_cpu = false;
    var show_memory = false;
    var show_disk = false;
    var show_uptime = false;
    var show_all = command.args.len == 0;

    for (command.args) |arg| {
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--cpu")) {
            show_cpu = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--memory")) {
            show_memory = true;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--disk")) {
            show_disk = true;
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--uptime")) {
            show_uptime = true;
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
            show_all = true;
        }
    }

    if (show_all) {
        show_cpu = true;
        show_memory = true;
        show_disk = true;
        show_uptime = true;
    }

    // Header
    try IO.print("\x1b[1;36m=== System Statistics ===\x1b[0m\n\n", .{});

    // CPU Info
    if (show_cpu) {
        try IO.print("\x1b[1;33mCPU:\x1b[0m\n", .{});
        if (builtin.os.tag == .macos) {
            try IO.print("  Cores: {d}\n", .{try std.Thread.getCpuCount()});
        } else if (builtin.os.tag == .linux) {
            if (std.Io.Dir.cwd().openFile(std.Options.debug_io,"/proc/cpuinfo", .{})) |file| {
                defer file.close(std.Options.debug_io);
                var cores: u32 = 0;
                var buf: [4096]u8 = undefined;
                const n = file.readStreaming(std.Options.debug_io, &.{&buf}) catch 0;
                var iter = std.mem.splitScalar(u8, buf[0..n], '\n');
                while (iter.next()) |line| {
                    if (std.mem.startsWith(u8, line, "processor")) {
                        cores += 1;
                    }
                }
                try IO.print("  Cores: {d}\n", .{cores});
            } else |_| {
                try IO.print("  Cores: {d}\n", .{try std.Thread.getCpuCount()});
            }
        } else {
            try IO.print("  Cores: {d}\n", .{try std.Thread.getCpuCount()});
        }
        try IO.print("\n", .{});
    }

    // Memory Info
    if (show_memory) {
        try IO.print("\x1b[1;33mMemory:\x1b[0m\n", .{});
        if (builtin.os.tag == .linux) {
            if (std.Io.Dir.cwd().openFile(std.Options.debug_io,"/proc/meminfo", .{})) |file| {
                defer file.close(std.Options.debug_io);
                var buf: [4096]u8 = undefined;
                const n = file.readStreaming(std.Options.debug_io, &.{&buf}) catch 0;
                var iter = std.mem.splitScalar(u8, buf[0..n], '\n');
                while (iter.next()) |line| {
                    if (std.mem.startsWith(u8, line, "MemTotal:")) {
                        try IO.print("  {s}\n", .{line});
                    } else if (std.mem.startsWith(u8, line, "MemFree:")) {
                        try IO.print("  {s}\n", .{line});
                    } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
                        try IO.print("  {s}\n", .{line});
                    }
                }
            } else |_| {
                try IO.print("  (unable to read memory info)\n", .{});
            }
        } else if (builtin.os.tag == .macos) {
            try IO.print("  (use 'vm_stat' for detailed memory info)\n", .{});
            try IO.print("  Page size: 16384 bytes (typical for macOS)\n", .{});
        } else {
            try IO.print("  (memory info not available on this platform)\n", .{});
        }
        try IO.print("\n", .{});
    }

    // Disk Info
    if (show_disk) {
        try IO.print("\x1b[1;33mDisk:\x1b[0m\n", .{});
        const cwd = std.Io.Dir.cwd();
        const stat = cwd.statFile(std.Options.debug_io, ".", .{}) catch null;
        if (stat) |_| {
            try IO.print("  (use 'df -h' for detailed disk info)\n", .{});
        } else {
            try IO.print("  (unable to read disk info)\n", .{});
        }
        try IO.print("\n", .{});
    }

    // Uptime
    if (show_uptime) {
        try IO.print("\x1b[1;33mUptime:\x1b[0m\n", .{});
        if (builtin.os.tag == .linux) {
            if (std.Io.Dir.cwd().openFile(std.Options.debug_io,"/proc/uptime", .{})) |file| {
                defer file.close(std.Options.debug_io);
                var buf: [128]u8 = undefined;
                const n = file.readStreaming(std.Options.debug_io, &.{&buf}) catch 0;
                if (n > 0) {
                    var iter = std.mem.splitScalar(u8, buf[0..n], ' ');
                    if (iter.next()) |uptime_str| {
                        const uptime_float = std.fmt.parseFloat(f64, uptime_str) catch 0;
                        const uptime_secs: u64 = @intFromFloat(uptime_float);
                        const days = uptime_secs / 86400;
                        const hours = (uptime_secs % 86400) / 3600;
                        const mins = (uptime_secs % 3600) / 60;
                        try IO.print("  {d} days, {d} hours, {d} minutes\n", .{ days, hours, mins });
                    }
                }
            } else |_| {
                try IO.print("  (unable to read uptime)\n", .{});
            }
        } else if (builtin.os.tag == .macos) {
            try IO.print("  (use 'uptime' command for uptime info)\n", .{});
        } else {
            try IO.print("  (uptime not available on this platform)\n", .{});
        }
    }

    return 0;
}

pub fn netstats(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = allocator;

    // Check for help
    for (command.args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try IO.print("netstats - display network statistics\n", .{});
            try IO.print("Usage: netstats [options]\n", .{});
            try IO.print("Options:\n", .{});
            try IO.print("  -i, --interfaces  Show network interfaces\n", .{});
            try IO.print("  -c, --connections Show active connections\n", .{});
            try IO.print("  -l, --listening   Show listening ports\n", .{});
            try IO.print("  -a, --all         Show all stats (default)\n", .{});
            return 0;
        }
    }

    var show_interfaces = false;
    var show_connections = false;
    var show_listening = false;
    var show_all = command.args.len == 0;

    for (command.args) |arg| {
        if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--interfaces")) {
            show_interfaces = true;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--connections")) {
            show_connections = true;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--listening")) {
            show_listening = true;
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
            show_all = true;
        }
    }

    if (show_all) {
        show_interfaces = true;
        show_connections = true;
        show_listening = true;
    }

    try IO.print("\x1b[1;36m=== Network Statistics ===\x1b[0m\n\n", .{});

    if (show_interfaces) {
        try IO.print("\x1b[1;33mNetwork Interfaces:\x1b[0m\n", .{});
        if (builtin.os.tag == .linux) {
            var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io,"/sys/class/net", .{ .iterate = true }) catch {
                try IO.print("  (unable to list interfaces)\n", .{});
                return 0;
            };
            defer dir.close(std.Options.debug_io);

            var iter = dir.iterate();
            while (iter.next(std.Options.debug_io) catch null) |entry| {
                if (entry.kind == .sym_link or entry.kind == .directory) {
                    try IO.print("  - {s}\n", .{entry.name});
                }
            }
        } else if (builtin.os.tag == .macos) {
            try IO.print("  (use 'ifconfig' or 'networksetup -listallhardwareports' for interfaces)\n", .{});
        } else {
            try IO.print("  (interface listing not available on this platform)\n", .{});
        }
        try IO.print("\n", .{});
    }

    if (show_connections or show_listening) {
        if (show_connections) {
            try IO.print("\x1b[1;33mActive Connections:\x1b[0m\n", .{});
        }
        if (show_listening) {
            try IO.print("\x1b[1;33mListening Ports:\x1b[0m\n", .{});
        }

        if (builtin.os.tag == .linux) {
            try IO.print("  (use 'ss -tuln' or 'netstat -tuln' for connection details)\n", .{});
        } else if (builtin.os.tag == .macos) {
            try IO.print("  (use 'lsof -i' or 'netstat -an' for connection details)\n", .{});
        } else {
            try IO.print("  (connection info not available on this platform)\n", .{});
        }
    }

    return 0;
}

pub fn netCheck(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    // Check for help
    for (command.args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try IO.print("net-check - check network connectivity\n", .{});
            try IO.print("Usage: net-check [options] [host]\n", .{});
            try IO.print("Options:\n", .{});
            try IO.print("  -q, --quiet   Only return exit code (0=ok, 1=fail)\n", .{});
            try IO.print("  -p, --port    Check specific port (e.g., -p 443)\n", .{});
            try IO.print("\nExamples:\n", .{});
            try IO.print("  net-check                  # Check default (google.com)\n", .{});
            try IO.print("  net-check example.com      # Check specific host\n", .{});
            try IO.print("  net-check -p 443 example.com  # Check port 443\n", .{});
            return 0;
        }
    }

    var quiet = false;
    var port: ?[]const u8 = null;
    var host: []const u8 = "google.com";
    var i: usize = 0;

    while (i < command.args.len) : (i += 1) {
        const arg = command.args[i];
        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--port")) {
            if (i + 1 < command.args.len) {
                i += 1;
                port = command.args[i];
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            host = arg;
        }
    }

    if (!quiet) {
        try IO.print("\x1b[1;36m=== Network Connectivity Check ===\x1b[0m\n\n", .{});
    }

    if (port) |p| {
        if (!quiet) {
            try IO.print("\x1b[1;33mPort Check:\x1b[0m {s}:{s}\n", .{ host, p });
        }

        const host_z = try allocator.dupeZ(u8, host);
        defer allocator.free(host_z);
        const port_z = try allocator.dupeZ(u8, p);
        defer allocator.free(port_z);

        const argv = [_]?[*:0]const u8{
            "nc", "-z", "-w", "3", host_z, port_z, null,
        };

        const fork_ret = std.c.fork();
        if (fork_ret < 0) {
            if (!quiet) {
                try IO.print("  \x1b[1;31m✗\x1b[0m Failed to fork process\n", .{});
            }
            return 1;
        }
        const pid: std.posix.pid_t = @intCast(fork_ret);

        if (pid == 0) {
            const dev_null = std.Io.Dir.openFileAbsolute(std.Options.debug_io,"/dev/null", .{ .mode = .write_only }) catch std.c._exit(127);
            _ = std.c.dup2(dev_null.handle, std.posix.STDERR_FILENO);
            _ = std.c.dup2(dev_null.handle, std.posix.STDOUT_FILENO);
            _ = c_exec.execvp("nc", @ptrCast(&argv));
            std.c._exit(127);
        } else {
            var wait_status: c_int = 0;
            _ = std.c.waitpid(pid, &wait_status, 0);
            const code: i32 = @intCast(std.posix.W.EXITSTATUS(@as(u32, @bitCast(wait_status))));

            if (code == 0) {
                if (!quiet) {
                    try IO.print("  \x1b[1;32m✓\x1b[0m Port {s} is open\n", .{p});
                }
            } else {
                if (!quiet) {
                    try IO.print("  \x1b[1;31m✗\x1b[0m Port {s} is closed or unreachable\n", .{p});
                }
                return 1;
            }
        }
    } else {
        if (!quiet) {
            try IO.print("\x1b[1;33mConnectivity Check:\x1b[0m {s}\n", .{host});
        }

        const host_z = try allocator.dupeZ(u8, host);
        defer allocator.free(host_z);

        const argv = if (builtin.os.tag == .macos)
            [_]?[*:0]const u8{ "ping", "-c", "1", "-t", "3", host_z, null }
        else
            [_]?[*:0]const u8{ "ping", "-c", "1", "-W", "3", host_z, null };

        const fork_ret2 = std.c.fork();
        if (fork_ret2 < 0) {
            if (!quiet) {
                try IO.print("  \x1b[1;31m✗\x1b[0m Failed to fork process\n", .{});
            }
            return 1;
        }
        const pid: std.posix.pid_t = @intCast(fork_ret2);

        if (pid == 0) {
            const dev_null = std.Io.Dir.openFileAbsolute(std.Options.debug_io,"/dev/null", .{ .mode = .write_only }) catch std.c._exit(127);
            _ = std.c.dup2(dev_null.handle, std.posix.STDERR_FILENO);
            _ = std.c.dup2(dev_null.handle, std.posix.STDOUT_FILENO);
            _ = c_exec.execvp("ping", @ptrCast(&argv));
            std.c._exit(127);
        } else {
            var wait_status2: c_int = 0;
            _ = std.c.waitpid(pid, &wait_status2, 0);
            const code: i32 = @intCast(std.posix.W.EXITSTATUS(@as(u32, @bitCast(wait_status2))));

            if (code == 0) {
                if (!quiet) {
                    try IO.print("  \x1b[1;32m✓\x1b[0m Host is reachable\n", .{});
                }
            } else {
                if (!quiet) {
                    try IO.print("  \x1b[1;31m✗\x1b[0m Host is unreachable\n", .{});
                }
                return 1;
            }
        }
    }

    if (!quiet) {
        try IO.print("\n\x1b[1;32mNetwork is reachable\x1b[0m\n", .{});
    }

    return 0;
}

// Helper functions
fn getLevelColor(level: []const u8) []const u8 {
    const lower = blk: {
        var buf: [32]u8 = undefined;
        const len = @min(level.len, buf.len);
        for (level[0..len], 0..) |c, i| {
            buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        break :blk buf[0..len];
    };

    if (std.mem.indexOf(u8, lower, "error") != null or std.mem.indexOf(u8, lower, "fatal") != null or std.mem.indexOf(u8, lower, "crit") != null) {
        return "\x1b[1;31m"; // Red
    } else if (std.mem.indexOf(u8, lower, "warn") != null) {
        return "\x1b[1;33m"; // Yellow
    } else if (std.mem.indexOf(u8, lower, "info") != null) {
        return "\x1b[1;32m"; // Green
    } else if (std.mem.indexOf(u8, lower, "debug") != null or std.mem.indexOf(u8, lower, "trace") != null) {
        return "\x1b[1;36m"; // Cyan
    }
    return "\x1b[0m";
}

fn logTailHighlightLine(line: []const u8, pattern: []const u8) !void {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, line, pos, pattern)) |idx| {
        try IO.print("{s}\x1b[1;33m{s}\x1b[0m", .{ line[pos..idx], pattern });
        pos = idx + pattern.len;
    }
    try IO.print("{s}\n", .{line[pos..]});
}

fn logTailAutoHighlightLine(line: []const u8) !void {
    // Auto-highlight common log levels
    if (std.mem.indexOf(u8, line, "ERROR") != null or std.mem.indexOf(u8, line, "FATAL") != null) {
        try IO.print("\x1b[1;31m{s}\x1b[0m\n", .{line});
    } else if (std.mem.indexOf(u8, line, "WARN") != null) {
        try IO.print("\x1b[1;33m{s}\x1b[0m\n", .{line});
    } else if (std.mem.indexOf(u8, line, "INFO") != null) {
        try IO.print("\x1b[1;32m{s}\x1b[0m\n", .{line});
    } else if (std.mem.indexOf(u8, line, "DEBUG") != null) {
        try IO.print("\x1b[1;36m{s}\x1b[0m\n", .{line});
    } else {
        try IO.print("{s}\n", .{line});
    }
}

pub fn logTail(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    var num_lines: usize = 10;
    var follow = false;
    var filter: ?[]const u8 = null;
    var highlight: ?[]const u8 = null;
    var file_path: ?[]const u8 = null;
    var show_help = false;

    var i: usize = 0;
    while (i < command.args.len) : (i += 1) {
        const arg = command.args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--lines")) {
            if (i + 1 < command.args.len) {
                i += 1;
                num_lines = std.fmt.parseInt(usize, command.args[i], 10) catch 10;
            }
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--follow")) {
            follow = true;
        } else if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--grep")) {
            if (i + 1 < command.args.len) {
                i += 1;
                filter = command.args[i];
            }
        } else if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--highlight")) {
            if (i + 1 < command.args.len) {
                i += 1;
                highlight = command.args[i];
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            file_path = arg;
        }
    }

    if (show_help or file_path == null) {
        try IO.print("log-tail - tail log files with filtering and highlighting\n", .{});
        try IO.print("Usage: log-tail [options] FILE\n", .{});
        try IO.print("Options:\n", .{});
        try IO.print("  -n, --lines N      Show last N lines (default: 10)\n", .{});
        try IO.print("  -f, --follow       Follow file (like tail -f)\n", .{});
        try IO.print("  -g, --grep PATTERN Filter lines by pattern\n", .{});
        try IO.print("  -H, --highlight PATTERN  Highlight pattern in output\n", .{});
        return if (show_help) 0 else 1;
    }

    const path = file_path.?;

    const file = std.Io.Dir.cwd().openFile(std.Options.debug_io,path, .{}) catch |err| {
        try IO.eprint("den: log-tail: cannot open '{s}': {}\n", .{ path, err });
        return 1;
    };
    defer file.close(std.Options.debug_io);

    const stat = file.stat(std.Options.debug_io) catch |err| {
        try IO.eprint("den: log-tail: cannot stat '{s}': {}\n", .{ path, err });
        return 1;
    };

    const max_size: usize = 10 * 1024 * 1024;
    const read_size = @min(stat.size, max_size);

    const content = allocator.alloc(u8, read_size) catch {
        try IO.eprint("den: log-tail: out of memory\n", .{});
        return 1;
    };
    defer allocator.free(content);

    var total_read: usize = 0;
    while (total_read < read_size) {
        const n = file.readStreaming(std.Options.debug_io, &.{content[total_read..]}) catch |err| {
            try IO.eprint("den: log-tail: read error: {}\n", .{err});
            return 1;
        };
        if (n == 0) break;
        total_read += n;
    }
    const bytes_read = total_read;

    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, content[0..bytes_read], '\n');
    while (line_iter.next()) |line| {
        if (filter) |f| {
            if (std.mem.indexOf(u8, line, f) == null) {
                continue;
            }
        }
        lines.append(allocator, line) catch {};
    }

    const start_idx = if (lines.items.len > num_lines) lines.items.len - num_lines else 0;

    for (lines.items[start_idx..]) |line| {
        if (highlight) |h| {
            try logTailHighlightLine(line, h);
        } else {
            try logTailAutoHighlightLine(line);
        }
    }

    if (follow) {
        try IO.print("\n\x1b[2m--- Following {s} (Ctrl+C to stop) ---\x1b[0m\n", .{path});

        var last_pos = stat.size;

        while (true) {
            std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromNanoseconds(500_000_000), .awake) catch {};

            const new_stat = file.stat(std.Options.debug_io) catch continue;
            if (new_stat.size > last_pos) {
                var read_pos = last_pos;

                var buf: [4096]u8 = undefined;
                while (true) {
                    const n = file.readPositional(std.Options.debug_io, &.{&buf}, read_pos) catch break;
                    if (n == 0) break;
                    read_pos += n;

                    var new_lines = std.mem.splitScalar(u8, buf[0..n], '\n');
                    while (new_lines.next()) |new_line| {
                        if (new_line.len == 0) continue;

                        if (filter) |f| {
                            if (std.mem.indexOf(u8, new_line, f) == null) {
                                continue;
                            }
                        }

                        if (highlight) |h| {
                            try logTailHighlightLine(new_line, h);
                        } else {
                            try logTailAutoHighlightLine(new_line);
                        }
                    }
                }

                last_pos = new_stat.size;
            }
        }
    }

    return 0;
}

pub fn procMonitor(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = allocator;

    var pattern: ?[]const u8 = null;
    var pid_filter: ?i32 = null;
    var interval: u32 = 2;
    var count: ?u32 = null;
    var show_help = false;

    var i: usize = 0;
    while (i < command.args.len) : (i += 1) {
        const arg = command.args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--pid")) {
            if (i + 1 < command.args.len) {
                i += 1;
                pid_filter = std.fmt.parseInt(i32, command.args[i], 10) catch null;
            }
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--interval")) {
            if (i + 1 < command.args.len) {
                i += 1;
                interval = std.fmt.parseInt(u32, command.args[i], 10) catch 2;
            }
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count")) {
            if (i + 1 < command.args.len) {
                i += 1;
                count = std.fmt.parseInt(u32, command.args[i], 10) catch null;
            }
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--sort")) {
            if (i + 1 < command.args.len) {
                i += 1;
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            pattern = arg;
        }
    }

    if (show_help) {
        try IO.print("proc-monitor - monitor processes\n", .{});
        try IO.print("Usage: proc-monitor [options] [PATTERN]\n", .{});
        try IO.print("Options:\n", .{});
        try IO.print("  -p, --pid PID       Monitor specific PID\n", .{});
        try IO.print("  -n, --interval N    Update interval in seconds (default: 2)\n", .{});
        try IO.print("  -c, --count N       Number of iterations (default: continuous)\n", .{});
        try IO.print("  -s, --sort FIELD    Sort by: cpu, mem, pid, name (default: cpu)\n", .{});
        return 0;
    }

    var iterations: u32 = 0;
    const max_iterations = count orelse std.math.maxInt(u32);

    while (iterations < max_iterations) : (iterations += 1) {
        if (iterations > 0) {
            try IO.print("\x1b[2J\x1b[H", .{});
        }

        try IO.print("\x1b[1;36m=== Process Monitor ===\x1b[0m", .{});
        if (pattern) |p| {
            try IO.print(" (filter: {s})", .{p});
        }
        if (pid_filter) |pid| {
            try IO.print(" (pid: {})", .{pid});
        }
        try IO.print("\n\n", .{});

        const ps_args = if (builtin.os.tag == .macos)
            [_]?[*:0]const u8{ "ps", "-axo", "pid,pcpu,pmem,rss,comm", null }
        else
            [_]?[*:0]const u8{ "ps", "-eo", "pid,pcpu,pmem,rss,comm", null };

        var pipe_fds: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&pipe_fds) != 0) {
            try IO.eprint("den: proc-monitor: failed to create pipe\n", .{});
            return 1;
        }

        const fork_ret3 = std.c.fork();
        if (fork_ret3 < 0) {
            try IO.eprint("den: proc-monitor: failed to fork\n", .{});
            return 1;
        }
        const pid: std.posix.pid_t = @intCast(fork_ret3);

        if (pid == 0) {
            std.posix.close(pipe_fds[0]);
            _ = std.c.dup2(pipe_fds[1], std.posix.STDOUT_FILENO);
            std.posix.close(pipe_fds[1]);
            const dev_null = std.Io.Dir.openFileAbsolute(std.Options.debug_io,"/dev/null", .{ .mode = .write_only }) catch std.c._exit(127);
            _ = std.c.dup2(dev_null.handle, std.posix.STDERR_FILENO);
            _ = c_exec.execvp("ps", @ptrCast(&ps_args));
            std.c._exit(127);
        } else {
            std.posix.close(pipe_fds[1]);

            var buf: [8192]u8 = undefined;
            var total_read: usize = 0;

            while (total_read < buf.len) {
                const n = (std.Io.File{ .handle = pipe_fds[0], .flags = .{ .nonblocking = false } }).readStreaming(std.Options.debug_io, &.{buf[total_read..]}) catch break;
                if (n == 0) break;
                total_read += n;
            }

            std.posix.close(pipe_fds[0]);
            {
                var reap_status: c_int = 0;
                _ = std.c.waitpid(pid, &reap_status, 0);
            }

            var line_num: usize = 0;
            var proc_count: usize = 0;
            var lines = std.mem.splitScalar(u8, buf[0..total_read], '\n');

            try IO.print("\x1b[1m{s:>7}  {s:>6}  {s:>6}  {s:>10}  {s}\x1b[0m\n", .{
                "PID", "%CPU", "%MEM", "RSS", "COMMAND",
            });
            try IO.print("{s:-<60}\n", .{""});

            while (lines.next()) |line| {
                line_num += 1;
                if (line_num == 1) continue;
                if (line.len == 0) continue;

                var fields = std.mem.tokenizeScalar(u8, line, ' ');
                const pid_str = fields.next() orelse continue;
                const cpu_str = fields.next() orelse continue;
                const mem_str = fields.next() orelse continue;
                const rss_str = fields.next() orelse continue;

                var cmd_start: usize = 0;
                var field_count: usize = 0;
                for (line, 0..) |c, idx| {
                    if (c != ' ' and field_count < 4) {
                        while (idx + cmd_start < line.len and line[idx + cmd_start] != ' ') : (cmd_start += 1) {}
                        field_count += 1;
                        if (field_count == 4) {
                            cmd_start = idx;
                            break;
                        }
                    }
                }
                const cmd_name = std.mem.trim(u8, line[cmd_start..], " ");

                if (pid_filter) |filter_pid| {
                    const proc_pid = std.fmt.parseInt(i32, pid_str, 10) catch continue;
                    if (proc_pid != filter_pid) continue;
                }

                if (pattern) |p| {
                    if (std.mem.indexOf(u8, cmd_name, p) == null) continue;
                }

                const rss_kb = std.fmt.parseInt(u64, rss_str, 10) catch 0;
                var rss_display: [16]u8 = undefined;
                const rss_formatted = if (rss_kb >= 1024 * 1024)
                    std.fmt.bufPrint(&rss_display, "{d:.1}G", .{@as(f64, @floatFromInt(rss_kb)) / (1024.0 * 1024.0)}) catch "?"
                else if (rss_kb >= 1024)
                    std.fmt.bufPrint(&rss_display, "{d:.1}M", .{@as(f64, @floatFromInt(rss_kb)) / 1024.0}) catch "?"
                else
                    std.fmt.bufPrint(&rss_display, "{}K", .{rss_kb}) catch "?";

                const cpu_val = std.fmt.parseFloat(f64, cpu_str) catch 0.0;
                const color = if (cpu_val >= 50.0) "\x1b[1;31m" else if (cpu_val >= 20.0) "\x1b[1;33m" else "\x1b[0m";

                try IO.print("{s}{s:>7}  {s:>6}  {s:>6}  {s:>10}  {s}\x1b[0m\n", .{
                    color, pid_str, cpu_str, mem_str, rss_formatted, cmd_name,
                });

                proc_count += 1;
                if (proc_count >= 20) break;
            }

            try IO.print("\n\x1b[2mShowing top {} processes", .{proc_count});
            if (count == null) {
                try IO.print(" (updating every {}s, Ctrl+C to stop)", .{interval});
            }
            try IO.print("\x1b[0m\n", .{});
        }

        if (iterations + 1 < max_iterations) {
            std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromNanoseconds(@as(u64, interval) * 1_000_000_000), .awake) catch {};
        }
    }

    return 0;
}

pub fn logParse(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = allocator;

    var format: enum { auto, json, kv, csv } = .auto;
    var fields: ?[]const u8 = null;
    var filter_field: ?[]const u8 = null;
    var filter_value: ?[]const u8 = null;
    var file_path: ?[]const u8 = null;
    var show_help = false;
    var pretty = false;
    var count_only = false;

    var i: usize = 0;
    while (i < command.args.len) : (i += 1) {
        const arg = command.args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--format")) {
            if (i + 1 < command.args.len) {
                i += 1;
                const fmt = command.args[i];
                if (std.mem.eql(u8, fmt, "json")) format = .json else if (std.mem.eql(u8, fmt, "kv")) format = .kv else if (std.mem.eql(u8, fmt, "csv")) format = .csv else format = .auto;
            }
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--select")) {
            if (i + 1 < command.args.len) {
                i += 1;
                fields = command.args[i];
            }
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--where")) {
            if (i + 1 < command.args.len) {
                i += 1;
                const where_clause = command.args[i];
                if (std.mem.indexOf(u8, where_clause, "=")) |eq_idx| {
                    filter_field = where_clause[0..eq_idx];
                    filter_value = where_clause[eq_idx + 1 ..];
                }
            }
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--pretty")) {
            pretty = true;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count")) {
            count_only = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            file_path = arg;
        }
    }

    if (show_help) {
        try IO.print("log-parse - parse structured log files\n", .{});
        try IO.print("Usage: log-parse [options] FILE\n", .{});
        try IO.print("\nFormats:\n", .{});
        try IO.print("  -f, --format FORMAT  Log format: json, kv, csv, auto (default)\n", .{});
        try IO.print("\nFiltering:\n", .{});
        try IO.print("  -s, --select FIELDS  Select specific fields (comma-separated)\n", .{});
        try IO.print("  -w, --where EXPR     Filter by field=value\n", .{});
        try IO.print("  -c, --count          Only show count of matching lines\n", .{});
        try IO.print("\nOutput:\n", .{});
        try IO.print("  -p, --pretty         Pretty print output\n", .{});
        return 0;
    }

    var content_buf: [1024 * 1024]u8 = undefined;
    var content_len: usize = 0;

    if (file_path) |path| {
        const file = std.Io.Dir.cwd().openFile(std.Options.debug_io,path, .{}) catch |err| {
            try IO.eprint("den: log-parse: cannot open '{s}': {}\n", .{ path, err });
            return 1;
        };
        defer file.close(std.Options.debug_io);

        while (content_len < content_buf.len) {
            const n = file.readStreaming(std.Options.debug_io, &.{content_buf[content_len..]}) catch break;
            if (n == 0) break;
            content_len += n;
        }
    } else {
        try IO.eprint("den: log-parse: no file specified\n", .{});
        return 1;
    }

    const content = content_buf[0..content_len];

    var line_count: usize = 0;
    var match_count: usize = 0;
    var csv_headers: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        line_count += 1;

        var line_format = format;
        if (format == .auto) {
            if (line.len > 0 and line[0] == '{') {
                line_format = .json;
            } else if (std.mem.indexOf(u8, line, "=") != null) {
                line_format = .kv;
            } else if (std.mem.indexOf(u8, line, ",") != null) {
                line_format = .csv;
            } else {
                line_format = .kv;
            }
        }

        var field_map: [32]struct { key: []const u8, value: []const u8 } = undefined;
        var field_count: usize = 0;

        switch (line_format) {
            .json => {
                var in_key = false;
                var in_value = false;
                var in_string = false;
                var key_start: usize = 0;
                var key_end: usize = 0;
                var value_start: usize = 0;

                for (line, 0..) |c, idx| {
                    if (c == '"' and (idx == 0 or line[idx - 1] != '\\')) {
                        if (!in_string) {
                            in_string = true;
                            if (!in_key and !in_value) {
                                in_key = true;
                                key_start = idx + 1;
                            } else if (in_value) {
                                value_start = idx + 1;
                            }
                        } else {
                            in_string = false;
                            if (in_key) {
                                key_end = idx;
                            } else if (in_value and field_count < field_map.len) {
                                field_map[field_count] = .{
                                    .key = line[key_start..key_end],
                                    .value = line[value_start..idx],
                                };
                                field_count += 1;
                                in_value = false;
                            }
                        }
                    } else if (c == ':' and !in_string and in_key) {
                        in_key = false;
                        in_value = true;
                    } else if ((c == ',' or c == '}') and !in_string and in_value) {
                        if (value_start == 0) {
                            var vs: usize = key_end + 1;
                            while (vs < idx and (line[vs] == ':' or line[vs] == ' ')) : (vs += 1) {}
                            if (field_count < field_map.len) {
                                field_map[field_count] = .{
                                    .key = line[key_start..key_end],
                                    .value = std.mem.trim(u8, line[vs..idx], " \t"),
                                };
                                field_count += 1;
                            }
                        }
                        in_value = false;
                        value_start = 0;
                    }
                }
            },
            .kv => {
                var tokens = std.mem.tokenizeScalar(u8, line, ' ');
                while (tokens.next()) |token| {
                    if (std.mem.indexOf(u8, token, "=")) |eq_idx| {
                        if (field_count < field_map.len) {
                            var value = token[eq_idx + 1 ..];
                            if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                                value = value[1 .. value.len - 1];
                            }
                            field_map[field_count] = .{
                                .key = token[0..eq_idx],
                                .value = value,
                            };
                            field_count += 1;
                        }
                    }
                }
            },
            .csv => {
                if (line_count == 1) {
                    csv_headers = line;
                    continue;
                }

                if (csv_headers) |headers| {
                    var header_iter = std.mem.splitScalar(u8, headers, ',');
                    var value_iter = std.mem.splitScalar(u8, line, ',');

                    while (header_iter.next()) |header| {
                        if (value_iter.next()) |value| {
                            if (field_count < field_map.len) {
                                field_map[field_count] = .{
                                    .key = std.mem.trim(u8, header, " \t\""),
                                    .value = std.mem.trim(u8, value, " \t\""),
                                };
                                field_count += 1;
                            }
                        }
                    }
                }
            },
            .auto => continue,
        }

        if (filter_field) |ff| {
            var matches = false;
            for (field_map[0..field_count]) |field| {
                if (std.mem.eql(u8, field.key, ff)) {
                    if (filter_value) |fv| {
                        if (std.mem.indexOf(u8, field.value, fv) != null) {
                            matches = true;
                        }
                    } else {
                        matches = true;
                    }
                    break;
                }
            }
            if (!matches) continue;
        }

        match_count += 1;

        if (count_only) continue;

        if (fields) |selected| {
            var field_list = std.mem.splitScalar(u8, selected, ',');
            var first = true;
            while (field_list.next()) |wanted| {
                for (field_map[0..field_count]) |field| {
                    if (std.mem.eql(u8, field.key, wanted)) {
                        if (!first) try IO.print(" ", .{});
                        if (pretty) {
                            try IO.print("\x1b[1;36m{s}\x1b[0m=\x1b[33m{s}\x1b[0m", .{ field.key, field.value });
                        } else {
                            try IO.print("{s}", .{field.value});
                        }
                        first = false;
                        break;
                    }
                }
            }
            try IO.print("\n", .{});
        } else {
            if (pretty) {
                for (field_map[0..field_count], 0..) |field, idx| {
                    if (idx > 0) try IO.print(" ", .{});
                    const color = if (std.mem.eql(u8, field.key, "level") or std.mem.eql(u8, field.key, "severity"))
                        getLevelColor(field.value)
                    else
                        "\x1b[0m";
                    try IO.print("\x1b[1;36m{s}\x1b[0m={s}{s}\x1b[0m", .{ field.key, color, field.value });
                }
                try IO.print("\n", .{});
            } else {
                for (field_map[0..field_count], 0..) |field, idx| {
                    if (idx > 0) try IO.print("\t", .{});
                    try IO.print("{s}={s}", .{ field.key, field.value });
                }
                try IO.print("\n", .{});
            }
        }
    }

    if (count_only) {
        try IO.print("{}\n", .{match_count});
    }

    return 0;
}
