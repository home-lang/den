# Den Shell Architecture

This document provides a comprehensive overview of Den Shell's architecture, design decisions, and component interactions.

## Table of Contents

1. [Overview](#overview)
2. [Core Architecture](#core-architecture)
3. [Component Overview](#component-overview)
4. [Data Flow](#data-flow)
5. [Execution Pipeline](#execution-pipeline)
6. [Concurrency Model](#concurrency-model)
7. [Memory Management](#memory-management)
8. [Extension Points](#extension-points)

## Overview

Den Shell is a modern, high-performance POSIX-compatible shell written in Zig. The architecture is designed for:

- **Performance**: Optimized for startup time, execution speed, and memory efficiency
- **Modularity**: Clean separation of concerns with well-defined interfaces
- **Extensibility**: Plugin system and hooks for customization
- **Correctness**: Strong typing and comprehensive testing
- **Concurrency**: Thread pool and parallel execution for I/O-bound operations

### Technology Stack

- **Language**: Zig 0.15.1
- **Build System**: Zig build system
- **Testing**: Zig test framework with custom profiling
- **Concurrency**: Custom thread pool and lock-free data structures

## Core Architecture

Den Shell follows a layered architecture with clear separation between components:

```
┌─────────────────────────────────────────────────────────────┐
│                         CLI Layer                            │
│                    (src/cli.zig, src/main.zig)              │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                       Shell Core                             │
│                    (src/shell.zig)                           │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Environment │ History │ Jobs │ Aliases │ Variables   │  │
│  └──────────────────────────────────────────────────────┘  │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                      REPL Layer                              │
│                    (src/repl/)                               │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Input │ Completion │ Highlighting │ Auto-suggest     │  │
│  └──────────────────────────────────────────────────────┘  │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                     Parser Layer                             │
│        (src/parser/, src/expansion/, src/types/)            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Tokenizer → Parser → AST → Expansion → Commands      │  │
│  └──────────────────────────────────────────────────────┘  │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                    Executor Layer                            │
│                  (src/executor/)                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Builtins │ External │ Pipelines │ Redirections       │  │
│  └──────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                   Cross-Cutting Concerns                     │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Plugins │ Hooks │ Scripting │ Profiling │ Logging    │  │
│  └──────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

## Component Overview

### 1. CLI Layer (src/cli.zig, src/main.zig)

**Purpose**: Entry point and command-line argument handling

**Key Components**:
- `main.zig`: Program entry point with GPA allocator setup
- `cli.zig`: Command parsing and subcommand dispatch

**Responsibilities**:
- Parse command-line arguments
- Route to appropriate subcommands (shell, exec, complete, setup, etc.)
- Initialize allocator and shell instance
- Handle version and help commands

### 2. Shell Core (src/shell.zig)

**Purpose**: Central state management and coordination

**Key Components**:
- `Shell` struct: Main shell state
- Environment variables management
- History tracking
- Job control
- Alias management
- Positional parameters
- Thread pool for concurrency

**Responsibilities**:
- Initialize and manage shell state
- Coordinate between subsystems
- Execute hooks at lifecycle events
- Manage background jobs
- Track command history

**Key Data Structures**:
```zig
pub const Shell = struct {
    allocator: std.mem.Allocator,
    running: bool,
    environment: std.StringHashMap([]const u8),
    aliases: std.StringHashMap([]const u8),
    history: [1000]?[]const u8,
    background_jobs: [16]?BackgroundJob,
    script_manager: ScriptManager,
    function_manager: FunctionManager,
    plugin_registry: PluginRegistry,
    plugin_manager: PluginManager,
    thread_pool: concurrency.ThreadPool, // For parallel operations
    // ... more fields
}
```

### 3. REPL Layer (src/repl/)

**Purpose**: Interactive command-line interface

**Key Components**:
- `editor.zig`: Line editing with history navigation
- Completion engine (src/completion/)
- Syntax highlighting (plugins)
- Auto-suggestions (plugins)

**Responsibilities**:
- Read user input with editing capabilities
- Provide completions for commands, files, variables
- Highlight syntax in real-time
- Show suggestions based on history
- Handle special keys (Ctrl+C, Ctrl+D, etc.)

### 4. Parser Layer (src/parser/, src/expansion/, src/types/)

**Purpose**: Transform input text into executable AST

**Pipeline**:
```
Input String → Tokenizer → Parser → AST → Expansion → Command Tree
```

**Key Components**:

#### Tokenizer (src/parser/tokenizer.zig)
- Breaks input into tokens
- Handles quotes, escapes, operators
- Tracks token positions for error reporting

**Token Types**:
- Words (commands, arguments)
- Operators (|, ||, &&, ;, &, <, >, >>)
- Special characters ($, `, \)
- Keywords (if, while, for, function)

#### Parser (src/parser/parser.zig)
- Builds AST from tokens
- Handles operator precedence
- Validates syntax
- Supports complex constructs (pipelines, conditionals, loops)

**AST Node Types**:
- Command: Simple command with arguments
- Pipeline: Commands connected with pipes
- Conditional: if/elif/else statements
- Loop: for/while loops
- Function: Function definitions
- Compound: Grouped commands ({})

#### Expansion (src/expansion/)
- Parameter expansion ($VAR, ${VAR})
- Command substitution ($(cmd), `cmd`)
- Arithmetic expansion ($((expr)))
- Glob expansion (*.txt, [a-z]*)
- Brace expansion ({a,b,c}, {1..10})
- Tilde expansion (~, ~/dir)

### 5. Executor Layer (src/executor/)

**Purpose**: Execute parsed commands

**Key Components**:

#### Command Executor (src/executor/executor.zig)
- Routes commands to builtins or external processes
- Handles pipelines with proper file descriptor management
- Manages redirections (<, >, >>, 2>&1)
- Implements job control (fg, bg, jobs)

#### Builtin Commands (src/builtins/)
- `cd`: Change directory with CDPATH support
- `echo`: Print text with escape sequences
- `export`: Set environment variables
- `alias`: Create command aliases
- `source`: Execute script files
- `exit`: Exit shell with status code
- Many more (see src/builtins/mod.zig)

#### Process Management (src/executor/process.zig)
- Fork/exec for external commands
- Process group management
- Signal handling (SIGINT, SIGTERM, SIGCHLD)
- Background job tracking

#### I/O Redirection (src/executor/redirect.zig)
- File descriptor manipulation
- Pipe creation and management
- Here-document implementation
- File mode handling (read, write, append)

### 6. Plugin System (src/plugins/)

**Purpose**: Extensibility and customization

**Key Components**:

#### Plugin Interface (src/plugins/interface.zig)
```zig
pub const Plugin = struct {
    name: []const u8,
    version: []const u8,
    init: *const fn (*PluginContext) anyerror!void,
    deinit: *const fn (*PluginContext) void,
    hooks: []const HookRegistration,
};

pub const HookType = enum {
    shell_init,
    shell_exit,
    pre_command,
    post_command,
    prompt,
    // ... more hooks
};
```

#### Plugin Manager (src/plugins/manager.zig)
- Load plugins from directories
- Manage plugin lifecycle
- Handle plugin dependencies
- Provide isolation between plugins

#### Builtin Plugins (src/plugins/builtin_plugins_advanced.zig)
- AutoSuggest: History-based suggestions
- Highlight: Syntax highlighting
- ScriptSuggester: Script completion

**Hook Points**:
- `shell_init`: After shell initialization
- `shell_exit`: Before shell cleanup
- `pre_command`: Before command execution
- `post_command`: After command execution
- `prompt`: Generate custom prompts
- `completion`: Custom completions

### 7. Scripting Layer (src/scripting/)

**Purpose**: Script execution and function management

**Key Components**:

#### Script Manager (src/scripting/script_manager.zig)
- Load and execute script files
- Track script state and variables
- Handle script errors

#### Function Manager (src/scripting/functions.zig)
- Define shell functions
- Store function bodies
- Execute functions with arguments
- Handle function-local variables

### 8. Utilities (src/utils/)

**Purpose**: Shared functionality and helpers

**Key Modules**:
- `io.zig`: I/O utilities, terminal handling
- `path.zig`: Path manipulation and resolution
- `completion.zig`: Completion engine
- `glob.zig`: Glob pattern matching
- `brace.zig`: Brace expansion
- `expansion.zig`: Variable/command expansion
- `concurrency.zig`: Thread pool, atomic structures
- `parallel_discovery.zig`: Parallel file operations

## Data Flow

### Command Execution Flow

```
User Input
    │
    ▼
┌───────────────┐
│ REPL/Editor   │  Read line with editing
└───────┬───────┘
        │
        ▼
┌───────────────┐
│   Tokenizer   │  Break into tokens
└───────┬───────┘
        │
        ▼
┌───────────────┐
│    Parser     │  Build AST
└───────┬───────┘
        │
        ▼
┌───────────────┐
│   Expansion   │  Expand variables, globs, etc.
└───────┬───────┘
        │
        ▼
┌───────────────┐
│   Executor    │  Execute commands
└───────┬───────┘
        │
        ├─▶ Builtin Command
        │       │
        │       ▼
        │   Execute internally
        │
        └─▶ External Command
                │
                ▼
            Fork & Exec
                │
                ▼
            Wait for completion
                │
                ▼
            Return exit code
```

### Plugin Hook Flow

```
Shell Event (e.g., pre_command)
    │
    ▼
┌────────────────┐
│ Plugin Registry│  Find registered hooks
└────────┬───────┘
         │
         ▼
┌────────────────┐
│  Hook Context  │  Build context with event data
└────────┬───────┘
         │
         ▼
   ┌─────────────┐
   │ For each    │
   │ registered  │
   │ plugin      │
   └──────┬──────┘
          │
          ▼
   ┌──────────────┐
   │ Call plugin  │
   │ hook handler │
   └──────┬───────┘
          │
          ▼
   ┌──────────────┐
   │ Collect      │
   │ results      │
   └──────┬───────┘
          │
          ▼
    Return to caller
```

## Execution Pipeline

### Simple Command

```bash
ls -la /tmp
```

1. **Tokenize**: `[ls] [-la] [/tmp]`
2. **Parse**: `Command{name: "ls", args: ["-la", "/tmp"]}`
3. **Expand**: No expansion needed
4. **Execute**:
   - Check if builtin → No
   - Fork process
   - Exec `/usr/bin/ls` with args
   - Wait for completion

### Pipeline

```bash
cat file.txt | grep "pattern" | wc -l
```

1. **Tokenize**: `[cat] [file.txt] [|] [grep] ["pattern"] [|] [wc] [-l]`
2. **Parse**: `Pipeline{[Command(cat), Command(grep), Command(wc)]}`
3. **Execute Pipeline**:
   ```
   - Create pipe1: cat → grep
   - Create pipe2: grep → wc
   - Fork cat: stdout → pipe1
   - Fork grep: stdin ← pipe1, stdout → pipe2
   - Fork wc: stdin ← pipe2
   - Close all pipe ends in parent
   - Wait for all processes
   ```

### Variable Expansion

```bash
echo "Hello $USER, your home is $HOME"
```

1. **Tokenize**: `[echo] ["Hello $USER, your home is $HOME"]`
2. **Parse**: `Command{name: "echo", args: ["Hello $USER, your home is $HOME"]}`
3. **Expand**:
   - Find `$USER` → Replace with environment value
   - Find `$HOME` → Replace with environment value
   - Result: `"Hello john, your home is /home/john"`
4. **Execute**: Builtin echo prints the expanded string

## Concurrency Model

Den Shell implements a hybrid concurrency model:

### Thread Pool Architecture

```
Shell Initialization
    │
    ▼
Create ThreadPool (auto CPU count)
    │
    ├─▶ Worker Thread 1
    ├─▶ Worker Thread 2
    ├─▶ Worker Thread 3
    └─▶ Worker Thread N
         │
         ▼
    Job Queue (mutex-protected)
         │
         ▼
    Wait on condition variable
         │
         ▼
    Execute jobs as submitted
```

### Concurrent Operations

**Plugin Discovery**:
- Scan multiple directories in parallel
- Each directory assigned to worker thread
- Results collected with mutex protection

**File Globbing** (potential):
- Parallel directory traversal
- Concurrent pattern matching
- Merge results

**Completion** (potential):
- Query multiple sources concurrently
- Merge completion results
- Return sorted/deduplicated list

### Synchronization Primitives

- **ThreadPool**: Work queue with condition variables
- **AtomicCounter**: Lock-free metrics
- **SPSCQueue**: Lock-free producer-consumer
- **RWLock**: Reader-writer locks for read-heavy data
- **ConcurrentHashMap**: Sharded hash map (16 shards)

## Memory Management

### Allocation Strategy

Den Shell uses a **General Purpose Allocator (GPA)** at the top level with careful lifetime management:

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var shell = try Shell.init(allocator);
    defer shell.deinit();

    try shell.run();
}
```

### Memory Ownership

- **Shell owns**: Environment, aliases, history, jobs
- **Parser owns**: AST nodes (temporary, freed after execution)
- **Executor owns**: Process handles, file descriptors
- **Plugins own**: Internal state (cleaned up in deinit)

### Lifetime Management

1. **Shell Level**: Long-lived (entire session)
   - Environment variables
   - History
   - Aliases
   - Background jobs

2. **Command Level**: Medium-lived (single command)
   - AST nodes
   - Expanded arguments
   - Temporary files

3. **Execution Level**: Short-lived (during execution)
   - Pipe buffers
   - Process state
   - I/O buffers

### Memory Optimization Techniques

See [MEMORY_OPTIMIZATION.md](MEMORY_OPTIMIZATION.md) for details:
- Arena allocators for parser
- String interning for common values
- Fixed-size arrays for bounded collections
- Lazy initialization of optional features

## Extension Points

### 1. Builtin Commands

Add new builtins by implementing in `src/builtins/`:

```zig
pub fn myBuiltin(
    shell: *Shell,
    args: []const []const u8,
    stdout: anytype,
) !i32 {
    // Implementation
    return 0;
}
```

Register in `src/builtins/mod.zig`.

### 2. Plugins

Create plugins by implementing the `Plugin` interface:

```zig
pub const MyPlugin = struct {
    pub fn init(ctx: *PluginContext) !void {
        // Initialize plugin
    }

    pub fn deinit(ctx: *PluginContext) void {
        // Cleanup
    }

    pub const hooks = [_]HookRegistration{
        .{ .hook_type = .pre_command, .handler = preCommand },
    };

    fn preCommand(ctx: *HookContext) !void {
        // Handle pre-command event
    }
};
```

### 3. Completion Sources

Add completion sources in `src/completion/`:

```zig
pub fn completeMyThing(
    prefix: []const u8,
    allocator: std.mem.Allocator,
) ![][]const u8 {
    // Return completions
}
```

### 4. Custom Expansion

Add expansion rules in `src/expansion/`:

```zig
pub fn expandMyPattern(
    input: []const u8,
    allocator: std.mem.Allocator,
    env: *std.StringHashMap([]const u8),
) ![][]const u8 {
    // Expand pattern
}
```

## Design Principles

### 1. Separation of Concerns
- Clear boundaries between components
- Single responsibility per module
- Minimal coupling

### 2. Fail Fast
- Early validation
- Descriptive error messages
- Proper error propagation

### 3. Performance
- Lazy initialization
- Minimize allocations
- Cache where beneficial
- Parallel operations where possible

### 4. Compatibility
- POSIX compliance for core features
- Bash-like syntax for familiarity
- Cross-platform (Linux, macOS)

### 5. Testability
- Pure functions where possible
- Dependency injection
- Comprehensive test coverage

## Future Architecture Enhancements

### Planned Improvements

1. **Async I/O**: Non-blocking file operations
2. **JIT Compilation**: Compile frequently-used scripts
3. **Distributed Execution**: Remote command execution
4. **Advanced Caching**: Cache parsed scripts, completions
5. **Live Reload**: Hot-reload plugins and configuration

### Scalability Considerations

- **Memory**: Fixed-size history/job arrays can be made dynamic
- **Concurrency**: Thread pool size auto-adjusts to CPU count
- **Plugins**: Isolated address spaces for safety
- **Performance**: Profiling infrastructure for continuous optimization

## Related Documentation

- [Data Structures](DATA_STRUCTURES.md) - Detailed structure documentation
- [Algorithms](ALGORITHMS.md) - Algorithm implementations
- [API Reference](API.md) - Public API documentation
- [Contributing](CONTRIBUTING.md) - How to contribute

## References

- [Zig Language Reference](https://ziglang.org/documentation/master/)
- [POSIX Shell Standard](https://pubs.opengroup.org/onlinepubs/9699919799/)
- [Bash Reference Manual](https://www.gnu.org/software/bash/manual/)
