const std = @import("std");

/// Structured Value type system for Den shell
/// Inspired by Nushell's structured data pipelines
/// All new features are additive - existing POSIX behavior remains untouched
pub const Value = union(enum) {
    /// Plain text string
    string: []const u8,
    /// Integer (i64)
    int: i64,
    /// Float (f64)
    float: f64,
    /// Boolean
    bool_val: bool,
    /// Nothing / null
    nothing,
    /// List of values
    list: List,
    /// Ordered key-value record
    record: Record,
    /// Table (list of records with uniform columns)
    table: Table,
    /// Duration in nanoseconds
    duration: i64,
    /// File size in bytes
    filesize: u64,
    /// Date/time as unix timestamp (nanoseconds since epoch)
    date: i64,
    /// Range (start..end or start..<end)
    range: Range,
    /// Raw binary data
    binary: []const u8,
    /// Closure (for pipeline operators)
    closure: Closure,
    /// Error value
    error_val: ErrorValue,

    pub const List = struct {
        items: []Value,

        pub fn deinit(self: *List, allocator: std.mem.Allocator) void {
            for (self.items) |*item| {
                item.deinit(allocator);
            }
            allocator.free(self.items);
        }

        pub fn clone(self: List, allocator: std.mem.Allocator) std.mem.Allocator.Error!List {
            const new_items = try allocator.alloc(Value, self.items.len);
            errdefer allocator.free(new_items);
            for (self.items, 0..) |item, i| {
                new_items[i] = try item.clone(allocator);
            }
            return .{ .items = new_items };
        }
    };

    pub const Record = struct {
        keys: [][]const u8,
        values: []Value,

        pub fn deinit(self: *Record, allocator: std.mem.Allocator) void {
            for (self.keys) |key| {
                allocator.free(key);
            }
            allocator.free(self.keys);
            for (self.values) |*val| {
                val.deinit(allocator);
            }
            allocator.free(self.values);
        }

        pub fn clone(self: Record, allocator: std.mem.Allocator) std.mem.Allocator.Error!Record {
            const new_keys = try allocator.alloc([]const u8, self.keys.len);
            errdefer allocator.free(new_keys);
            const new_values = try allocator.alloc(Value, self.values.len);
            errdefer allocator.free(new_values);
            for (self.keys, 0..) |key, i| {
                new_keys[i] = try allocator.dupe(u8, key);
            }
            for (self.values, 0..) |val, i| {
                new_values[i] = try val.clone(allocator);
            }
            return .{ .keys = new_keys, .values = new_values };
        }

        pub fn get(self: Record, key: []const u8) ?Value {
            for (self.keys, 0..) |k, i| {
                if (std.mem.eql(u8, k, key)) return self.values[i];
            }
            return null;
        }

        pub fn len(self: Record) usize {
            return self.keys.len;
        }
    };

    pub const Table = struct {
        columns: [][]const u8,
        rows: [][]Value,

        pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
            for (self.columns) |col| {
                allocator.free(col);
            }
            allocator.free(self.columns);
            for (self.rows) |row| {
                for (row) |*val| {
                    val.deinit(allocator);
                }
                allocator.free(row);
            }
            allocator.free(self.rows);
        }

        pub fn clone(self: Table, allocator: std.mem.Allocator) std.mem.Allocator.Error!Table {
            const new_cols = try allocator.alloc([]const u8, self.columns.len);
            errdefer allocator.free(new_cols);
            for (self.columns, 0..) |col, i| {
                new_cols[i] = try allocator.dupe(u8, col);
            }
            const new_rows = try allocator.alloc([]Value, self.rows.len);
            errdefer allocator.free(new_rows);
            for (self.rows, 0..) |row, i| {
                const new_row = try allocator.alloc(Value, row.len);
                for (row, 0..) |val, j| {
                    new_row[j] = try val.clone(allocator);
                }
                new_rows[i] = new_row;
            }
            return .{ .columns = new_cols, .rows = new_rows };
        }

        pub fn rowCount(self: Table) usize {
            return self.rows.len;
        }

        pub fn colCount(self: Table) usize {
            return self.columns.len;
        }

        /// Convert a row to a Record
        pub fn rowToRecord(self: Table, row_idx: usize, allocator: std.mem.Allocator) !Record {
            if (row_idx >= self.rows.len) return error.IndexOutOfBounds;
            const row = self.rows[row_idx];
            const keys = try allocator.alloc([]const u8, self.columns.len);
            errdefer allocator.free(keys);
            const values = try allocator.alloc(Value, self.columns.len);
            errdefer allocator.free(values);
            for (self.columns, 0..) |col, i| {
                keys[i] = try allocator.dupe(u8, col);
                values[i] = if (i < row.len) try row[i].clone(allocator) else .nothing;
            }
            return .{ .keys = keys, .values = values };
        }
    };

    pub const Range = struct {
        start: i64,
        end: i64,
        step: i64 = 1,
        inclusive: bool = true,

        pub fn iterator(self: Range) RangeIterator {
            return .{ .current = self.start, .end = self.end, .step = self.step, .inclusive = self.inclusive };
        }

        pub fn len(self: Range) usize {
            if (self.step == 0) return 0;
            if (self.step > 0 and self.start > self.end) return 0;
            if (self.step < 0 and self.start < self.end) return 0;
            const diff = if (self.step > 0)
                @as(u64, @intCast(self.end - self.start))
            else
                @as(u64, @intCast(self.start - self.end));
            const abs_step = if (self.step > 0) @as(u64, @intCast(self.step)) else @as(u64, @intCast(-self.step));
            const count = diff / abs_step;
            return @intCast(if (self.inclusive) count + 1 else count);
        }
    };

    pub const RangeIterator = struct {
        current: i64,
        end: i64,
        step: i64,
        inclusive: bool,

        pub fn next(self: *RangeIterator) ?i64 {
            if (self.step > 0) {
                if (self.inclusive and self.current > self.end) return null;
                if (!self.inclusive and self.current >= self.end) return null;
            } else if (self.step < 0) {
                if (self.inclusive and self.current < self.end) return null;
                if (!self.inclusive and self.current <= self.end) return null;
            } else {
                return null;
            }
            const val = self.current;
            self.current += self.step;
            return val;
        }
    };

    pub const Closure = struct {
        params: []const Param,
        body_source: []const u8,
        captures: []const Capture,

        pub const Param = struct {
            name: []const u8,
            type_hint: ?[]const u8 = null,
            default_value: ?*const Value = null,
        };

        pub const Capture = struct {
            name: []const u8,
            value: Value,
        };
    };

    pub const ErrorValue = struct {
        message: []const u8,
        code: ?i32 = null,
    };

    /// Free all owned memory
    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .list => |*l| {
                var list = l.*;
                list.deinit(allocator);
            },
            .record => |*r| {
                var rec = r.*;
                rec.deinit(allocator);
            },
            .table => |*t| {
                var tbl = t.*;
                tbl.deinit(allocator);
            },
            .binary => |b| allocator.free(b),
            .error_val => |e| allocator.free(e.message),
            .int, .float, .bool_val, .nothing, .duration, .filesize, .date, .range, .closure => {},
        }
    }

    /// Deep clone a value
    pub fn clone(self: Value, allocator: std.mem.Allocator) std.mem.Allocator.Error!Value {
        return switch (self) {
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
            .int => |i| .{ .int = i },
            .float => |f| .{ .float = f },
            .bool_val => |b| .{ .bool_val = b },
            .nothing => .nothing,
            .list => |l| .{ .list = try l.clone(allocator) },
            .record => |r| .{ .record = try r.clone(allocator) },
            .table => |t| .{ .table = try t.clone(allocator) },
            .duration => |d| .{ .duration = d },
            .filesize => |f| .{ .filesize = f },
            .date => |d| .{ .date = d },
            .range => |r| .{ .range = r },
            .binary => |b| .{ .binary = try allocator.dupe(u8, b) },
            .closure => |c| .{ .closure = c },
            .error_val => |e| .{ .error_val = .{ .message = try allocator.dupe(u8, e.message), .code = e.code } },
        };
    }

    /// Get the type name as a string
    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .string => "string",
            .int => "int",
            .float => "float",
            .bool_val => "bool",
            .nothing => "nothing",
            .list => "list",
            .record => "record",
            .table => "table",
            .duration => "duration",
            .filesize => "filesize",
            .date => "date",
            .range => "range",
            .binary => "binary",
            .closure => "closure",
            .error_val => "error",
        };
    }

    /// Convert to string representation
    pub fn asString(self: Value, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .string => |s| try allocator.dupe(u8, s),
            .int => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
            .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
            .bool_val => |b| try allocator.dupe(u8, if (b) "true" else "false"),
            .nothing => try allocator.dupe(u8, ""),
            .duration => |d| try formatDuration(d, allocator),
            .filesize => |f| try formatFilesize(f, allocator),
            .date => |d| try std.fmt.allocPrint(allocator, "{d}", .{d}),
            .range => |r| try std.fmt.allocPrint(allocator, "{d}{s}{d}", .{ r.start, if (r.inclusive) ".." else "..<", r.end }),
            .binary => |b| try std.fmt.allocPrint(allocator, "<binary {d} bytes>", .{b.len}),
            .closure => try allocator.dupe(u8, "<closure>"),
            .error_val => |e| try std.fmt.allocPrint(allocator, "Error: {s}", .{e.message}),
            .list => |l| blk: {
                var buf = std.ArrayList(u8){};
                errdefer buf.deinit(allocator);
                try buf.append(allocator, '[');
                for (l.items, 0..) |item, idx| {
                    if (idx > 0) try buf.appendSlice(allocator, ", ");
                    const s = try item.asString(allocator);
                    defer allocator.free(s);
                    try buf.appendSlice(allocator, s);
                }
                try buf.append(allocator, ']');
                break :blk try buf.toOwnedSlice(allocator);
            },
            .record => |r| blk: {
                var buf = std.ArrayList(u8){};
                errdefer buf.deinit(allocator);
                try buf.append(allocator, '{');
                for (r.keys, 0..) |key, idx| {
                    if (idx > 0) try buf.appendSlice(allocator, ", ");
                    try buf.appendSlice(allocator, key);
                    try buf.appendSlice(allocator, ": ");
                    const s = try r.values[idx].asString(allocator);
                    defer allocator.free(s);
                    try buf.appendSlice(allocator, s);
                }
                try buf.append(allocator, '}');
                break :blk try buf.toOwnedSlice(allocator);
            },
            .table => |t| blk: {
                var buf = std.ArrayList(u8){};
                errdefer buf.deinit(allocator);
                try buf.appendSlice(allocator, "<table ");
                const rows_str = try std.fmt.allocPrint(allocator, "{d}", .{t.rows.len});
                defer allocator.free(rows_str);
                try buf.appendSlice(allocator, rows_str);
                try buf.appendSlice(allocator, " rows x ");
                const cols_str = try std.fmt.allocPrint(allocator, "{d}", .{t.columns.len});
                defer allocator.free(cols_str);
                try buf.appendSlice(allocator, cols_str);
                try buf.appendSlice(allocator, " cols>");
                break :blk try buf.toOwnedSlice(allocator);
            },
        };
    }

    /// Convert value to bool
    pub fn asBool(self: Value) bool {
        return switch (self) {
            .bool_val => |b| b,
            .int => |i| i != 0,
            .float => |f| f != 0.0,
            .string => |s| s.len > 0,
            .nothing => false,
            .list => |l| l.items.len > 0,
            .record => |r| r.keys.len > 0,
            .table => |t| t.rows.len > 0,
            .error_val => false,
            else => true,
        };
    }

    /// Convert value to int (if possible)
    pub fn asInt(self: Value) ?i64 {
        return switch (self) {
            .int => |i| i,
            .float => |f| @intFromFloat(f),
            .bool_val => |b| @as(i64, if (b) 1 else 0),
            .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
            .filesize => |f| @intCast(f),
            .duration => |d| d,
            else => null,
        };
    }

    /// Convert value to float (if possible)
    pub fn asFloat(self: Value) ?f64 {
        return switch (self) {
            .float => |f| f,
            .int => |i| @floatFromInt(i),
            .bool_val => |b| @as(f64, if (b) 1.0 else 0.0),
            .string => |s| std.fmt.parseFloat(f64, s) catch null,
            else => null,
        };
    }

    /// Check equality between values
    pub fn eql(self: Value, other: Value) bool {
        const self_tag = std.meta.activeTag(self);
        const other_tag = std.meta.activeTag(other);
        if (self_tag != other_tag) {
            // Cross-type numeric comparison
            if (self.asFloat()) |sf| {
                if (other.asFloat()) |of| {
                    return sf == of;
                }
            }
            return false;
        }
        return switch (self) {
            .string => |s| std.mem.eql(u8, s, other.string),
            .int => |i| i == other.int,
            .float => |f| f == other.float,
            .bool_val => |b| b == other.bool_val,
            .nothing => true,
            .duration => |d| d == other.duration,
            .filesize => |f| f == other.filesize,
            .date => |d| d == other.date,
            .range => |r| r.start == other.range.start and r.end == other.range.end and r.inclusive == other.range.inclusive,
            else => false,
        };
    }

    /// Compare two values (for sorting)
    pub fn compare(self: Value, other: Value) std.math.Order {
        // Try numeric comparison first
        if (self.asFloat()) |sf| {
            if (other.asFloat()) |of| {
                return std.math.order(sf, of);
            }
        }
        // Fall back to string comparison
        const self_tag = std.meta.activeTag(self);
        const other_tag = std.meta.activeTag(other);
        if (self_tag != other_tag) return .eq;
        return switch (self) {
            .string => |s| std.mem.order(u8, s, other.string),
            .int => |i| std.math.order(i, other.int),
            .float => |f| std.math.order(f, other.float),
            .duration => |d| std.math.order(d, other.duration),
            .filesize => |f| std.math.order(f, other.filesize),
            .date => |d| std.math.order(d, other.date),
            else => .eq,
        };
    }

    /// Create a Value from a Variable (bridge)
    pub fn fromVariable(v: @import("variable.zig").Variable, allocator: std.mem.Allocator) !Value {
        return switch (v) {
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
            .array => |arr| blk: {
                const items = try allocator.alloc(Value, arr.len);
                for (arr, 0..) |item, i| {
                    items[i] = .{ .string = try allocator.dupe(u8, item) };
                }
                break :blk .{ .list = .{ .items = items } };
            },
            .assoc => |map| blk: {
                var count: usize = 0;
                var it = map.iterator();
                while (it.next()) |_| count += 1;
                const keys = try allocator.alloc([]const u8, count);
                const values = try allocator.alloc(Value, count);
                it = map.iterator();
                var i: usize = 0;
                while (it.next()) |entry| {
                    keys[i] = try allocator.dupe(u8, entry.key_ptr.*);
                    values[i] = .{ .string = try allocator.dupe(u8, entry.value_ptr.*) };
                    i += 1;
                }
                break :blk .{ .record = .{ .keys = keys, .values = values } };
            },
        };
    }

    /// Convert a Value to a Variable (bridge)
    pub fn toVariable(self: Value, allocator: std.mem.Allocator) !@import("variable.zig").Variable {
        const Variable = @import("variable.zig").Variable;
        return switch (self) {
            .string => |s| Variable{ .string = try allocator.dupe(u8, s) },
            .int => |i| Variable{ .string = try std.fmt.allocPrint(allocator, "{d}", .{i}) },
            .float => |f| Variable{ .string = try std.fmt.allocPrint(allocator, "{d}", .{f}) },
            .bool_val => |b| Variable{ .string = try allocator.dupe(u8, if (b) "true" else "false") },
            .nothing => Variable{ .string = try allocator.dupe(u8, "") },
            .list => |l| blk: {
                const arr = try allocator.alloc([]const u8, l.items.len);
                for (l.items, 0..) |item, idx| {
                    arr[idx] = try item.asString(allocator);
                }
                break :blk Variable{ .array = arr };
            },
            else => blk: {
                const s = try self.asString(allocator);
                break :blk Variable{ .string = s };
            },
        };
    }
};

fn formatDuration(nanos: i64, allocator: std.mem.Allocator) ![]const u8 {
    const abs = if (nanos < 0) @as(u64, @intCast(-nanos)) else @as(u64, @intCast(nanos));
    const sign: []const u8 = if (nanos < 0) "-" else "";

    if (abs < 1_000) return std.fmt.allocPrint(allocator, "{s}{d}ns", .{ sign, abs });
    if (abs < 1_000_000) return std.fmt.allocPrint(allocator, "{s}{d}us", .{ sign, abs / 1_000 });
    if (abs < 1_000_000_000) return std.fmt.allocPrint(allocator, "{s}{d}ms", .{ sign, abs / 1_000_000 });
    if (abs < 60_000_000_000) return std.fmt.allocPrint(allocator, "{s}{d}sec", .{ sign, abs / 1_000_000_000 });
    if (abs < 3_600_000_000_000) return std.fmt.allocPrint(allocator, "{s}{d}min", .{ sign, abs / 60_000_000_000 });
    return std.fmt.allocPrint(allocator, "{s}{d}hr", .{ sign, abs / 3_600_000_000_000 });
}

fn formatFilesize(bytes: u64, allocator: std.mem.Allocator) ![]const u8 {
    if (bytes < 1024) return std.fmt.allocPrint(allocator, "{d} B", .{bytes});
    if (bytes < 1024 * 1024) return std.fmt.allocPrint(allocator, "{d:.1} KB", .{@as(f64, @floatFromInt(bytes)) / 1024.0});
    if (bytes < 1024 * 1024 * 1024) return std.fmt.allocPrint(allocator, "{d:.1} MB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)});
    return std.fmt.allocPrint(allocator, "{d:.1} GB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0)});
}

/// Parse a duration string like "5sec", "10min", "2hr"
pub fn parseDuration(s: []const u8) ?i64 {
    const suffixes = [_]struct { suffix: []const u8, multiplier: i64 }{
        .{ .suffix = "ns", .multiplier = 1 },
        .{ .suffix = "us", .multiplier = 1_000 },
        .{ .suffix = "ms", .multiplier = 1_000_000 },
        .{ .suffix = "sec", .multiplier = 1_000_000_000 },
        .{ .suffix = "min", .multiplier = 60_000_000_000 },
        .{ .suffix = "hr", .multiplier = 3_600_000_000_000 },
        .{ .suffix = "day", .multiplier = 86_400_000_000_000 },
        .{ .suffix = "wk", .multiplier = 604_800_000_000_000 },
    };
    for (suffixes) |entry| {
        if (std.mem.endsWith(u8, s, entry.suffix)) {
            const num_str = s[0 .. s.len - entry.suffix.len];
            const num = std.fmt.parseInt(i64, num_str, 10) catch return null;
            return num * entry.multiplier;
        }
    }
    return null;
}

/// Parse a filesize string like "10kb", "5mb", "1gb"
pub fn parseFilesize(s: []const u8) ?u64 {
    const suffixes = [_]struct { suffix: []const u8, multiplier: u64 }{
        .{ .suffix = "b", .multiplier = 1 },
        .{ .suffix = "kb", .multiplier = 1024 },
        .{ .suffix = "mb", .multiplier = 1024 * 1024 },
        .{ .suffix = "gb", .multiplier = 1024 * 1024 * 1024 },
        .{ .suffix = "tb", .multiplier = 1024 * 1024 * 1024 * 1024 },
        .{ .suffix = "pb", .multiplier = 1024 * 1024 * 1024 * 1024 * 1024 },
        .{ .suffix = "kib", .multiplier = 1024 },
        .{ .suffix = "mib", .multiplier = 1024 * 1024 },
        .{ .suffix = "gib", .multiplier = 1024 * 1024 * 1024 },
    };
    // Case-insensitive comparison done per-character below
    for (suffixes) |entry| {
        if (s.len > entry.suffix.len) {
            const suffix_start = s.len - entry.suffix.len;
            var match = true;
            for (0..entry.suffix.len) |i| {
                if (std.ascii.toLower(s[suffix_start + i]) != entry.suffix[i]) {
                    match = false;
                    break;
                }
            }
            if (match) {
                const num_str = s[0..suffix_start];
                const num = std.fmt.parseInt(u64, num_str, 10) catch return null;
                return num * entry.multiplier;
            }
        }
    }
    return null;
}

/// Helper: create a string Value (takes ownership)
pub fn string(s: []const u8) Value {
    return .{ .string = s };
}

/// Helper: create an int Value
pub fn int(i: i64) Value {
    return .{ .int = i };
}

/// Helper: create a float Value
pub fn float(f: f64) Value {
    return .{ .float = f };
}

/// Helper: create a bool Value
pub fn boolean(b: bool) Value {
    return .{ .bool_val = b };
}

/// Helper: nothing value
pub const nothing: Value = .nothing;

test "Value basic types" {
    const allocator = std.testing.allocator;

    var v = Value{ .int = 42 };
    const s = try v.asString(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("42", s);

    var v2 = Value{ .bool_val = true };
    const s2 = try v2.asString(allocator);
    defer allocator.free(s2);
    try std.testing.expectEqualStrings("true", s2);

    try std.testing.expect(v.eql(.{ .int = 42 }));
    try std.testing.expect(!v.eql(.{ .int = 43 }));
}

test "Value comparison" {
    const v1 = Value{ .int = 10 };
    const v2 = Value{ .int = 20 };
    try std.testing.expectEqual(std.math.Order.lt, v1.compare(v2));
    try std.testing.expectEqual(std.math.Order.gt, v2.compare(v1));
    try std.testing.expectEqual(std.math.Order.eq, v1.compare(v1));
}

test "Range iterator" {
    const r = Value.Range{ .start = 1, .end = 5, .inclusive = true };
    var it = r.iterator();
    try std.testing.expectEqual(@as(?i64, 1), it.next());
    try std.testing.expectEqual(@as(?i64, 2), it.next());
    try std.testing.expectEqual(@as(?i64, 3), it.next());
    try std.testing.expectEqual(@as(?i64, 4), it.next());
    try std.testing.expectEqual(@as(?i64, 5), it.next());
    try std.testing.expectEqual(@as(?i64, null), it.next());
}

test "Duration parsing" {
    try std.testing.expectEqual(@as(?i64, 5_000_000_000), parseDuration("5sec"));
    try std.testing.expectEqual(@as(?i64, 600_000_000_000), parseDuration("10min"));
    try std.testing.expectEqual(@as(?i64, 7_200_000_000_000), parseDuration("2hr"));
    try std.testing.expectEqual(@as(?i64, null), parseDuration("abc"));
}
