# Testing Guide

Den Shell aims for 100% test coverage across all modules. This guide covers testing strategies, running tests, and contributing test cases.

## Table of Contents

1. [Testing Philosophy](#testing-philosophy)
2. [Test Structure](#test-structure)
3. [Running Tests](#running-tests)
4. [Test Coverage](#test-coverage)
5. [Writing Tests](#writing-tests)
6. [Test Categories](#test-categories)
7. [Continuous Integration](#continuous-integration)
8. [Test Framework](#test-framework)

## Testing Philosophy

### Goals

- **100% Code Coverage**: Every line of code has a test
- **Behavior Testing**: Focus on behavior, not implementation
- **Fast Feedback**: Tests complete in seconds
- **Reliability**: Tests are deterministic and repeatable
- **Safety**: Tests catch memory leaks and undefined behavior

### Test Pyramid

```
        /\        E2E Tests (10%)
       /  \       - Full shell integration
      /____\      - Real-world scenarios
     /      \     Integration Tests (30%)
    /        \    - Module interactions
   /__________\   - Multi-component tests
  /            \  Unit Tests (60%)
 /______________\ - Individual functions
                  - Edge cases
```

## Test Structure

### Directory Organization

```
den/
├── src/
│   ├── parser/
│   │   ├── parser.zig          # Implementation
│   │   └── test_parser.zig     # Unit tests
│   ├── executor/
│   │   ├── mod.zig
│   │   └── test_executor.zig
│   └── ...
├── tests/
│   ├── test_integration.zig    # Integration tests
│   ├── test_e2e.zig           # End-to-end tests
│   └── test_cli.zig           # CLI tests
└── bench/
    ├── startup_bench.zig       # Startup benchmarks
    └── ...
```

### Test File Naming

- Unit tests: `test_<module>.zig` (in same directory as module)
- Integration tests: `test_integration.zig` in `tests/`
- E2E tests: `test_e2e.zig` in `tests/`
- Benchmarks: `*_bench.zig` in `bench/`

## Running Tests

### All Tests

```bash
# Run all unit tests
zig build test

# Run all tests including integration
zig build test-all

# Run with verbose output
zig build test -- --verbose
```

### Specific Test Suites

```bash
# Unit tests only
zig build test

# Plugin tests
zig build test-plugins

# Integration tests
zig build test-integration

# E2E tests
zig build test-e2e

# CLI tests
zig build test-cli
```

### Individual Test Files

```bash
# Test specific module
zig test src/parser/test_parser.zig

# Test with imports
zig test src/parser/test_parser.zig --dep zig-config
```

### Test Filters

```bash
# Run specific test
zig build test -- --test-filter "parser basic"

# Run tests matching pattern
zig build test -- --test-filter "tokenizer"
```

### Memory Testing

```bash
# Check for memory leaks
zig build test -- --check-leaks

# With allocation tracking
zig build test -- --track-memory
```

## Test Coverage

### Measuring Coverage

```bash
# Generate coverage report
zig build test-coverage

# View coverage report
open coverage/index.html
```

### Current Coverage

| Module | Coverage | Lines | Tests |
|--------|----------|-------|-------|
| Parser | 98% | 1,245 | 67 |
| Executor | 95% | 2,103 | 89 |
| Expansion | 97% | 856 | 54 |
| History | 100% | 423 | 38 |
| Completion | 92% | 678 | 45 |
| Builtins | 89% | 3,412 | 124 |
| Plugins | 100% | 234 | 28 |
| Utils | 96% | 567 | 42 |
| **Total** | **94%** | **9,518** | **487** |

### Coverage Goals

- [x] Parser: 95%+
- [x] Executor: 95%+
- [x] History: 100%
- [x] Plugins: 100%
- [ ] Builtins: 95%+ (currently 89%)
- [ ] Completion: 95%+ (currently 92%)
- [ ] **Overall: 100%** (currently 94%)

## Writing Tests

### Basic Test Structure

```zig
const std = @import("std");
const testing = std.testing;

test "parser: basic command" {
    const allocator = testing.allocator;

    // Setup
    var parser = try Parser.init(allocator);
    defer parser.deinit();

    // Execute
    const result = try parser.parse("echo hello");

    // Assert
    try testing.expectEqual(1, result.commands.len);
    try testing.expectEqualStrings("echo", result.commands[0].name);
    try testing.expectEqualStrings("hello", result.commands[0].args[0]);

    // Cleanup (if needed)
    result.deinit();
}
```

### Test Naming Conventions

```zig
// Format: test "module: description"
test "parser: handles empty input" { }
test "tokenizer: splits on whitespace" { }
test "executor: executes builtin commands" { }

// For error cases
test "parser: returns error on invalid syntax" { }
test "executor: handles missing command" { }
```

### Common Assertions

```zig
// Equality
try testing.expectEqual(expected, actual);
try testing.expectEqualStrings("hello", string);

// Boolean
try testing.expect(condition);

// Error handling
try testing.expectError(error.InvalidSyntax, func());

// Memory
try testing.expectEqual(0, allocator.leaked);
```

### Testing Memory Safety

```zig
test "parser: no memory leaks" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try testing.expect(leaked == .ok);
    }
    const allocator = gpa.allocator();

    var parser = try Parser.init(allocator);
    defer parser.deinit();

    // Test operations
    _ = try parser.parse("command");
}
```

### Testing Async Code

```zig
test "executor: handles background jobs" {
    const allocator = testing.allocator;

    var executor = try Executor.init(allocator);
    defer executor.deinit();

    // Start background job
    const job_id = try executor.startBackgroundJob("sleep 1");

    // Wait for completion
    const result = try executor.waitForJob(job_id);
    try testing.expectEqual(0, result);
}
```

## Test Categories

### 1. Unit Tests

Test individual functions and methods in isolation.

```zig
// src/parser/test_parser.zig
test "tokenizer: splits command with spaces" {
    const allocator = testing.allocator;
    const input = "echo hello world";

    var tokenizer = Tokenizer.init(allocator, input);
    defer tokenizer.deinit();

    const tokens = try tokenizer.tokenize();

    try testing.expectEqual(3, tokens.len);
    try testing.expectEqualStrings("echo", tokens[0].value);
    try testing.expectEqualStrings("hello", tokens[1].value);
    try testing.expectEqualStrings("world", tokens[2].value);
}
```

### 2. Integration Tests

Test multiple modules working together.

```zig
// tests/test_integration.zig
test "integration: parse and execute command" {
    const allocator = testing.allocator;

    var shell = try Shell.init(allocator);
    defer shell.deinit();

    const exit_code = try shell.executeCommand("echo test");

    try testing.expectEqual(0, exit_code);
}
```

### 3. End-to-End Tests

Test complete user workflows.

```zig
// tests/test_e2e.zig
test "e2e: interactive session" {
    const allocator = testing.allocator;

    // Start shell
    var shell = try Shell.init(allocator);
    defer shell.deinit();

    // Execute commands
    try shell.executeCommand("export VAR=value");
    try shell.executeCommand("echo $VAR");

    // Verify state
    const var_value = shell.getVariable("VAR");
    try testing.expectEqualStrings("value", var_value.?);
}
```

### 4. Regression Tests

Prevent bugs from reappearing.

```zig
test "regression: issue #42 - glob with spaces" {
    // Test for bug fix: globbing failed with spaces in pattern
    const allocator = testing.allocator;

    var globber = try Glob.init(allocator);
    defer globber.deinit();

    const pattern = "src/**/*.zig";
    const matches = try globber.match(pattern);
    defer allocator.free(matches);

    try testing.expect(matches.len > 0);
}
```

### 5. Fuzz Tests

Test with random/malformed input.

```zig
test "fuzz: parser handles random input" {
    const allocator = testing.allocator;
    var prng = std.rand.DefaultPrng.init(12345);
    const random = prng.random();

    var parser = try Parser.init(allocator);
    defer parser.deinit();

    // Test 1000 random inputs
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var input: [256]u8 = undefined;
        random.bytes(&input);

        // Should not crash
        _ = parser.parse(&input) catch continue;
    }
}
```

## Continuous Integration

### GitHub Actions

Den runs tests on every commit:

```yaml
# .github/workflows/test.yml
name: Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.16-dev

      - name: Run tests
        run: zig build test

      - name: Check coverage
        run: zig build test-coverage

      - name: Upload coverage
        uses: codecov/codecov-action@v3
```

### Pre-commit Hooks

```bash
# .git/hooks/pre-commit
#!/bin/bash
zig build test || {
    echo "Tests failed. Commit aborted."
    exit 1
}
```

### Coverage Requirements

Pull requests must:
- [ ] Pass all existing tests
- [ ] Add tests for new code
- [ ] Maintain or improve coverage
- [ ] Include regression tests for bug fixes

## Test Framework

### Zig Test Framework

Den uses Zig's built-in test framework:

```zig
// Automatic test discovery
test "my test" { }

// Test namespaces
const MyTests = struct {
    test "nested test" { }
};

// Test-only code
const TestHelpers = if (@import("builtin").is_test) struct {
    pub fn helper() void { }
} else struct {};
```

### Custom Test Utilities

```zig
// src/test_utils.zig
pub const TestAllocator = struct {
    allocator: std.mem.Allocator,
    leaked: usize,

    pub fn init() TestAllocator {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        return .{
            .allocator = gpa.allocator(),
            .leaked = 0,
        };
    }

    pub fn deinit(self: *TestAllocator) !void {
        const leaked = self.gpa.deinit();
        if (leaked == .leak) return error.MemoryLeak;
    }
};
```

### Mock Utilities

```zig
// Test doubles
pub const MockIO = struct {
    output: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) MockIO {
        return .{ .output = std.ArrayList(u8).init(allocator) };
    }

    pub fn print(self: *MockIO, comptime fmt: []const u8, args: anytype) !void {
        try self.output.writer().print(fmt, args);
    }

    pub fn getOutput(self: *MockIO) []const u8 {
        return self.output.items;
    }
};
```

## Best Practices

### Do's

✅ Test behavior, not implementation
✅ Use descriptive test names
✅ Test edge cases and error paths
✅ Check for memory leaks
✅ Write tests before fixing bugs
✅ Keep tests fast and independent
✅ Use setup/teardown helpers

### Don'ts

❌ Don't test private implementation details
❌ Don't use sleep() for timing
❌ Don't leave debug prints
❌ Don't skip tests
❌ Don't test multiple things in one test
❌ Don't rely on test execution order

## Test Checklist

Before submitting a PR:

- [ ] All tests pass
- [ ] New code has tests
- [ ] Tests cover edge cases
- [ ] No memory leaks
- [ ] Tests are deterministic
- [ ] Test names are descriptive
- [ ] Coverage maintained/improved

## Examples

### Testing Builtins

```zig
test "builtin cd: changes directory" {
    const allocator = testing.allocator;

    var executor = try Executor.init(allocator);
    defer executor.deinit();

    const original_cwd = try std.process.getCwd(allocator);
    defer allocator.free(original_cwd);

    // Change to temp directory
    const temp_dir = try std.fs.cwd().openDir("/tmp", .{});
    defer temp_dir.close();

    var cmd = Command{ .name = "cd", .args = &[_][]const u8{"/tmp"} };
    const result = try executor.executeBuiltin(&cmd);

    try testing.expectEqual(0, result);

    const new_cwd = try std.process.getCwd(allocator);
    defer allocator.free(new_cwd);

    try testing.expect(std.mem.endsWith(u8, new_cwd, "/tmp"));
}
```

### Testing Pipelines

```zig
test "pipeline: echo | grep" {
    const allocator = testing.allocator;

    var shell = try Shell.init(allocator);
    defer shell.deinit();

    const result = try shell.executeCommand("echo 'hello world' | grep hello");

    try testing.expectEqual(0, result);
}
```

### Testing Error Handling

```zig
test "parser: invalid syntax returns error" {
    const allocator = testing.allocator;

    var parser = try Parser.init(allocator);
    defer parser.deinit();

    const result = parser.parse("command |");

    try testing.expectError(error.UnexpectedEndOfInput, result);
}
```

## Resources

- [Zig Testing Documentation](https://ziglang.org/documentation/master/#Testing)
- [Test-Driven Development](https://en.wikipedia.org/wiki/Test-driven_development)
- [Testing Best Practices](https://kentcdodds.com/blog/common-mistakes-with-react-testing-library)

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for how to contribute tests.

When adding a new feature:
1. Write tests first (TDD)
2. Implement feature
3. Ensure all tests pass
4. Add integration/E2E tests
5. Update documentation

---

**Goal**: Achieve and maintain 100% test coverage while ensuring Den Shell remains robust, reliable, and production-ready.
