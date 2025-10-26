# Den Shell Performance Profiling

This document describes the profiling infrastructure and benchmarking tools available in Den Shell.

## Overview

Den Shell includes a comprehensive profiling and benchmarking system to measure and optimize performance across all shell operations.

## Profiling Infrastructure

### Profiler

The `Profiler` class provides real-time performance monitoring with minimal overhead:

```zig
const Profiler = @import("profiling/profiler.zig").Profiler;

// Create profiler
var profiler = try Profiler.init(allocator);
defer profiler.deinit();

// Enable profiling
profiler.enable("trace.json");

// Profile an operation
var zone = profiler.beginZone("parse_command");
// ... do work ...
try profiler.endZone(&zone, .parsing);

// Generate report
try profiler.generateReport(stdout);

// Export Chrome trace
try profiler.exportChromeTrace("trace.json");
```

### Profile Categories

Events are categorized for analysis:

- `startup` - Shell initialization
- `command_execution` - Command execution pipeline
- `parsing` - Command parsing and tokenization
- `expansion` - Variable and glob expansion
- `completion` - Tab completion generation
- `history` - History operations
- `prompt` - Prompt rendering
- `io` - I/O operations
- `other` - Miscellaneous operations

### Scoped Profiling

Use scoped zones for automatic cleanup:

```zig
{
    var zone = profile(profiler, "operation", .other);
    defer zone.deinit();

    // ... do work ...
}
```

## Benchmarking

### Running Benchmarks

Use the `den-profile` CLI tool:

```bash
# List available benchmarks
den-profile list

# Run specific benchmark
den-profile run startup
den-profile run command
den-profile run completion
den-profile run history
den-profile run prompt

# Run all benchmarks
den-profile all
```

### Benchmark Output

Each benchmark provides detailed statistics:

```
Startup Time Benchmark Results

Minimal Startup:
  Iterations: 1000
  Mean:       0.152ms
  Median:     0.148ms
  Min:        0.102ms
  Max:        1.234ms
  Std Dev:    0.089ms
```

## Available Benchmarks

### 1. Startup Benchmarks

Tests shell initialization performance:

- Minimal startup (no config, no plugins)
- Config file loading
- History loading (1000 entries)
- Plugin discovery
- Prompt initialization

**Run:** `den-profile run startup`

### 2. Command Execution Benchmarks

Tests command execution pipeline:

- Simple command parsing
- Complex command parsing (pipes, redirections)
- Variable expansion
- Glob expansion
- Process spawn
- Pipe setup
- Redirection setup

**Run:** `den-profile run command`

### 3. Completion Benchmarks

Tests tab completion generation:

- Command completion
- File completion (50 files)
- PATH search (500 executables)
- Fuzzy matching
- Completion ranking (100 items)
- Alias expansion

**Run:** `den-profile run completion`

### 4. History Benchmarks

Tests history operations:

- Linear search (10k entries)
- Prefix search (1k entries)
- Substring search (1k entries)
- Duplicate removal (1k entries)
- Time range filtering (1k entries)
- History persistence (100 entries)
- History loading

**Run:** `den-profile run history`

### 5. Prompt Rendering Benchmarks

Tests prompt generation:

- Simple prompt rendering
- Complex prompt rendering
- Git status query
- Color formatting
- Path shortening
- Username/hostname query
- Variable expansion
- Right prompt rendering
- Transient prompt
- Module detection

**Run:** `den-profile run prompt`

## Writing Custom Benchmarks

### Basic Benchmark

```zig
const Benchmark = @import("profiling/benchmarks.zig").Benchmark;

fn myFunction(allocator: std.mem.Allocator, arg: usize) !void {
    // Function to benchmark
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var bench = Benchmark.init(allocator, "My Benchmark", 1000);
    const result = try bench.run(myFunction, .{ allocator, 42 });

    const stdout = std.io.getStdOut().writer();
    try result.print(stdout);
}
```

### Benchmark Suite

Group related benchmarks:

```zig
const BenchmarkSuite = @import("profiling/benchmarks.zig").BenchmarkSuite;

pub fn main() !void {
    var suite = BenchmarkSuite.init(allocator, "My Suite");
    defer suite.deinit();

    // Add benchmarks
    var bench1 = Benchmark.init(allocator, "Test 1", 1000);
    try suite.addResult(try bench1.run(func1, .{allocator}));

    var bench2 = Benchmark.init(allocator, "Test 2", 1000);
    try suite.addResult(try bench2.run(func2, .{allocator}));

    // Print summary
    try suite.printSummary(stdout);
}
```

## Chrome Tracing

Export profiling data for visualization in Chrome DevTools:

```bash
# Enable profiling
export DEN_PROFILE=1
export DEN_PROFILE_OUTPUT=trace.json

# Run shell
den

# Open trace in Chrome
# Navigate to: chrome://tracing
# Load trace.json
```

## Performance Targets

### Startup Time

- Minimal startup: < 5ms
- With config: < 10ms
- With plugins: < 20ms
- With full history: < 50ms

### Command Execution

- Simple command: < 1ms (parsing + spawn)
- Complex pipeline: < 5ms
- With redirection: < 2ms

### Completion

- Command completion: < 10ms
- File completion: < 20ms
- PATH search: < 30ms

### History

- Search 10k entries: < 10ms
- Load history: < 50ms
- Save history: < 20ms

### Prompt

- Simple prompt: < 0.1ms
- Complex prompt: < 5ms
- With git status: < 20ms

## Optimization Tips

### 1. Reduce Allocations

- Use arena allocators for temporary data
- Pool frequently allocated objects
- Reuse buffers when possible

### 2. Cache Expensive Operations

- Git status (cache for 1-2 seconds)
- Module detection (cache per directory)
- PATH search (cache until PATH changes)

### 3. Lazy Loading

- Load plugins on-demand
- Defer history loading until needed
- Lazy load completions

### 4. Parallel Operations

- Run independent operations concurrently
- Use async I/O for network operations
- Parallelize plugin hooks

### 5. Profile-Guided Optimization

1. Run benchmarks to identify bottlenecks
2. Profile real-world usage
3. Optimize hot paths
4. Verify improvements with benchmarks

## Continuous Profiling

### CI Integration

Benchmarks run automatically in CI:

```yaml
- name: Run Benchmarks
  run: |
    zig build bench
    den-profile all > benchmark-results.txt
```

### Regression Detection

Compare benchmark results over time:

```bash
# Save baseline
den-profile all > baseline.txt

# After changes
den-profile all > current.txt

# Compare
diff baseline.txt current.txt
```

## Profiling Best Practices

1. **Warmup Iterations**
   - Benchmarks automatically run warmup iterations
   - Default: 10% of total iterations

2. **Multiple Iterations**
   - Run enough iterations for statistical significance
   - Typical: 1000-10000 iterations

3. **Minimize Noise**
   - Close other applications
   - Disable CPU frequency scaling
   - Run on dedicated hardware

4. **Measure What Matters**
   - Focus on user-visible latency
   - Profile real-world workloads
   - Consider worst-case scenarios

5. **Document Results**
   - Record hardware specifications
   - Note environmental factors
   - Track results over time

## Troubleshooting

### High Variance

If benchmarks show high variance:
- Increase iteration count
- Close background processes
- Check for thermal throttling
- Use release builds

### Unexpected Results

If results don't match expectations:
- Verify correct build mode (ReleaseFast)
- Check for debug assertions
- Profile in realistic conditions
- Compare with baseline

### Memory Issues

If profiling causes memory issues:
- Reduce event buffer size
- Clear profiler periodically
- Use sampling instead of tracing

## Resources

- [Chrome Tracing Documentation](https://www.chromium.org/developers/how-tos/trace-event-profiling-tool/)
- [Zig Performance Tips](https://ziglang.org/documentation/master/#Performance)
- [Benchmarking Best Practices](https://easyperf.net/blog/)

## Future Enhancements

- [ ] Memory profiling
- [ ] CPU profiling integration
- [ ] Flamegraph generation
- [ ] Comparative analysis tools
- [ ] Performance regression tests
- [ ] Real-time monitoring dashboard
