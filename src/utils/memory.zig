// Memory optimization utilities for Den Shell - Zig 0.15.1 compatible
const std = @import("std");

/// Simple object pool for reducing allocations
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

/// Stack buffer for small allocations (avoids heap)
pub fn StackBuffer(comptime size: usize) type {
    return struct {
        const Self = @This();

        buffer: [size]u8,
        used: usize,

        pub fn init() Self {
            return .{
                .buffer = undefined,
                .used = 0,
            };
        }

        pub fn alloc(self: *Self, n: usize) ?[]u8 {
            if (self.used + n > size) return null;
            const slice = self.buffer[self.used .. self.used + n];
            self.used += n;
            return slice;
        }

        pub fn reset(self: *Self) void {
            self.used = 0;
        }

        pub fn available(self: *const Self) usize {
            return size - self.used;
        }
    };
}

/// Arena allocator wrapper with statistics
pub const ShellArena = struct {
    arena: std.heap.ArenaAllocator,
    total_allocated: usize,
    peak_allocated: usize,

    pub fn init(backing_allocator: std.mem.Allocator) ShellArena {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .total_allocated = 0,
            .peak_allocated = 0,
        };
    }

    pub fn allocator(self: *ShellArena) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *ShellArena) void {
        self.arena.deinit();
    }

    pub fn reset(self: *ShellArena) void {
        _ = self.arena.reset(.retain_capacity);
        self.total_allocated = 0;
    }

    pub fn getStats(self: *const ShellArena) struct { total: usize, peak: usize } {
        return .{
            .total = self.total_allocated,
            .peak = self.peak_allocated,
        };
    }
};

/// Memory-efficient string builder
pub const StringBuilder = struct {
    const stack_size = 256;

    stack_buf: [stack_size]u8,
    heap_buf: ?std.ArrayListUnmanaged(u8),
    len: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StringBuilder {
        return .{
            .stack_buf = undefined,
            .heap_buf = null,
            .len = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StringBuilder) void {
        if (self.heap_buf) |*buf| {
            buf.deinit(self.allocator);
        }
    }

    pub fn append(self: *StringBuilder, str: []const u8) !void {
        const new_len = self.len + str.len;

        if (new_len <= stack_size) {
            @memcpy(self.stack_buf[self.len .. self.len + str.len], str);
            self.len = new_len;
        } else {
            if (self.heap_buf == null) {
                var buf: std.ArrayListUnmanaged(u8) = .{};
                try buf.ensureTotalCapacity(self.allocator, new_len);
                try buf.appendSlice(self.allocator, self.stack_buf[0..self.len]);
                self.heap_buf = buf;
            }

            try self.heap_buf.?.appendSlice(self.allocator, str);
            self.len = new_len;
        }
    }

    pub fn toSlice(self: *StringBuilder) []const u8 {
        if (self.heap_buf) |buf| {
            return buf.items;
        }
        return self.stack_buf[0..self.len];
    }

    pub fn reset(self: *StringBuilder) void {
        self.len = 0;
        if (self.heap_buf) |*buf| {
            buf.clearRetainingCapacity();
        }
    }
};

/// Memory pool for shell command execution
pub const CommandMemoryPool = struct {
    allocator: std.mem.Allocator,
    command_arena: ShellArena,
    arg_buffer: std.ArrayListUnmanaged([]const u8),
    env_buffer: std.ArrayListUnmanaged([]const u8),

    pub fn init(allocator: std.mem.Allocator) CommandMemoryPool {
        return .{
            .allocator = allocator,
            .command_arena = ShellArena.init(allocator),
            .arg_buffer = .{},
            .env_buffer = .{},
        };
    }

    pub fn deinit(self: *CommandMemoryPool) void {
        self.command_arena.deinit();
        self.arg_buffer.deinit(self.allocator);
        self.env_buffer.deinit(self.allocator);
    }

    pub fn reset(self: *CommandMemoryPool) void {
        self.command_arena.reset();
        self.arg_buffer.clearRetainingCapacity();
        self.env_buffer.clearRetainingCapacity();
    }

    pub fn getArenaAllocator(self: *CommandMemoryPool) std.mem.Allocator {
        return self.command_arena.allocator();
    }
};

/// Fixed-size stack array list for hot paths
pub fn StackArrayList(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        items: [capacity]T,
        len: usize,

        pub fn init() Self {
            return .{
                .items = undefined,
                .len = 0,
            };
        }

        pub fn append(self: *Self, item: T) error{OutOfMemory}!void {
            if (self.len >= capacity) return error.OutOfMemory;
            self.items[self.len] = item;
            self.len += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.items[self.len];
        }

        pub fn get(self: *Self, index: usize) ?T {
            if (index >= self.len) return null;
            return self.items[index];
        }

        pub fn slice(self: *Self) []T {
            return self.items[0..self.len];
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.len >= capacity;
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

test "StackBuffer basic operations" {
    var buf = StackBuffer(256).init();

    const slice1 = buf.alloc(100).?;
    try std.testing.expectEqual(@as(usize, 100), slice1.len);

    const slice2 = buf.alloc(100).?;
    try std.testing.expectEqual(@as(usize, 100), slice2.len);

    const slice3 = buf.alloc(100);
    try std.testing.expectEqual(@as(?[]u8, null), slice3);

    buf.reset();
    try std.testing.expectEqual(@as(usize, 256), buf.available());
}

test "StringBuilder stack and heap" {
    var sb = StringBuilder.init(std.testing.allocator);
    defer sb.deinit();

    try sb.append("Hello");
    try sb.append(" World");
    try std.testing.expectEqualStrings("Hello World", sb.toSlice());

    sb.reset();
    const large = "x" ** 300;
    try sb.append(large);
    try std.testing.expectEqual(@as(usize, 300), sb.toSlice().len);
}

test "StackArrayList operations" {
    var list = StackArrayList(i32, 10).init();

    try list.append(1);
    try list.append(2);
    try list.append(3);

    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqual(@as(i32, 3), list.pop().?);
    try std.testing.expectEqual(@as(usize, 2), list.len);

    list.clear();
    try std.testing.expectEqual(@as(usize, 0), list.len);
}

test "ShellArena basic operations" {
    var arena = ShellArena.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();
    _ = try alloc.alloc(u8, 100);
    _ = try alloc.alloc(u8, 200);

    arena.reset();

    _ = try alloc.alloc(u8, 50);
}
