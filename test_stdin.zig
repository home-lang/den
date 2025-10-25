const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    const stdin = std.io.stdin();
    var buf_reader = std.io.bufferedReader(stdin.reader());
    const reader = buf_reader.reader();
    
    std.debug.print("Type something: ", .{});
    
    var buffer: [1024]u8 = undefined;
    if (try reader.readUntilDelimiterOrEof(&buffer, '\n')) |line| {
        std.debug.print("You typed: {s}\n", .{line});
    }
}
