const std = @import("std");
const types = @import("../../types/mod.zig");
const Value = types.Value;
const IO = @import("../../utils/io.zig").IO;
const value_format = @import("../../types/value_format.zig");
const common = @import("common.zig");

// ============================================================================
// JSON: from json / to json
// ============================================================================

pub fn fromJson(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    const input = if (command.args.len > 0)
        try allocator.dupe(u8, command.args[0])
    else
        try common.readAllStdin(allocator);
    defer allocator.free(input);

    var val = jsonToValue(input, allocator) catch {
        try IO.eprint("Error: invalid JSON input\n", .{});
        return 1;
    };
    defer val.deinit(allocator);

    const output = try value_format.formatValue(val, allocator, .table);
    defer allocator.free(output);
    try IO.print("{s}\n", .{output});
    return 0;
}

pub fn toJson(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = command;
    const input = try common.readAllStdin(allocator);
    defer allocator.free(input);
    // Pass through - stdin is already text, just format nicely
    try IO.print("{s}", .{input});
    return 0;
}

fn jsonToValue(input: []const u8, allocator: std.mem.Allocator) !Value {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
    if (trimmed.len == 0) return .nothing;

    // Try to parse as JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();
    return jsonValueToValue(parsed.value, allocator);
}

fn jsonValueToValue(jv: std.json.Value, allocator: std.mem.Allocator) std.mem.Allocator.Error!Value {
    return switch (jv) {
        .null => .nothing,
        .bool => |b| .{ .bool_val = b },
        .integer => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            // Check if array of objects (table)
            var all_objects = arr.items.len > 0;
            for (arr.items) |item| {
                if (item != .object) {
                    all_objects = false;
                    break;
                }
            }
            if (all_objects and arr.items.len > 0) {
                break :blk try jsonArrayToTable(arr.items, allocator);
            }
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

fn jsonArrayToTable(items: []const std.json.Value, allocator: std.mem.Allocator) std.mem.Allocator.Error!Value {
    // Collect all unique keys across all objects
    var key_set = std.StringArrayHashMap(void).init(allocator);
    defer key_set.deinit();
    for (items) |item| {
        if (item == .object) {
            var it = item.object.iterator();
            while (it.next()) |entry| {
                try key_set.put(entry.key_ptr.*, {});
            }
        }
    }

    const columns = try allocator.alloc([]const u8, key_set.count());
    var kit = key_set.iterator();
    var ci: usize = 0;
    while (kit.next()) |entry| {
        columns[ci] = try allocator.dupe(u8, entry.key_ptr.*);
        ci += 1;
    }

    const rows = try allocator.alloc([]Value, items.len);
    for (items, 0..) |item, ri| {
        const row = try allocator.alloc(Value, columns.len);
        for (columns, 0..) |col, cj| {
            if (item == .object) {
                if (item.object.get(col)) |val| {
                    row[cj] = try jsonValueToValue(val, allocator);
                } else {
                    row[cj] = .nothing;
                }
            } else {
                row[cj] = .nothing;
            }
        }
        rows[ri] = row;
    }

    return .{ .table = .{ .columns = columns, .rows = rows } };
}

// ============================================================================
// CSV: from csv / to csv
// ============================================================================

pub fn fromCsv(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    const input = if (command.args.len > 0)
        try allocator.dupe(u8, command.args[0])
    else
        try common.readAllStdin(allocator);
    defer allocator.free(input);

    var val = csvToValue(input, allocator) catch {
        try IO.eprint("Error: invalid CSV input\n", .{});
        return 1;
    };
    defer val.deinit(allocator);

    const output = try value_format.formatValue(val, allocator, .table);
    defer allocator.free(output);
    try IO.print("{s}\n", .{output});
    return 0;
}

pub fn toCsv(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = command;
    const input = try common.readAllStdin(allocator);
    defer allocator.free(input);
    try IO.print("{s}", .{input});
    return 0;
}

fn csvToValue(input: []const u8, allocator: std.mem.Allocator) !Value {
    var lines_iter = std.mem.splitScalar(u8, input, '\n');

    // Parse header
    const header_line = lines_iter.first();
    var header_fields = std.ArrayList([]const u8).empty;
    defer header_fields.deinit(allocator);
    try parseCsvLine(allocator, header_line, &header_fields);

    if (header_fields.items.len == 0) return .nothing;

    const columns = try allocator.alloc([]const u8, header_fields.items.len);
    for (header_fields.items, 0..) |field, i| {
        columns[i] = field;
    }

    // Parse data rows
    var rows_list = std.ArrayList([]Value).empty;
    defer rows_list.deinit(allocator);

    while (lines_iter.next()) |line| {
        if (std.mem.trim(u8, line, &std.ascii.whitespace).len == 0) continue;
        var fields = std.ArrayList([]const u8).empty;
        defer fields.deinit(allocator);
        try parseCsvLine(allocator, line, &fields);

        const row = try allocator.alloc(Value, columns.len);
        for (0..columns.len) |ci| {
            if (ci < fields.items.len) {
                row[ci] = .{ .string = fields.items[ci] };
            } else {
                row[ci] = .{ .string = try allocator.dupe(u8, "") };
            }
        }
        try rows_list.append(allocator, row);
    }

    const rows = try rows_list.toOwnedSlice(allocator);
    return .{ .table = .{ .columns = columns, .rows = rows } };
}

fn parseCsvLine(allocator: std.mem.Allocator, line: []const u8, fields: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (i <= line.len) {
        if (i >= line.len) break;
        if (line[i] == '"') {
            // Quoted field
            i += 1;
            var field = std.ArrayList(u8).empty;
            errdefer field.deinit(allocator);
            while (i < line.len) {
                if (line[i] == '"') {
                    if (i + 1 < line.len and line[i + 1] == '"') {
                        try field.append(allocator, '"');
                        i += 2;
                    } else {
                        i += 1;
                        break;
                    }
                } else {
                    try field.append(allocator, line[i]);
                    i += 1;
                }
            }
            try fields.append(allocator, try field.toOwnedSlice(allocator));
            if (i < line.len and line[i] == ',') i += 1;
        } else {
            // Unquoted field
            const start = i;
            while (i < line.len and line[i] != ',') i += 1;
            try fields.append(allocator, try allocator.dupe(u8, line[start..i]));
            if (i < line.len and line[i] == ',') i += 1;
        }
    }
}

// ============================================================================
// TOML: from toml / to toml
// ============================================================================

pub fn fromToml(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    const input = if (command.args.len > 0)
        try allocator.dupe(u8, command.args[0])
    else
        try common.readAllStdin(allocator);
    defer allocator.free(input);

    var val = tomlToValue(input, allocator) catch {
        try IO.eprint("Error: invalid TOML input\n", .{});
        return 1;
    };
    defer val.deinit(allocator);

    const output = try value_format.formatValue(val, allocator, .table);
    defer allocator.free(output);
    try IO.print("{s}\n", .{output});
    return 0;
}

pub fn toToml(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = command;
    const input = try common.readAllStdin(allocator);
    defer allocator.free(input);
    try IO.print("{s}", .{input});
    return 0;
}

fn tomlToValue(input: []const u8, allocator: std.mem.Allocator) !Value {
    // Simple TOML parser: key = value, [section], arrays, basic types
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(allocator);
    var values = std.ArrayList(Value).empty;
    defer values.deinit(allocator);

    var current_section: ?[]const u8 = null;
    var lines_iter = std.mem.splitScalar(u8, input, '\n');
    while (lines_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[' and line[line.len - 1] == ']') {
            current_section = line[1 .. line.len - 1];
            continue;
        }

        if (std.mem.indexOf(u8, line, "=")) |eq_pos| {
            const key_raw = std.mem.trim(u8, line[0..eq_pos], &std.ascii.whitespace);
            const val_raw = std.mem.trim(u8, line[eq_pos + 1 ..], &std.ascii.whitespace);

            const full_key = if (current_section) |sec|
                try std.fmt.allocPrint(allocator, "{s}.{s}", .{ sec, key_raw })
            else
                try allocator.dupe(u8, key_raw);

            try keys.append(allocator, full_key);
            try values.append(allocator, try parseTomlValue(val_raw, allocator));
        }
    }

    const k = try keys.toOwnedSlice(allocator);
    const v = try values.toOwnedSlice(allocator);
    return .{ .record = .{ .keys = k, .values = v } };
}

fn parseTomlValue(raw: []const u8, allocator: std.mem.Allocator) !Value {
    if (raw.len == 0) return .nothing;
    // String (quoted)
    if ((raw[0] == '"' and raw.len > 1 and raw[raw.len - 1] == '"') or
        (raw[0] == '\'' and raw.len > 1 and raw[raw.len - 1] == '\''))
    {
        return .{ .string = try allocator.dupe(u8, raw[1 .. raw.len - 1]) };
    }
    // Boolean
    if (std.mem.eql(u8, raw, "true")) return .{ .bool_val = true };
    if (std.mem.eql(u8, raw, "false")) return .{ .bool_val = false };
    // Integer
    if (std.fmt.parseInt(i64, raw, 10)) |i| return .{ .int = i } else |_| {}
    // Float
    if (std.fmt.parseFloat(f64, raw)) |f| return .{ .float = f } else |_| {}
    // Array
    if (raw[0] == '[' and raw[raw.len - 1] == ']') {
        const inner = raw[1 .. raw.len - 1];
        var items = std.ArrayList(Value).empty;
        defer items.deinit(allocator);
        var it = std.mem.splitScalar(u8, inner, ',');
        while (it.next()) |item| {
            const trimmed = std.mem.trim(u8, item, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                try items.append(allocator, try parseTomlValue(trimmed, allocator));
            }
        }
        return .{ .list = .{ .items = try items.toOwnedSlice(allocator) } };
    }
    // Default: string
    return .{ .string = try allocator.dupe(u8, raw) };
}

// ============================================================================
// YAML (subset): from yaml / to yaml
// ============================================================================

pub fn fromYaml(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    const input = if (command.args.len > 0)
        try allocator.dupe(u8, command.args[0])
    else
        try common.readAllStdin(allocator);
    defer allocator.free(input);

    var val = yamlToValue(input, allocator) catch {
        try IO.eprint("Error: invalid YAML input\n", .{});
        return 1;
    };
    defer val.deinit(allocator);

    const output = try value_format.formatValue(val, allocator, .table);
    defer allocator.free(output);
    try IO.print("{s}\n", .{output});
    return 0;
}

pub fn toYaml(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = command;
    const input = try common.readAllStdin(allocator);
    defer allocator.free(input);
    try IO.print("{s}", .{input});
    return 0;
}

fn yamlToValue(input: []const u8, allocator: std.mem.Allocator) !Value {
    // Simple YAML subset: key: value, - list items
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(allocator);
    var values = std.ArrayList(Value).empty;
    defer values.deinit(allocator);

    var in_list = false;
    var list_key: ?[]const u8 = null;
    var list_items = std.ArrayList(Value).empty;
    defer list_items.deinit(allocator);

    var lines_iter = std.mem.splitScalar(u8, input, '\n');
    while (lines_iter.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line, &std.ascii.whitespace), "---")) continue;

        // List item
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (trimmed.len > 1 and trimmed[0] == '-' and trimmed[1] == ' ') {
            in_list = true;
            const item_val = std.mem.trim(u8, trimmed[2..], &std.ascii.whitespace);
            try list_items.append(allocator, try parseYamlScalar(item_val, allocator));
            continue;
        }

        // Flush pending list
        if (in_list and list_key != null) {
            try keys.append(allocator, list_key.?);
            try values.append(allocator, .{ .list = .{ .items = try list_items.toOwnedSlice(allocator) } });
            list_items = std.ArrayList(Value).empty;
            in_list = false;
            list_key = null;
        }

        // Key: value
        if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
            const key = std.mem.trim(u8, line[0..colon_pos], &std.ascii.whitespace);
            const val_part = if (colon_pos + 1 < line.len) std.mem.trim(u8, line[colon_pos + 1 ..], &std.ascii.whitespace) else "";

            if (val_part.len == 0) {
                // Could be start of a list or nested map
                list_key = try allocator.dupe(u8, key);
                continue;
            }
            try keys.append(allocator, try allocator.dupe(u8, key));
            try values.append(allocator, try parseYamlScalar(val_part, allocator));
        }
    }

    // Flush pending list
    if (in_list and list_key != null) {
        try keys.append(allocator, list_key.?);
        try values.append(allocator, .{ .list = .{ .items = try list_items.toOwnedSlice(allocator) } });
    }

    const k = try keys.toOwnedSlice(allocator);
    const v = try values.toOwnedSlice(allocator);
    return .{ .record = .{ .keys = k, .values = v } };
}

fn parseYamlScalar(raw: []const u8, allocator: std.mem.Allocator) !Value {
    if (raw.len == 0) return .nothing;
    // Quoted string
    if ((raw[0] == '"' and raw.len > 1 and raw[raw.len - 1] == '"') or
        (raw[0] == '\'' and raw.len > 1 and raw[raw.len - 1] == '\''))
    {
        return .{ .string = try allocator.dupe(u8, raw[1 .. raw.len - 1]) };
    }
    if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "yes")) return .{ .bool_val = true };
    if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "no")) return .{ .bool_val = false };
    if (std.mem.eql(u8, raw, "null") or std.mem.eql(u8, raw, "~")) return .nothing;
    if (std.fmt.parseInt(i64, raw, 10)) |i| return .{ .int = i } else |_| {}
    if (std.fmt.parseFloat(f64, raw)) |f| return .{ .float = f } else |_| {}
    return .{ .string = try allocator.dupe(u8, raw) };
}

// ============================================================================
// table / grid commands
// ============================================================================

pub fn tableCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = command;
    const input = try common.readAllStdin(allocator);
    defer allocator.free(input);
    // Try JSON first, then CSV
    if (jsonToValue(input, allocator)) |val_result| {
        var val = val_result;
        defer val.deinit(allocator);
        const output = try value_format.formatValue(val, allocator, .table);
        defer allocator.free(output);
        try IO.print("{s}\n", .{output});
        return 0;
    } else |_| {}
    // Fallback: pass through
    try IO.print("{s}", .{input});
    return 0;
}

pub fn gridCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = command;
    const input = try common.readAllStdin(allocator);
    defer allocator.free(input);
    // Split input into lines as list items
    var items = std.ArrayList(Value).empty;
    defer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) {
            try items.append(allocator, .{ .string = try allocator.dupe(u8, line) });
        }
    }
    const val = Value{ .list = .{ .items = items.items } };
    const output = try value_format.formatValue(val, allocator, .grid);
    defer allocator.free(output);
    try IO.print("{s}", .{output});
    return 0;
}

// ============================================================================
// Dispatch: from / to subcommands
// ============================================================================

pub fn fromCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("Usage: from <format> [input]\n  Formats: json, csv, toml, yaml\n", .{});
        return 1;
    }
    const format = command.args[0];
    // Shift args for subcommand
    var sub_cmd = command.*;
    sub_cmd.args = if (command.args.len > 1) command.args[1..] else &[_][]const u8{};

    if (std.mem.eql(u8, format, "json")) return fromJson(allocator, &sub_cmd);
    if (std.mem.eql(u8, format, "csv")) return fromCsv(allocator, &sub_cmd);
    if (std.mem.eql(u8, format, "toml")) return fromToml(allocator, &sub_cmd);
    if (std.mem.eql(u8, format, "yaml")) return fromYaml(allocator, &sub_cmd);

    try IO.eprint("Unknown format: {s}\nSupported: json, csv, toml, yaml\n", .{format});
    return 1;
}

pub fn toCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("Usage: to <format>\n  Formats: json, csv, toml, yaml\n", .{});
        return 1;
    }
    const format = command.args[0];
    var sub_cmd = command.*;
    sub_cmd.args = if (command.args.len > 1) command.args[1..] else &[_][]const u8{};

    if (std.mem.eql(u8, format, "json")) return toJson(allocator, &sub_cmd);
    if (std.mem.eql(u8, format, "csv")) return toCsv(allocator, &sub_cmd);
    if (std.mem.eql(u8, format, "toml")) return toToml(allocator, &sub_cmd);
    if (std.mem.eql(u8, format, "yaml")) return toYaml(allocator, &sub_cmd);

    try IO.eprint("Unknown format: {s}\nSupported: json, csv, toml, yaml\n", .{format});
    return 1;
}
