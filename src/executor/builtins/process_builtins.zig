const std = @import("std");
const builtin = @import("builtin");
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;

/// Process-related builtins: times, umask, timeout
/// Note: builtinTime remains in executor/mod.zig as it requires executeExternal

/// times builtin - display accumulated process times
pub fn times(_: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = command;

    // Print shell and children process times
    // For now, just print placeholder
    try IO.print("0m0.000s 0m0.000s\n", .{});
    try IO.print("0m0.000s 0m0.000s\n", .{});
    return 0;
}

/// umask builtin - display or set file mode creation mask
pub fn umask(_: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (builtin.os.tag == .windows) {
        try IO.print("den: umask: not supported on Windows\n", .{});
        return 1;
    }

    // Parse flags
    var symbolic = false; // -S: symbolic output
    var portable = false; // -p: portable output (can be used as input)
    var arg_idx: usize = 0;

    while (arg_idx < command.args.len) {
        const arg = command.args[arg_idx];
        if (arg.len > 0 and arg[0] == '-') {
            for (arg[1..]) |c| {
                switch (c) {
                    'S' => symbolic = true,
                    'p' => portable = true,
                    else => {
                        try IO.eprint("den: umask: -{c}: invalid option\n", .{c});
                        try IO.eprint("den: umask: usage: umask [-p] [-S] [mode]\n", .{});
                        return 1;
                    },
                }
            }
            arg_idx += 1;
        } else {
            break;
        }
    }

    // Get current umask
    const current = std.c.umask(0);
    _ = std.c.umask(current);

    if (arg_idx >= command.args.len) {
        // No mask argument - print current umask
        if (symbolic) {
            // Symbolic format: u=rwx,g=rx,o=rx (showing what IS allowed, not masked)
            const perms: u9 = @truncate(~current & 0o777);
            const u_r: u8 = if (perms & 0o400 != 0) 'r' else '-';
            const u_w: u8 = if (perms & 0o200 != 0) 'w' else '-';
            const u_x: u8 = if (perms & 0o100 != 0) 'x' else '-';
            const g_r: u8 = if (perms & 0o040 != 0) 'r' else '-';
            const g_w: u8 = if (perms & 0o020 != 0) 'w' else '-';
            const g_x: u8 = if (perms & 0o010 != 0) 'x' else '-';
            const o_r: u8 = if (perms & 0o004 != 0) 'r' else '-';
            const o_w: u8 = if (perms & 0o002 != 0) 'w' else '-';
            const o_x: u8 = if (perms & 0o001 != 0) 'x' else '-';
            try IO.print("u={c}{c}{c},g={c}{c}{c},o={c}{c}{c}\n", .{ u_r, u_w, u_x, g_r, g_w, g_x, o_r, o_w, o_x });
        } else if (portable) {
            // Portable format: umask 0022
            try IO.print("umask {o:0>4}\n", .{current});
        } else {
            // Default octal format
            try IO.print("{o:0>4}\n", .{current});
        }
        return 0;
    }

    // Set umask
    const mask_str = command.args[arg_idx];

    // Check if it's symbolic mode (contains letters)
    var is_symbolic_mode = false;
    for (mask_str) |c| {
        if (c == 'u' or c == 'g' or c == 'o' or c == 'a' or c == '+' or c == '-' or c == '=') {
            is_symbolic_mode = true;
            break;
        }
    }

    if (is_symbolic_mode) {
        // Parse symbolic mode like u=rwx,g=rx,o=rx or u+w,g-w
        var new_mask = current;

        var iter = std.mem.splitScalar(u8, mask_str, ',');
        while (iter.next()) |part| {
            if (part.len < 2) continue;

            // Parse who (u, g, o, a)
            var who_mask: std.c.mode_t = 0;
            var i: usize = 0;
            while (i < part.len and (part[i] == 'u' or part[i] == 'g' or part[i] == 'o' or part[i] == 'a')) : (i += 1) {
                switch (part[i]) {
                    'u' => who_mask |= 0o700,
                    'g' => who_mask |= 0o070,
                    'o' => who_mask |= 0o007,
                    'a' => who_mask |= 0o777,
                    else => {},
                }
            }
            if (who_mask == 0) who_mask = 0o777; // default to all

            if (i >= part.len) continue;

            // Parse operator (+, -, =)
            const op = part[i];
            i += 1;

            // Parse permissions (r, w, x)
            var perm_bits: std.c.mode_t = 0;
            while (i < part.len) : (i += 1) {
                switch (part[i]) {
                    'r' => perm_bits |= 0o444,
                    'w' => perm_bits |= 0o222,
                    'x' => perm_bits |= 0o111,
                    else => {},
                }
            }

            // Apply based on who
            perm_bits &= who_mask;

            switch (op) {
                '=' => {
                    // Clear and set
                    new_mask = (new_mask & ~who_mask) | (~perm_bits & who_mask);
                },
                '+' => {
                    // Remove from mask (allow permission)
                    new_mask &= ~perm_bits;
                },
                '-' => {
                    // Add to mask (deny permission)
                    new_mask |= perm_bits;
                },
                else => {},
            }
        }

        _ = std.c.umask(new_mask);
    } else {
        // Octal mode
        const mask = std.fmt.parseInt(std.c.mode_t, mask_str, 8) catch {
            try IO.eprint("den: umask: {s}: invalid octal number\n", .{mask_str});
            return 1;
        };
        _ = std.c.umask(mask);
    }

    return 0;
}

/// timeout builtin - run a command with a time limit
pub fn timeout(_: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    // timeout [-s signal] [-k duration] duration command [args...]
    var signal_name: []const u8 = "TERM"; // Default signal
    var kill_after: ?f64 = null; // -k: send KILL after duration
    var preserve_status = false; // --preserve-status
    var foreground = false; // --foreground
    var arg_start: usize = 0;

    // Parse options
    while (arg_start < command.args.len) {
        const arg = command.args[arg_start];
        if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--signal")) {
                arg_start += 1;
                if (arg_start >= command.args.len) {
                    try IO.eprint("den: timeout: -s requires an argument\n", .{});
                    return 1;
                }
                signal_name = command.args[arg_start];
            } else if (std.mem.eql(u8, arg, "-k") or std.mem.eql(u8, arg, "--kill-after")) {
                arg_start += 1;
                if (arg_start >= command.args.len) {
                    try IO.eprint("den: timeout: -k requires an argument\n", .{});
                    return 1;
                }
                kill_after = parseDuration(command.args[arg_start]) catch {
                    try IO.eprint("den: timeout: invalid duration: {s}\n", .{command.args[arg_start]});
                    return 1;
                };
            } else if (std.mem.eql(u8, arg, "--preserve-status")) {
                preserve_status = true;
            } else if (std.mem.eql(u8, arg, "--foreground")) {
                foreground = true;
            } else if (std.mem.eql(u8, arg, "--help")) {
                try IO.print("Usage: timeout [OPTION] DURATION COMMAND [ARG]...\n", .{});
                try IO.print("Start COMMAND, and kill it if still running after DURATION.\n\n", .{});
                try IO.print("Options:\n", .{});
                try IO.print("  -s, --signal=SIGNAL    Signal to send (default: TERM)\n", .{});
                try IO.print("  -k, --kill-after=DUR   Send KILL signal after DUR if still running\n", .{});
                try IO.print("  --preserve-status      Exit with the same status as COMMAND\n", .{});
                try IO.print("  --foreground           Don't create a new process group\n", .{});
                try IO.print("\nDURATION is a number with optional suffix: s (seconds), m (minutes), h (hours), d (days)\n", .{});
                return 0;
            } else if (std.mem.eql(u8, arg, "--")) {
                arg_start += 1;
                break;
            } else {
                // Unknown option or start of duration
                break;
            }
            arg_start += 1;
        } else {
            break;
        }
    }

    // Need at least duration and command
    if (arg_start + 1 >= command.args.len) {
        try IO.eprint("den: timeout: missing operand\n", .{});
        try IO.eprint("den: timeout: usage: timeout [OPTION] DURATION COMMAND [ARG]...\n", .{});
        return 1;
    }

    // Parse duration
    const duration_str = command.args[arg_start];
    const duration_secs = parseDuration(duration_str) catch {
        try IO.eprint("den: timeout: invalid duration: {s}\n", .{duration_str});
        return 1;
    };

    // Get command and args
    const cmd_name = command.args[arg_start + 1];
    const cmd_args = if (arg_start + 2 < command.args.len) command.args[arg_start + 2 ..] else &[_][]const u8{};

    // Acknowledge options we don't fully use yet
    if (foreground) {
        // Foreground mode - acknowledged but not changing behavior
    }

    // Get signal number from name
    const sig = parseSignalName(signal_name);

    // Fork and exec the command
    const fork_result = std.posix.fork() catch |err| {
        try IO.eprint("den: timeout: fork failed: {}\n", .{err});
        return 1;
    };

    if (fork_result == 0) {
        // Child process - exec the command
        // Use a page allocator since we're post-fork
        const page_alloc = std.heap.page_allocator;

        // Create null-terminated command name
        const cmd_z = page_alloc.dupeZ(u8, cmd_name) catch {
            std.posix.exit(127);
        };

        // Build argv array with null-terminated strings
        var argv_buf: [256]?[*:0]const u8 = undefined;
        argv_buf[0] = cmd_z.ptr;

        var argv_idx: usize = 1;
        for (cmd_args) |arg| {
            if (argv_idx >= argv_buf.len - 1) break;
            const arg_z = page_alloc.dupeZ(u8, arg) catch {
                std.posix.exit(127);
            };
            argv_buf[argv_idx] = arg_z.ptr;
            argv_idx += 1;
        }
        argv_buf[argv_idx] = null;

        _ = std.posix.execvpeZ(cmd_z.ptr, @ptrCast(argv_buf[0..argv_idx :null]), getCEnviron()) catch {
            // exec failed
            std.posix.exit(127);
        };
        // If we get here, exec failed
        std.posix.exit(127);
    }

    // Parent process - wait with timeout
    const child_pid = fork_result;
    const timeout_ns: u64 = @intFromFloat(duration_secs * 1_000_000_000);
    const start_time = std.time.Instant.now() catch {
        // Can't get time, just wait normally
        const result = std.posix.waitpid(child_pid, 0);
        return @intCast(std.posix.W.EXITSTATUS(result.status));
    };

    // Poll for child completion with timeout
    while (true) {
        // Check if child has exited (non-blocking)
        const wait_result = std.posix.waitpid(child_pid, std.posix.W.NOHANG);
        if (wait_result.pid != 0) {
            // Child exited
            if (std.posix.W.IFEXITED(wait_result.status)) {
                return @intCast(std.posix.W.EXITSTATUS(wait_result.status));
            } else if (std.posix.W.IFSIGNALED(wait_result.status)) {
                return 128 + @as(i32, @intCast(std.posix.W.TERMSIG(wait_result.status)));
            }
            return 1;
        }

        // Check timeout
        const now = std.time.Instant.now() catch break;
        if (now.since(start_time) >= timeout_ns) {
            // Timeout - send signal
            std.posix.kill(child_pid, sig) catch {};

            // Wait a bit for graceful exit, then send KILL if -k was specified
            if (kill_after) |ka| {
                const ka_secs: u64 = @intFromFloat(ka);
                const ka_nanos: u64 = @intFromFloat((ka - @as(f64, @floatFromInt(ka_secs))) * 1_000_000_000);
                std.posix.nanosleep(ka_secs, ka_nanos);
                // Check if still running
                const check = std.posix.waitpid(child_pid, std.posix.W.NOHANG);
                if (check.pid == 0) {
                    // Still running, send KILL
                    std.posix.kill(child_pid, std.posix.SIG.KILL) catch {};
                }
            }

            // Wait for child to actually exit
            const final_result = std.posix.waitpid(child_pid, 0);
            if (preserve_status) {
                if (std.posix.W.IFEXITED(final_result.status)) {
                    return @intCast(std.posix.W.EXITSTATUS(final_result.status));
                } else if (std.posix.W.IFSIGNALED(final_result.status)) {
                    return 128 + @as(i32, @intCast(std.posix.W.TERMSIG(final_result.status)));
                }
            }
            return 124; // Standard timeout exit code
        }

        // Sleep briefly before checking again
        std.posix.nanosleep(0, 10_000_000); // 10ms
    }

    return 1;
}

/// Parse duration string (e.g., "5", "5s", "2m", "1h", "1d")
pub fn parseDuration(str: []const u8) !f64 {
    if (str.len == 0) return error.InvalidDuration;

    var num_end: usize = str.len;
    var multiplier: f64 = 1.0;

    // Check for suffix
    if (str.len > 0) {
        const last = str[str.len - 1];
        if (last == 's' or last == 'S') {
            num_end = str.len - 1;
            multiplier = 1.0;
        } else if (last == 'm' or last == 'M') {
            num_end = str.len - 1;
            multiplier = 60.0;
        } else if (last == 'h' or last == 'H') {
            num_end = str.len - 1;
            multiplier = 3600.0;
        } else if (last == 'd' or last == 'D') {
            num_end = str.len - 1;
            multiplier = 86400.0;
        }
    }

    if (num_end == 0) return error.InvalidDuration;

    const num = std.fmt.parseFloat(f64, str[0..num_end]) catch return error.InvalidDuration;
    return num * multiplier;
}

/// Convert signal name to signal enum for timeout
pub fn parseSignalName(name: []const u8) std.posix.SIG {
    const upper = blk: {
        var buf: [16]u8 = undefined;
        const len = @min(name.len, buf.len);
        for (name[0..len], 0..) |c, i| {
            buf[i] = std.ascii.toUpper(c);
        }
        break :blk buf[0..len];
    };

    // Handle numeric signal
    if (std.fmt.parseInt(u6, name, 10)) |num| {
        return @enumFromInt(num);
    } else |_| {}

    // Remove SIG prefix if present
    const sig_name = if (std.mem.startsWith(u8, upper, "SIG")) upper[3..] else upper;

    // Map common signal names
    if (std.mem.eql(u8, sig_name, "HUP")) return .HUP;
    if (std.mem.eql(u8, sig_name, "INT")) return .INT;
    if (std.mem.eql(u8, sig_name, "QUIT")) return .QUIT;
    if (std.mem.eql(u8, sig_name, "ILL")) return .ILL;
    if (std.mem.eql(u8, sig_name, "TRAP")) return .TRAP;
    if (std.mem.eql(u8, sig_name, "ABRT")) return .ABRT;
    if (std.mem.eql(u8, sig_name, "BUS")) return .BUS;
    if (std.mem.eql(u8, sig_name, "FPE")) return .FPE;
    if (std.mem.eql(u8, sig_name, "KILL")) return .KILL;
    if (std.mem.eql(u8, sig_name, "USR1")) return .USR1;
    if (std.mem.eql(u8, sig_name, "SEGV")) return .SEGV;
    if (std.mem.eql(u8, sig_name, "USR2")) return .USR2;
    if (std.mem.eql(u8, sig_name, "PIPE")) return .PIPE;
    if (std.mem.eql(u8, sig_name, "ALRM")) return .ALRM;
    if (std.mem.eql(u8, sig_name, "TERM")) return .TERM;
    if (std.mem.eql(u8, sig_name, "CHLD")) return .CHLD;
    if (std.mem.eql(u8, sig_name, "CONT")) return .CONT;
    if (std.mem.eql(u8, sig_name, "STOP")) return .STOP;
    if (std.mem.eql(u8, sig_name, "TSTP")) return .TSTP;

    return .TERM; // Default to SIGTERM
}

/// Get C environment pointer (platform-specific)
fn getCEnviron() [*:null]const ?[*:0]const u8 {
    if (builtin.os.tag == .macos) {
        const NSGetEnviron = @extern(*const fn () callconv(.c) *[*:null]?[*:0]u8, .{ .name = "_NSGetEnviron" });
        return @ptrCast(NSGetEnviron().*);
    } else {
        const c_environ = @extern(*[*:null]?[*:0]u8, .{ .name = "environ" });
        return @ptrCast(c_environ.*);
    }
}
