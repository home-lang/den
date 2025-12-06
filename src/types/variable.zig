const std = @import("std");

/// Variable attributes for declare/typeset
pub const VarAttributes = packed struct {
    readonly: bool = false, // -r: readonly
    integer: bool = false, // -i: integer attribute
    exported: bool = false, // -x: export to environment
    lowercase: bool = false, // -l: convert to lowercase
    uppercase: bool = false, // -u: convert to uppercase
    nameref: bool = false, // -n: name reference
    indexed_array: bool = false, // -a: indexed array
    assoc_array: bool = false, // -A: associative array
};

/// Variable type - can be a string, indexed array, or associative array
pub const Variable = union(enum) {
    string: []const u8,
    array: [][]const u8,
    assoc: std.StringHashMap([]const u8),

    pub fn deinit(self: *Variable, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .array => |arr| {
                for (arr) |item| {
                    allocator.free(item);
                }
                allocator.free(arr);
            },
            .assoc => |*map| {
                var it = map.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    allocator.free(entry.value_ptr.*);
                }
                map.deinit();
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
            .assoc => |map| blk: {
                var new_map = std.StringHashMap([]const u8).init(allocator);
                errdefer new_map.deinit();

                var it = map.iterator();
                while (it.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    const value = try allocator.dupe(u8, entry.value_ptr.*);
                    try new_map.put(key, value);
                }
                break :blk Variable{ .assoc = new_map };
            },
        };
    }

    /// Get as string - arrays join with spaces, assoc returns keys
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
            .assoc => |map| {
                // Return space-separated keys
                var total_len: usize = 0;
                var count: usize = 0;
                var it = map.iterator();
                while (it.next()) |entry| {
                    total_len += entry.key_ptr.*.len;
                    count += 1;
                }
                if (count == 0) return try allocator.dupe(u8, "");
                total_len += count - 1; // spaces

                const result = try allocator.alloc(u8, total_len);
                var pos: usize = 0;
                var first = true;
                it = map.iterator();
                while (it.next()) |entry| {
                    if (!first) {
                        result[pos] = ' ';
                        pos += 1;
                    }
                    first = false;
                    const key = entry.key_ptr.*;
                    @memcpy(result[pos..][0..key.len], key);
                    pos += key.len;
                }
                return result;
            },
        };
    }

    /// Get length - 1 for strings, array.len for arrays, map.count for assoc
    pub fn length(self: Variable) usize {
        return switch (self) {
            .string => 1,
            .array => |arr| arr.len,
            .assoc => |map| map.count(),
        };
    }
};
