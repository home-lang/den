const std = @import("std");
const builtin = @import("builtin");

/// Stack trace configuration
pub const Config = struct {
    max_depth: usize = 64,
    use_color: bool = true,
    show_addresses: bool = true,
    show_module: bool = true,
};

/// Captured stack trace
pub const StackTrace = struct {
    addresses: []usize,
    count: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, max_depth: usize) !StackTrace {
        const addresses = try allocator.alloc(usize, max_depth);
        return .{
            .addresses = addresses,
            .count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StackTrace) void {
        self.allocator.free(self.addresses);
    }

    /// Capture the current stack trace
    pub fn capture(self: *StackTrace, skip_frames: usize) void {
        var stack = std.builtin.StackTrace{
            .instruction_addresses = self.addresses[0..],
            .index = 0,
        };

        std.debug.captureStackTrace(@returnAddress(), &stack);

        // Skip the requested frames plus our own frame
        const total_skip = skip_frames + 1;
        if (stack.index > total_skip) {
            self.count = stack.index - total_skip;
            // Move the addresses to the beginning
            var i: usize = 0;
            while (i < self.count) : (i += 1) {
                self.addresses[i] = self.addresses[i + total_skip];
            }
        } else {
            self.count = 0;
        }
    }

    /// Format the stack trace
    pub fn format(
        self: StackTrace,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.writeAll("Stack trace:\n");
        for (self.addresses[0..self.count], 0..) |addr, i| {
            try writer.print("  [{d}] 0x{x:0>16}\n", .{ i, addr });
        }
    }

    /// Print the stack trace with detailed formatting
    pub fn print(self: *const StackTrace, config: Config) void {
        const Color = struct {
            const reset = "\x1b[0m";
            const bold = "\x1b[1m";
            const dim = "\x1b[2m";
            const cyan = "\x1b[36m";
            const yellow = "\x1b[33m";
        };

        var buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();

        // Header
        if (config.use_color) {
            writer.print("{s}{s}Stack Trace:{s}\n", .{ Color.bold, Color.cyan, Color.reset }) catch return;
        } else {
            writer.writeAll("Stack Trace:\n") catch return;
        }

        // Print each frame
        for (self.addresses[0..self.count], 0..) |addr, i| {
            if (config.use_color) {
                writer.print("  {s}[{d}]{s} ", .{ Color.yellow, i, Color.reset }) catch continue;
            } else {
                writer.print("  [{d}] ", .{i}) catch continue;
            }

            if (config.show_addresses) {
                writer.print("0x{x:0>16}", .{addr}) catch continue;
            }

            writer.writeByte('\n') catch continue;
        }

        const output = fbs.getWritten();
        writeStderr(output);
    }
};

/// Print current stack trace
pub fn printCurrentStackTrace(config: Config) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stack = StackTrace.init(allocator, config.max_depth) catch return;
    defer stack.deinit();

    stack.capture(1); // Skip this frame
    stack.print(config);
}

/// Panic handler that prints a formatted stack trace
pub fn panicWithStackTrace(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;
    _ = ret_addr;

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    writer.print("\n\x1b[1m\x1b[31mPANIC:\x1b[0m {s}\n\n", .{msg}) catch {};

    writeStderr(fbs.getWritten());

    // Print stack trace
    printCurrentStackTrace(.{
        .use_color = true,
        .show_addresses = true,
        .show_module = true,
    });

    std.process.abort();
}

/// Helper to write to stderr
fn writeStderr(msg: []const u8) void {
    if (builtin.os.tag == .windows) {
        const handle = std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) orelse return;
        const stderr = std.fs.File{ .handle = handle };
        _ = stderr.write(msg) catch {};
    } else {
        _ = std.posix.write(std.posix.STDERR_FILENO, msg) catch {};
    }
}

/// Trace point for debugging execution flow
pub const TracePoint = struct {
    name: []const u8,
    file: []const u8,
    line: u32,
    time: i64,

    pub fn init(comptime src: std.builtin.SourceLocation, name: []const u8) TracePoint {
        return .{
            .name = name,
            .file = src.file,
            .line = src.line,
            .time = std.time.milliTimestamp(),
        };
    }

    pub fn print(self: TracePoint) void {
        var buf: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();

        writer.print("[TRACE] {s} at {s}:{d} (t={d}ms)\n", .{
            self.name,
            self.file,
            self.line,
            self.time,
        }) catch return;

        writeStderr(fbs.getWritten());
    }
};

/// Execution trace - tracks a series of trace points
pub const ExecutionTrace = struct {
    allocator: std.mem.Allocator,
    points: std.ArrayList(TracePoint),
    start_time: i64,

    pub fn init(allocator: std.mem.Allocator) ExecutionTrace {
        return .{
            .allocator = allocator,
            .points = std.ArrayList(TracePoint).init(allocator),
            .start_time = std.time.milliTimestamp(),
        };
    }

    pub fn deinit(self: *ExecutionTrace) void {
        self.points.deinit();
    }

    pub fn addPoint(self: *ExecutionTrace, point: TracePoint) !void {
        try self.points.append(point);
    }

    pub fn print(self: *const ExecutionTrace) void {
        var buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();

        writer.writeAll("\n=== Execution Trace ===\n") catch return;

        for (self.points.items, 0..) |point, i| {
            const elapsed = point.time - self.start_time;
            writer.print("[{d}] +{d}ms: {s} at {s}:{d}\n", .{
                i,
                elapsed,
                point.name,
                point.file,
                point.line,
            }) catch continue;
        }

        const total = std.time.milliTimestamp() - self.start_time;
        writer.print("\nTotal time: {d}ms\n", .{total}) catch return;

        writeStderr(fbs.getWritten());
    }
};

/// Macro to add a trace point
pub fn trace(comptime src: std.builtin.SourceLocation, name: []const u8) TracePoint {
    const point = TracePoint.init(src, name);
    if (builtin.mode == .Debug) {
        point.print();
    }
    return point;
}
