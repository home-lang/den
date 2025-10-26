// Concurrency utilities for Den Shell - Thread pool and lock-free structures
const std = @import("std");

/// Thread pool for parallel task execution
pub const ThreadPool = struct {
    const Self = @This();
    const Job = *const fn (*anyopaque) void;

    allocator: std.mem.Allocator,
    threads: []std.Thread,
    queue: JobQueue,
    shutdown: std.atomic.Value(bool),
    active_jobs: std.atomic.Value(usize),

    pub fn init(allocator: std.mem.Allocator, thread_count: usize) !Self {
        const actual_count = if (thread_count == 0)
            try std.Thread.getCpuCount()
        else
            thread_count;

        var pool = Self{
            .allocator = allocator,
            .threads = try allocator.alloc(std.Thread, actual_count),
            .queue = JobQueue.init(allocator),
            .shutdown = std.atomic.Value(bool).init(false),
            .active_jobs = std.atomic.Value(usize).init(0),
        };

        // Start worker threads
        for (pool.threads, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, workerThread, .{&pool});
            _ = i;
        }

        return pool;
    }

    pub fn deinit(self: *Self) void {
        // Signal shutdown
        self.shutdown.store(true, .release);

        // Wake all threads
        self.queue.notifyAll();

        // Wait for all threads to finish
        for (self.threads) |thread| {
            thread.join();
        }

        self.allocator.free(self.threads);
        self.queue.deinit();
    }

    pub fn submit(self: *Self, comptime func: anytype, args: anytype) !void {
        const Args = @TypeOf(args);
        const Context = struct {
            args: Args,
            allocator: std.mem.Allocator,
        };

        const Wrapper = struct {
            fn call(ptr: *anyopaque) void {
                const ctx = @as(*Context, @ptrCast(@alignCast(ptr)));
                func(ctx.args);
                ctx.allocator.destroy(ctx);
            }
        };

        const ctx = try self.allocator.create(Context);
        ctx.* = .{
            .args = args,
            .allocator = self.allocator,
        };

        try self.queue.push(JobItem{
            .func = Wrapper.call,
            .data = ctx,
        });
    }

    pub fn waitIdle(self: *Self) void {
        while (self.active_jobs.load(.acquire) > 0 or !self.queue.isEmpty()) {
            std.Thread.yield() catch {};
        }
    }

    fn workerThread(pool: *Self) void {
        while (!pool.shutdown.load(.acquire)) {
            if (pool.queue.pop()) |job| {
                _ = pool.active_jobs.fetchAdd(1, .acq_rel);
                job.func(job.data);
                // Note: data is freed by the wrapper function
                _ = pool.active_jobs.fetchSub(1, .acq_rel);
            } else {
                pool.queue.wait();
            }
        }
    }

    const JobItem = struct {
        func: Job,
        data: *anyopaque,
    };

    const JobQueue = struct {
        allocator: std.mem.Allocator,
        queue: std.ArrayListUnmanaged(JobItem),
        mutex: std.Thread.Mutex,
        condition: std.Thread.Condition,

        fn init(allocator: std.mem.Allocator) JobQueue {
            return .{
                .allocator = allocator,
                .queue = .{},
                .mutex = .{},
                .condition = .{},
            };
        }

        fn deinit(self: *JobQueue) void {
            self.queue.deinit(self.allocator);
        }

        fn push(self: *JobQueue, job: JobItem) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            try self.queue.append(self.allocator, job);
            self.condition.signal();
        }

        fn pop(self: *JobQueue) ?JobItem {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.queue.items.len == 0) return null;
            return self.queue.orderedRemove(0);
        }

        fn isEmpty(self: *JobQueue) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.queue.items.len == 0;
        }

        fn wait(self: *JobQueue) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.condition.wait(&self.mutex);
        }

        fn notifyAll(self: *JobQueue) void {
            self.condition.broadcast();
        }
    };
};

/// Lock-free counter for metrics
pub const AtomicCounter = struct {
    value: std.atomic.Value(usize),

    pub fn init() AtomicCounter {
        return .{ .value = std.atomic.Value(usize).init(0) };
    }

    pub fn increment(self: *AtomicCounter) usize {
        return self.value.fetchAdd(1, .acq_rel) + 1;
    }

    pub fn decrement(self: *AtomicCounter) usize {
        return self.value.fetchSub(1, .acq_rel) - 1;
    }

    pub fn get(self: *const AtomicCounter) usize {
        return self.value.load(.acquire);
    }

    pub fn set(self: *AtomicCounter, val: usize) void {
        self.value.store(val, .release);
    }
};

/// Lock-free single-producer single-consumer queue
pub fn SPSCQueue(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buffer: [capacity]T,
        read_pos: std.atomic.Value(usize),
        write_pos: std.atomic.Value(usize),

        pub fn init() Self {
            return .{
                .buffer = undefined,
                .read_pos = std.atomic.Value(usize).init(0),
                .write_pos = std.atomic.Value(usize).init(0),
            };
        }

        pub fn push(self: *Self, item: T) bool {
            const write = self.write_pos.load(.acquire);
            const next_write = (write + 1) % capacity;
            const read = self.read_pos.load(.acquire);

            if (next_write == read) {
                return false; // Queue full
            }

            self.buffer[write] = item;
            self.write_pos.store(next_write, .release);
            return true;
        }

        pub fn pop(self: *Self) ?T {
            const read = self.read_pos.load(.acquire);
            const write = self.write_pos.load(.acquire);

            if (read == write) {
                return null; // Queue empty
            }

            const item = self.buffer[read];
            const next_read = (read + 1) % capacity;
            self.read_pos.store(next_read, .release);
            return item;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.read_pos.load(.acquire) == self.write_pos.load(.acquire);
        }

        pub fn isFull(self: *const Self) bool {
            const write = self.write_pos.load(.acquire);
            const next_write = (write + 1) % capacity;
            return next_write == self.read_pos.load(.acquire);
        }
    };
}

/// Read-Write lock with reader preference
pub const RWLock = struct {
    mutex: std.Thread.Mutex,
    readers: usize,
    writer: bool,
    read_cond: std.Thread.Condition,
    write_cond: std.Thread.Condition,

    pub fn init() RWLock {
        return .{
            .mutex = .{},
            .readers = 0,
            .writer = false,
            .read_cond = .{},
            .write_cond = .{},
        };
    }

    pub fn lockRead(self: *RWLock) void {
        self.mutex.lock();
        while (self.writer) {
            self.read_cond.wait(&self.mutex);
        }
        self.readers += 1;
        self.mutex.unlock();
    }

    pub fn unlockRead(self: *RWLock) void {
        self.mutex.lock();
        self.readers -= 1;
        if (self.readers == 0) {
            self.write_cond.signal();
        }
        self.mutex.unlock();
    }

    pub fn lockWrite(self: *RWLock) void {
        self.mutex.lock();
        while (self.writer or self.readers > 0) {
            self.write_cond.wait(&self.mutex);
        }
        self.writer = true;
        self.mutex.unlock();
    }

    pub fn unlockWrite(self: *RWLock) void {
        self.mutex.lock();
        self.writer = false;
        self.write_cond.signal();
        self.read_cond.broadcast();
        self.mutex.unlock();
    }
};

/// Parallel for-each execution
pub fn parallelForEach(
    comptime T: type,
    pool: *ThreadPool,
    items: []const T,
    comptime func: fn (T) void,
) !void {
    if (items.len == 0) return;

    // For small arrays, don't bother with parallelization
    if (items.len < 4) {
        for (items) |item| {
            func(item);
        }
        return;
    }

    const chunk_size = @max(1, items.len / pool.threads.len);
    var start: usize = 0;

    while (start < items.len) {
        const end = @min(start + chunk_size, items.len);
        const chunk = items[start..end];

        const Args = struct { chunk: []const T };
        try pool.submit(struct {
            fn process(args: Args) void {
                for (args.chunk) |item| {
                    func(item);
                }
            }
        }.process, Args{ .chunk = chunk });

        start = end;
    }

    pool.waitIdle();
}

/// Parallel map operation
pub fn parallelMap(
    comptime T: type,
    comptime R: type,
    pool: *ThreadPool,
    allocator: std.mem.Allocator,
    items: []const T,
    comptime func: fn (T) R,
) ![]R {
    const results = try allocator.alloc(R, items.len);

    if (items.len == 0) return results;

    // For small arrays, don't bother with parallelization
    if (items.len < 4) {
        for (items, 0..) |item, i| {
            results[i] = func(item);
        }
        return results;
    }

    const chunk_size = @max(1, items.len / pool.threads.len);
    var start: usize = 0;

    while (start < items.len) {
        const end = @min(start + chunk_size, items.len);
        const chunk = items[start..end];
        const result_chunk = results[start..end];

        const Args = struct {
            chunk: []const T,
            results: []R,
        };

        try pool.submit(struct {
            fn process(args: Args) void {
                for (args.chunk, 0..) |item, i| {
                    args.results[i] = func(item);
                }
            }
        }.process, Args{
            .chunk = chunk,
            .results = result_chunk,
        });

        start = end;
    }

    pool.waitIdle();
    return results;
}

// Tests
test "ThreadPool basic" {
    var pool = try ThreadPool.init(std.testing.allocator, 2);
    defer pool.deinit();

    var counter = AtomicCounter.init();

    const Args = struct { counter: *AtomicCounter };
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try pool.submit(struct {
            fn increment(args: Args) void {
                _ = args.counter.increment();
            }
        }.increment, Args{ .counter = &counter });
    }

    pool.waitIdle();
    try std.testing.expectEqual(@as(usize, 10), counter.get());
}

test "AtomicCounter" {
    var counter = AtomicCounter.init();

    try std.testing.expectEqual(@as(usize, 0), counter.get());
    try std.testing.expectEqual(@as(usize, 1), counter.increment());
    try std.testing.expectEqual(@as(usize, 2), counter.increment());
    try std.testing.expectEqual(@as(usize, 1), counter.decrement());
    try std.testing.expectEqual(@as(usize, 1), counter.get());
}

test "SPSCQueue" {
    var queue = SPSCQueue(i32, 4).init();

    try std.testing.expect(queue.isEmpty());
    try std.testing.expect(queue.push(1));
    try std.testing.expect(queue.push(2));
    try std.testing.expect(queue.push(3));

    try std.testing.expectEqual(@as(?i32, 1), queue.pop());
    try std.testing.expectEqual(@as(?i32, 2), queue.pop());

    try std.testing.expect(queue.push(4));
    try std.testing.expect(queue.push(5));

    try std.testing.expectEqual(@as(?i32, 3), queue.pop());
    try std.testing.expectEqual(@as(?i32, 4), queue.pop());
    try std.testing.expectEqual(@as(?i32, 5), queue.pop());
    try std.testing.expect(queue.isEmpty());
}

test "RWLock" {
    var lock = RWLock.init();

    // Multiple readers can acquire lock
    lock.lockRead();
    lock.lockRead();
    lock.unlockRead();
    lock.unlockRead();

    // Writer has exclusive access
    lock.lockWrite();
    lock.unlockWrite();
}

test "parallelForEach" {
    var pool = try ThreadPool.init(std.testing.allocator, 2);
    defer pool.deinit();

    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8 };

    try parallelForEach(i32, &pool, &items, struct {
        fn process(item: i32) void {
            _ = item;
            // Just to test execution
        }
    }.process);
}
