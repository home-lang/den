const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const utils = @import("utils");
const ansi = utils.ansi;

fn writeStdout(data: []const u8) !void {
    if (builtin.os.tag == .windows) {
        const win = std.os.windows;
        const handle = try win.GetStdHandle(win.STD_OUTPUT_HANDLE);
        const stdout = std.fs.File{ .handle = handle };
        try stdout.writeAll(data);
    } else {
        _ = try posix.write(posix.STDOUT_FILENO, data);
    }
}

fn print(comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, fmt, args);
    try writeStdout(result);
}

pub fn main() !void {
    try writeStdout("\n=== Den Shell ANSI/Terminal Utilities Demo ===\n\n");

    // 1. Basic Colors
    try writeStdout("1. Basic 16 Colors:\n");
    try print("  {s}Red{s} ", .{ ansi.Colors.red, ansi.Style.reset.toSequence() });
    try print("{s}Green{s} ", .{ ansi.Colors.green, ansi.Style.reset.toSequence() });
    try print("{s}Blue{s} ", .{ ansi.Colors.blue, ansi.Style.reset.toSequence() });
    try print("{s}Yellow{s}\n", .{ ansi.Colors.yellow, ansi.Style.reset.toSequence() });

    // 2. Bright Colors
    try writeStdout("\n2. Bright Colors:\n");
    try print("  {s}Bright Red{s} ", .{ ansi.Colors.bright_red, ansi.Style.reset.toSequence() });
    try print("{s}Bright Green{s} ", .{ ansi.Colors.bright_green, ansi.Style.reset.toSequence() });
    try print("{s}Bright Blue{s}\n", .{ ansi.Colors.bright_blue, ansi.Style.reset.toSequence() });

    // 3. RGB Colors
    try writeStdout("\n3. 24-bit RGB Colors:\n  ");
    const rgb_color = ansi.Color{ .rgb = .{ .r = 255, .g = 100, .b = 50 } };
    var rgb_buf: [32]u8 = undefined;
    const rgb_seq = try rgb_color.toForeground(&rgb_buf);
    try print("{s}Custom RGB Orange{s}\n", .{ rgb_seq, ansi.Style.reset.toSequence() });

    // 4. Hex Colors
    try writeStdout("\n4. Hex Colors:\n  ");
    const hex_color = try ansi.Color.fromHex("#00FF00");
    var hex_buf: [32]u8 = undefined;
    const hex_seq = try hex_color.toForeground(&hex_buf);
    try print("{s}Hex Green #00FF00{s}\n", .{ hex_seq, ansi.Style.reset.toSequence() });

    // 5. Text Styles
    try writeStdout("\n5. Text Styles:\n");
    try print("  {s}Bold{s} ", .{ ansi.Style.bold.toSequence(), ansi.Style.reset.toSequence() });
    try print("{s}Italic{s} ", .{ ansi.Style.italic.toSequence(), ansi.Style.reset.toSequence() });
    try print("{s}Underline{s} ", .{ ansi.Style.underline.toSequence(), ansi.Style.reset.toSequence() });
    try print("{s}Dim{s}\n", .{ ansi.Style.dim.toSequence(), ansi.Style.reset.toSequence() });

    // 6. Combined Styles using Builder
    try writeStdout("\n6. Combined Styles (Builder):\n  ");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var builder = ansi.Builder.init(allocator);
    defer builder.deinit();

    const blue = ansi.Color{ .basic = 4 };
    try builder.fg(blue);
    try builder.style(.bold);
    try builder.style(.underline);
    const combined = try builder.build();
    try print("{s}Bold Blue Underlined{s}\n", .{ combined, ansi.Style.reset.toSequence() });

    // 7. Terminal Size Detection
    try writeStdout("\n7. Terminal Size Detection:\n");
    const size = ansi.getTerminalSize() catch |err| {
        try print("  Error detecting size: {}\n", .{err});
        return;
    };
    try print("  Terminal size: {d} rows x {d} cols\n", .{ size.rows, size.cols });

    // 8. Cursor Movement Demo
    try writeStdout("\n8. Cursor Movement:\n");
    try writeStdout("  Original position");
    try writeStdout(ansi.Sequences.save_cursor);
    const down_seq = ansi.Sequences.cursorDown(2);
    try writeStdout(&down_seq);
    const forward_seq = ansi.Sequences.cursorForward(5);
    try writeStdout(&forward_seq);
    try writeStdout("[Moved down 2, right 5]");
    try writeStdout(ansi.Sequences.restore_cursor);
    try writeStdout("\n");

    // 9. 256-Color Palette
    try writeStdout("\n9. 256-Color Palette Sample:\n  ");
    var i: u8 = 16;
    while (i < 232) : (i += 1) {
        const palette_color = ansi.Color{ .palette = i };
        var palette_buf: [32]u8 = undefined;
        const palette_seq = try palette_color.toBackground(&palette_buf);
        try print("{s} {s}", .{ palette_seq, ansi.Style.reset.toSequence() });
        if ((i - 15) % 36 == 0) {
            try writeStdout("\n  ");
        }
    }
    try writeStdout("\n");

    // 10. Raw Mode Demo (non-interactive, just show capability)
    try writeStdout("\n10. Raw Mode:\n");
    try writeStdout("  Raw mode is available for interactive input.\n");
    try writeStdout("  (Not demonstrated interactively in this example)\n");

    // 11. Alternative Screen Buffer
    try writeStdout("\n11. Alternative Screen Buffer:\n");
    try writeStdout("  Can switch to alt screen (not done in example to avoid disruption)\n");

    // 12. Clear Operations
    try writeStdout("\n12. Clear Operations Available:\n");
    try writeStdout("  - clearScreen(): Clear entire screen\n");
    try writeStdout("  - clearToEnd(): Clear from cursor to end\n");
    try writeStdout("  - clearToBegin(): Clear from cursor to beginning\n");
    try writeStdout("  - clearLine(): Clear current line\n");

    // 13. Color Gradient Example
    try writeStdout("\n13. RGB Color Gradient:\n  ");
    var r: u8 = 0;
    while (r <= 255) : (r += 15) {
        const grad_color = ansi.Color{ .rgb = .{ .r = r, .g = 100, .b = 255 - r } };
        var grad_buf: [32]u8 = undefined;
        const grad_seq = try grad_color.toForeground(&grad_buf);
        try print("{s}█{s}", .{ grad_seq, ansi.Style.reset.toSequence() });
    }
    try writeStdout("\n");

    try writeStdout("\n=== Demo Complete ===\n\n");
}
