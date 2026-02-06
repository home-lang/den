// Object pooling utilities for Den Shell
// Reduces allocations by reusing objects
const std = @import("std");

/// Simple object pool for reducing allocations
/// Fixed-size pool that pre-allocates objects
pub fn ObjectPool(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        available: [capacity]?*T,
        available_count: usize,
        all_items: [capacity]T,

        pub fn init(allocator: std.mem.Allocator) Self {
            var self = Self{
                .allocator = allocator,
                .available = [_]?*T{null} ** capacity,
                .available_count = capacity,
                .all_items = undefined,
            };

            // Initialize available list with all items
            for (0..capacity) |i| {
                self.available[i] = &self.all_items[i];
            }

            return self;
        }

        pub fn acquire(self: *Self) ?*T {
            if (self.available_count == 0) return null;
            self.available_count -= 1;
            const item = self.available[self.available_count];
            self.available[self.available_count] = null;
            return item;
        }

        pub fn release(self: *Self, item: *T) void {
            if (self.available_count >= capacity) return;
            self.available[self.available_count] = item;
            self.available_count += 1;
        }

        pub fn reset(self: *Self) void {
            for (0..capacity) |i| {
                self.available[i] = &self.all_items[i];
            }
            self.available_count = capacity;
        }

        pub fn available_items(self: *const Self) usize {
            return self.available_count;
        }
    };
}

/// String pool for interning frequently used strings
/// Deduplicates strings to save memory
pub const StringPool = struct {
    allocator: std.mem.Allocator,
    strings: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) StringPool {
        return .{
            .allocator = allocator,
            .strings = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *StringPool) void {
        var iter = self.strings.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.strings.deinit();
    }

    /// Intern a string - returns a pointer to the pooled string
    /// If the string already exists, returns the existing pointer
    pub fn intern(self: *StringPool, str: []const u8) ![]const u8 {
        if (self.strings.getKey(str)) |existing| {
            return existing;
        }

        const owned = try self.allocator.dupe(u8, str);
        try self.strings.put(owned, {});
        return owned;
    }

    /// Check if a string is in the pool
    pub fn contains(self: *StringPool, str: []const u8) bool {
        return self.strings.contains(str);
    }

    /// Get count of interned strings
    pub fn count(self: *StringPool) usize {
        return self.strings.count();
    }

    /// Clear all interned strings
    pub fn clear(self: *StringPool) void {
        var iter = self.strings.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.strings.clearRetainingCapacity();
    }
};

/// Slab allocator for fixed-size objects
/// Allocates objects in slabs for efficient memory usage
pub fn SlabAllocator(comptime T: type, comptime slab_size: usize) type {
    return struct {
        const Self = @This();
        const Slab = struct {
            items: [slab_size]T,
            free_mask: std.bit_set.IntegerBitSet(slab_size),
        };

        allocator: std.mem.Allocator,
        slabs: std.array_list.Managed(*Slab),
        total_allocated: usize,
        total_freed: usize,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .slabs = std.array_list.Managed(*Slab).init(allocator),
                .total_allocated = 0,
                .total_freed = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.slabs.items) |slab| {
                self.allocator.destroy(slab);
            }
            self.slabs.deinit();
        }

        pub fn alloc(self: *Self) !*T {
            // Find a slab with free space
            for (self.slabs.items) |slab| {
                if (slab.free_mask.count() < slab_size) {
                    // Find first free slot
                    for (0..slab_size) |i| {
                        if (!slab.free_mask.isSet(i)) {
                            slab.free_mask.set(i);
                            self.total_allocated += 1;
                            return &slab.items[i];
                        }
                    }
                }
            }

            // Need a new slab
            const new_slab = try self.allocator.create(Slab);
            new_slab.free_mask = std.bit_set.IntegerBitSet(slab_size).initEmpty();
            try self.slabs.append(new_slab);

            new_slab.free_mask.set(0);
            self.total_allocated += 1;
            return &new_slab.items[0];
        }

        pub fn free(self: *Self, ptr: *T) void {
            const addr = @intFromPtr(ptr);

            for (self.slabs.items) |slab| {
                const slab_start = @intFromPtr(&slab.items[0]);
                const slab_end = slab_start + slab_size * @sizeOf(T);

                if (addr >= slab_start and addr < slab_end) {
                    const index = (addr - slab_start) / @sizeOf(T);
                    slab.free_mask.unset(index);
                    self.total_freed += 1;
                    return;
                }
            }
        }

        pub fn getStats(self: *Self) struct { allocated: usize, freed: usize, in_use: usize } {
            return .{
                .allocated = self.total_allocated,
                .freed = self.total_freed,
                .in_use = self.total_allocated - self.total_freed,
            };
        }
    };
}

// Tests
test "ObjectPool basic operations" {
    const TestStruct = struct { value: i32 };
    var pool = ObjectPool(TestStruct, 10).init(std.testing.allocator);

    const item1 = pool.acquire().?;
    item1.value = 42;

    const item2 = pool.acquire().?;
    item2.value = 100;

    try std.testing.expectEqual(@as(usize, 8), pool.available_items());

    pool.release(item1);
    try std.testing.expectEqual(@as(usize, 9), pool.available_items());

    _ = pool.acquire().?;
    try std.testing.expectEqual(@as(usize, 8), pool.available_items());

    pool.reset();
    try std.testing.expectEqual(@as(usize, 10), pool.available_items());
}

test "StringPool interning" {
    var pool = StringPool.init(std.testing.allocator);
    defer pool.deinit();

    const str1 = try pool.intern("hello");
    const str2 = try pool.intern("hello");
    const str3 = try pool.intern("world");

    // Same string should return same pointer
    try std.testing.expectEqual(str1.ptr, str2.ptr);
    try std.testing.expect(str1.ptr != str3.ptr);

    // Pool should have 2 unique strings
    try std.testing.expectEqual(@as(usize, 2), pool.count());
}

test "SlabAllocator basic operations" {
    const TestItem = struct {
        value: i32,
        data: [32]u8,
    };

    var slab = SlabAllocator(TestItem, 16).init(std.testing.allocator);
    defer slab.deinit();

    const item1 = try slab.alloc();
    item1.value = 42;

    const item2 = try slab.alloc();
    item2.value = 100;

    const stats1 = slab.getStats();
    try std.testing.expectEqual(@as(usize, 2), stats1.allocated);
    try std.testing.expectEqual(@as(usize, 2), stats1.in_use);

    slab.free(item1);

    const stats2 = slab.getStats();
    try std.testing.expectEqual(@as(usize, 1), stats2.in_use);
}
