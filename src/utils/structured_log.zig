const std = @import("std");
const builtin = @import("builtin");
const log_mod = @import("log.zig");

/// Structured log field
pub const Field = union(enum) {
    string: []const u8,
    int: i64,
    uint: u64,
    float: f64,
    bool: bool,
    duration_ns: u64,
    bytes: usize,

    pub fn format(
        self: Field,
        writer: anytype,
    ) !void {
        switch (self) {
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .int => |i| try writer.print("{d}", .{i}),
            .uint => |u| try writer.print("{d}", .{u}),
            .float => |f| try writer.print("{d:.2}", .{f}),
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .duration_ns => |ns| {
                if (ns < 1000) {
                    try writer.print("{d}ns", .{ns});
                } else if (ns < 1_000_000) {
                    try writer.print("{d:.2}μs", .{@as(f64, @floatFromInt(ns)) / 1000.0});
                } else if (ns < 1_000_000_000) {
                    try writer.print("{d:.2}ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0});
                } else {
                    try writer.print("{d:.2}s", .{@as(f64, @floatFromInt(ns)) / 1_000_000_000.0});
                }
            },
            .bytes => |b| {
                if (b < 1024) {
                    try writer.print("{d}B", .{b});
                } else if (b < 1024 * 1024) {
                    try writer.print("{d:.2}KB", .{@as(f64, @floatFromInt(b)) / 1024.0});
                } else if (b < 1024 * 1024 * 1024) {
                    try writer.print("{d:.2}MB", .{@as(f64, @floatFromInt(b)) / (1024.0 * 1024.0)});
                } else {
                    try writer.print("{d:.2}GB", .{@as(f64, @floatFromInt(b)) / (1024.0 * 1024.0 * 1024.0)});
                }
            },
        }
    }
};

/// Structured logger for key-value logging
pub const StructuredLogger = struct {
    allocator: std.mem.Allocator,
    fields: std.StringHashMap(Field),

    pub fn init(allocator: std.mem.Allocator) StructuredLogger {
        return .{
            .allocator = allocator,
            .fields = std.StringHashMap(Field).init(allocator),
        };
    }

    pub fn deinit(self: *StructuredLogger) void {
        self.fields.deinit();
    }

    /// Add a string field
    pub fn withString(self: *StructuredLogger, key: []const u8, value: []const u8) !void {
        try self.fields.put(key, .{ .string = value });
    }

    /// Add an integer field
    pub fn withInt(self: *StructuredLogger, key: []const u8, value: i64) !void {
        try self.fields.put(key, .{ .int = value });
    }

    /// Add an unsigned integer field
    pub fn withUint(self: *StructuredLogger, key: []const u8, value: u64) !void {
        try self.fields.put(key, .{ .uint = value });
    }

    /// Add a float field
    pub fn withFloat(self: *StructuredLogger, key: []const u8, value: f64) !void {
        try self.fields.put(key, .{ .float = value });
    }

    /// Add a boolean field
    pub fn withBool(self: *StructuredLogger, key: []const u8, value: bool) !void {
        try self.fields.put(key, .{ .bool = value });
    }

    /// Add a duration field (in nanoseconds)
    pub fn withDuration(self: *StructuredLogger, key: []const u8, ns: u64) !void {
        try self.fields.put(key, .{ .duration_ns = ns });
    }

    /// Add a bytes field (formatted as KB, MB, etc.)
    pub fn withBytes(self: *StructuredLogger, key: []const u8, bytes: usize) !void {
        try self.fields.put(key, .{ .bytes = bytes });
    }

    /// Log the structured message
    pub fn log(
        self: *StructuredLogger,
        level: log_mod.Level,
        comptime src: std.builtin.SourceLocation,
        comptime msg: []const u8,
    ) void {
        var buf: [4096]u8 = undefined;
        var pos: usize = 0;

        // Write the main message
        if (pos + msg.len <= buf.len) {
            @memcpy(buf[pos..][0..msg.len], msg);
            pos += msg.len;
        }

        // Add fields
        if (self.fields.count() > 0) {
            if (pos + 2 <= buf.len) {
                buf[pos] = ' ';
                buf[pos + 1] = '{';
                pos += 2;
            }
            var it = self.fields.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) {
                    if (pos + 2 <= buf.len) {
                        buf[pos] = ',';
                        buf[pos + 1] = ' ';
                        pos += 2;
                    }
                }
                // Format the field
                if (std.fmt.bufPrint(buf[pos..], "{s}=", .{entry.key_ptr.*})) |result| {
                    pos += result.len;
                } else |_| {}
                // Format the value based on its type
                switch (entry.value_ptr.*) {
                    .string => |s| {
                        if (std.fmt.bufPrint(buf[pos..], "\"{s}\"", .{s})) |result| {
                            pos += result.len;
                        } else |_| {}
                    },
                    .int => |i| {
                        if (std.fmt.bufPrint(buf[pos..], "{d}", .{i})) |result| {
                            pos += result.len;
                        } else |_| {}
                    },
                    .uint => |u| {
                        if (std.fmt.bufPrint(buf[pos..], "{d}", .{u})) |result| {
                            pos += result.len;
                        } else |_| {}
                    },
                    .float => |f| {
                        if (std.fmt.bufPrint(buf[pos..], "{d:.2}", .{f})) |result| {
                            pos += result.len;
                        } else |_| {}
                    },
                    .bool => |b| {
                        const val = if (b) "true" else "false";
                        if (pos + val.len <= buf.len) {
                            @memcpy(buf[pos..][0..val.len], val);
                            pos += val.len;
                        }
                    },
                    .duration_ns => |ns| {
                        if (ns < 1000) {
                            if (std.fmt.bufPrint(buf[pos..], "{d}ns", .{ns})) |result| pos += result.len else |_| {}
                        } else if (ns < 1_000_000) {
                            if (std.fmt.bufPrint(buf[pos..], "{d:.2}us", .{@as(f64, @floatFromInt(ns)) / 1000.0})) |result| pos += result.len else |_| {}
                        } else if (ns < 1_000_000_000) {
                            if (std.fmt.bufPrint(buf[pos..], "{d:.2}ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0})) |result| pos += result.len else |_| {}
                        } else {
                            if (std.fmt.bufPrint(buf[pos..], "{d:.2}s", .{@as(f64, @floatFromInt(ns)) / 1_000_000_000.0})) |result| pos += result.len else |_| {}
                        }
                    },
                    .bytes => |b| {
                        if (b < 1024) {
                            if (std.fmt.bufPrint(buf[pos..], "{d}B", .{b})) |result| pos += result.len else |_| {}
                        } else if (b < 1024 * 1024) {
                            if (std.fmt.bufPrint(buf[pos..], "{d:.2}KB", .{@as(f64, @floatFromInt(b)) / 1024.0})) |result| pos += result.len else |_| {}
                        } else if (b < 1024 * 1024 * 1024) {
                            if (std.fmt.bufPrint(buf[pos..], "{d:.2}MB", .{@as(f64, @floatFromInt(b)) / (1024.0 * 1024.0)})) |result| pos += result.len else |_| {}
                        } else {
                            if (std.fmt.bufPrint(buf[pos..], "{d:.2}GB", .{@as(f64, @floatFromInt(b)) / (1024.0 * 1024.0 * 1024.0)})) |result| pos += result.len else |_| {}
                        }
                    },
                }
                first = false;
            }
            if (pos < buf.len) {
                buf[pos] = '}';
                pos += 1;
            }
        }

        // Log using the standard logger
        const logger = log_mod.getLogger();
        logger.log(level, src, "{s}", .{buf[0..pos]});
    }

    /// Convenience methods for each log level
    pub fn debug(self: *StructuredLogger, comptime src: std.builtin.SourceLocation, comptime msg: []const u8) void {
        self.log(.debug, src, msg);
    }

    pub fn info(self: *StructuredLogger, comptime src: std.builtin.SourceLocation, comptime msg: []const u8) void {
        self.log(.info, src, msg);
    }

    pub fn warn(self: *StructuredLogger, comptime src: std.builtin.SourceLocation, comptime msg: []const u8) void {
        self.log(.warn, src, msg);
    }

    pub fn err(self: *StructuredLogger, comptime src: std.builtin.SourceLocation, comptime msg: []const u8) void {
        self.log(.err, src, msg);
    }

    pub fn fatal(self: *StructuredLogger, comptime src: std.builtin.SourceLocation, comptime msg: []const u8) void {
        self.log(.fatal, src, msg);
    }
};
