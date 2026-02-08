const std = @import("std");
const Value = @import("value.zig").Value;
const table_renderer = @import("../utils/table_renderer.zig");

/// Display mode for Value formatting
pub const DisplayMode = enum {
    /// Standard table/record/list display
    table,
    /// Compact grid display
    grid,
    /// Raw text output
    raw,
};

/// Format a Value for display to the terminal
pub fn formatValue(value: Value, allocator: std.mem.Allocator, mode: DisplayMode) ![]const u8 {
    return switch (mode) {
        .table => formatTableMode(value, allocator),
        .grid => formatGridMode(value, allocator),
        .raw => value.asString(allocator),
    };
}

fn formatTableMode(value: Value, allocator: std.mem.Allocator) ![]const u8 {
    return switch (value) {
        .table => |t| {
            const config = table_renderer.TableConfig{};
            return table_renderer.renderTable(t.columns, t.rows, allocator, config);
        },
        .list => |l| {
            // Check if list of records (display as table)
            if (l.items.len > 0 and l.items[0] == .record) {
                return formatListOfRecordsAsTable(l.items, allocator);
            }
            return formatList(l.items, allocator);
        },
        .record => |r| formatRecord(r, allocator),
        else => value.asString(allocator),
    };
}

fn formatGridMode(value: Value, allocator: std.mem.Allocator) ![]const u8 {
    return switch (value) {
        .list => |l| {
            // Get terminal width (default 80)
            const term_width: usize = 80;
            var items_strs = std.ArrayList([]const u8){};
            defer {
                for (items_strs.items) |s| allocator.free(s);
                items_strs.deinit(allocator);
            }
            var max_width: usize = 0;
            for (l.items) |item| {
                const s = try item.asString(allocator);
                if (s.len > max_width) max_width = s.len;
                try items_strs.append(allocator, s);
            }
            const col_width = max_width + 2;
            const num_cols = @max(1, term_width / col_width);
            var buf = std.ArrayList(u8){};
            errdefer buf.deinit(allocator);
            for (items_strs.items, 0..) |s, i| {
                try buf.appendSlice(allocator, s);
                // Pad to column width
                const padding = col_width - @min(s.len, col_width);
                for (0..padding) |_| try buf.append(allocator, ' ');
                if ((i + 1) % num_cols == 0) try buf.append(allocator, '\n');
            }
            if (items_strs.items.len % num_cols != 0) try buf.append(allocator, '\n');
            return try buf.toOwnedSlice(allocator);
        },
        else => value.asString(allocator),
    };
}

fn formatList(items: []const Value, allocator: std.mem.Allocator) ![]const u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    for (items, 0..) |item, i| {
        const s = try item.asString(allocator);
        defer allocator.free(s);
        if (i > 0) try buf.append(allocator, '\n');
        try buf.appendSlice(allocator, s);
    }
    return try buf.toOwnedSlice(allocator);
}

fn formatRecord(r: Value.Record, allocator: std.mem.Allocator) ![]const u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

    // Find max key length for alignment
    var max_key_len: usize = 0;
    for (r.keys) |key| {
        if (key.len > max_key_len) max_key_len = key.len;
    }

    for (r.keys, 0..) |key, i| {
        if (i > 0) try buf.append(allocator, '\n');
        // Key with padding
        try buf.appendSlice(allocator, "\x1b[1;36m"); // bold cyan
        try buf.appendSlice(allocator, key);
        try buf.appendSlice(allocator, "\x1b[0m");
        const padding = max_key_len - key.len + 1;
        for (0..padding) |_| try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, ": ");
        const val_str = try r.values[i].asString(allocator);
        defer allocator.free(val_str);
        try buf.appendSlice(allocator, val_str);
    }
    return try buf.toOwnedSlice(allocator);
}

fn formatListOfRecordsAsTable(items: []const Value, allocator: std.mem.Allocator) ![]const u8 {
    // Collect column names from first record
    if (items.len == 0) return try allocator.dupe(u8, "");
    const first_rec = items[0].record;
    const columns = try allocator.alloc([]const u8, first_rec.keys.len);
    defer allocator.free(columns);
    for (first_rec.keys, 0..) |key, i| {
        columns[i] = key;
    }

    // Build rows
    const rows = try allocator.alloc([]Value, items.len);
    defer allocator.free(rows);
    for (items, 0..) |item, i| {
        if (item != .record) {
            // Fallback: create single-column row
            const row = try allocator.alloc(Value, 1);
            row[0] = item;
            rows[i] = row;
        } else {
            rows[i] = item.record.values;
        }
    }

    const config = table_renderer.TableConfig{};
    return table_renderer.renderTable(columns, rows, allocator, config);
}
