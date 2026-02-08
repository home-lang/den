const std = @import("std");
const builtin = @import("builtin");
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;

const c_exec = struct {
    extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
};

const c_kq = struct {
    extern "c" fn kqueue() c_int;
};

/// Kevent structure matching the macOS C definition.
const Kevent = extern struct {
    ident: usize,
    filter: i16,
    flags: u16,
    fflags: u32,
    data: isize,
    udata: ?*anyopaque,
};

/// C kevent() function for kqueue event registration and polling.
const c_kqueue = struct {
    extern "c" fn kevent(
        kq: c_int,
        changelist: [*]const Kevent,
        nchanges: c_int,
        eventlist: [*]Kevent,
        nevents: c_int,
        timeout: ?*const std.posix.timespec,
    ) c_int;
};

// kqueue filter and flag constants for macOS
const EVFILT_VNODE: i16 = -4;
const EV_ADD: u16 = 0x0001;
const EV_ENABLE: u16 = 0x0004;
const EV_CLEAR: u16 = 0x0020;

const NOTE_DELETE: u32 = 0x00000001;
const NOTE_WRITE: u32 = 0x00000002;
const NOTE_EXTEND: u32 = 0x00000004;
const NOTE_ATTRIB: u32 = 0x00000008;
const NOTE_RENAME: u32 = 0x00000020;

/// Global flag for graceful Ctrl+C handling.
var watch_interrupted: bool = false;

/// Signal handler for SIGINT during watch.
fn sigintHandler(_: std.posix.SIG) callconv(.c) void {
    watch_interrupted = true;
}

/// watch <path> <command> - Watch a file or directory and run a command on changes.
///
/// Usage:
///   watch <path> <command...>
///   watch --interval <ms> <path> <command...>
///   watch -i <ms> <path> <command...>
///
/// Options:
///   -i, --interval <ms>   Debounce interval in milliseconds (default: 500)
///   -h, --help            Show help
///
/// When changes are detected on <path>, prints "changed: <path>" and runs <command>
/// via /bin/sh -c. Watches for writes, deletes, renames, and attribute changes.
/// Press Ctrl+C to stop.
pub fn watchCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    var interval_ms: u64 = 500;
    var path: ?[]const u8 = null;
    var cmd_start: ?usize = null;

    // Parse arguments
    var i: usize = 0;
    while (i < command.args.len) : (i += 1) {
        const arg = command.args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printHelp();
            return 0;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--interval")) {
            if (i + 1 >= command.args.len) {
                try IO.eprint("den: watch: --interval requires a value\n", .{});
                return 1;
            }
            i += 1;
            interval_ms = std.fmt.parseInt(u64, command.args[i], 10) catch {
                try IO.eprint("den: watch: invalid interval: {s}\n", .{command.args[i]});
                return 1;
            };
        } else if (path == null) {
            path = arg;
        } else {
            cmd_start = i;
            break;
        }
    }

    if (path == null) {
        try IO.eprint("den: watch: missing path argument\n", .{});
        try IO.eprint("Usage: watch <path> <command...>\n", .{});
        return 1;
    }

    if (cmd_start == null) {
        try IO.eprint("den: watch: missing command argument\n", .{});
        try IO.eprint("Usage: watch <path> <command...>\n", .{});
        return 1;
    }

    const watch_path = path.?;

    // Build the shell command string by joining remaining args
    const shell_cmd = buildShellCommand(allocator, command.args[cmd_start.?..]) catch {
        try IO.eprint("den: watch: out of memory\n", .{});
        return 1;
    };
    defer allocator.free(shell_cmd);

    // Install SIGINT handler for graceful shutdown
    watch_interrupted = false;
    var old_action: std.posix.Sigaction = undefined;
    const new_action = std.posix.Sigaction{
        .handler = .{ .handler = sigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &new_action, &old_action);

    // Attempt kqueue-based watching on macOS, fall back to polling otherwise
    const result = if (builtin.os.tag == .macos)
        watchWithKqueue(allocator, watch_path, shell_cmd, interval_ms)
    else
        watchWithPolling(allocator, watch_path, shell_cmd, interval_ms);

    // Restore original SIGINT handler
    std.posix.sigaction(std.posix.SIG.INT, &old_action, null);

    if (result) |exit_code| {
        return exit_code;
    } else |err| {
        // If kqueue failed on macOS, try polling as fallback
        if (builtin.os.tag == .macos) {
            const poll_result = watchWithPolling(allocator, watch_path, shell_cmd, interval_ms);
            if (poll_result) |exit_code| {
                return exit_code;
            } else |poll_err| {
                try IO.eprint("den: watch: failed to watch '{s}': {}\n", .{ watch_path, poll_err });
                return 1;
            }
        }
        try IO.eprint("den: watch: failed to watch '{s}': {}\n", .{ watch_path, err });
        return 1;
    }
}

/// Watch a path using macOS kqueue for efficient file system event notification.
fn watchWithKqueue(allocator: std.mem.Allocator, watch_path: []const u8, shell_cmd: []const u8, interval_ms: u64) !i32 {
    // Create null-terminated path for C open()
    const path_z = try allocator.dupeZ(u8, watch_path);
    defer allocator.free(path_z);

    // Open the target path for event monitoring (read-only)
    const watch_fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (watch_fd < 0) {
        try IO.eprint("den: watch: cannot open '{s}' for watching\n", .{watch_path});
        return 1;
    }
    defer std.posix.close(@intCast(watch_fd));

    // Create a kqueue file descriptor
    const kq_fd = c_kq.kqueue();
    if (kq_fd < 0) {
        try IO.eprint("den: watch: failed to create kqueue\n", .{});
        return error.KqueueFailed;
    }
    const kq: std.posix.fd_t = @intCast(kq_fd);
    defer std.posix.close(kq);

    // Register EVFILT_VNODE event for the watched path
    var changelist = [1]Kevent{
        .{
            .ident = @intCast(watch_fd),
            .filter = EVFILT_VNODE,
            .flags = EV_ADD | EV_ENABLE | EV_CLEAR,
            .fflags = NOTE_WRITE | NOTE_DELETE | NOTE_RENAME | NOTE_ATTRIB | NOTE_EXTEND,
            .data = 0,
            .udata = null,
        },
    };

    // Register the event (pass changelist for registration, empty eventlist)
    var empty_eventlist: [1]Kevent = undefined;
    const reg_result = c_kqueue.kevent(kq, &changelist, 1, &empty_eventlist, 0, null);
    if (reg_result < 0) {
        try IO.eprint("den: watch: failed to register kqueue event\n", .{});
        return error.KqueueRegisterFailed;
    }

    // Create null-terminated shell command for exec
    const cmd_z = try allocator.dupeZ(u8, shell_cmd);
    defer allocator.free(cmd_z);

    try IO.print("Watching '{s}' for changes (Ctrl+C to stop)...\n", .{watch_path});

    // Convert interval to nanoseconds for debounce
    const debounce_ns: u64 = interval_ms * 1_000_000;
    var last_event_time: u64 = 0;

    // Main event loop
    while (!watch_interrupted) {
        var eventlist: [1]Kevent = undefined;

        // Use a short timeout so we can check the interrupt flag periodically
        const timeout = std.posix.timespec{
            .sec = @intCast(1),
            .nsec = @intCast(0),
        };

        const nevents = c_kqueue.kevent(kq, &changelist, 0, &eventlist, 1, &timeout);

        if (watch_interrupted) break;

        if (nevents < 0) {
            // EINTR is expected when a signal is received
            continue;
        }

        if (nevents == 0) {
            // Timeout with no events, loop and recheck interrupt flag
            continue;
        }

        // Event received - apply debounce
        const now = getCurrentTimeNs();
        if (now > 0 and last_event_time > 0 and (now - last_event_time) < debounce_ns) {
            continue;
        }
        last_event_time = now;

        // Describe what changed
        const fflags = eventlist[0].fflags;
        const change_type = describeChange(fflags);
        try IO.print("\x1b[1;33mchanged:\x1b[0m {s} ({s})\n", .{ watch_path, change_type });

        // Execute the command
        const exit_code = executeShellCommand(cmd_z);
        if (exit_code != 0) {
            try IO.eprint("\x1b[1;31mcommand exited with code {d}\x1b[0m\n", .{exit_code});
        }
    }

    try IO.print("\nWatch stopped.\n", .{});
    return 0;
}

/// Fallback: watch a path using stat()-based polling with a configurable interval.
fn watchWithPolling(allocator: std.mem.Allocator, watch_path: []const u8, shell_cmd: []const u8, interval_ms: u64) !i32 {
    // Get initial file stats
    var last_mtime = getFileMtime(watch_path) catch |err| {
        try IO.eprint("den: watch: cannot stat '{s}': {}\n", .{ watch_path, err });
        return 1;
    };
    var last_size = getFileSize(watch_path) catch 0;

    // Create null-terminated shell command for exec
    const cmd_z = try allocator.dupeZ(u8, shell_cmd);
    defer allocator.free(cmd_z);

    try IO.print("Watching '{s}' for changes (polling every {d}ms, Ctrl+C to stop)...\n", .{ watch_path, interval_ms });

    const sleep_ns: u64 = interval_ms * 1_000_000;

    // Main polling loop
    while (!watch_interrupted) {
        // Sleep for the polling interval
        std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromNanoseconds(sleep_ns), .awake) catch {};

        if (watch_interrupted) break;

        // Check for changes
        const current_mtime = getFileMtime(watch_path) catch {
            // File may have been deleted
            try IO.print("\x1b[1;33mchanged:\x1b[0m {s} (deleted or inaccessible)\n", .{watch_path});
            const exit_code = executeShellCommand(cmd_z);
            if (exit_code != 0) {
                try IO.eprint("\x1b[1;31mcommand exited with code {d}\x1b[0m\n", .{exit_code});
            }
            // Wait for the file to reappear
            while (!watch_interrupted) {
                std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromNanoseconds(sleep_ns), .awake) catch {};
                last_mtime = getFileMtime(watch_path) catch continue;
                last_size = getFileSize(watch_path) catch 0;
                break;
            }
            continue;
        };
        const current_size = getFileSize(watch_path) catch 0;

        if (current_mtime != last_mtime or current_size != last_size) {
            try IO.print("\x1b[1;33mchanged:\x1b[0m {s} (modified)\n", .{watch_path});

            last_mtime = current_mtime;
            last_size = current_size;

            // Execute the command
            const exit_code = executeShellCommand(cmd_z);
            if (exit_code != 0) {
                try IO.eprint("\x1b[1;31mcommand exited with code {d}\x1b[0m\n", .{exit_code});
            }
        }
    }

    try IO.print("\nWatch stopped.\n", .{});
    return 0;
}

/// Execute a shell command via fork/exec of /bin/sh -c "<command>".
/// The cmd_z parameter must be a null-terminated command string.
/// Returns the exit code of the child process.
fn executeShellCommand(cmd_z: [*:0]const u8) i32 {
    const argv = [_]?[*:0]const u8{
        "/bin/sh",
        "-c",
        cmd_z,
        null,
    };

    const fork_ret = std.c.fork();
    if (fork_ret < 0) {
        return 127;
    }
    const pid: std.posix.pid_t = @intCast(fork_ret);

    if (pid == 0) {
        // Child process: exec /bin/sh -c "<command>"
        _ = c_exec.execvp("/bin/sh", @ptrCast(&argv));
        std.c._exit(127);
    }

    // Parent: wait for child to finish
    var wait_status: c_int = 0;
    _ = std.c.waitpid(pid, &wait_status, 0);
    const status_u32: u32 = @bitCast(wait_status);
    if (std.posix.W.IFEXITED(status_u32)) {
        return @intCast(std.posix.W.EXITSTATUS(status_u32));
    } else if (std.posix.W.IFSIGNALED(status_u32)) {
        return 128 + @as(i32, @intCast(@intFromEnum(std.posix.W.TERMSIG(status_u32))));
    }
    return 1;
}

/// Build a single shell command string from argument slices.
fn buildShellCommand(allocator: std.mem.Allocator, args: [][]const u8) ![]u8 {
    if (args.len == 0) return error.EmptyCommand;

    // Calculate total length needed
    var total_len: usize = 0;
    for (args, 0..) |arg, idx| {
        if (idx > 0) total_len += 1; // space separator
        total_len += arg.len;
    }

    const buf = try allocator.alloc(u8, total_len);
    var pos: usize = 0;
    for (args, 0..) |arg, idx| {
        if (idx > 0) {
            buf[pos] = ' ';
            pos += 1;
        }
        @memcpy(buf[pos..][0..arg.len], arg);
        pos += arg.len;
    }

    return buf;
}

/// Get file modification time as a nanosecond timestamp.
fn getFileMtime(path: []const u8) !i96 {
    const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{}) catch |err| {
        return err;
    };
    return stat.mtime.nanoseconds;
}

/// Get file size.
fn getFileSize(path: []const u8) !u64 {
    const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{}) catch |err| {
        return err;
    };
    return stat.size;
}

/// Get the current monotonic time in nanoseconds for debounce timing.
fn getCurrentTimeNs() u64 {
    const instant = std.time.Instant.now() catch return 0;
    // Convert the Instant's internal timestamp (sec + nsec) to a single nanosecond value.
    // Use the same approach as async_git.zig but in nanoseconds.
    const sec_ns = @as(i64, instant.timestamp.sec) * 1_000_000_000;
    const total_ns = sec_ns + @as(i64, instant.timestamp.nsec);
    return if (total_ns > 0) @intCast(total_ns) else 0;
}

/// Describe what kind of change occurred based on kqueue fflags.
fn describeChange(fflags: u32) []const u8 {
    if (fflags & NOTE_DELETE != 0) return "deleted";
    if (fflags & NOTE_RENAME != 0) return "renamed";
    if (fflags & NOTE_WRITE != 0) return "written";
    if (fflags & NOTE_EXTEND != 0) return "extended";
    if (fflags & NOTE_ATTRIB != 0) return "attributes changed";
    return "changed";
}

/// Print help text for the watch command.
fn printHelp() !void {
    try IO.print("watch - watch a file or directory and run a command on changes\n", .{});
    try IO.print("Usage: watch [options] <path> <command...>\n", .{});
    try IO.print("\nOptions:\n", .{});
    try IO.print("  -i, --interval <ms>  Debounce interval in milliseconds (default: 500)\n", .{});
    try IO.print("  -h, --help           Show this help message\n", .{});
    try IO.print("\nExamples:\n", .{});
    try IO.print("  watch src/ make build          # Rebuild on source changes\n", .{});
    try IO.print("  watch config.json echo updated # Echo when config changes\n", .{});
    try IO.print("  watch -i 1000 . ls -la         # Poll every 1s, list directory\n", .{});
    try IO.print("\nOn macOS, uses kqueue for efficient event-driven watching.\n", .{});
    try IO.print("On other platforms, uses stat()-based polling.\n", .{});
    try IO.print("Press Ctrl+C to stop watching.\n", .{});
}
