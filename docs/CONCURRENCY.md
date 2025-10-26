# Concurrency Optimization Guide for Den Shell

This document describes the concurrency infrastructure and best practices for parallel execution in Den Shell.

## Overview

Den Shell implements a comprehensive concurrency framework to maximize performance through parallelization:

1. **Thread Pool** - Efficient task execution across multiple worker threads
2. **Parallel Discovery** - Concurrent module and plugin detection
3. **Lock-Free Structures** - SPSC queues and atomic counters
4. **Sharded Hash Maps** - Reduced lock contention through sharding
5. **RW Locks** - Reader-writer locks for read-heavy workloads
6. **Batch Processing** - Efficient processing of large datasets

## Performance Goals

Based on design targets:

### Thread Pool Benefits
- **CPU Utilization**: Uses all available CPU cores
- **Task Overhead**: Minimal overhead for task submission (~nanoseconds)
- **Work Stealing**: Automatic load balancing across threads

### Parallel Discovery
- **Module Detection**: 2-4x faster with 4 threads on multi-directory scans
- **Scalability**: Linear speedup with number of CPUs

### Lock-Free Structures
- **SPSC Queue**: Zero-lock single producer/consumer communication
- **Atomic Counter**: Lock-free increment/decrement operations
- **Reduced Contention**: No mutex overhead for simple operations

## API Reference

### ThreadPool

```zig
const concurrency = @import("utils/concurrency.zig");

// Create pool with automatic CPU count detection
var pool = try concurrency.ThreadPool.init(allocator, 0);
defer pool.deinit();

// Submit tasks to pool
const Args = struct { value: i32 };
try pool.submit(struct {
    fn process(args: Args) void {
        std.debug.print("Processing: {}\n", .{args.value});
    }
}.process, Args{ .value = 42 });

// Wait for all tasks to complete
pool.waitIdle();
```

**Key Features**:
- Automatic CPU count detection (pass 0 for thread_count)
- Work queue with condition variable for efficient waiting
- Automatic memory management for task arguments
- Thread-safe task submission

### ParallelScanner (Module/Plugin Discovery)

```zig
const parallel_discovery = @import("utils/parallel_discovery.zig");

var pool = try concurrency.ThreadPool.init(allocator, 4);
defer pool.deinit();

var scanner = parallel_discovery.ParallelScanner.init(allocator, &pool);
defer scanner.deinit();

// Scan multiple directories in parallel
const dirs = [_][]const u8{
    "/usr/local/lib/den/plugins",
    "~/.local/share/den/plugins",
    "./plugins",
};

const plugins = try scanner.scanDirectories(&dirs, ".so");
std.debug.print("Found {} plugins\n", .{plugins.len});
```

**Optimizations**:
- Single directory: Direct scan (no thread pool overhead)
- Multiple directories: Parallel scan across threads
- Thread-safe result collection with mutex protection

### AtomicCounter

```zig
const concurrency = @import("utils/concurrency.zig");

var counter = concurrency.AtomicCounter.init();

// Lock-free operations
_ = counter.increment(); // Returns new value
_ = counter.decrement(); // Returns new value

const current = counter.get(); // Read current value
counter.set(100); // Set to specific value
```

**Use Cases**:
- Metrics collection across threads
- Reference counting
- Progress tracking
- Any counter that doesn't need mutex protection

### SPSCQueue (Lock-Free Queue)

```zig
const concurrency = @import("utils/concurrency.zig");

// Create queue with 1024 element capacity
var queue = concurrency.SPSCQueue(i32, 1024).init();

// Producer thread
if (queue.push(42)) {
    // Successfully pushed
} else {
    // Queue is full
}

// Consumer thread
if (queue.pop()) |value| {
    std.debug.print("Got: {}\n", .{value});
} else {
    // Queue is empty
}
```

**Characteristics**:
- **Zero locks**: Uses atomic operations only
- **Single producer, single consumer**: Design constraint for lock-freedom
- **Fixed capacity**: Ring buffer implementation
- **Fast**: Ideal for thread communication

### ConcurrentHashMap (Sharded for Low Contention)

```zig
const parallel_discovery = @import("utils/parallel_discovery.zig");

// 16 shards = 16x less contention than single mutex
var map = parallel_discovery.ConcurrentHashMap([]const u8, PluginInfo, 16).init(allocator);
defer map.deinit();

// Thread-safe operations
try map.put("git-plugin", plugin_info);

if (map.get("git-plugin")) |info| {
    std.debug.print("Found: {}\n", .{info.name});
}

_ = map.remove("git-plugin");
const total = map.count(); // Sum across all shards
```

**Design**:
- **Sharding**: Hash-based distribution across N maps
- **Per-shard locks**: Only contend within same shard
- **Scalability**: Scales with number of shards
- **Trade-off**: Memory overhead for reduced contention

### RWLock (Reader-Writer Lock)

```zig
const concurrency = @import("utils/concurrency.zig");

var lock = concurrency.RWLock.init();

// Multiple readers can acquire simultaneously
lock.lockRead();
const data = shared_data; // Read operation
lock.unlockRead();

// Writers have exclusive access
lock.lockWrite();
shared_data = new_value; // Write operation
lock.unlockWrite();
```

**Best For**:
- Read-heavy workloads
- Configuration data
- Cache lookups
- Any scenario where reads vastly outnumber writes

### ParallelFileProcessor

```zig
const parallel_discovery = @import("utils/parallel_discovery.zig");

var pool = try concurrency.ThreadPool.init(allocator, 4);
defer pool.deinit();

var processor = parallel_discovery.ParallelFileProcessor.init(allocator, &pool);

// Process files in parallel
const files = [_][]const u8{ "a.txt", "b.txt", "c.txt" };
try processor.processFiles(&files, struct {
    fn process(file_path: []const u8) !void {
        const content = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
        defer allocator.free(content);
        // Process content...
    }
}.process);
```

**Optimizations**:
- Small file counts (< 4): Sequential processing
- Large file counts: Automatic chunking across threads
- Error resilience: Continues on individual file errors

## Optimization Patterns

### Pattern 1: Parallel Module Loading

```zig
// BAD: Sequential module loading
fn loadModules(allocator: Allocator, paths: [][]const u8) ![]Module {
    var modules = std.ArrayList(Module).init(allocator);

    for (paths) |path| {
        const module = try loadModule(path); // Slow I/O
        try modules.append(module);
    }

    return modules.toOwnedSlice();
}

// GOOD: Parallel module loading
fn loadModules(allocator: Allocator, pool: *ThreadPool, paths: [][]const u8) ![]Module {
    var results = std.ArrayList(Module).init(allocator);
    var mutex = std.Thread.Mutex{};

    var processor = ParallelFileProcessor.init(allocator, pool);

    try processor.processFiles(paths, struct {
        fn load(path: []const u8) !void {
            const module = try loadModule(path);

            mutex.lock();
            defer mutex.unlock();
            try results.append(module);
        }
    }.load);

    return results.toOwnedSlice();
}
```

### Pattern 2: Concurrent Plugin Discovery

```zig
// BAD: Linear directory scanning
fn discoverPlugins(allocator: Allocator) ![]PluginPath {
    var plugins = std.ArrayList(PluginPath).init(allocator);

    const search_dirs = [_][]const u8{ "/usr/lib", "/usr/local/lib", "~/.local/lib" };

    for (search_dirs) |dir| {
        var walker = try std.fs.cwd().walk(dir);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (std.mem.endsWith(u8, entry.basename, ".so")) {
                try plugins.append(entry.path);
            }
        }
    }

    return plugins.toOwnedSlice();
}

// GOOD: Parallel directory scanning
fn discoverPlugins(allocator: Allocator, pool: *ThreadPool) ![][]const u8 {
    var scanner = ParallelScanner.init(allocator, pool);
    defer scanner.deinit();

    const search_dirs = [_][]const u8{ "/usr/lib", "/usr/local/lib", "~/.local/lib" };

    return try scanner.scanDirectories(&search_dirs, ".so");
}
```

### Pattern 3: Lock-Free Progress Tracking

```zig
// BAD: Mutex for every increment
var progress_mutex = std.Thread.Mutex{};
var progress: usize = 0;

fn processItem(item: Item) void {
    // ... process ...

    progress_mutex.lock();
    progress += 1;
    progress_mutex.unlock();
}

// GOOD: Lock-free atomic counter
var progress = AtomicCounter.init();

fn processItem(item: Item) void {
    // ... process ...

    _ = progress.increment(); // No lock needed
}
```

### Pattern 4: Sharded Cache for Reduced Contention

```zig
// BAD: Single mutex for all cache operations
var cache_mutex = std.Thread.Mutex{};
var cache = std.StringHashMap(CachedData).init(allocator);

fn getFromCache(key: []const u8) ?CachedData {
    cache_mutex.lock();
    defer cache_mutex.unlock();
    return cache.get(key); // All threads contend here
}

// GOOD: Sharded cache with per-shard locks
var cache = ConcurrentHashMap([]const u8, CachedData, 16).init(allocator);

fn getFromCache(key: []const u8) ?CachedData {
    return cache.get(key); // Only contends within shard
}
```

### Pattern 5: Batch Processing with Thread Pool

```zig
// Process large dataset in parallel
var pool = try ThreadPool.init(allocator, 0); // Auto-detect CPUs
defer pool.deinit();

const data = [_]i32{1, 2, 3, ..., 10000};

try concurrency.parallelForEach(i32, &pool, &data, struct {
    fn process(item: i32) void {
        const result = expensiveComputation(item);
        storeResult(result);
    }
}.process);

pool.waitIdle(); // Wait for all work to complete
```

## Best Practices

1. **Choose the Right Tool**:
   - Thread Pool: CPU-bound tasks, I/O operations
   - Atomic Counters: Simple metrics, no complex state
   - SPSC Queue: Producer-consumer patterns
   - Sharded Maps: High-contention scenarios
   - RW Locks: Read-heavy workloads

2. **Minimize Lock Contention**:
   - Use sharding to distribute load
   - Prefer lock-free structures when possible
   - Keep critical sections small
   - Avoid nested locks

3. **Task Granularity**:
   - Too small: Thread pool overhead dominates
   - Too large: Poor load balancing
   - Sweet spot: 10-100ms per task

4. **Memory Management**:
   - Thread pool handles task argument cleanup
   - Use arena allocators for batch operations
   - Be mindful of false sharing (cache line bouncing)

5. **Error Handling**:
   - Parallel operations should be resilient
   - Log errors, don't crash entire process
   - Provide partial results when possible

## Benchmarking

Run concurrency benchmarks:

```bash
zig build bench
./.zig-cache/o/.../concurrency_bench
```

Expected results:
- Thread pool overhead: ~microseconds per task
- Parallel discovery: 2-4x speedup on multi-directory scans
- Atomic counter: 10-100x faster than mutex
- SPSC queue: Near-zero overhead for communication
- Sharded maps: Linear scalability with shard count

## Integration Examples

### Shell Startup with Parallel Plugin Loading

```zig
pub fn initializeShell(allocator: Allocator) !Shell {
    var pool = try ThreadPool.init(allocator, 0);
    defer pool.deinit();

    // Discover plugins in parallel
    var scanner = ParallelScanner.init(allocator, &pool);
    defer scanner.deinit();

    const plugin_paths = try scanner.scanDirectories(&plugin_dirs, ".so");

    // Load plugins in parallel
    var processor = ParallelFileProcessor.init(allocator, &pool);
    try processor.processFiles(plugin_paths, loadPlugin);

    return Shell{
        .plugins = loaded_plugins,
        // ...
    };
}
```

### Concurrent Command Completion

```zig
pub fn getCompletions(
    prefix: []const u8,
    pool: *ThreadPool,
    sources: []CompletionSource,
) ![]Completion {
    var results = std.ArrayList(Completion).init(allocator);
    var mutex = std.Thread.Mutex{};

    // Query all sources in parallel
    for (sources) |source| {
        const Args = struct {
            source: CompletionSource,
            prefix: []const u8,
            results: *std.ArrayList(Completion),
            mutex: *std.Thread.Mutex,
        };

        try pool.submit(struct {
            fn query(args: Args) void {
                const completions = args.source.getCompletions(args.prefix) catch return;

                args.mutex.lock();
                defer args.mutex.unlock();
                args.results.appendSlice(completions) catch {};
            }
        }.query, Args{
            .source = source,
            .prefix = prefix,
            .results = &results,
            .mutex = &mutex,
        });
    }

    pool.waitIdle();
    return results.toOwnedSlice();
}
```

## Future Improvements

- [ ] Work-stealing thread pool for better load balancing
- [ ] Per-thread arena allocators to reduce contention
- [ ] Lock-free hash map implementation
- [ ] Thread-local caches for hot paths
- [ ] Async I/O integration with thread pool
- [ ] Profiling tools for concurrency bottlenecks

## References

- Implementation: `src/utils/concurrency.zig`
- Parallel discovery: `src/utils/parallel_discovery.zig`
- Benchmarks: `bench/concurrency_bench.zig`
- Zig threading: https://ziglang.org/documentation/master/std/#std.Thread
