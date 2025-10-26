# CPU Optimization Guide for Den Shell

This document describes the CPU optimization infrastructure and best practices for Den Shell.

## Overview

Den Shell implements multiple CPU optimization strategies to minimize computational overhead and improve responsiveness:

1. **LRU Caching** - Cache results of expensive operations
2. **Fast String Matching** - Boyer-Moore-Horspool algorithm for string search
3. **Optimized Prefix Matching** - SIMD-friendly prefix checks
4. **Fuzzy Matching** - Intelligent scoring for command completion
5. **History Indexing** - Hash-based O(1) lookups for history search
6. **Single-Pass Parsing** - Combine tokenization and parsing to reduce passes

## Performance Characteristics

Based on benchmark results:

### LRU Cache
- **With Cache (100 ops, 16 slots)**: 0.003ms
- **Without Cache (100 ops)**: 0.000ms

**Use when**: Results are expensive to compute and frequently reused (path resolution, glob expansion)

### Fast String Matching
- **FastStringMatcher (5 searches)**: 0.000ms (instant)
- **std.mem.indexOf (5 searches)**: 0.000ms (instant)

**Note**: Boyer-Moore-Horspool shines with longer patterns and texts. For short strings, standard library is sufficient.

**Use when**: Searching for patterns in long strings (file contents, large outputs)

### Optimized Prefix Matching
- **Optimized Prefix (5 checks)**: 0.000ms (instant)
- **std.mem.startsWith (5 checks)**: 0.000ms (instant)

**Note**: SIMD optimization kicks in for strings ≥16 bytes. Both are equally fast for short strings.

**Use when**: Checking prefixes for completion matching

### Fuzzy Score
- **Fuzzy Score (7 candidates)**: 0.000ms (instant)

**Use when**: Ranking completion candidates or command suggestions

### History Search
- **History Index (20 searches)**: 0.011ms
- **Linear Search (20 searches)**: 0.013ms (~15% slower)

**Use when**: Searching command history (O(1) hash lookup vs O(n) linear scan)

### Optimized Parser
- **Optimized Parser (5 commands)**: 0.000ms (instant)
- **Streaming Tokenizer (5 commands)**: 0.000ms (instant)

**Use when**: Parsing simple commands (fast path without full AST construction)

## API Reference

### LRUCache

```zig
const cpu_opt = @import("utils/cpu_opt.zig");

// Create cache with 16 slots
var cache = cpu_opt.LRUCache([]const u8, PathResolution, 16).init(allocator);

// Try to get cached result
if (cache.get(path)) |resolution| {
    return resolution; // Cache hit
}

// Compute expensive result
const result = try resolvePath(path);

// Store for future use
cache.put(path, result);
```

### FastStringMatcher

```zig
const cpu_opt = @import("utils/cpu_opt.zig");

// Create matcher for pattern
const matcher = cpu_opt.FastStringMatcher.init("TODO:");

// Search in text
if (matcher.find(file_contents)) |pos| {
    std.debug.print("Found at position {}\n", .{pos});
}

// Quick check for presence
if (matcher.matches(line)) {
    // Pattern found
}
```

### Optimized Prefix Matching

```zig
const cpu_opt = @import("utils/cpu_opt.zig");

// Fast prefix check (uses SIMD for long strings)
if (cpu_opt.hasPrefix(command, "git-")) {
    // Handle git commands
}
```

### Fuzzy Matching

```zig
const cpu_opt = @import("utils/cpu_opt.zig");

// Score candidates for completion
var best_score: u8 = 0;
var best_match: ?[]const u8 = null;

for (candidates) |candidate| {
    const score = cpu_opt.fuzzyScore(candidate, query);
    if (score > best_score) {
        best_score = score;
        best_match = candidate;
    }
}
```

**Scoring Algorithm**:
- Base score: 10 points per matched character
- Consecutive matches: +2 points per character in sequence
- Match at start of string: +15 points
- Match after word boundary (space, slash, dash, underscore): +10 points
- Final score normalized to 0-100

### History Index

```zig
const cpu_opt = @import("utils/cpu_opt.zig");

var index = cpu_opt.HistoryIndex.init(allocator);
defer index.deinit();

// Add commands to index
try index.add("git commit -m 'test'");
try index.add("ls -la");

// O(1) hash lookup for exact/substring match
if (index.search("git")) |cmd| {
    std.debug.print("Found: {s}\n", .{cmd});
}

// O(n) reverse search for prefix
if (index.prefixSearch("ls")) |cmd| {
    std.debug.print("Found: {s}\n", .{cmd});
}
```

### Optimized Parser

```zig
const optimized_parser = @import("parser/optimized_parser.zig");

// Check if input is a simple command (no pipes, redirects)
if (optimized_parser.OptimizedParser.isSimpleCommand(input)) {
    // Use fast path
    var parser = optimized_parser.OptimizedParser.init(allocator, input);
    if (try parser.parseSimpleCommand()) |cmd| {
        // Execute directly without full AST
        const name = cmd.name;
        const args = cmd.getArgs();
        try executeSimple(name, args);
    }
} else {
    // Use full parser for complex commands
    const ast = try fullParser.parse(input);
    try execute(ast);
}
```

## Optimization Patterns

### Pattern 1: Caching Expensive Path Resolution

```zig
// BAD: Always resolve paths
fn resolvePath(path: []const u8) ![]const u8 {
    // Expensive filesystem operations
    return try std.fs.realpathAlloc(allocator, path);
}

// GOOD: Cache resolved paths
const PathCache = cpu_opt.LRUCache([]const u8, []const u8, 32);

var path_cache = PathCache.init(allocator);

fn resolvePath(path: []const u8) ![]const u8 {
    if (path_cache.get(path)) |cached| {
        return cached;
    }

    const resolved = try std.fs.realpathAlloc(allocator, path);
    path_cache.put(path, resolved);
    return resolved;
}
```

### Pattern 2: Fast Pattern Matching in Large Files

```zig
// BAD: Multiple indexOf calls
fn findAllOccurrences(text: []const u8, pattern: []const u8) ![]usize {
    var positions = std.ArrayList(usize).init(allocator);
    var pos: usize = 0;

    while (std.mem.indexOf(u8, text[pos..], pattern)) |offset| {
        try positions.append(pos + offset);
        pos += offset + 1;
    }

    return positions.toOwnedSlice();
}

// GOOD: Use FastStringMatcher for repeated searches
fn findAllOccurrences(text: []const u8, pattern: []const u8) ![]usize {
    var positions = std.ArrayList(usize).init(allocator);
    const matcher = cpu_opt.FastStringMatcher.init(pattern);

    var pos: usize = 0;
    while (pos < text.len) {
        if (matcher.find(text[pos..])) |offset| {
            try positions.append(pos + offset);
            pos += offset + 1;
        } else {
            break;
        }
    }

    return positions.toOwnedSlice();
}
```

### Pattern 3: Intelligent Command Completion

```zig
// BAD: Simple prefix matching
fn findCompletions(query: []const u8, commands: [][]const u8) [][]const u8 {
    var results = std.ArrayList([]const u8).init(allocator);

    for (commands) |cmd| {
        if (std.mem.startsWith(u8, cmd, query)) {
            try results.append(cmd);
        }
    }

    return results.toOwnedSlice();
}

// GOOD: Fuzzy matching with scoring
fn findCompletions(query: []const u8, commands: [][]const u8) [][]const u8 {
    var scored = std.ArrayList(struct { cmd: []const u8, score: u8 }).init(allocator);

    for (commands) |cmd| {
        const score = cpu_opt.fuzzyScore(cmd, query);
        if (score > 0) {
            try scored.append(.{ .cmd = cmd, .score = score });
        }
    }

    // Sort by score (highest first)
    std.sort.pdq(scored.items, {}, struct {
        fn lessThan(_: void, a: anytype, b: anytype) bool {
            return a.score > b.score;
        }
    }.lessThan);

    var results = std.ArrayList([]const u8).init(allocator);
    for (scored.items) |item| {
        try results.append(item.cmd);
    }

    return results.toOwnedSlice();
}
```

### Pattern 4: Fast History Search

```zig
// BAD: Linear search through history
fn searchHistory(query: []const u8, history: [][]const u8) ?[]const u8 {
    var i: usize = history.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.indexOf(u8, history[i], query) != null) {
            return history[i];
        }
    }
    return null;
}

// GOOD: Use indexed history
var history_index = cpu_opt.HistoryIndex.init(allocator);

fn addToHistory(cmd: []const u8) !void {
    try history_index.add(cmd);
}

fn searchHistory(query: []const u8) ?[]const u8 {
    return history_index.search(query);
}
```

### Pattern 5: Fast Path for Simple Commands

```zig
// BAD: Always use full parser
fn executeCommand(input: []const u8) !void {
    const ast = try parser.parse(input);
    try executor.execute(ast);
}

// GOOD: Use fast path for simple commands
fn executeCommand(input: []const u8) !void {
    if (optimized_parser.OptimizedParser.isSimpleCommand(input)) {
        // Fast path - no AST construction
        var parser = optimized_parser.OptimizedParser.init(allocator, input);
        if (try parser.parseSimpleCommand()) |cmd| {
            try executeSimple(cmd.name, cmd.getArgs());
            return;
        }
    }

    // Complex command - use full parser
    const ast = try fullParser.parse(input);
    try executor.execute(ast);
}
```

## Integration Points

### Completion System

The fuzzy matching algorithm can be integrated into the completion system:

```zig
// src/completion.zig
const cpu_opt = @import("utils/cpu_opt.zig");

pub fn complete(prefix: []const u8, candidates: [][]const u8) ![][]const u8 {
    var scored = std.ArrayList(struct {
        candidate: []const u8,
        score: u8
    }).init(allocator);

    for (candidates) |candidate| {
        const score = cpu_opt.fuzzyScore(candidate, prefix);
        if (score > 0) {
            try scored.append(.{
                .candidate = candidate,
                .score = score
            });
        }
    }

    // Sort by score
    std.sort.pdq(scored.items, {}, scoreComparator);

    // Return top matches
    var results = std.ArrayList([]const u8).init(allocator);
    const limit = @min(10, scored.items.len);
    for (scored.items[0..limit]) |item| {
        try results.append(item.candidate);
    }

    return results.toOwnedSlice();
}
```

### History System

The history index can replace linear history search:

```zig
// src/history.zig
const cpu_opt = @import("utils/cpu_opt.zig");

pub const History = struct {
    index: cpu_opt.HistoryIndex,

    pub fn init(allocator: std.mem.Allocator) History {
        return .{
            .index = cpu_opt.HistoryIndex.init(allocator),
        };
    }

    pub fn add(self: *History, command: []const u8) !void {
        try self.index.add(command);
    }

    pub fn search(self: *const History, query: []const u8) ?[]const u8 {
        return self.index.search(query);
    }

    pub fn searchPrefix(self: *const History, prefix: []const u8) ?[]const u8 {
        return self.index.prefixSearch(prefix);
    }

    pub fn deinit(self: *History) void {
        self.index.deinit();
    }
};
```

### Parser Fast Path

The optimized parser can be used as a fast path for simple commands:

```zig
// src/executor.zig
const optimized_parser = @import("parser/optimized_parser.zig");

pub fn execute(input: []const u8) !void {
    // Try fast path first
    if (optimized_parser.OptimizedParser.isSimpleCommand(input)) {
        var parser = optimized_parser.OptimizedParser.init(allocator, input);
        if (try parser.parseSimpleCommand()) |cmd| {
            return try executeSimple(cmd);
        }
    }

    // Fall back to full parser
    const ast = try fullParser.parse(input);
    return try executeAst(ast);
}

fn executeSimple(cmd: optimized_parser.SimpleCommand) !void {
    const argv = try allocator.alloc([]const u8, cmd.arg_count + 1);
    defer allocator.free(argv);

    argv[0] = cmd.name;
    @memcpy(argv[1..], cmd.getArgs());

    var child = std.process.Child.init(argv, allocator);
    _ = try child.spawnAndWait();
}
```

## Best Practices

1. **Profile first**: Use benchmarks to identify actual bottlenecks
2. **Cache judiciously**: Only cache expensive operations with good hit rates
3. **Use fast paths**: Check for simple cases before complex processing
4. **SIMD awareness**: Optimization benefits increase with string length
5. **Index strategically**: Hash indexes help when data is searched frequently
6. **Measure impact**: Benchmark before and after optimizations

## Benchmarking

Run CPU optimization benchmarks:

```bash
zig build bench
./.zig-cache/o/.../cpu_bench
```

This will benchmark:
- LRU cache vs no cache
- FastStringMatcher vs std.mem.indexOf
- Optimized prefix vs std.mem.startsWith
- Fuzzy matching scoring
- History index vs linear search
- Optimized parser vs streaming tokenizer

## Future Improvements

- [ ] Apply optimized parser as default fast path
- [ ] Integrate fuzzy matching into completion system
- [ ] Replace history linear search with index
- [ ] Add caching for expensive path resolutions
- [ ] Profile real-world workloads to find bottlenecks
- [ ] Implement SIMD-optimized string operations
- [ ] Add CPU profiling visualization

## References

- Benchmark results: `bench/cpu_bench.zig`
- Implementation: `src/utils/cpu_opt.zig`
- Optimized parser: `src/parser/optimized_parser.zig`
- Boyer-Moore-Horspool: https://en.wikipedia.org/wiki/Boyer%E2%80%93Moore%E2%80%93Horspool_algorithm
