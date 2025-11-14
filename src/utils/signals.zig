const std = @import("std");
const builtin = @import("builtin");

/// Signal handler state
var signal_received: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var window_size_changed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Signal types we handle
pub const Signal = enum {
    none,
    interrupt,  // SIGINT (Ctrl+C)
    terminate,  // SIGTERM
    winch,      // SIGWINCH (window resize)

    pub fn fromPosix(sig: u32) Signal {
        if (builtin.os.tag == .windows) {
            return .none;
        }

        return switch (sig) {
            std.posix.SIG.INT => .interrupt,
            std.posix.SIG.TERM => .terminate,
            std.posix.SIG.WINCH => .winch,
            else => .none,
        };
    }
};

/// Terminal window size
pub const WindowSize = struct {
    rows: u16,
    cols: u16,
};

/// Install signal handlers
pub fn installHandlers() !void {
    if (builtin.os.tag == .windows) {
        // Windows signal handling not yet implemented
        return;
    }

    // Create empty signal mask
    const empty_mask = std.posix.sigemptyset();

    // Install SIGINT handler (Ctrl+C)
    var sigint_action = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = empty_mask,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sigint_action, null);

    // Install SIGTERM handler
    var sigterm_action = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = empty_mask,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &sigterm_action, null);

    // Install SIGWINCH handler (window resize)
    var sigwinch_action = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = empty_mask,
        .flags = std.posix.SA.RESTART, // Restart syscalls if interrupted
    };
    std.posix.sigaction(std.posix.SIG.WINCH, &sigwinch_action, null);
}

/// Signal handler function
fn handleSignal(sig: c_int) callconv(.c) void {
    const signal = Signal.fromPosix(@intCast(sig));

    switch (signal) {
        .interrupt, .terminate => {
            signal_received.store(@intCast(sig), .release);
        },
        .winch => {
            window_size_changed.store(true, .release);
        },
        .none => {},
    }
}

/// Check if a signal was received and return it
pub fn checkSignal() ?Signal {
    const sig = signal_received.swap(0, .acquire);
    if (sig == 0) return null;
    return Signal.fromPosix(sig);
}

/// Check if window size changed and reset the flag
pub fn checkWindowSizeChanged() bool {
    return window_size_changed.swap(false, .acquire);
}

/// Get current terminal window size
pub fn getWindowSize() !WindowSize {
    if (builtin.os.tag == .windows) {
        // Windows implementation
        const windows = std.os.windows;
        const handle = try windows.GetStdHandle(windows.STD_OUTPUT_HANDLE);

        var info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (windows.kernel32.GetConsoleScreenBufferInfo(handle, &info) == 0) {
            return error.GetConsoleFailed;
        }

        const cols = @as(u16, @intCast(info.srWindow.Right - info.srWindow.Left + 1));
        const rows = @as(u16, @intCast(info.srWindow.Bottom - info.srWindow.Top + 1));

        return WindowSize{
            .rows = rows,
            .cols = cols,
        };
    } else {
        // Unix implementation using ioctl
        const TIOCGWINSZ = if (builtin.os.tag == .linux)
            0x5413
        else if (builtin.os.tag == .macos or builtin.os.tag == .freebsd or builtin.os.tag == .netbsd or builtin.os.tag == .openbsd)
            0x40087468
        else
            0x5413; // Default to Linux value

        var ws: std.posix.winsize = undefined;
        const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, TIOCGWINSZ, @intFromPtr(&ws));

        if (rc != 0) {
            return error.IoctlFailed;
        }

        return WindowSize{
            .rows = ws.ws_row,
            .cols = ws.ws_col,
        };
    }
}

/// Reset signal handlers to default
pub fn resetHandlers() !void {
    if (builtin.os.tag == .windows) {
        return;
    }

    // Create empty signal mask
    const empty_mask = std.posix.sigemptyset();

    // Reset SIGINT
    var sigint_action = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = empty_mask,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sigint_action, null);

    // Reset SIGTERM
    var sigterm_action = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = empty_mask,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &sigterm_action, null);

    // Reset SIGWINCH
    var sigwinch_action = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = empty_mask,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.WINCH, &sigwinch_action, null);
}

test "signal handling basic" {
    const testing = std.testing;

    // Test initial state
    try testing.expectEqual(@as(?Signal, null), checkSignal());
    try testing.expectEqual(false, checkWindowSizeChanged());
}

test "window size" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const size = try getWindowSize();

    // Basic sanity checks
    const testing = std.testing;
    try testing.expect(size.rows > 0);
    try testing.expect(size.cols > 0);
    try testing.expect(size.rows < 1000); // Reasonable upper bound
    try testing.expect(size.cols < 1000);
}
