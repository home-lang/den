const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Try using initBuffer or direct construction
    var list: std.ArrayList(u8) = .{ .allocator = allocator, .items = &.{}, .capacity = 0 };
    defer list.deinit();
    
    try list.append('a');
    std.debug.print("List: {any}\n", .{list.items});
}
