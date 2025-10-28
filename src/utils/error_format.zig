const std = @import("std");
const builtin = @import("builtin");

/// ANSI color codes
const Color = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const red = "\x1b[31m";
    const yellow = "\x1b[33m";
    const cyan = "\x1b[36m";
};

/// Error context for better error messages
pub const ErrorContext = struct {
    file: []const u8,
    line: u32,
    column: u32,
    function: []const u8,
    message: []const u8,

    pub fn init(
        file: []const u8,
        line: u32,
        column: u32,
        function: []const u8,
        message: []const u8,
    ) ErrorContext {
        return .{
            .file = file,
            .line = line,
            .column = column,
            .function = function,
            .message = message,
        };
    }
};

/// Format an error with context
pub fn formatError(
    allocator: std.mem.Allocator,
    err: anyerror,
    context: ?ErrorContext,
    use_color: bool,
) ![]const u8 {
    var buf = std.ArrayList(u8){};
    const writer = buf.writer();

    // Error header
    if (use_color) {
        try writer.print("{s}{s}error:{s} ", .{ Color.bold, Color.red, Color.reset });
    } else {
        try writer.writeAll("error: ");
    }

    // Error name
    try writer.print("{s}\n", .{@errorName(err)});

    // Context information
    if (context) |ctx| {
        // Location
        if (use_color) {
            try writer.print("  {s}-->{s} {s}:{d}:{d}\n", .{
                Color.cyan,
                Color.reset,
                ctx.file,
                ctx.line,
                ctx.column,
            });
        } else {
            try writer.print("  --> {s}:{d}:{d}\n", .{ ctx.file, ctx.line, ctx.column });
        }

        // Function
        if (ctx.function.len > 0) {
            if (use_color) {
                try writer.print("  {s}in:{s} {s}\n", .{ Color.dim, Color.reset, ctx.function });
            } else {
                try writer.print("  in: {s}\n", .{ctx.function});
            }
        }

        // Message
        if (ctx.message.len > 0) {
            try writer.print("\n  {s}\n", .{ctx.message});
        }
    }

    return buf.toOwnedSlice();
}

/// Format an error chain (multiple errors in sequence)
pub fn formatErrorChain(
    allocator: std.mem.Allocator,
    errors: []const anyerror,
    contexts: []const ?ErrorContext,
    use_color: bool,
) ![]const u8 {
    var buf = std.ArrayList(u8){};
    const writer = buf.writer();

    if (use_color) {
        try writer.print("{s}{s}error chain:{s}\n", .{ Color.bold, Color.red, Color.reset });
    } else {
        try writer.writeAll("error chain:\n");
    }

    for (errors, 0..) |err, i| {
        const ctx = if (i < contexts.len) contexts[i] else null;

        // Chain indicator
        if (use_color) {
            try writer.print("\n{s}[{d}]{s} ", .{ Color.yellow, i + 1, Color.reset });
        } else {
            try writer.print("\n[{d}] ", .{i + 1});
        }

        // Error name
        try writer.print("{s}\n", .{@errorName(err)});

        // Context
        if (ctx) |c| {
            if (use_color) {
                try writer.print("    {s}-->{s} {s}:{d}:{d}\n", .{
                    Color.cyan,
                    Color.reset,
                    c.file,
                    c.line,
                    c.column,
                });
            } else {
                try writer.print("    --> {s}:{d}:{d}\n", .{ c.file, c.line, c.column });
            }

            if (c.message.len > 0) {
                try writer.print("    {s}\n", .{c.message});
            }
        }
    }

    return buf.toOwnedSlice();
}

/// Print a formatted error to stderr
pub fn printError(err: anyerror, context: ?ErrorContext, use_color: bool) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const formatted = formatError(allocator, err, context, use_color) catch {
        // Fallback if formatting fails
        const msg = std.fmt.allocPrint(allocator, "error: {s}\n", .{@errorName(err)}) catch return;
        writeStderr(msg);
        return;
    };

    writeStderr(formatted);
}

/// Print a formatted error chain to stderr
pub fn printErrorChain(
    errors: []const anyerror,
    contexts: []const ?ErrorContext,
    use_color: bool,
) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const formatted = formatErrorChain(allocator, errors, contexts, use_color) catch {
        // Fallback if formatting fails
        writeStderr("error chain:\n");
        for (errors, 0..) |err, i| {
            const msg = std.fmt.allocPrint(allocator, "[{d}] {s}\n", .{ i + 1, @errorName(err) }) catch continue;
            writeStderr(msg);
        }
        return;
    };

    writeStderr(formatted);
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

/// Create an error with source location
pub fn errorWithLocation(
    comptime err: anyerror,
    comptime src: std.builtin.SourceLocation,
) ErrorWithLocation {
    return .{
        .err = err,
        .file = src.file,
        .line = src.line,
        .function = src.fn_name,
    };
}

pub const ErrorWithLocation = struct {
    err: anyerror,
    file: []const u8,
    line: u32,
    function: []const u8,

    pub fn format(
        self: ErrorWithLocation,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s} at {s}:{d} in {s}", .{
            @errorName(self.err),
            self.file,
            self.line,
            self.function,
        });
    }
};

/// Try with error context - wraps a function call with automatic error context
pub fn tryWithContext(
    comptime T: type,
    comptime src: std.builtin.SourceLocation,
    result: anyerror!T,
    message: []const u8,
) anyerror!T {
    return result catch |err| {
        const context = ErrorContext.init(
            src.file,
            src.line,
            0,
            src.fn_name,
            message,
        );
        printError(err, context, true);
        return err;
    };
}
