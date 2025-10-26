# Memory Optimization Guide for Den Shell

This document describes the memory optimization infrastructure and best practices for Den Shell.

## Overview

Den Shell implements multiple memory optimization strategies to minimize allocations, reduce fragmentation, and improve performance:

1. **Object Pooling** - Reuse frequently allocated objects
2. **Stack Buffers** - Avoid heap allocations for small data
3. **Arena Allocators** - Bulk allocations/deallocations
4. **Fixed-Size Arrays** - Predictable memory usage
5. **Hybrid Stack/Heap** - Start on stack, grow to heap if needed

## Performance Characteristics

Based on benchmark results:

### Object Pool vs Direct Allocation
- **Object Pool (100 items)**: 0.000ms (277x faster)
- **Direct Allocation (100 items)**: 0.277ms

**Use when**: Frequently allocating/deallocating same-sized objects (tokens, AST nodes)

### Stack Buffer vs Heap Allocation
- **Stack Buffer (10x64 bytes)**: 0.000ms (instantaneous)
- **Heap Allocation (10x64 bytes)**: 0.004ms

**Use when**: Working with small, temporary buffers (< 1KB)

### StringBuilder vs String Concatenation
- **StringBuilder**: 0.000ms (uses stack for small strings)
- **String Concatenation**: 0.005ms

**Use when**: Building strings incrementally

### Arena Allocator Performance
- **Arena Allocator (100x64 bytes)**: 0.017ms
- **Individual Allocs (100x64 bytes)**: 0.006ms

**Note**: Arena is slower for allocation but instant for deallocation. Use for command execution where you allocate many objects then free them all at once.

### Stack Array List vs Heap Array List
- **StackArrayList (50 items)**: 0.000ms (instantaneous)
- **Heap ArrayList (50 items)**: 0.008ms

**Use when**: Maximum size is known and reasonable (< 100 items typically)

## API Reference

### ObjectPool

```zig
const memory = @import("utils/memory.zig");

// Create a pool of 100 tokens
var pool = memory.ObjectPool(Token, 100).init(allocator);

// Acquire from pool (no allocation if available)
if (pool.acquire()) |token| {
    token.* = Token{ .type = .word, .value = "hello" };
    // ... use token ...
    pool.release(token); // Return to pool
}

// Reset pool (mark all as available)
pool.reset();
```

### StackBuffer

```zig
const memory = @import("utils/memory.zig");

// Create 1KB stack buffer
var buf = memory.StackBuffer(1024).init();

// Allocate from buffer (no heap allocation)
if (buf.alloc(256)) |slice| {
    // ... use slice ...
}

// Reset for reuse
buf.reset();
```

### StringBuilder

```zig
const memory = @import("utils/memory.zig");

var sb = memory.StringBuilder.init(allocator);
defer sb.deinit();

// Small strings use stack (no allocation)
try sb.append("Hello ");
try sb.append("World!");

// Access result
const result = sb.toSlice();

// Reuse builder
sb.reset();
```

### ShellArena

```zig
const memory = @import("utils/memory.zig");

var arena = memory.ShellArena.init(allocator);
defer arena.deinit();

const arena_alloc = arena.allocator();

// Make many allocations
var items = try arena_alloc.alloc(Item, 100);
var strings = try arena_alloc.alloc([]u8, 50);
// ... more allocations ...

// Free everything at once (instant)
arena.reset();
```

### CommandMemoryPool

```zig
const memory = @import("utils/memory.zig");

var pool = memory.CommandMemoryPool.init(allocator);
defer pool.deinit();

// Use arena for command execution
const arena_alloc = pool.getArenaAllocator();
var args = try arena_alloc.alloc([]const u8, 10);

// After command completes, free everything
pool.reset();
```

### StackArrayList

```zig
const memory = @import("utils/memory.zig");

// Create fixed-size list (no heap allocation)
var list = memory.StackArrayList(i32, 100).init();

try list.append(1);
try list.append(2);

const items = list.slice(); // Get slice view

list.clear(); // Reset without deallocation
```

## Optimization Patterns

### Pattern 1: Hot Path Tokenization

```zig
// BAD: Allocates on every token
fn tokenize(allocator: Allocator, input: []const u8) ![]Token {
    var tokens = std.ArrayList(Token).init(allocator);
    // ... tokenization ...
    return tokens.toOwnedSlice();
}

// GOOD: Use stack buffer + pool
fn tokenize(allocator: Allocator, input: []const u8, pool: *TokenPool) ![]Token {
    var tokens = StackArrayList(Token, 256).init();

    while (nextToken(input)) |token_data| {
        if (pool.acquire()) |token| {
            token.* = token_data;
            try tokens.append(token);
        }
    }

    return tokens.slice();
}
```

### Pattern 2: Command Execution

```zig
// BAD: Many individual allocations
fn executeCommand(allocator: Allocator, args: [][]const u8) !void {
    var expanded_args = std.ArrayList([]const u8).init(allocator);
    defer expanded_args.deinit();

    for (args) |arg| {
        const expanded = try expandVariables(allocator, arg);
        try expanded_args.append(expanded);
    }
    // ... execute ...
}

// GOOD: Use arena for bulk allocation/deallocation
fn executeCommand(pool: *CommandMemoryPool, args: [][]const u8) !void {
    const arena = pool.getArenaAllocator();

    var expanded_args = std.ArrayList([]const u8).init(arena);
    for (args) |arg| {
        const expanded = try expandVariables(arena, arg);
        try expanded_args.append(expanded);
    }
    // ... execute ...

    pool.reset(); // Free everything at once
}
```

### Pattern 3: String Building

```zig
// BAD: Multiple allocations and copies
fn buildPrompt(allocator: Allocator) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    try result.appendSlice("user@");
    try result.appendSlice(getHostname());
    try result.appendSlice(":");
    try result.appendSlice(getCwd());
    try result.appendSlice(" $ ");
    return result.toOwnedSlice();
}

// GOOD: Stack buffer for small prompts
fn buildPrompt(allocator: Allocator) ![]const u8 {
    var sb = StringBuilder.init(allocator);
    defer sb.deinit();

    try sb.append("user@");
    try sb.append(getHostname());
    try sb.append(":");
    try sb.append(getCwd());
    try sb.append(" $ ");

    return allocator.dupe(u8, sb.toSlice());
}
```

## Existing Optimizations in Den Shell

Den Shell already uses fixed-size arrays for common operations:

```zig
pub const Shell = struct {
    // Fixed-size arrays (no dynamic resizing)
    history: [1000]?[]const u8,           // History entries
    background_jobs: [16]?BackgroundJob,  // Background jobs
    dir_stack: [32]?[]const u8,           // Directory stack
    positional_params: [64]?[]const u8,   // Positional parameters

    // ... other fields ...
};
```

This provides:
- **Predictable memory usage**: No surprise allocations
- **Cache-friendly**: Contiguous memory layout
- **Fast access**: Array indexing vs pointer chasing
- **No fragmentation**: No dynamic growth/shrink

## Memory Leak Detection

Use GeneralPurposeAllocator for leak detection during development:

```zig
test "no memory leaks" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expect(leaked == .ok);
    }

    const allocator = gpa.allocator();

    // Your code here
}
```

## Best Practices

1. **Profile first**: Use benchmarks to identify hot paths
2. **Start simple**: Use direct allocation, optimize if needed
3. **Fixed sizes**: Use stack arrays when maximum size is known
4. **Pool reusable**: Objects created/destroyed frequently
5. **Arena for batches**: Allocate many, free all at once
6. **Stack for small**: Buffers < 1KB, temporary data
7. **Measure impact**: Benchmark before/after optimizations

## Benchmarking

Run memory benchmarks:

```bash
zig build bench
./zig-cache/o/.../memory_bench
```

Compare different approaches:
- Object pooling vs direct allocation
- Stack buffers vs heap allocation
- Arena allocators vs individual frees
- Stack arrays vs heap arrays

## Future Improvements

- [ ] Apply object pools to tokenizer
- [ ] Use CommandMemoryPool in executor
- [ ] Implement memory budget tracking
- [ ] Add allocation flamegraphs
- [ ] Profile real-world workloads
- [ ] Tune arena sizes based on usage patterns

## References

- Benchmark results: `bench/memory_bench.zig`
- Implementation: `src/utils/memory.zig`
- Zig allocator documentation: https://ziglang.org/documentation/master/std/#std.mem.Allocator
