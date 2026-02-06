// Parallel module and plugin discovery for Den Shell
const std = @import("std");
const concurrency = @import("concurrency");

/// Parallel directory scanner for plugin/module discovery
pub const ParallelScanner = struct {
    allocator: std.mem.Allocator,
    thread_pool: *concurrency.ThreadPool,
    results: std.ArrayListUnmanaged([]const u8),
    results_mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, thread_pool: *concurrency.ThreadPool) ParallelScanner {
        return .{
            .allocator = allocator,
            .thread_pool = thread_pool,
            .results = .{},
            .results_mutex = .{},
        };
    }

    pub fn deinit(self: *ParallelScanner) void {
        for (self.results.items) |path| {
            self.allocator.free(path);
        }
        self.results.deinit(self.allocator);
    }

    /// Scan directories in parallel for files matching a pattern
    pub fn scanDirectories(
        self: *ParallelScanner,
        directories: []const []const u8,
        extension: []const u8,
    ) ![]const []const u8 {
        if (directories.len == 0) return &[_][]const u8{};

        // For single directory, just scan directly
        if (directories.len == 1) {
            try self.scanDirectory(directories[0], extension);
            return self.results.items;
        }

        // Parallel scan for multiple directories
        for (directories) |dir| {
            const Args = struct {
                scanner: *ParallelScanner,
                directory: []const u8,
                ext: []const u8,
            };

            try self.thread_pool.submit(struct {
                fn scan(args: Args) void {
                    args.scanner.scanDirectory(args.directory, args.ext) catch {};
                }
            }.scan, Args{
                .scanner = self,
                .directory = dir,
                .ext = extension,
            });
        }

        self.thread_pool.waitIdle();
        return self.results.items;
    }

    fn scanDirectory(self: *ParallelScanner, dir_path: []const u8, extension: []const u8) !void {
        var dir = std.Io.Dir.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            // Directory doesn't exist or can't be opened, skip it
            if (err == error.FileNotFound or err == error.NotDir) {
                return;
            }
            return err;
        };
        defer dir.close();

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;

            if (std.mem.endsWith(u8, entry.basename, extension)) {
                const full_path = try std.fs.path.join(
                    self.allocator,
                    &[_][]const u8{ dir_path, entry.path },
                );

                self.results_mutex.lock();
                defer self.results_mutex.unlock();
                try self.results.append(self.allocator, full_path);
            }
        }
    }
};

/// Parallel file processor for loading modules
pub const ParallelFileProcessor = struct {
    allocator: std.mem.Allocator,
    thread_pool: *concurrency.ThreadPool,

    pub fn init(allocator: std.mem.Allocator, thread_pool: *concurrency.ThreadPool) ParallelFileProcessor {
        return .{
            .allocator = allocator,
            .thread_pool = thread_pool,
        };
    }

    /// Process files in parallel with a callback
    pub fn processFiles(
        self: *ParallelFileProcessor,
        files: []const []const u8,
        comptime processor: fn ([]const u8) anyerror!void,
    ) !void {
        if (files.len == 0) return;

        // For small file counts, process sequentially
        if (files.len < 4) {
            for (files) |file| {
                try processor(file);
            }
            return;
        }

        // Parallel processing for many files
        const chunk_size = @max(1, files.len / self.thread_pool.threads.len);
        var start: usize = 0;

        while (start < files.len) {
            const end = @min(start + chunk_size, files.len);
            const chunk = files[start..end];

            const Args = struct { chunk: []const []const u8 };
            try self.thread_pool.submit(struct {
                fn process(args: Args) void {
                    for (args.chunk) |file| {
                        processor(file) catch {};
                    }
                }
            }.process, Args{ .chunk = chunk });

            start = end;
        }

        self.thread_pool.waitIdle();
    }
};

/// Concurrent hash map with sharding for reduced lock contention
pub fn ConcurrentHashMap(comptime K: type, comptime V: type, comptime shard_count: usize) type {
    return struct {
        const Self = @This();
        const Shard = struct {
            map: std.StringHashMapUnmanaged(V),
            mutex: std.Thread.Mutex,

            fn init() Shard {
                return .{
                    .map = .{},
                    .mutex = .{},
                };
            }

            fn deinit(self: *Shard, allocator: std.mem.Allocator) void {
                self.map.deinit(allocator);
            }
        };

        allocator: std.mem.Allocator,
        shards: [shard_count]Shard,

        pub fn init(allocator: std.mem.Allocator) Self {
            var self = Self{
                .allocator = allocator,
                .shards = undefined,
            };

            for (&self.shards) |*shard| {
                shard.* = Shard.init();
            }

            return self;
        }

        pub fn deinit(self: *Self) void {
            for (&self.shards) |*shard| {
                shard.deinit(self.allocator);
            }
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            const shard_idx = self.getShardIndex(key);
            var shard = &self.shards[shard_idx];

            shard.mutex.lock();
            defer shard.mutex.unlock();

            try shard.map.put(self.allocator, key, value);
        }

        pub fn get(self: *Self, key: K) ?V {
            const shard_idx = self.getShardIndex(key);
            var shard = &self.shards[shard_idx];

            shard.mutex.lock();
            defer shard.mutex.unlock();

            return shard.map.get(key);
        }

        pub fn remove(self: *Self, key: K) bool {
            const shard_idx = self.getShardIndex(key);
            var shard = &self.shards[shard_idx];

            shard.mutex.lock();
            defer shard.mutex.unlock();

            return shard.map.remove(key);
        }

        fn getShardIndex(self: *const Self, key: K) usize {
            _ = self;
            // Simple hash function for sharding
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHashStrat(&hasher, key, .Deep);
            return hasher.final() % shard_count;
        }

        pub fn count(self: *Self) usize {
            var total: usize = 0;
            for (&self.shards) |*shard| {
                shard.mutex.lock();
                total += shard.map.count();
                shard.mutex.unlock();
            }
            return total;
        }
    };
}

/// Batch processor with work stealing
pub const BatchProcessor = struct {
    const Self = @This();
    const WorkItem = struct {
        data: *anyopaque,
        process: *const fn (*anyopaque) void,
        cleanup: *const fn (std.mem.Allocator, *anyopaque) void,
    };

    allocator: std.mem.Allocator,
    thread_pool: *concurrency.ThreadPool,
    work_queue: std.ArrayListUnmanaged(WorkItem),
    queue_mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, thread_pool: *concurrency.ThreadPool) Self {
        return .{
            .allocator = allocator,
            .thread_pool = thread_pool,
            .work_queue = .{},
            .queue_mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.work_queue.deinit(self.allocator);
    }

    pub fn addWork(
        self: *Self,
        comptime T: type,
        data: T,
        comptime processor: fn (T) void,
    ) !void {
        const data_copy = try self.allocator.create(T);
        data_copy.* = data;

        const wrapper = struct {
            fn process(ptr: *anyopaque) void {
                const typed_data = @as(*T, @ptrCast(@alignCast(ptr)));
                processor(typed_data.*);
            }

            fn cleanup(allocator: std.mem.Allocator, ptr: *anyopaque) void {
                const typed_data = @as(*T, @ptrCast(@alignCast(ptr)));
                allocator.destroy(typed_data);
            }
        };

        const item = WorkItem{
            .data = @ptrCast(data_copy),
            .process = wrapper.process,
            .cleanup = wrapper.cleanup,
        };

        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        try self.work_queue.append(self.allocator, item);
    }

    pub fn processBatch(self: *Self) !void {
        const chunk_size = @max(1, self.work_queue.items.len / self.thread_pool.threads.len);
        var start: usize = 0;

        while (start < self.work_queue.items.len) {
            const end = @min(start + chunk_size, self.work_queue.items.len);
            const chunk = self.work_queue.items[start..end];

            const Args = struct {
                items: []WorkItem,
                allocator: std.mem.Allocator,
            };

            try self.thread_pool.submit(struct {
                fn process(args: Args) void {
                    for (args.items) |item| {
                        item.process(item.data);
                        item.cleanup(args.allocator, item.data);
                    }
                }
            }.process, Args{
                .items = chunk,
                .allocator = self.allocator,
            });

            start = end;
        }

        self.thread_pool.waitIdle();
        self.work_queue.clearRetainingCapacity();
    }
};

// Tests
test "ParallelScanner" {
    var pool = try concurrency.ThreadPool.init(std.testing.allocator, 2);
    defer pool.deinit();

    var scanner = ParallelScanner.init(std.testing.allocator, &pool);
    defer scanner.deinit();

    // Test with current directory
    const dirs = [_][]const u8{"src"};
    const results = try scanner.scanDirectories(&dirs, ".zig");

    try std.testing.expect(results.len > 0);
}

test "ConcurrentHashMap" {
    var map = ConcurrentHashMap([]const u8, i32, 4).init(std.testing.allocator);
    defer map.deinit();

    try map.put("one", 1);
    try map.put("two", 2);
    try map.put("three", 3);

    try std.testing.expectEqual(@as(?i32, 1), map.get("one"));
    try std.testing.expectEqual(@as(?i32, 2), map.get("two"));
    try std.testing.expectEqual(@as(usize, 3), map.count());

    try std.testing.expect(map.remove("one"));
    try std.testing.expectEqual(@as(?i32, null), map.get("one"));
    try std.testing.expectEqual(@as(usize, 2), map.count());
}

test "BatchProcessor" {
    var pool = try concurrency.ThreadPool.init(std.testing.allocator, 2);
    defer pool.deinit();

    var processor = BatchProcessor.init(std.testing.allocator, &pool);
    defer processor.deinit();

    var counter = concurrency.AtomicCounter.init();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try processor.addWork(*concurrency.AtomicCounter, &counter, struct {
            fn process(c: *concurrency.AtomicCounter) void {
                _ = c.increment();
            }
        }.process);
    }

    try processor.processBatch();
    try std.testing.expectEqual(@as(usize, 10), counter.get());
}
