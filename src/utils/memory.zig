// Memory optimization utilities for Den Shell - Zig 0.15.1 compatible
const std = @import("std");
const builtin = @import("builtin");

/// Memory leak detection allocator for debug builds
/// Wraps another allocator and tracks all allocations
pub const LeakDetector = struct {
    const AllocationInfo = struct {
        size: usize,
        stack_trace: ?std.builtin.StackTrace,
        timestamp: i64,
    };

    backing_allocator: std.mem.Allocator,
    allocations: std.AutoHashMap(usize, AllocationInfo),
    total_allocated: usize,
    total_freed: usize,
    peak_usage: usize,
    allocation_count: usize,
    free_count: usize,
    mutex: std.Thread.Mutex,

    pub fn init(backing_allocator: std.mem.Allocator) LeakDetector {
        return .{
            .backing_allocator = backing_allocator,
            .allocations = std.AutoHashMap(usize, AllocationInfo).init(backing_allocator),
            .total_allocated = 0,
            .total_freed = 0,
            .peak_usage = 0,
            .allocation_count = 0,
            .free_count = 0,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *LeakDetector) void {
        self.allocations.deinit();
    }

    pub fn allocator(self: *LeakDetector) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *LeakDetector = @ptrCast(@alignCast(ctx));

        const result = self.backing_allocator.rawAlloc(len, ptr_align, ret_addr);
        if (result) |ptr| {
            self.mutex.lock();
            defer self.mutex.unlock();

            const addr = @intFromPtr(ptr);
            self.allocations.put(addr, .{
                .size = len,
                .stack_trace = if (builtin.mode == .Debug) std.debug.getSelfDebugInfo() catch null else null,
                .timestamp = std.time.milliTimestamp(),
            }) catch {};

            self.total_allocated += len;
            self.allocation_count += 1;
            const current_usage = self.total_allocated - self.total_freed;
            if (current_usage > self.peak_usage) {
                self.peak_usage = current_usage;
            }
        }
        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        const self: *LeakDetector = @ptrCast(@alignCast(ctx));

        const old_len = buf.len;
        const result = self.backing_allocator.rawResize(buf, buf_align, new_len, ret_addr);

        if (result) {
            self.mutex.lock();
            defer self.mutex.unlock();

            const addr = @intFromPtr(buf.ptr);
            if (self.allocations.getPtr(addr)) |info| {
                self.total_allocated += new_len;
                self.total_freed += old_len;
                info.size = new_len;
                info.timestamp = std.time.milliTimestamp();
            }
        }
        return result;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        const self: *LeakDetector = @ptrCast(@alignCast(ctx));

        self.mutex.lock();
        defer self.mutex.unlock();

        const addr = @intFromPtr(buf.ptr);
        if (self.allocations.fetchRemove(addr)) |_| {
            self.total_freed += buf.len;
            self.free_count += 1;
        }

        self.backing_allocator.rawFree(buf, buf_align, ret_addr);
    }

    /// Check for memory leaks and return a report
    pub fn checkLeaks(self: *LeakDetector) LeakReport {
        self.mutex.lock();
        defer self.mutex.unlock();

        var leaked_bytes: usize = 0;
        var leak_count: usize = 0;

        var iter = self.allocations.iterator();
        while (iter.next()) |entry| {
            leaked_bytes += entry.value_ptr.size;
            leak_count += 1;
        }

        return .{
            .leaked_bytes = leaked_bytes,
            .leak_count = leak_count,
            .total_allocated = self.total_allocated,
            .total_freed = self.total_freed,
            .peak_usage = self.peak_usage,
            .allocation_count = self.allocation_count,
            .free_count = self.free_count,
        };
    }

    /// Print leak report to stderr
    pub fn printLeakReport(self: *LeakDetector) void {
        const report = self.checkLeaks();
        const stderr = std.io.getStdErr().writer();

        stderr.print("\n=== Memory Leak Report ===\n", .{}) catch {};
        stderr.print("Total allocated: {} bytes ({} allocations)\n", .{ report.total_allocated, report.allocation_count }) catch {};
        stderr.print("Total freed: {} bytes ({} frees)\n", .{ report.total_freed, report.free_count }) catch {};
        stderr.print("Peak usage: {} bytes\n", .{report.peak_usage}) catch {};

        if (report.leak_count > 0) {
            stderr.print("\n!!! LEAKS DETECTED !!!\n", .{}) catch {};
            stderr.print("Leaked: {} bytes in {} allocation(s)\n", .{ report.leaked_bytes, report.leak_count }) catch {};

            // Print individual leaks
            self.mutex.lock();
            defer self.mutex.unlock();

            var count: usize = 0;
            var iter = self.allocations.iterator();
            while (iter.next()) |entry| {
                if (count >= 10) {
                    stderr.print("  ... and {} more\n", .{report.leak_count - 10}) catch {};
                    break;
                }
                stderr.print("  Leak at 0x{x}: {} bytes\n", .{ entry.key_ptr.*, entry.value_ptr.size }) catch {};
                count += 1;
            }
        } else {
            stderr.print("\nNo leaks detected.\n", .{}) catch {};
        }
        stderr.print("===========================\n", .{}) catch {};
    }

    /// Assert no leaks (for tests)
    pub fn assertNoLeaks(self: *LeakDetector) !void {
        const report = self.checkLeaks();
        if (report.leak_count > 0) {
            self.printLeakReport();
            return error.MemoryLeak;
        }
    }
};

pub const LeakReport = struct {
    leaked_bytes: usize,
    leak_count: usize,
    total_allocated: usize,
    total_freed: usize,
    peak_usage: usize,
    allocation_count: usize,
    free_count: usize,

    pub fn hasLeaks(self: LeakReport) bool {
        return self.leak_count > 0;
    }
};

/// Debug allocator that can be enabled/disabled at runtime
pub const DebugAllocator = struct {
    inner: union {
        leak_detector: LeakDetector,
        passthrough: std.mem.Allocator,
    },
    enabled: bool,

    pub fn init(backing_allocator: std.mem.Allocator, enable_tracking: bool) DebugAllocator {
        if (enable_tracking and builtin.mode == .Debug) {
            return .{
                .inner = .{ .leak_detector = LeakDetector.init(backing_allocator) },
                .enabled = true,
            };
        }
        return .{
            .inner = .{ .passthrough = backing_allocator },
            .enabled = false,
        };
    }

    pub fn deinit(self: *DebugAllocator) void {
        if (self.enabled) {
            self.inner.leak_detector.deinit();
        }
    }

    pub fn allocator(self: *DebugAllocator) std.mem.Allocator {
        if (self.enabled) {
            return self.inner.leak_detector.allocator();
        }
        return self.inner.passthrough;
    }

    pub fn checkLeaks(self: *DebugAllocator) ?LeakReport {
        if (self.enabled) {
            return self.inner.leak_detector.checkLeaks();
        }
        return null;
    }

    pub fn printLeakReport(self: *DebugAllocator) void {
        if (self.enabled) {
            self.inner.leak_detector.printLeakReport();
        }
    }
};

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

test "LeakDetector basic operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var detector = LeakDetector.init(gpa.allocator());
    defer detector.deinit();

    const alloc = detector.allocator();

    // Allocate and free properly
    const ptr1 = try alloc.alloc(u8, 100);
    const ptr2 = try alloc.alloc(u8, 200);

    alloc.free(ptr1);
    alloc.free(ptr2);

    const report = detector.checkLeaks();
    try std.testing.expectEqual(@as(usize, 0), report.leak_count);
    try std.testing.expectEqual(@as(usize, 300), report.total_allocated);
    try std.testing.expectEqual(@as(usize, 300), report.total_freed);
}

test "LeakDetector detects leaks" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var detector = LeakDetector.init(gpa.allocator());
    defer detector.deinit();

    const alloc = detector.allocator();

    // Allocate but don't free one
    const ptr1 = try alloc.alloc(u8, 100);
    const ptr2 = try alloc.alloc(u8, 200);

    alloc.free(ptr1);
    // ptr2 is leaked!

    const report = detector.checkLeaks();
    try std.testing.expectEqual(@as(usize, 1), report.leak_count);
    try std.testing.expectEqual(@as(usize, 200), report.leaked_bytes);

    // Clean up the leak manually for test
    alloc.free(ptr2);
}

test "LeakReport hasLeaks" {
    const report_clean = LeakReport{
        .leaked_bytes = 0,
        .leak_count = 0,
        .total_allocated = 100,
        .total_freed = 100,
        .peak_usage = 100,
        .allocation_count = 1,
        .free_count = 1,
    };
    try std.testing.expect(!report_clean.hasLeaks());

    const report_leaky = LeakReport{
        .leaked_bytes = 50,
        .leak_count = 1,
        .total_allocated = 100,
        .total_freed = 50,
        .peak_usage = 100,
        .allocation_count = 2,
        .free_count = 1,
    };
    try std.testing.expect(report_leaky.hasLeaks());
}

/// String pool for interning frequently used strings
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

/// Slab allocator for fixed-size objects
pub fn SlabAllocator(comptime T: type, comptime slab_size: usize) type {
    return struct {
        const Self = @This();
        const Slab = struct {
            items: [slab_size]T,
            free_mask: std.bit_set.IntegerBitSet(slab_size),
        };

        allocator: std.mem.Allocator,
        slabs: std.ArrayList(*Slab),
        total_allocated: usize,
        total_freed: usize,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .slabs = std.ArrayList(*Slab).init(allocator),
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
