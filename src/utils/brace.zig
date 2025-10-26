const std = @import("std");

/// Brace expansion utilities
pub const BraceExpander = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BraceExpander {
        return .{ .allocator = allocator };
    }

    /// Expand brace patterns like {1..10} or {a..z} or {foo,bar,baz}
    pub fn expand(self: *BraceExpander, input: []const u8) ![][]const u8 {
        // Find first brace pattern
        const brace_start = std.mem.indexOfScalar(u8, input, '{') orelse {
            // No braces, return input as-is
            const result = try self.allocator.alloc([]const u8, 1);
            result[0] = try self.allocator.dupe(u8, input);
            return result;
        };

        const brace_end = std.mem.indexOfScalarPos(u8, input, brace_start, '}') orelse {
            // No closing brace, return input as-is
            const result = try self.allocator.alloc([]const u8, 1);
            result[0] = try self.allocator.dupe(u8, input);
            return result;
        };

        const prefix = input[0..brace_start];
        const suffix = input[brace_end + 1 ..];
        const brace_content = input[brace_start + 1 .. brace_end];

        // Check if it's a sequence (..) or a list (,)
        if (std.mem.indexOf(u8, brace_content, "..")) |sep_pos| {
            // Sequence expansion: {1..10} or {a..z}
            return try self.expandSequence(prefix, brace_content, suffix, sep_pos);
        } else if (std.mem.indexOfScalar(u8, brace_content, ',')) |_| {
            // List expansion: {foo,bar,baz}
            return try self.expandList(prefix, brace_content, suffix);
        } else {
            // Not a valid brace pattern, return as-is
            const result = try self.allocator.alloc([]const u8, 1);
            result[0] = try self.allocator.dupe(u8, input);
            return result;
        }
    }

    fn expandSequence(self: *BraceExpander, prefix: []const u8, content: []const u8, suffix: []const u8, sep_pos: usize) ![][]const u8 {
        const start_str = content[0..sep_pos];
        const end_str = content[sep_pos + 2 ..];

        // Try to parse as integers first
        const start_num = std.fmt.parseInt(i64, start_str, 10) catch {
            // Try as characters
            if (start_str.len == 1 and end_str.len == 1) {
                return try self.expandCharSequence(prefix, start_str[0], end_str[0], suffix);
            }

            // Invalid sequence, return as-is
            const result = try self.allocator.alloc([]const u8, 1);
            const full = try std.fmt.allocPrint(self.allocator, "{s}{{{s}}}{s}", .{ prefix, content, suffix });
            result[0] = full;
            return result;
        };

        const end_num = std.fmt.parseInt(i64, end_str, 10) catch {
            // Invalid sequence, return as-is
            const result = try self.allocator.alloc([]const u8, 1);
            const full = try std.fmt.allocPrint(self.allocator, "{s}{{{s}}}{s}", .{ prefix, content, suffix });
            result[0] = full;
            return result;
        };

        return try self.expandNumericSequence(prefix, start_num, end_num, suffix);
    }

    fn expandNumericSequence(self: *BraceExpander, prefix: []const u8, start: i64, end: i64, suffix: []const u8) ![][]const u8 {
        const step: i64 = if (start <= end) 1 else -1;
        const count = @abs(end - start) + 1;

        if (count > 1000) {
            // Limit to prevent abuse
            const result = try self.allocator.alloc([]const u8, 1);
            const full = try std.fmt.allocPrint(self.allocator, "{s}{{{d}..{d}}}{s}", .{ prefix, start, end, suffix });
            result[0] = full;
            return result;
        }

        const result = try self.allocator.alloc([]const u8, @intCast(count));
        var i: usize = 0;
        var current = start;

        while ((step > 0 and current <= end) or (step < 0 and current >= end)) : ({
            current += step;
            i += 1;
        }) {
            result[i] = try std.fmt.allocPrint(self.allocator, "{s}{d}{s}", .{ prefix, current, suffix });
        }

        return result;
    }

    fn expandCharSequence(self: *BraceExpander, prefix: []const u8, start: u8, end: u8, suffix: []const u8) ![][]const u8 {
        const step: i8 = if (start <= end) 1 else -1;
        const count = @abs(@as(i16, end) - @as(i16, start)) + 1;

        if (count > 52) {
            // Limit to prevent abuse (a-z is 26, A-Z is 26)
            const result = try self.allocator.alloc([]const u8, 1);
            const full = try std.fmt.allocPrint(self.allocator, "{s}{{{c}..{c}}}{s}", .{ prefix, start, end, suffix });
            result[0] = full;
            return result;
        }

        const result = try self.allocator.alloc([]const u8, @intCast(count));
        var i: usize = 0;
        var current: i16 = start;

        while ((step > 0 and current <= end) or (step < 0 and current >= end)) : ({
            current += step;
            i += 1;
        }) {
            result[i] = try std.fmt.allocPrint(self.allocator, "{s}{c}{s}", .{ prefix, @as(u8, @intCast(current)), suffix });
        }

        return result;
    }

    fn expandList(self: *BraceExpander, prefix: []const u8, content: []const u8, suffix: []const u8) ![][]const u8 {
        // Count items first
        var count: usize = 1;
        for (content) |c| {
            if (c == ',') count += 1;
        }

        const result = try self.allocator.alloc([]const u8, count);
        var idx: usize = 0;

        var iter = std.mem.splitScalar(u8, content, ',');
        while (iter.next()) |item| : (idx += 1) {
            const trimmed = std.mem.trim(u8, item, &std.ascii.whitespace);
            result[idx] = try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ prefix, trimmed, suffix });
        }

        return result;
    }
};

test "brace expansion numeric sequence" {
    const allocator = std.testing.allocator;
    var expander = BraceExpander.init(allocator);

    const result = try expander.expand("file{1..3}.txt");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("file1.txt", result[0]);
    try std.testing.expectEqualStrings("file2.txt", result[1]);
    try std.testing.expectEqualStrings("file3.txt", result[2]);
}

test "brace expansion char sequence" {
    const allocator = std.testing.allocator;
    var expander = BraceExpander.init(allocator);

    const result = try expander.expand("test{a..c}");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("testa", result[0]);
    try std.testing.expectEqualStrings("testb", result[1]);
    try std.testing.expectEqualStrings("testc", result[2]);
}

test "brace expansion list" {
    const allocator = std.testing.allocator;
    var expander = BraceExpander.init(allocator);

    const result = try expander.expand("file.{txt,md,zig}");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("file.txt", result[0]);
    try std.testing.expectEqualStrings("file.md", result[1]);
    try std.testing.expectEqualStrings("file.zig", result[2]);
}
