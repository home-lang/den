const std = @import("std");
const posix = std.posix;
const types = @import("../../types/mod.zig");
const Value = types.Value;
const IO = @import("../../utils/io.zig").IO;
const value_format = @import("../../types/value_format.zig");
const common = @import("common.zig");

/// Detect columns from whitespace-aligned text output (like ps aux, df, etc.)
pub fn detectColumns(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = command;
    const input = common.readAllStdin(allocator) catch return 1;
    defer allocator.free(input);

    var lines = std.mem.splitScalar(u8, input, '\n');

    // First line is the header
    const header_line = lines.first();
    if (header_line.len == 0) return 0;

    // Detect column boundaries from header
    var col_starts = std.ArrayList(usize).empty;
    defer col_starts.deinit(allocator);
    var col_names = std.ArrayList([]const u8).empty;
    defer col_names.deinit(allocator);

    var in_word = false;
    var word_start: usize = 0;
    for (header_line, 0..) |c, i| {
        if (!std.ascii.isWhitespace(c)) {
            if (!in_word) {
                word_start = i;
                in_word = true;
                try col_starts.append(allocator, i);
            }
        } else {
            if (in_word) {
                try col_names.append(allocator, try allocator.dupe(u8, header_line[word_start..i]));
                in_word = false;
            }
        }
    }
    if (in_word) {
        try col_names.append(allocator, try allocator.dupe(u8, header_line[word_start..]));
    }

    if (col_names.items.len == 0) return 0;

    // Build columns
    const columns = try allocator.alloc([]const u8, col_names.items.len);
    for (col_names.items, 0..) |name, i| {
        columns[i] = name;
    }

    // Parse data rows
    var rows = std.ArrayList([]Value).empty;
    defer rows.deinit(allocator);

    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const row = try allocator.alloc(Value, col_names.items.len);
        for (0..col_names.items.len) |ci| {
            const start = if (ci < col_starts.items.len) col_starts.items[ci] else line.len;
            const end = if (ci + 1 < col_starts.items.len) col_starts.items[ci + 1] else line.len;

            if (start < line.len) {
                const actual_end = @min(end, line.len);
                const cell = std.mem.trim(u8, line[start..actual_end], &std.ascii.whitespace);
                row[ci] = .{ .string = try allocator.dupe(u8, cell) };
            } else {
                row[ci] = .{ .string = try allocator.dupe(u8, "") };
            }
        }
        try rows.append(allocator, row);
    }

    var table = Value{ .table = .{
        .columns = columns,
        .rows = try rows.toOwnedSlice(allocator),
    } };
    defer table.deinit(allocator);

    const output = try value_format.formatValue(table, allocator, .table);
    defer allocator.free(output);
    try IO.print("{s}\n", .{output});
    return 0;
}
