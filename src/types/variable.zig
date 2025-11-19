const std = @import("std");

/// Variable type - can be a string or an array
pub const Variable = union(enum) {
    string: []const u8,
    array: [][]const u8,

    pub fn deinit(self: Variable, allocator: std.mem.Allocator) void {
        switch (self) {
            .string => |s| allocator.free(s),
            .array => |arr| {
                for (arr) |item| {
                    allocator.free(item);
                }
                allocator.free(arr);
            },
        }
    }

    pub fn clone(self: Variable, allocator: std.mem.Allocator) !Variable {
        return switch (self) {
            .string => |s| Variable{ .string = try allocator.dupe(u8, s) },
            .array => |arr| blk: {
                const new_arr = try allocator.alloc([]const u8, arr.len);
                errdefer allocator.free(new_arr);

                for (arr, 0..) |item, i| {
                    new_arr[i] = try allocator.dupe(u8, item);
                }
                break :blk Variable{ .array = new_arr };
            },
        };
    }

    /// Get as string - arrays join with spaces
    pub fn asString(self: Variable, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .string => |s| try allocator.dupe(u8, s),
            .array => |arr| {
                if (arr.len == 0) return try allocator.dupe(u8, "");
                if (arr.len == 1) return try allocator.dupe(u8, arr[0]);

                // Calculate total length
                var total_len: usize = 0;
                for (arr) |item| {
                    total_len += item.len;
                }
                total_len += arr.len - 1; // spaces between elements

                // Join with spaces
                const result = try allocator.alloc(u8, total_len);
                var pos: usize = 0;
                for (arr, 0..) |item, i| {
                    @memcpy(result[pos..][0..item.len], item);
                    pos += item.len;
                    if (i < arr.len - 1) {
                        result[pos] = ' ';
                        pos += 1;
                    }
                }
                return result;
            },
        };
    }

    /// Get length - 1 for strings, array.len for arrays
    pub fn length(self: Variable) usize {
        return switch (self) {
            .string => 1,
            .array => |arr| arr.len,
        };
    }
};
