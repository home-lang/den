const std = @import("std");

/// String utilities for shell operations
pub const String = struct {
    /// Check if string starts with prefix
    pub fn startsWith(str: []const u8, prefix: []const u8) bool {
        if (prefix.len > str.len) return false;
        return std.mem.eql(u8, str[0..prefix.len], prefix);
    }

    /// Check if string ends with suffix
    pub fn endsWith(str: []const u8, suffix: []const u8) bool {
        if (suffix.len > str.len) return false;
        const start = str.len - suffix.len;
        return std.mem.eql(u8, str[start..], suffix);
    }

    /// Check if string contains substring
    pub fn contains(str: []const u8, needle: []const u8) bool {
        return std.mem.indexOf(u8, str, needle) != null;
    }

    /// Split string by delimiter
    pub fn split(allocator: std.mem.Allocator, str: []const u8, delimiter: []const u8) ![][]const u8 {
        var result = std.array_list.Managed([]const u8).init(allocator);
        errdefer result.deinit();

        var iter = std.mem.splitSequence(u8, str, delimiter);
        while (iter.next()) |part| {
            const owned = try allocator.dupe(u8, part);
            try result.append(owned);
        }

        return result.toOwnedSlice();
    }

    /// Join strings with separator
    pub fn join(allocator: std.mem.Allocator, parts: []const []const u8, separator: []const u8) ![]u8 {
        if (parts.len == 0) return try allocator.dupe(u8, "");

        var total_len: usize = 0;
        for (parts) |part| {
            total_len += part.len;
        }
        total_len += separator.len * (parts.len - 1);

        const result = try allocator.alloc(u8, total_len);
        var pos: usize = 0;

        for (parts, 0..) |part, i| {
            @memcpy(result[pos .. pos + part.len], part);
            pos += part.len;

            if (i < parts.len - 1) {
                @memcpy(result[pos .. pos + separator.len], separator);
                pos += separator.len;
            }
        }

        return result;
    }

    /// Trim whitespace from both ends
    pub fn trim(str: []const u8) []const u8 {
        return std.mem.trim(u8, str, &std.ascii.whitespace);
    }

    /// Trim specific characters from both ends
    pub fn trimChars(str: []const u8, chars: []const u8) []const u8 {
        return std.mem.trim(u8, str, chars);
    }

    /// Replace first occurrence
    pub fn replaceFirst(allocator: std.mem.Allocator, str: []const u8, old: []const u8, new: []const u8) ![]u8 {
        if (std.mem.indexOf(u8, str, old)) |index| {
            const result = try allocator.alloc(u8, str.len - old.len + new.len);
            @memcpy(result[0..index], str[0..index]);
            @memcpy(result[index .. index + new.len], new);
            @memcpy(result[index + new.len ..], str[index + old.len ..]);
            return result;
        }
        return try allocator.dupe(u8, str);
    }

    /// Replace all occurrences
    pub fn replaceAll(allocator: std.mem.Allocator, str: []const u8, old: []const u8, new: []const u8) ![]u8 {
        var result = std.array_list.Managed(u8){};
        errdefer result.deinit();

        var remaining = str;
        while (std.mem.indexOf(u8, remaining, old)) |index| {
            try result.appendSlice(remaining[0..index]);
            try result.appendSlice(new);
            remaining = remaining[index + old.len ..];
        }
        try result.appendSlice(remaining);

        return result.toOwnedSlice();
    }

    /// Case-insensitive string equality
    pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |char_a, char_b| {
            if (std.ascii.toLower(char_a) != std.ascii.toLower(char_b)) {
                return false;
            }
        }
        return true;
    }
};

test "String.startsWith" {
    try std.testing.expect(String.startsWith("hello world", "hello"));
    try std.testing.expect(!String.startsWith("hello world", "world"));
}

test "String.endsWith" {
    try std.testing.expect(String.endsWith("hello world", "world"));
    try std.testing.expect(!String.endsWith("hello world", "hello"));
}

test "String.contains" {
    try std.testing.expect(String.contains("hello world", "lo wo"));
    try std.testing.expect(!String.contains("hello world", "xyz"));
}

test "String.trim" {
    const result = String.trim("  hello  ");
    try std.testing.expectEqualStrings("hello", result);
}

test "String.eqlIgnoreCase" {
    try std.testing.expect(String.eqlIgnoreCase("Hello", "HELLO"));
    try std.testing.expect(String.eqlIgnoreCase("WoRlD", "world"));
    try std.testing.expect(!String.eqlIgnoreCase("hello", "world"));
}
