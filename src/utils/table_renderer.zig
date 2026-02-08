const std = @import("std");
const Value = @import("../types/value.zig").Value;

/// Border style for table rendering
pub const BorderStyle = enum {
    /// No borders
    none,
    /// ASCII borders: +--+
    ascii,
    /// Unicode thin borders: ─│┌┐└┘├┤┬┴┼
    thin,
    /// Unicode rounded borders: ─│╭╮╰╯├┤┬┴┼
    rounded,
    /// Unicode heavy borders: ━┃┏┓┗┛┣┫┳┻╋
    heavy,
};

/// Column alignment
pub const Alignment = enum {
    left,
    right,
    center,
};

/// Table rendering configuration
pub const TableConfig = struct {
    border_style: BorderStyle = .rounded,
    header_bold: bool = true,
    header_color: ?[]const u8 = "\x1b[1;36m", // bold cyan
    show_footer: bool = true,
    max_col_width: usize = 60,
    padding: usize = 1,
};

const BorderChars = struct {
    horizontal: []const u8,
    vertical: []const u8,
    top_left: []const u8,
    top_right: []const u8,
    bottom_left: []const u8,
    bottom_right: []const u8,
    t_left: []const u8,
    t_right: []const u8,
    t_top: []const u8,
    t_bottom: []const u8,
    cross: []const u8,
};

fn getBorderChars(style: BorderStyle) BorderChars {
    return switch (style) {
        .none => .{
            .horizontal = " ",
            .vertical = " ",
            .top_left = " ",
            .top_right = " ",
            .bottom_left = " ",
            .bottom_right = " ",
            .t_left = " ",
            .t_right = " ",
            .t_top = " ",
            .t_bottom = " ",
            .cross = " ",
        },
        .ascii => .{
            .horizontal = "-",
            .vertical = "|",
            .top_left = "+",
            .top_right = "+",
            .bottom_left = "+",
            .bottom_right = "+",
            .t_left = "+",
            .t_right = "+",
            .t_top = "+",
            .t_bottom = "+",
            .cross = "+",
        },
        .thin => .{
            .horizontal = "\xe2\x94\x80", // ─
            .vertical = "\xe2\x94\x82", // │
            .top_left = "\xe2\x94\x8c", // ┌
            .top_right = "\xe2\x94\x90", // ┐
            .bottom_left = "\xe2\x94\x94", // └
            .bottom_right = "\xe2\x94\x98", // ┘
            .t_left = "\xe2\x94\x9c", // ├
            .t_right = "\xe2\x94\xa4", // ┤
            .t_top = "\xe2\x94\xac", // ┬
            .t_bottom = "\xe2\x94\xb4", // ┴
            .cross = "\xe2\x94\xbc", // ┼
        },
        .rounded => .{
            .horizontal = "\xe2\x94\x80", // ─
            .vertical = "\xe2\x94\x82", // │
            .top_left = "\xe2\x95\xad", // ╭
            .top_right = "\xe2\x95\xae", // ╮
            .bottom_left = "\xe2\x95\xb0", // ╰
            .bottom_right = "\xe2\x95\xaf", // ╯
            .t_left = "\xe2\x94\x9c", // ├
            .t_right = "\xe2\x94\xa4", // ┤
            .t_top = "\xe2\x94\xac", // ┬
            .t_bottom = "\xe2\x94\xb4", // ┴
            .cross = "\xe2\x94\xbc", // ┼
        },
        .heavy => .{
            .horizontal = "\xe2\x94\x81", // ━
            .vertical = "\xe2\x94\x83", // ┃
            .top_left = "\xe2\x94\x8f", // ┏
            .top_right = "\xe2\x94\x93", // ┓
            .bottom_left = "\xe2\x94\x97", // ┗
            .bottom_right = "\xe2\x94\x9b", // ┛
            .t_left = "\xe2\x94\xa3", // ┣
            .t_right = "\xe2\x94\xab", // ┫
            .t_top = "\xe2\x94\xb3", // ┳
            .t_bottom = "\xe2\x94\xbb", // ┻
            .cross = "\xe2\x95\x8b", // ╋
        },
    };
}

/// Render a table from columns and rows of Values
pub fn renderTable(
    columns: []const []const u8,
    rows: []const []const Value,
    allocator: std.mem.Allocator,
    config: TableConfig,
) ![]const u8 {
    if (columns.len == 0) return try allocator.dupe(u8, "");

    // Calculate column widths
    const col_widths = try allocator.alloc(usize, columns.len);
    defer allocator.free(col_widths);
    for (columns, 0..) |col, i| {
        col_widths[i] = col.len;
    }

    // Pre-render all cell strings
    const cell_strs = try allocator.alloc([][]const u8, rows.len);
    defer {
        for (cell_strs) |row_strs| {
            for (row_strs) |s| allocator.free(s);
            allocator.free(row_strs);
        }
        allocator.free(cell_strs);
    }

    for (rows, 0..) |row, ri| {
        const row_strs = try allocator.alloc([]const u8, columns.len);
        for (0..columns.len) |ci| {
            const s = if (ci < row.len) try row[ci].asString(allocator) else try allocator.dupe(u8, "");
            row_strs[ci] = s;
            const display_len = visibleLength(s);
            const truncated = @min(display_len, config.max_col_width);
            if (truncated > col_widths[ci]) col_widths[ci] = truncated;
        }
        cell_strs[ri] = row_strs;
    }

    const bc = getBorderChars(config.border_style);
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

    // Top border
    try appendBorderLine(allocator, &buf, col_widths, bc, .top, config.padding);

    // Header row
    try buf.appendSlice(allocator, bc.vertical);
    for (columns, 0..) |col, i| {
        for (0..config.padding) |_| try buf.append(allocator, ' ');
        if (config.header_color) |color| try buf.appendSlice(allocator, color);
        if (config.header_bold) try buf.appendSlice(allocator, "\x1b[1m");
        try buf.appendSlice(allocator, col);
        if (config.header_color != null or config.header_bold) try buf.appendSlice(allocator, "\x1b[0m");
        const pad = col_widths[i] - @min(col.len, col_widths[i]);
        for (0..pad + config.padding) |_| try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, bc.vertical);
    }
    try buf.append(allocator, '\n');

    // Header separator
    try appendBorderLine(allocator, &buf, col_widths, bc, .middle, config.padding);

    // Data rows
    for (cell_strs) |row_strs| {
        try buf.appendSlice(allocator, bc.vertical);
        for (row_strs, 0..) |cell, ci| {
            for (0..config.padding) |_| try buf.append(allocator, ' ');
            const display_len = visibleLength(cell);
            const truncated_len = @min(display_len, config.max_col_width);
            if (truncated_len < cell.len and display_len > config.max_col_width) {
                // Need to truncate - approximate
                const approx_end = @min(cell.len, config.max_col_width);
                try buf.appendSlice(allocator, cell[0..approx_end]);
            } else {
                try buf.appendSlice(allocator, cell);
            }
            const pad = col_widths[ci] - @min(truncated_len, col_widths[ci]);
            for (0..pad + config.padding) |_| try buf.append(allocator, ' ');
            try buf.appendSlice(allocator, bc.vertical);
        }
        try buf.append(allocator, '\n');
    }

    // Bottom border
    try appendBorderLine(allocator, &buf, col_widths, bc, .bottom, config.padding);

    // Footer
    if (config.show_footer and rows.len > 0) {
        const footer = try std.fmt.allocPrint(allocator, "\x1b[2m({d} row{s})\x1b[0m\n", .{
            rows.len,
            if (rows.len == 1) "" else "s",
        });
        defer allocator.free(footer);
        try buf.appendSlice(allocator, footer);
    }

    return try buf.toOwnedSlice(allocator);
}

const LineType = enum { top, middle, bottom };

fn appendBorderLine(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), col_widths: []const usize, bc: BorderChars, line_type: LineType, padding: usize) !void {
    const left = switch (line_type) {
        .top => bc.top_left,
        .middle => bc.t_left,
        .bottom => bc.bottom_left,
    };
    const right = switch (line_type) {
        .top => bc.top_right,
        .middle => bc.t_right,
        .bottom => bc.bottom_right,
    };
    const junction = switch (line_type) {
        .top => bc.t_top,
        .middle => bc.cross,
        .bottom => bc.t_bottom,
    };

    try buf.appendSlice(allocator, left);
    for (col_widths, 0..) |w, i| {
        for (0..w + padding * 2) |_| try buf.appendSlice(allocator, bc.horizontal);
        if (i < col_widths.len - 1) try buf.appendSlice(allocator, junction);
    }
    try buf.appendSlice(allocator, right);
    try buf.append(allocator, '\n');
}

/// Calculate visible string length (excluding ANSI escape sequences)
fn visibleLength(s: []const u8) usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            // Skip ANSI escape sequence
            i += 2;
            while (i < s.len and s[i] != 'm') i += 1;
            if (i < s.len) i += 1;
        } else {
            len += 1;
            i += 1;
        }
    }
    return len;
}
