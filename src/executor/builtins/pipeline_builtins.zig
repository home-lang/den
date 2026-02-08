const std = @import("std");
const posix = std.posix;
const types = @import("../../types/mod.zig");
const Value = types.Value;
const IO = @import("../../utils/io.zig").IO;
const value_format = @import("../../types/value_format.zig");

/// Read all stdin into a string
fn readAllStdin(allocator: std.mem.Allocator) ![]const u8 {
    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(posix.STDIN_FILENO, &buf) catch |err| {
            if (err == error.WouldBlock) break;
            return err;
        };
        if (n == 0) break;
        try result.appendSlice(allocator, buf[0..n]);
    }
    return try result.toOwnedSlice(allocator);
}

/// Read stdin and try to parse as structured data (JSON), or split into lines
fn readStdinAsValue(allocator: std.mem.Allocator) !Value {
    const input = readAllStdin(allocator) catch return .nothing;
    defer allocator.free(input);
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
    if (trimmed.len == 0) return .nothing;

    // Try JSON first
    if (std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{})) |parsed| {
        defer parsed.deinit();
        return jsonValueToValue(parsed.value, allocator);
    } else |_| {}

    // Fallback: split by newlines into a list of strings
    var items = std.ArrayList(Value){};
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) {
            try items.append(allocator, .{ .string = try allocator.dupe(u8, line) });
        }
    }
    return .{ .list = .{ .items = try items.toOwnedSlice(allocator) } };
}

fn jsonValueToValue(jv: std.json.Value, allocator: std.mem.Allocator) !Value {
    return switch (jv) {
        .null => .nothing,
        .bool => |b| .{ .bool_val = b },
        .integer => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            const items = try allocator.alloc(Value, arr.items.len);
            for (arr.items, 0..) |item, i| {
                items[i] = try jsonValueToValue(item, allocator);
            }
            break :blk .{ .list = .{ .items = items } };
        },
        .object => |obj| blk: {
            const keys = try allocator.alloc([]const u8, obj.count());
            const values = try allocator.alloc(Value, obj.count());
            var it = obj.iterator();
            var i: usize = 0;
            while (it.next()) |entry| {
                keys[i] = try allocator.dupe(u8, entry.key_ptr.*);
                values[i] = try jsonValueToValue(entry.value_ptr.*, allocator);
                i += 1;
            }
            break :blk .{ .record = .{ .keys = keys, .values = values } };
        },
        .number_string => |s| blk: {
            if (std.fmt.parseInt(i64, s, 10)) |i| {
                break :blk .{ .int = i };
            } else |_| {
                if (std.fmt.parseFloat(f64, s)) |f| {
                    break :blk .{ .float = f };
                } else |_| {
                    break :blk .{ .string = try allocator.dupe(u8, s) };
                }
            }
        },
    };
}

fn outputValue(val: Value, allocator: std.mem.Allocator) !void {
    const output = try value_format.formatValue(val, allocator, .table);
    defer allocator.free(output);
    try IO.print("{s}\n", .{output});
}

// ============================================================================
// Selection commands
// ============================================================================

pub fn selectCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("Usage: select <column1> [column2...]\n", .{});
        return 1;
    }
    var val = try readStdinAsValue(allocator);
    defer val.deinit(allocator);

    if (val == .table) {
        var new_cols = std.ArrayList([]const u8){};
        defer new_cols.deinit(allocator);
        var col_indices = std.ArrayList(usize){};
        defer col_indices.deinit(allocator);

        for (command.args) |wanted| {
            for (val.table.columns, 0..) |col, ci| {
                if (std.mem.eql(u8, col, wanted)) {
                    try new_cols.append(allocator, try allocator.dupe(u8, col));
                    try col_indices.append(allocator, ci);
                    break;
                }
            }
        }

        var new_rows = std.ArrayList([]Value){};
        defer new_rows.deinit(allocator);
        for (val.table.rows) |row| {
            const new_row = try allocator.alloc(Value, col_indices.items.len);
            for (col_indices.items, 0..) |ci, ni| {
                new_row[ni] = if (ci < row.len) try row[ci].clone(allocator) else .nothing;
            }
            try new_rows.append(allocator, new_row);
        }

        var result = Value{ .table = .{
            .columns = try new_cols.toOwnedSlice(allocator),
            .rows = try new_rows.toOwnedSlice(allocator),
        } };
        defer result.deinit(allocator);
        try outputValue(result, allocator);
    } else {
        try outputValue(val, allocator);
    }
    return 0;
}

pub fn getCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("Usage: get <field>\n", .{});
        return 1;
    }
    var val = try readStdinAsValue(allocator);
    defer val.deinit(allocator);

    const field = command.args[0];
    if (val == .record) {
        if (val.record.get(field)) |found| {
            const s = try found.asString(allocator);
            defer allocator.free(s);
            try IO.print("{s}\n", .{s});
            return 0;
        }
    } else if (val == .list) {
        // Try numeric index
        if (std.fmt.parseInt(usize, field, 10)) |idx| {
            if (idx < val.list.items.len) {
                const s = try val.list.items[idx].asString(allocator);
                defer allocator.free(s);
                try IO.print("{s}\n", .{s});
                return 0;
            }
        } else |_| {}
    }
    try IO.eprint("Field not found: {s}\n", .{field});
    return 1;
}

pub fn firstCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    var val = try readStdinAsValue(allocator);
    defer val.deinit(allocator);

    const n: usize = if (command.args.len > 0)
        std.fmt.parseInt(usize, command.args[0], 10) catch 1
    else
        1;

    if (val == .list) {
        const count = @min(n, val.list.items.len);
        if (count == 1 and val.list.items.len > 0) {
            const s = try val.list.items[0].asString(allocator);
            defer allocator.free(s);
            try IO.print("{s}\n", .{s});
        } else {
            for (val.list.items[0..count]) |item| {
                const s = try item.asString(allocator);
                defer allocator.free(s);
                try IO.print("{s}\n", .{s});
            }
        }
    } else if (val == .table) {
        const count = @min(n, val.table.rows.len);
        var new_rows = try allocator.alloc([]Value, count);
        for (0..count) |i| {
            new_rows[i] = val.table.rows[i];
        }
        const result = Value{ .table = .{ .columns = val.table.columns, .rows = new_rows } };
        try outputValue(result, allocator);
        allocator.free(new_rows);
    } else {
        try outputValue(val, allocator);
    }
    return 0;
}

pub fn lastCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    var val = try readStdinAsValue(allocator);
    defer val.deinit(allocator);

    const n: usize = if (command.args.len > 0)
        std.fmt.parseInt(usize, command.args[0], 10) catch 1
    else
        1;

    if (val == .list) {
        const count = @min(n, val.list.items.len);
        const start = val.list.items.len - count;
        for (val.list.items[start..]) |item| {
            const s = try item.asString(allocator);
            defer allocator.free(s);
            try IO.print("{s}\n", .{s});
        }
    } else {
        try outputValue(val, allocator);
    }
    return 0;
}

pub fn skipCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    var val = try readStdinAsValue(allocator);
    defer val.deinit(allocator);

    const n: usize = if (command.args.len > 0)
        std.fmt.parseInt(usize, command.args[0], 10) catch 0
    else
        1;

    if (val == .list and n < val.list.items.len) {
        for (val.list.items[n..]) |item| {
            const s = try item.asString(allocator);
            defer allocator.free(s);
            try IO.print("{s}\n", .{s});
        }
    }
    return 0;
}

pub fn takeCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    return firstCmd(allocator, command);
}

// ============================================================================
// Aggregation commands
// ============================================================================

pub fn lengthCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = command;
    var val = try readStdinAsValue(allocator);
    defer val.deinit(allocator);

    const count: usize = switch (val) {
        .list => |l| l.items.len,
        .table => |t| t.rows.len,
        .record => |r| r.keys.len,
        .string => |s| s.len,
        else => 1,
    };
    try IO.print("{d}\n", .{count});
    return 0;
}

pub fn flattenCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = command;
    var val = try readStdinAsValue(allocator);
    defer val.deinit(allocator);

    if (val == .list) {
        var flat = std.ArrayList(Value){};
        defer flat.deinit(allocator);
        for (val.list.items) |item| {
            if (item == .list) {
                for (item.list.items) |inner| {
                    try flat.append(allocator, try inner.clone(allocator));
                }
            } else {
                try flat.append(allocator, try item.clone(allocator));
            }
        }
        var result = Value{ .list = .{ .items = try flat.toOwnedSlice(allocator) } };
        defer result.deinit(allocator);
        try outputValue(result, allocator);
    } else {
        try outputValue(val, allocator);
    }
    return 0;
}

pub fn uniqCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = command;
    var val = try readStdinAsValue(allocator);
    defer val.deinit(allocator);

    if (val == .list) {
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();
        var result = std.ArrayList(Value){};
        defer result.deinit(allocator);
        for (val.list.items) |item| {
            const s = try item.asString(allocator);
            if (!seen.contains(s)) {
                try seen.put(s, {});
                try result.append(allocator, try item.clone(allocator));
            } else {
                allocator.free(s);
            }
        }
        var res_val = Value{ .list = .{ .items = try result.toOwnedSlice(allocator) } };
        defer res_val.deinit(allocator);
        try outputValue(res_val, allocator);
    } else {
        try outputValue(val, allocator);
    }
    return 0;
}

pub fn reverseCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = command;
    var val = try readStdinAsValue(allocator);
    defer val.deinit(allocator);

    if (val == .list) {
        std.mem.reverse(Value, val.list.items);
        try outputValue(val, allocator);
    } else {
        try outputValue(val, allocator);
    }
    return 0;
}

pub fn sortByCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = command;
    var val = try readStdinAsValue(allocator);
    defer val.deinit(allocator);

    if (val == .list) {
        std.mem.sort(Value, val.list.items, {}, struct {
            fn lessThan(_: void, a: Value, b: Value) bool {
                return a.compare(b) == .lt;
            }
        }.lessThan);
        try outputValue(val, allocator);
    } else {
        try outputValue(val, allocator);
    }
    return 0;
}

pub fn transposeCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = command;
    var val = try readStdinAsValue(allocator);
    defer val.deinit(allocator);

    if (val == .record) {
        // Record -> Table with key/value columns
        const columns = try allocator.alloc([]const u8, 2);
        columns[0] = try allocator.dupe(u8, "key");
        columns[1] = try allocator.dupe(u8, "value");

        const rows = try allocator.alloc([]Value, val.record.keys.len);
        for (val.record.keys, 0..) |key, i| {
            const row = try allocator.alloc(Value, 2);
            row[0] = .{ .string = try allocator.dupe(u8, key) };
            row[1] = try val.record.values[i].clone(allocator);
            rows[i] = row;
        }
        var result = Value{ .table = .{ .columns = columns, .rows = rows } };
        defer result.deinit(allocator);
        try outputValue(result, allocator);
    } else {
        try outputValue(val, allocator);
    }
    return 0;
}

// ============================================================================
// Combination commands
// ============================================================================

pub fn enumerateCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = command;
    var val = try readStdinAsValue(allocator);
    defer val.deinit(allocator);

    if (val == .list) {
        var result = std.ArrayList(Value){};
        defer result.deinit(allocator);
        for (val.list.items, 0..) |item, i| {
            const keys = try allocator.alloc([]const u8, 2);
            keys[0] = try allocator.dupe(u8, "index");
            keys[1] = try allocator.dupe(u8, "item");
            const values = try allocator.alloc(Value, 2);
            values[0] = .{ .int = @intCast(i) };
            values[1] = try item.clone(allocator);
            try result.append(allocator, .{ .record = .{ .keys = keys, .values = values } });
        }
        var res_val = Value{ .list = .{ .items = try result.toOwnedSlice(allocator) } };
        defer res_val.deinit(allocator);
        try outputValue(res_val, allocator);
    } else {
        try outputValue(val, allocator);
    }
    return 0;
}

pub fn wrapCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    const col_name = if (command.args.len > 0) command.args[0] else "value";
    var val = try readStdinAsValue(allocator);
    defer val.deinit(allocator);

    const keys = try allocator.alloc([]const u8, 1);
    keys[0] = try allocator.dupe(u8, col_name);
    const values = try allocator.alloc(Value, 1);
    values[0] = try val.clone(allocator);
    var result = Value{ .record = .{ .keys = keys, .values = values } };
    defer result.deinit(allocator);
    try outputValue(result, allocator);
    return 0;
}

pub fn columnsCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = command;
    var val = try readStdinAsValue(allocator);
    defer val.deinit(allocator);

    if (val == .table) {
        for (val.table.columns) |col| {
            try IO.print("{s}\n", .{col});
        }
    } else if (val == .record) {
        for (val.record.keys) |key| {
            try IO.print("{s}\n", .{key});
        }
    }
    return 0;
}

pub fn valuesCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = command;
    var val = try readStdinAsValue(allocator);
    defer val.deinit(allocator);

    if (val == .record) {
        for (val.record.values) |v| {
            const s = try v.asString(allocator);
            defer allocator.free(s);
            try IO.print("{s}\n", .{s});
        }
    }
    return 0;
}

pub fn headersCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    return columnsCmd(allocator, command);
}

pub fn compactCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = command;
    var val = try readStdinAsValue(allocator);
    defer val.deinit(allocator);

    if (val == .list) {
        var result = std.ArrayList(Value){};
        defer result.deinit(allocator);
        for (val.list.items) |item| {
            if (item != .nothing) {
                try result.append(allocator, try item.clone(allocator));
            }
        }
        var res_val = Value{ .list = .{ .items = try result.toOwnedSlice(allocator) } };
        defer res_val.deinit(allocator);
        try outputValue(res_val, allocator);
    } else {
        try outputValue(val, allocator);
    }
    return 0;
}

pub fn whereCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    // Simple where: where field op value
    if (command.args.len < 3) {
        try IO.eprint("Usage: where <field> <op> <value>\n  Operators: ==, !=, >, <, >=, <=, =~\n", .{});
        return 1;
    }
    var val = try readStdinAsValue(allocator);
    defer val.deinit(allocator);

    const field = command.args[0];
    const op = command.args[1];
    const expected = command.args[2];

    if (val == .list) {
        var result = std.ArrayList(Value){};
        defer result.deinit(allocator);
        for (val.list.items) |item| {
            if (item == .record) {
                if (item.record.get(field)) |field_val| {
                    const field_str = try field_val.asString(allocator);
                    defer allocator.free(field_str);
                    if (matchesCondition(field_str, op, expected)) {
                        try result.append(allocator, try item.clone(allocator));
                    }
                }
            } else {
                const s = try item.asString(allocator);
                defer allocator.free(s);
                if (matchesCondition(s, op, expected)) {
                    try result.append(allocator, try item.clone(allocator));
                }
            }
        }
        var res_val = Value{ .list = .{ .items = try result.toOwnedSlice(allocator) } };
        defer res_val.deinit(allocator);
        try outputValue(res_val, allocator);
    } else if (val == .table) {
        // Find column index
        var col_idx: ?usize = null;
        for (val.table.columns, 0..) |col, ci| {
            if (std.mem.eql(u8, col, field)) {
                col_idx = ci;
                break;
            }
        }
        if (col_idx == null) {
            try IO.eprint("Column not found: {s}\n", .{field});
            return 1;
        }
        var new_rows = std.ArrayList([]Value){};
        defer new_rows.deinit(allocator);
        for (val.table.rows) |row| {
            if (col_idx.? < row.len) {
                const cell_str = try row[col_idx.?].asString(allocator);
                defer allocator.free(cell_str);
                if (matchesCondition(cell_str, op, expected)) {
                    const new_row = try allocator.alloc(Value, row.len);
                    for (row, 0..) |cell, ci| {
                        new_row[ci] = try cell.clone(allocator);
                    }
                    try new_rows.append(allocator, new_row);
                }
            }
        }
        const cols = try allocator.alloc([]const u8, val.table.columns.len);
        for (val.table.columns, 0..) |col, ci| {
            cols[ci] = try allocator.dupe(u8, col);
        }
        var result = Value{ .table = .{ .columns = cols, .rows = try new_rows.toOwnedSlice(allocator) } };
        defer result.deinit(allocator);
        try outputValue(result, allocator);
    }
    return 0;
}

fn matchesCondition(actual: []const u8, op: []const u8, expected: []const u8) bool {
    if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "=")) {
        return std.mem.eql(u8, actual, expected);
    } else if (std.mem.eql(u8, op, "!=")) {
        return !std.mem.eql(u8, actual, expected);
    } else if (std.mem.eql(u8, op, "=~")) {
        return std.mem.indexOf(u8, actual, expected) != null;
    } else if (std.mem.eql(u8, op, ">") or std.mem.eql(u8, op, "<") or
        std.mem.eql(u8, op, ">=") or std.mem.eql(u8, op, "<="))
    {
        // Try numeric comparison
        const a_num = std.fmt.parseFloat(f64, actual) catch {
            // String comparison
            const cmp = std.mem.order(u8, actual, expected);
            return switch (cmp) {
                .lt => std.mem.eql(u8, op, "<") or std.mem.eql(u8, op, "<="),
                .gt => std.mem.eql(u8, op, ">") or std.mem.eql(u8, op, ">="),
                .eq => std.mem.eql(u8, op, ">=") or std.mem.eql(u8, op, "<="),
            };
        };
        const b_num = std.fmt.parseFloat(f64, expected) catch return false;
        if (std.mem.eql(u8, op, ">")) return a_num > b_num;
        if (std.mem.eql(u8, op, "<")) return a_num < b_num;
        if (std.mem.eql(u8, op, ">=")) return a_num >= b_num;
        if (std.mem.eql(u8, op, "<=")) return a_num <= b_num;
    }
    return false;
}

pub fn findCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("Usage: find <pattern>\n", .{});
        return 1;
    }
    var val = try readStdinAsValue(allocator);
    defer val.deinit(allocator);
    const pattern = command.args[0];

    if (val == .list) {
        var result = std.ArrayList(Value){};
        defer result.deinit(allocator);
        for (val.list.items) |item| {
            const s = try item.asString(allocator);
            defer allocator.free(s);
            if (std.mem.indexOf(u8, s, pattern) != null) {
                try result.append(allocator, try item.clone(allocator));
            }
        }
        var res_val = Value{ .list = .{ .items = try result.toOwnedSlice(allocator) } };
        defer res_val.deinit(allocator);
        try outputValue(res_val, allocator);
    }
    return 0;
}

pub fn rejectCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("Usage: reject <column1> [column2...]\n", .{});
        return 1;
    }
    var val = try readStdinAsValue(allocator);
    defer val.deinit(allocator);

    if (val == .table) {
        var keep_indices = std.ArrayList(usize){};
        defer keep_indices.deinit(allocator);
        var new_cols = std.ArrayList([]const u8){};
        defer new_cols.deinit(allocator);

        for (val.table.columns, 0..) |col, ci| {
            var rejected = false;
            for (command.args) |reject_col| {
                if (std.mem.eql(u8, col, reject_col)) {
                    rejected = true;
                    break;
                }
            }
            if (!rejected) {
                try keep_indices.append(allocator, ci);
                try new_cols.append(allocator, try allocator.dupe(u8, col));
            }
        }

        var new_rows = std.ArrayList([]Value){};
        defer new_rows.deinit(allocator);
        for (val.table.rows) |row| {
            const new_row = try allocator.alloc(Value, keep_indices.items.len);
            for (keep_indices.items, 0..) |ci, ni| {
                new_row[ni] = if (ci < row.len) try row[ci].clone(allocator) else .nothing;
            }
            try new_rows.append(allocator, new_row);
        }

        var result = Value{ .table = .{
            .columns = try new_cols.toOwnedSlice(allocator),
            .rows = try new_rows.toOwnedSlice(allocator),
        } };
        defer result.deinit(allocator);
        try outputValue(result, allocator);
    } else {
        try outputValue(val, allocator);
    }
    return 0;
}

pub fn renameCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len < 2) {
        try IO.eprint("Usage: rename <old_name> <new_name>\n", .{});
        return 1;
    }
    var val = try readStdinAsValue(allocator);
    defer val.deinit(allocator);

    const old_name = command.args[0];
    const new_name = command.args[1];

    if (val == .table) {
        const new_cols = try allocator.alloc([]const u8, val.table.columns.len);
        for (val.table.columns, 0..) |col, ci| {
            if (std.mem.eql(u8, col, old_name)) {
                new_cols[ci] = try allocator.dupe(u8, new_name);
            } else {
                new_cols[ci] = try allocator.dupe(u8, col);
            }
        }
        // Clone rows
        const new_rows = try allocator.alloc([]Value, val.table.rows.len);
        for (val.table.rows, 0..) |row, ri| {
            const new_row = try allocator.alloc(Value, row.len);
            for (row, 0..) |cell, ci| {
                new_row[ci] = try cell.clone(allocator);
            }
            new_rows[ri] = new_row;
        }
        var result = Value{ .table = .{ .columns = new_cols, .rows = new_rows } };
        defer result.deinit(allocator);
        try outputValue(result, allocator);
    } else {
        try outputValue(val, allocator);
    }
    return 0;
}

pub fn groupByCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("Usage: group-by <column>\n", .{});
        return 1;
    }
    var val = try readStdinAsValue(allocator);
    defer val.deinit(allocator);
    const group_col = command.args[0];

    if (val == .list) {
        var groups = std.StringArrayHashMap(std.ArrayList(Value)).init(allocator);
        defer {
            var it = groups.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(allocator);
            }
            groups.deinit();
        }

        for (val.list.items) |item| {
            var key: []const u8 = "";
            if (item == .record) {
                if (item.record.get(group_col)) |fv| {
                    const s = try fv.asString(allocator);
                    key = s;
                }
            }
            const gop = try groups.getOrPut(key);
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayList(Value){};
            }
            try gop.value_ptr.append(allocator, try item.clone(allocator));
        }

        // Build result record
        var keys = std.ArrayList([]const u8){};
        defer keys.deinit(allocator);
        var values_list = std.ArrayList(Value){};
        defer values_list.deinit(allocator);
        var it = groups.iterator();
        while (it.next()) |entry| {
            try keys.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
            try values_list.append(allocator, .{ .list = .{ .items = try entry.value_ptr.toOwnedSlice(allocator) } });
        }

        var result = Value{ .record = .{
            .keys = try keys.toOwnedSlice(allocator),
            .values = try values_list.toOwnedSlice(allocator),
        } };
        defer result.deinit(allocator);
        try outputValue(result, allocator);
    }
    return 0;
}

pub fn appendCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("Usage: append <value>\n", .{});
        return 1;
    }
    var val = try readStdinAsValue(allocator);
    defer val.deinit(allocator);

    if (val == .list) {
        var items = std.ArrayList(Value){};
        defer items.deinit(allocator);
        for (val.list.items) |item| {
            try items.append(allocator, try item.clone(allocator));
        }
        for (command.args) |arg| {
            try items.append(allocator, .{ .string = try allocator.dupe(u8, arg) });
        }
        var result = Value{ .list = .{ .items = try items.toOwnedSlice(allocator) } };
        defer result.deinit(allocator);
        try outputValue(result, allocator);
    } else {
        try outputValue(val, allocator);
    }
    return 0;
}

pub fn prependCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("Usage: prepend <value>\n", .{});
        return 1;
    }
    var val = try readStdinAsValue(allocator);
    defer val.deinit(allocator);

    if (val == .list) {
        var items = std.ArrayList(Value){};
        defer items.deinit(allocator);
        for (command.args) |arg| {
            try items.append(allocator, .{ .string = try allocator.dupe(u8, arg) });
        }
        for (val.list.items) |item| {
            try items.append(allocator, try item.clone(allocator));
        }
        var result = Value{ .list = .{ .items = try items.toOwnedSlice(allocator) } };
        defer result.deinit(allocator);
        try outputValue(result, allocator);
    } else {
        try outputValue(val, allocator);
    }
    return 0;
}

/// generate - Produce a sequence from a stateful generator function.
/// Usage: generate <initial> <count> <expression>
/// The expression can use $prev for the previous value and $index for current index.
/// Example: generate 1 10 "expr $prev * 2" -> 1 2 4 8 16 32 64 128 256 512
pub fn generateCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = allocator;
    if (command.args.len < 3) {
        try IO.eprint("Usage: generate <initial> <count> <expression>\n", .{});
        try IO.eprint("  Generates a sequence by applying <expression> iteratively\n", .{});
        try IO.eprint("  $prev = previous value, $index = current index\n", .{});
        try IO.eprint("  Example: generate 1 10 'expr $prev \\* 2'\n", .{});
        return 1;
    }

    const initial = command.args[0];
    const count = std.fmt.parseInt(usize, command.args[1], 10) catch {
        try IO.eprint("generate: invalid count: {s}\n", .{command.args[1]});
        return 1;
    };

    // Build the expression from remaining args
    var expr_buf: [2048]u8 = undefined;
    var expr_len: usize = 0;
    for (command.args[2..], 0..) |arg, idx| {
        if (idx > 0) {
            if (expr_len >= expr_buf.len) break;
            expr_buf[expr_len] = ' ';
            expr_len += 1;
        }
        if (expr_len + arg.len > expr_buf.len) break;
        @memcpy(expr_buf[expr_len..][0..arg.len], arg);
        expr_len += arg.len;
    }
    const expr_template = expr_buf[0..expr_len];

    const c_exec_gen = struct {
        extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
    };

    var prev_buf: [256]u8 = undefined;
    @memcpy(prev_buf[0..initial.len], initial);
    var prev_len: usize = initial.len;

    for (0..count) |i| {
        // Output current value
        try IO.print("{s}\n", .{prev_buf[0..prev_len]});

        if (i + 1 >= count) break;

        // Substitute $prev and $index in expression
        var sub_buf: [2048]u8 = undefined;
        var sub_len: usize = 0;
        var j: usize = 0;
        while (j < expr_template.len) {
            if (j + 5 <= expr_template.len and std.mem.eql(u8, expr_template[j .. j + 5], "$prev")) {
                if (sub_len + prev_len > sub_buf.len) break;
                @memcpy(sub_buf[sub_len..][0..prev_len], prev_buf[0..prev_len]);
                sub_len += prev_len;
                j += 5;
            } else if (j + 6 <= expr_template.len and std.mem.eql(u8, expr_template[j .. j + 6], "$index")) {
                const idx_str = std.fmt.bufPrint(sub_buf[sub_len..], "{d}", .{i}) catch break;
                sub_len += idx_str.len;
                j += 6;
            } else {
                if (sub_len >= sub_buf.len) break;
                sub_buf[sub_len] = expr_template[j];
                sub_len += 1;
                j += 1;
            }
        }

        // Execute via fork/exec to get next value
        const cmd_z = std.posix.toPosixPath(sub_buf[0..sub_len]) catch continue;
        var pipe_fds: [2]c_int = undefined;
        if (std.c.pipe(&pipe_fds) < 0) continue;

        const fork_ret = std.c.fork();
        if (fork_ret < 0) {
            std.posix.close(@intCast(pipe_fds[0]));
            std.posix.close(@intCast(pipe_fds[1]));
            continue;
        }
        if (fork_ret == 0) {
            std.posix.close(@intCast(pipe_fds[0]));
            _ = std.c.dup2(pipe_fds[1], 1);
            std.posix.close(@intCast(pipe_fds[1]));
            const argv_gen = [_]?[*:0]const u8{ "/bin/sh", "-c", &cmd_z, null };
            _ = c_exec_gen.execvp("/bin/sh", @ptrCast(&argv_gen));
            std.c._exit(127);
        }
        std.posix.close(@intCast(pipe_fds[1]));
        var output_buf: [256]u8 = undefined;
        var output_len: usize = 0;
        while (output_len < output_buf.len) {
            const n = std.posix.read(@intCast(pipe_fds[0]), output_buf[output_len..]) catch break;
            if (n == 0) break;
            output_len += n;
        }
        std.posix.close(@intCast(pipe_fds[0]));
        var wait_status: c_int = 0;
        _ = std.c.waitpid(@intCast(fork_ret), &wait_status, 0);

        const trimmed = std.mem.trimEnd(u8, output_buf[0..output_len], "\n\r");
        @memcpy(prev_buf[0..trimmed.len], trimmed);
        prev_len = trimmed.len;
    }
    return 0;
}

/// par-each - Execute a command for each input line in parallel.
/// Usage: <input> | par-each <command...>
/// Use {} as a placeholder for the input line, or it gets appended.
pub fn parEachCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("Usage: par-each <command...>\n", .{});
        try IO.eprint("  Execute <command> for each stdin line in parallel\n", .{});
        try IO.eprint("  Use {{}} as placeholder for the line value\n", .{});
        return 1;
    }

    const input = readAllStdin(allocator) catch |err| {
        try IO.eprint("par-each: failed to read stdin: {}\n", .{err});
        return 1;
    };
    defer allocator.free(input);

    // Collect lines
    var lines = std.ArrayList([]const u8){};
    defer lines.deinit(allocator);
    var line_iter = std.mem.splitScalar(u8, input, '\n');
    while (line_iter.next()) |line| {
        if (line.len > 0) try lines.append(allocator, line);
    }
    if (lines.items.len == 0) return 0;

    // Build command template
    var cmd_buf: [2048]u8 = undefined;
    var cmd_len: usize = 0;
    for (command.args, 0..) |arg, idx| {
        if (idx > 0) {
            if (cmd_len >= cmd_buf.len) break;
            cmd_buf[cmd_len] = ' ';
            cmd_len += 1;
        }
        if (cmd_len + arg.len > cmd_buf.len) break;
        @memcpy(cmd_buf[cmd_len..][0..arg.len], arg);
        cmd_len += arg.len;
    }
    const cmd_template = cmd_buf[0..cmd_len];

    const c_exec_par = struct {
        extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
    };

    const max_parallel: usize = @min(lines.items.len, 16);
    var active: usize = 0;

    for (lines.items) |line| {
        var full_cmd: [4096]u8 = undefined;
        var full_len: usize = 0;

        if (std.mem.indexOf(u8, cmd_template, "{}")) |_| {
            var k: usize = 0;
            while (k < cmd_template.len) {
                if (k + 1 < cmd_template.len and cmd_template[k] == '{' and cmd_template[k + 1] == '}') {
                    if (full_len + line.len > full_cmd.len) break;
                    @memcpy(full_cmd[full_len..][0..line.len], line);
                    full_len += line.len;
                    k += 2;
                } else {
                    if (full_len >= full_cmd.len) break;
                    full_cmd[full_len] = cmd_template[k];
                    full_len += 1;
                    k += 1;
                }
            }
        } else {
            @memcpy(full_cmd[0..cmd_template.len], cmd_template);
            full_len = cmd_template.len;
            if (full_len < full_cmd.len) {
                full_cmd[full_len] = ' ';
                full_len += 1;
            }
            if (full_len + line.len <= full_cmd.len) {
                @memcpy(full_cmd[full_len..][0..line.len], line);
                full_len += line.len;
            }
        }

        const cmd_z = std.posix.toPosixPath(full_cmd[0..full_len]) catch continue;

        if (active >= max_parallel) {
            var wait_status: c_int = 0;
            _ = std.c.waitpid(-1, &wait_status, 0);
            active -= 1;
        }

        const fork_ret = std.c.fork();
        if (fork_ret < 0) continue;
        if (fork_ret == 0) {
            const argv_par = [_]?[*:0]const u8{ "/bin/sh", "-c", &cmd_z, null };
            _ = c_exec_par.execvp("/bin/sh", @ptrCast(&argv_par));
            std.c._exit(127);
        }
        active += 1;
    }

    while (active > 0) {
        var wait_status: c_int = 0;
        _ = std.c.waitpid(-1, &wait_status, 0);
        active -= 1;
    }

    return 0;
}
