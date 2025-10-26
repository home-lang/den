# Den Test Framework

A comprehensive test framework for the Den shell with discovery, filtering, reporting, and CI integration.

## Features

- **Test Discovery**: Automatically discover test files matching patterns
- **Test Filtering**: Filter tests by name patterns
- **Multiple Output Formats**: Human-readable, JSON, JUnit XML, TAP
- **Parallel Execution**: Run tests in parallel for faster results
- **CI Integration**: GitHub Actions workflow included
- **Detailed Reporting**: Statistics, timing, and error messages
- **Color Output**: Beautiful colored terminal output

## Usage

### Run All Tests

```bash
zig build test-all
```

### Run Specific Test Suite

```bash
zig build test-tokenizer
zig build test-parser
zig build test-theme
```

### Using the Test Runner

Build the test runner:

```bash
zig build
```

Run with default settings:

```bash
./zig-out/bin/den-test
```

Filter tests:

```bash
./zig-out/bin/den-test parser
./zig-out/bin/den-test --filter tokenizer
```

Verbose output:

```bash
./zig-out/bin/den-test --verbose
```

JSON output:

```bash
./zig-out/bin/den-test --json
```

JUnit XML (for CI):

```bash
./zig-out/bin/den-test --junit > test-results.xml
```

Parallel execution:

```bash
./zig-out/bin/den-test --parallel 4
```

## Output Formats

### Human (default)

```
Running tokenizer
  [PASS] basic tokenization (12.34ms)
  [PASS] quote handling (5.67ms)
  [FAIL] error cases (8.90ms)
    Error: Expected error, got success

═══════════════════════════════════════
Test Results:
  Total:   3
  Passed:  2
  Failed:  1
  Skipped: 0
  Duration: 0.03s
═══════════════════════════════════════

FAILED
```

### JSON

```json
{
  "name": "tokenizer",
  "status": "passed",
  "duration_ns": 12340000
}
```

### JUnit XML

```xml
<?xml version="1.0" encoding="UTF-8"?>
<testsuite tests="3" failures="1" skipped="0" time="0.027">
  <testcase name="tokenizer" time="0.012" />
</testsuite>
```

### TAP (Test Anything Protocol)

```
ok - tokenizer
not ok - parser
  # Expected 5 tokens, got 3
1..2
```

## Test Discovery

The framework automatically discovers tests in:
- `src/**/*test*.zig`
- `test/**/*.zig`

Test files should follow naming conventions:
- `test_*.zig` (e.g., `test_parser.zig`)
- `*_test.zig` (e.g., `parser_test.zig`)

## CI Integration

GitHub Actions workflow (`.github/workflows/test.yml`):

- Runs on Ubuntu and macOS
- Tests multiple Zig versions
- Generates coverage reports
- Builds release binaries
- Caches dependencies

## Architecture

### Components

- **types.zig**: Core data types (TestResult, TestStats, TestFilter)
- **discovery.zig**: Test discovery and module detection
- **reporter.zig**: Output formatting and reporting
- **runner.zig**: Test execution engine
- **main.zig**: CLI interface

### Test Flow

1. **Discovery**: Find all test modules
2. **Filtering**: Apply user-specified filters
3. **Execution**: Run tests sequentially or in parallel
4. **Reporting**: Format and display results
5. **Exit**: Return appropriate exit code

## Writing Tests

Tests are written using Zig's built-in test framework:

```zig
const std = @import("std");

test "example test" {
    try std.testing.expectEqual(2 + 2, 4);
}
```

## Performance

The test framework includes:
- Nanosecond-precision timing
- Memory-efficient result storage
- Optional parallel execution
- Minimal overhead

## Future Enhancements

- [ ] Test retries on failure
- [ ] Coverage reporting integration
- [ ] Test dependencies and ordering
- [ ] Benchmark mode
- [ ] Interactive test selection
- [ ] Watch mode for development
