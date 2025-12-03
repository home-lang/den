# Contributing to Den Shell

Thank you for your interest in contributing to Den Shell! This guide will help you get started.

## Table of Contents

1. [Code of Conduct](#code-of-conduct)
2. [Getting Started](#getting-started)
3. [Development Setup](#development-setup)
4. [Project Structure](#project-structure)
5. [Development Workflow](#development-workflow)
6. [Coding Standards](#coding-standards)
7. [Testing](#testing)
8. [Documentation](#documentation)
9. [Pull Request Process](#pull-request-process)
10. [Issue Guidelines](#issue-guidelines)
11. [Performance Considerations](#performance-considerations)
12. [Common Tasks](#common-tasks)

## Code of Conduct

### Our Pledge

We are committed to providing a welcoming and inclusive environment for all contributors.

### Our Standards

**Positive behaviors**:
- Using welcoming and inclusive language
- Being respectful of differing viewpoints
- Gracefully accepting constructive criticism
- Focusing on what's best for the community
- Showing empathy towards others

**Unacceptable behaviors**:
- Harassment, insults, or derogatory comments
- Public or private harassment
- Publishing others' private information
- Other conduct inappropriate in a professional setting

### Enforcement

Violations may result in temporary or permanent ban from the project.

## Getting Started

### Prerequisites

- **Zig 0.16-dev**: [Download from ziglang.org](https://ziglang.org/download/)
- **Git**: For version control
- **A Unix-like system**: Linux, macOS, or WSL on Windows

### Quick Start

```bash
# Clone the repository
git clone https://github.com/stackblitz/den.git
cd den

# Build the project
zig build

# Run tests
zig build test

# Run the shell
./zig-out/bin/den
```

## Development Setup

### 1. Fork and Clone

```bash
# Fork on GitHub, then clone your fork
git clone https://github.com/YOUR_USERNAME/den.git
cd den

# Add upstream remote
git remote add upstream https://github.com/stackblitz/den.git
```

### 2. Create a Branch

```bash
# Update your main branch
git checkout main
git pull upstream main

# Create a feature branch
git checkout -b feature/my-feature
```

### 3. Install Development Tools (Optional)

```bash
# Zig Language Server (for IDE support)
# See: https://github.com/zigtools/zls

# Recommended editors:
# - VSCode with Zig extension
# - Neovim with zig.vim
# - Emacs with zig-mode
```

## Project Structure

```
den/
├── src/
│   ├── main.zig              # Entry point
│   ├── cli.zig               # CLI argument handling
│   ├── shell.zig             # Core shell state
│   ├── builtins/             # Builtin commands
│   │   ├── mod.zig           # Builtin registry
│   │   ├── cd.zig            # cd command
│   │   └── ...
│   ├── parser/               # Parser and tokenizer
│   │   ├── tokenizer.zig     # Lexical analysis
│   │   ├── parser.zig        # Syntax analysis
│   │   └── mod.zig
│   ├── executor/             # Command execution
│   │   ├── executor.zig      # Main executor
│   │   ├── process.zig       # Process management
│   │   └── redirect.zig      # I/O redirection
│   ├── expansion/            # Shell expansions
│   ├── plugins/              # Plugin system
│   ├── utils/                # Utilities
│   │   ├── concurrency.zig   # Thread pool, atomics
│   │   ├── glob.zig          # Glob matching
│   │   ├── completion.zig    # Tab completion
│   │   └── ...
│   └── types/                # Shared types
├── test/                     # Integration tests
├── bench/                    # Benchmarks
├── docs/                     # Documentation
├── build.zig                 # Build configuration
└── README.md
```

### Key Directories

- **src/**: All source code
- **src/builtins/**: Builtin command implementations
- **src/parser/**: Tokenizer and parser
- **src/executor/**: Command execution engine
- **src/plugins/**: Plugin system and builtin plugins
- **src/utils/**: Utility modules (glob, completion, etc.)
- **bench/**: Performance benchmarks
- **docs/**: Documentation files

## Development Workflow

### 1. Make Changes

```bash
# Edit files
vim src/builtins/my_builtin.zig

# Build to check for errors
zig build

# Run tests
zig build test
```

### 2. Test Your Changes

```bash
# Run specific test
zig test src/builtins/my_builtin.zig

# Run all tests
zig build test

# Run the shell interactively
./zig-out/bin/den

# Test a specific command
./zig-out/bin/den -c "echo hello"
```

### 3. Format Code

```bash
# Format all Zig files
zig fmt src/
zig fmt test/
zig fmt bench/
```

### 4. Commit Changes

```bash
# Stage changes
git add src/builtins/my_builtin.zig

# Commit with descriptive message
git commit -m "feat(builtins): add my_builtin command

- Implements XYZ functionality
- Adds tests
- Updates documentation"
```

### Commit Message Format

Use conventional commits:

```
<type>(<scope>): <subject>

<body>

<footer>
```

**Types**:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation only
- `style`: Formatting, missing semicolons, etc.
- `refactor`: Code change that neither fixes a bug nor adds a feature
- `perf`: Performance improvement
- `test`: Adding or updating tests
- `chore`: Maintenance tasks

**Examples**:
```
feat(parser): add support for case statements

Implements case/esac pattern matching similar to bash.
Includes tests and documentation.

Closes #123
```

```
fix(executor): handle SIGPIPE correctly

Previously, broken pipes would cause shell to exit.
Now properly handles SIGPIPE and continues execution.
```

### 5. Push and Create PR

```bash
# Push to your fork
git push origin feature/my-feature

# Create pull request on GitHub
```

## Coding Standards

### Zig Style Guide

Follow the [official Zig style guide](https://ziglang.org/documentation/master/#Style-Guide):

**Naming Conventions**:
```zig
// Types: PascalCase
pub const MyStruct = struct { ... };

// Functions: camelCase
pub fn myFunction() void { ... }

// Variables: snake_case
const my_variable: i32 = 42;

// Constants: SCREAMING_SNAKE_CASE
const MAX_SIZE: usize = 1024;
```

**Formatting**:
```zig
// Use zig fmt for automatic formatting
// 4 spaces for indentation
// Opening brace on same line

pub fn example() void {
    if (condition) {
        // Do something
    } else {
        // Do something else
    }
}
```

**Error Handling**:
```zig
// Always handle errors explicitly
const result = try functionThatMightFail();

// Or catch and handle
const result = functionThatMightFail() catch |err| {
    std.debug.print("Error: {}\n", .{err});
    return err;
};
```

**Memory Management**:
```zig
// Always pair allocations with deallocations
var list = std.ArrayList(u8).init(allocator);
defer list.deinit();

// Use arena allocators for temporary data
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
```

### Documentation Comments

Document all public APIs:

```zig
/// Executes a shell command and returns the exit code.
///
/// This function parses the command string, expands variables,
/// and executes the resulting command.
///
/// **Parameters**:
/// - `command`: The command string to execute
///
/// **Returns**: Exit code (0 for success)
///
/// **Errors**: SyntaxError, CommandNotFound, ExecutionFailed
///
/// **Example**:
/// ```zig
/// const exit_code = try shell.executeCommand("ls -la");
/// ```
pub fn executeCommand(self: *Shell, command: []const u8) !i32 {
    // Implementation
}
```

### Code Organization

```zig
// Order of declarations:
// 1. Imports
const std = @import("std");
const types = @import("types/mod.zig");

// 2. Constants
const MAX_ARGS: usize = 64;

// 3. Types
pub const MyStruct = struct {
    field: i32,
};

// 4. Public functions
pub fn publicFunction() void { }

// 5. Private functions
fn privateFunction() void { }

// 6. Tests
test "my test" {
    try std.testing.expect(true);
}
```

## Testing

### Writing Tests

```zig
// Unit tests in the same file
test "cd builtin changes directory" {
    var shell = try Shell.init(std.testing.allocator);
    defer shell.deinit();

    const exit_code = try builtins.cd(&shell, &[_][]const u8{"/tmp"}, undefined);
    try std.testing.expectEqual(@as(i32, 0), exit_code);

    const pwd = try std.process.getCwd(std.testing.allocator);
    defer std.testing.allocator.free(pwd);
    try std.testing.expect(std.mem.eql(u8, pwd, "/tmp"));
}
```

### Integration Tests

```bash
# Add test scripts in test/
cat > test/test_myfeature.sh << 'EOF'
#!/usr/bin/env bash

# Test my feature
den -c "my_command arg1 arg2"
if [ $? -ne 0 ]; then
    echo "FAIL: my_command failed"
    exit 1
fi

echo "PASS: my_command"
EOF

chmod +x test/test_myfeature.sh
```

### Running Tests

```bash
# All tests
zig build test

# Specific file
zig test src/builtins/cd.zig

# With coverage (if available)
zig build test -Dcoverage
```

### Benchmarks

Add benchmarks for performance-critical code:

```zig
// In bench/my_benchmark.zig
const std = @import("std");
const Benchmark = @import("profiling").Benchmark;

fn benchmarkMyFunction(allocator: std.mem.Allocator) !void {
    // Setup
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        _ = try myFunction();
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var bench = Benchmark.init(allocator, "My Function", 100);
    const result = try bench.run(benchmarkMyFunction, .{allocator});

    std.debug.print("Average: {d:.2}ms\n", .{result.average_ms});
}
```

## Documentation

### Documentation Requirements

All contributions must include:

1. **Code comments**: Explain complex logic
2. **API documentation**: Document public functions
3. **README updates**: If adding user-facing features
4. **CHANGELOG**: Add entry for changes

### Updating Documentation

```bash
# Add/update docs
vim docs/API.md

# Update examples
vim examples/my_example.zig

# Update README if needed
vim README.md
```

### Documentation Style

- Use clear, concise language
- Include code examples
- Explain both what and why
- Link to related documentation

## Pull Request Process

### Before Submitting

**Checklist**:
- [ ] Code builds without errors
- [ ] All tests pass
- [ ] Code is formatted (`zig fmt`)
- [ ] Documentation is updated
- [ ] Commit messages follow convention
- [ ] Changes are atomic and focused

### PR Description Template

```markdown
## Description
Brief description of changes

## Motivation
Why is this change needed?

## Changes
- Added X
- Fixed Y
- Removed Z

## Testing
How was this tested?

## Checklist
- [ ] Tests pass
- [ ] Documentation updated
- [ ] Code formatted
- [ ] CHANGELOG updated

## Related Issues
Closes #123
```

### Review Process

1. **Automated checks**: CI must pass
2. **Code review**: Maintainer reviews code
3. **Feedback**: Address review comments
4. **Approval**: Maintainer approves PR
5. **Merge**: PR is merged

### After Merge

```bash
# Update your main branch
git checkout main
git pull upstream main

# Delete feature branch
git branch -d feature/my-feature
git push origin --delete feature/my-feature
```

## Issue Guidelines

### Reporting Bugs

Use the bug report template:

```markdown
**Bug Description**
Clear description of the bug

**To Reproduce**
Steps to reproduce:
1. Run command: `den -c "..."`
2. Observe error

**Expected Behavior**
What should happen

**Actual Behavior**
What actually happens

**Environment**
- OS: macOS 14.0
- Zig version: 0.16-dev
- Den version: 0.1.0

**Additional Context**
Any other relevant information
```

### Feature Requests

Use the feature request template:

```markdown
**Feature Description**
Clear description of the feature

**Use Case**
Why is this feature needed?

**Proposed Solution**
How should this work?

**Alternatives Considered**
Other approaches considered

**Additional Context**
Any other relevant information
```

### Asking Questions

- Search existing issues first
- Use discussions for general questions
- Be specific and include context

## Performance Considerations

### Performance Guidelines

1. **Measure first**: Profile before optimizing
2. **Minimize allocations**: Reuse memory where possible
3. **Use appropriate data structures**: Choose based on access patterns
4. **Consider concurrency**: Use thread pool for I/O-bound tasks

### Profiling

```bash
# Build with profiling
zig build bench

# Run profiler
./zig-out/bin/den-profile

# Analyze results
# See docs/profiling.md for details
```

### Optimization Checklist

- [ ] Profiled to identify bottlenecks
- [ ] Measured performance impact
- [ ] Considered memory usage
- [ ] Added benchmark if significant change
- [ ] Documented performance characteristics

## Common Tasks

### Adding a Builtin Command

1. Create file in `src/builtins/`:
```zig
// src/builtins/mycommand.zig
const std = @import("std");
const Shell = @import("../shell.zig").Shell;

pub fn myCommand(
    shell: *Shell,
    args: []const []const u8,
    stdout: anytype,
) !i32 {
    // Implementation
    _ = shell;
    _ = args;
    try stdout.writeAll("Hello from mycommand\n");
    return 0;
}

test "mycommand basic" {
    // Tests
}
```

2. Register in `src/builtins/mod.zig`:
```zig
pub const BUILTINS = std.ComptimeStringMap(*const BuiltinFn, .{
    // ... existing builtins
    .{ "mycommand", myCommand },
});
```

3. Add tests and documentation

### Adding a Parser Feature

1. Update tokenizer if needed (`src/parser/tokenizer.zig`)
2. Update parser (`src/parser/parser.zig`)
3. Update AST types (`src/types/ast.zig`)
4. Update executor (`src/executor/executor.zig`)
5. Add tests

### Adding a Plugin

1. Create plugin file in `src/plugins/`:
```zig
// src/plugins/my_plugin.zig
const std = @import("std");
const interface = @import("interface.zig");

pub const MyPlugin = interface.Plugin{
    .name = "my-plugin",
    .version = "1.0.0",
    .description = "My custom plugin",
    .init = init,
    .deinit = deinit,
    .hooks = &[_]interface.HookRegistration{
        .{ .hook_type = .pre_command, .handler = preCommand },
    },
};

fn init(ctx: *interface.PluginContext) !void {
    // Initialize
}

fn deinit(ctx: *interface.PluginContext) void {
    // Cleanup
}

fn preCommand(ctx: *interface.HookContext) !void {
    // Handle hook
}
```

2. Register plugin in shell initialization

### Adding Documentation

1. Update relevant docs in `docs/`
2. Add examples if applicable
3. Update API.md for public APIs
4. Update CHANGELOG.md

## Getting Help

### Resources

- **Documentation**: [docs/](../docs/)
- **API Reference**: [docs/API.md](API.md)
- **Architecture**: [docs/ARCHITECTURE.md](ARCHITECTURE.md)
- **GitHub Discussions**: For questions
- **GitHub Issues**: For bugs and features

### Communication

- Be respectful and constructive
- Provide context and examples
- Search before asking
- Follow up on responses

## Recognition

Contributors are recognized in:
- CONTRIBUTORS.md (if it exists)
- Release notes
- Project README

Thank you for contributing to Den Shell! 🎉

## Additional Resources

- [Zig Documentation](https://ziglang.org/documentation/)
- [POSIX Shell Specification](https://pubs.opengroup.org/onlinepubs/9699919799/)
- [Project Architecture](ARCHITECTURE.md)
- [API Reference](API.md)
- [Data Structures](DATA_STRUCTURES.md)
- [Algorithms](ALGORITHMS.md)
