# Den Shell Data Structures

This document provides comprehensive documentation of all major data structures used in Den Shell.

## Table of Contents

1. [Core Shell Structures](#core-shell-structures)
2. [Parser Structures](#parser-structures)
3. [Executor Structures](#executor-structures)
4. [Plugin Structures](#plugin-structures)
5. [Concurrency Structures](#concurrency-structures)
6. [Utility Structures](#utility-structures)

## Core Shell Structures

### Shell (src/shell.zig)

The main shell state structure that coordinates all subsystems.

```zig
pub const Shell = struct {
    // Memory management
    allocator: std.mem.Allocator,

    // State
    running: bool,

    // Configuration
    config: types.DenConfig,

    // Environment
    environment: std.StringHashMap([]const u8),
    aliases: std.StringHashMap([]const u8),

    // Execution state
    last_exit_code: i32,

    // Background jobs
    background_jobs: [16]?BackgroundJob,
    background_jobs_count: usize,
    next_job_id: usize,
    last_background_pid: std.posix.pid_t,

    // History
    history: [1000]?[]const u8,
    history_count: usize,
    history_file_path: []const u8,

    // Directory stack (pushd/popd)
    dir_stack: [32]?[]const u8,
    dir_stack_count: usize,

    // Positional parameters ($1, $2, etc.)
    positional_params: [64]?[]const u8,
    positional_params_count: usize,

    // Shell identification
    shell_name: []const u8,
    last_arg: []const u8,

    // Shell options
    option_errexit: bool,  // set -e
    option_errtrace: bool, // set -E
    current_line: usize,

    // Subsystems
    script_manager: ScriptManager,
    function_manager: FunctionManager,
    plugin_registry: PluginRegistry,
    plugin_manager: PluginManager,

    // Optional plugins
    auto_suggest: ?AutoSuggestPlugin,
    highlighter: ?HighlightPlugin,
    script_suggester: ?ScriptSuggesterPlugin,

    // Concurrency
    thread_pool: concurrency.ThreadPool,
};
```

**Memory Layout**:
- Total size: ~100KB (dominated by history and job arrays)
- Environment: Dynamic HashMap (grows as needed)
- History: Fixed 1000-entry array
- Background jobs: Fixed 16-entry array
- Directory stack: Fixed 32-entry array
- Positional params: Fixed 64-entry array

**Usage**:
```zig
var shell = try Shell.init(allocator);
defer shell.deinit();

// Set environment variable
try shell.environment.put("MY_VAR", "value");

// Add to history
shell.history[shell.history_count] = try allocator.dupe(u8, "ls -la");
shell.history_count += 1;

// Add background job
shell.background_jobs[0] = BackgroundJob{
    .pid = 1234,
    .job_id = 1,
    .command = try allocator.dupe(u8, "sleep 100"),
    .status = .running,
};
shell.background_jobs_count += 1;
```

### BackgroundJob (src/shell.zig)

Represents a background process.

```zig
pub const BackgroundJob = struct {
    pid: std.posix.pid_t,
    job_id: usize,
    command: []const u8,
    status: JobStatus,
};

pub const JobStatus = enum {
    running,
    stopped,
    done,
};
```

**Lifecycle**:
1. Created when command ends with `&`
2. Tracked in `Shell.background_jobs` array
3. Status updated on SIGCHLD
4. Cleaned up when done

### DenConfig (src/types/config.zig)

Shell configuration structure.

```zig
pub const DenConfig = struct {
    // Prompt configuration
    prompt_format: []const u8 = "$ ",
    prompt_color: PromptColor = .default,

    // History configuration
    history_size: usize = 1000,
    history_file: []const u8 = "~/.den_history",

    // Completion configuration
    completion_enabled: bool = true,
    case_insensitive_completion: bool = false,

    // Feature flags
    enable_auto_suggest: bool = true,
    enable_syntax_highlight: bool = true,

    // Performance
    thread_pool_size: usize = 0, // 0 = auto-detect
};
```

## Parser Structures

### Token (src/parser/tokenizer.zig)

Represents a lexical token from the input.

```zig
pub const Token = struct {
    type: TokenType,
    value: []const u8,
    line: usize,
    column: usize,
};

pub const TokenType = enum {
    // Literals
    word,
    number,
    string,

    // Operators
    pipe,              // |
    pipe_pipe,         // ||
    ampersand,         // &
    ampersand_ampersand, // &&
    semicolon,         // ;
    less_than,         // <
    greater_than,      // >
    double_greater,    // >>

    // Special
    newline,
    eof,

    // Keywords
    kw_if,
    kw_then,
    kw_else,
    kw_elif,
    kw_fi,
    kw_while,
    kw_do,
    kw_done,
    kw_for,
    kw_in,
    kw_case,
    kw_esac,
    kw_function,
};
```

**Memory**: Tokens point into original input string (no copying)

**Usage**:
```zig
var tokenizer = Tokenizer.init(input);
while (try tokenizer.next()) |token| {
    switch (token.type) {
        .word => // Handle word
        .pipe => // Handle pipe
        else => // Handle other
    }
}
```

### ASTNode (src/types/ast.zig)

Abstract syntax tree node representing parsed commands.

```zig
pub const ASTNode = union(enum) {
    command: Command,
    pipeline: Pipeline,
    conditional: Conditional,
    loop: Loop,
    function_def: FunctionDef,
    compound: Compound,
    redirect: Redirect,
};

pub const Command = struct {
    name: []const u8,
    args: [][]const u8,
    redirects: []Redirect,
    env_vars: []EnvVar,
};

pub const Pipeline = struct {
    commands: []ASTNode,
    negate: bool, // For ! pipeline
};

pub const Conditional = struct {
    condition: *ASTNode,
    then_branch: *ASTNode,
    else_branch: ?*ASTNode,
};

pub const Loop = struct {
    type: LoopType,
    condition: *ASTNode,
    body: *ASTNode,
    iterator: ?[]const u8, // For 'for' loops
};

pub const LoopType = enum {
    while_loop,
    until_loop,
    for_loop,
    c_for_loop,
};
```

**Memory Layout**:
- AST nodes are heap-allocated
- Parser owns AST (freed after execution)
- Typical AST size: 100-1000 bytes per command

**Example AST**:
```bash
if [ -f file ]; then cat file | grep pattern; fi
```
```
Conditional {
    condition: Command { name: "[", args: ["-f", "file", "]"] },
    then_branch: Pipeline {
        commands: [
            Command { name: "cat", args: ["file"] },
            Command { name: "grep", args: ["pattern"] }
        ]
    },
    else_branch: null
}
```

### Redirect (src/types/ast.zig)

Represents I/O redirection.

```zig
pub const Redirect = struct {
    type: RedirectType,
    fd: i32,
    target: []const u8,
};

pub const RedirectType = enum {
    input,         // < file
    output,        // > file
    append,        // >> file
    here_doc,      // << EOF
    here_string,   // <<< "string"
    fd_dup,        // 2>&1
};
```

**Examples**:
- `< input.txt`: `Redirect{ .type = .input, .fd = 0, .target = "input.txt" }`
- `> output.txt`: `Redirect{ .type = .output, .fd = 1, .target = "output.txt" }`
- `2>&1`: `Redirect{ .type = .fd_dup, .fd = 2, .target = "1" }`

## Executor Structures

### ProcessInfo (src/executor/process.zig)

Information about a spawned process.

```zig
pub const ProcessInfo = struct {
    pid: std.posix.pid_t,
    pgid: std.posix.pid_t,
    stdin_fd: ?std.posix.fd_t,
    stdout_fd: ?std.posix.fd_t,
    stderr_fd: ?std.posix.fd_t,
    status: ProcessStatus,
};

pub const ProcessStatus = enum {
    running,
    exited,
    signaled,
    stopped,
};
```

### PipelineContext (src/executor/executor.zig)

Context for executing pipelines.

```zig
pub const PipelineContext = struct {
    pipes: []Pipe,
    processes: []ProcessInfo,
    allocator: std.mem.Allocator,
};

pub const Pipe = struct {
    read_fd: std.posix.fd_t,
    write_fd: std.posix.fd_t,
};
```

**Usage**:
```zig
// Execute: cat file | grep pattern | wc -l
var ctx = PipelineContext{
    .pipes = try allocator.alloc(Pipe, 2),  // N-1 pipes for N commands
    .processes = try allocator.alloc(ProcessInfo, 3),
    .allocator = allocator,
};
defer ctx.deinit();

// Create pipes
for (ctx.pipes) |*pipe| {
    var fds: [2]std.posix.fd_t = undefined;
    try std.posix.pipe(&fds);
    pipe.* = Pipe{ .read_fd = fds[0], .write_fd = fds[1] };
}

// Spawn processes with appropriate redirections
// ...
```

## Plugin Structures

### Plugin (src/plugins/interface.zig)

Plugin interface definition.

```zig
pub const Plugin = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,

    init: *const fn (*PluginContext) anyerror!void,
    deinit: *const fn (*PluginContext) void,

    hooks: []const HookRegistration,
};

pub const HookRegistration = struct {
    hook_type: HookType,
    handler: *const fn (*HookContext) anyerror!void,
};

pub const HookType = enum {
    shell_init,
    shell_exit,
    pre_command,
    post_command,
    pre_prompt,
    post_prompt,
    completion,
    highlight,
};
```

### PluginContext (src/plugins/interface.zig)

Context passed to plugin functions.

```zig
pub const PluginContext = struct {
    allocator: std.mem.Allocator,
    shell: *Shell,
    config: *DenConfig,
    user_data: ?*anyopaque,
};
```

### HookContext (src/plugins/interface.zig)

Context passed to hook handlers.

```zig
pub const HookContext = struct {
    hook_type: HookType,
    allocator: std.mem.Allocator,
    data: ?*anyopaque,       // Hook-specific data
    user_data: ?*anyopaque,  // Plugin-specific data
};
```

**Hook Data Types**:
- `pre_command`: `*Command` (can modify)
- `post_command`: `*CommandResult`
- `pre_prompt`: null
- `post_prompt`: `*[]const u8` (prompt string)
- `completion`: `*CompletionRequest`

### PluginRegistry (src/plugins/interface.zig)

Manages registered plugins and hooks.

```zig
pub const PluginRegistry = struct {
    allocator: std.mem.Allocator,
    plugins: std.StringHashMap(Plugin),
    hooks: std.AutoHashMap(HookType, []HookRegistration),
};
```

## Concurrency Structures

### ThreadPool (src/utils/concurrency.zig)

Thread pool for parallel task execution.

```zig
pub const ThreadPool = struct {
    allocator: std.mem.Allocator,
    threads: []std.Thread,
    queue: JobQueue,
    shutdown: std.atomic.Value(bool),
    active_jobs: std.atomic.Value(usize),

    pub fn init(allocator: std.mem.Allocator, thread_count: usize) !ThreadPool;
    pub fn deinit(self: *ThreadPool) void;
    pub fn submit(self: *ThreadPool, comptime func: anytype, args: anytype) !void;
    pub fn waitIdle(self: *ThreadPool) void;
};
```

**Memory Layout**:
- Thread handles: `N * sizeof(std.Thread)` (~8 bytes each)
- Job queue: Dynamic ArrayList
- Total overhead: ~1KB for 8 threads

**Usage**:
```zig
var pool = try ThreadPool.init(allocator, 0); // 0 = auto CPU count
defer pool.deinit();

// Submit work
try pool.submit(processFile, .{ .path = "/path/to/file" });
try pool.submit(processFile, .{ .path = "/path/to/file2" });

// Wait for completion
pool.waitIdle();
```

### AtomicCounter (src/utils/concurrency.zig)

Lock-free counter for metrics.

```zig
pub const AtomicCounter = struct {
    value: std.atomic.Value(usize),

    pub fn init() AtomicCounter;
    pub fn increment(self: *AtomicCounter) usize;
    pub fn decrement(self: *AtomicCounter) usize;
    pub fn get(self: *const AtomicCounter) usize;
    pub fn set(self: *AtomicCounter, val: usize) void;
};
```

**Performance**: 10-100x faster than mutex-protected counter

### SPSCQueue (src/utils/concurrency.zig)

Lock-free single-producer single-consumer queue.

```zig
pub fn SPSCQueue(comptime T: type, comptime capacity: usize) type {
    return struct {
        buffer: [capacity]T,
        read_pos: std.atomic.Value(usize),
        write_pos: std.atomic.Value(usize),

        pub fn init() Self;
        pub fn push(self: *Self, item: T) bool;
        pub fn pop(self: *Self) ?T;
        pub fn isEmpty(self: *const Self) bool;
        pub fn isFull(self: *const Self) bool;
    };
}
```

**Properties**:
- Zero locks (uses atomic operations only)
- Fixed capacity (ring buffer)
- Single producer, single consumer only
- ~100ns push/pop latency

**Usage**:
```zig
var queue = SPSCQueue(i32, 1024).init();

// Producer thread
_ = queue.push(42);

// Consumer thread
if (queue.pop()) |value| {
    std.debug.print("Got: {}\n", .{value});
}
```

### RWLock (src/utils/concurrency.zig)

Reader-writer lock for read-heavy workloads.

```zig
pub const RWLock = struct {
    mutex: std.Thread.Mutex,
    readers: usize,
    writer: bool,
    read_cond: std.Thread.Condition,
    write_cond: std.Thread.Condition,

    pub fn init() RWLock;
    pub fn lockRead(self: *RWLock) void;
    pub fn unlockRead(self: *RWLock) void;
    pub fn lockWrite(self: *RWLock) void;
    pub fn unlockWrite(self: *RWLock) void;
};
```

**Use Cases**:
- Configuration data (many reads, few writes)
- Cached data
- Lookup tables

### ConcurrentHashMap (src/utils/parallel_discovery.zig)

Sharded hash map for reduced lock contention.

```zig
pub fn ConcurrentHashMap(
    comptime K: type,
    comptime V: type,
    comptime shard_count: usize,
) type {
    return struct {
        shards: [shard_count]Shard,
        allocator: std.mem.Allocator,

        const Shard = struct {
            map: std.AutoHashMap(K, V),
            mutex: std.Thread.Mutex,
        };

        pub fn init(allocator: std.mem.Allocator) Self;
        pub fn deinit(self: *Self) void;
        pub fn put(self: *Self, key: K, value: V) !void;
        pub fn get(self: *Self, key: K) ?V;
        pub fn remove(self: *Self, key: K) bool;
        pub fn count(self: *Self) usize;
    };
}
```

**Properties**:
- N shards = N times less contention
- Hash-based distribution
- Per-shard locking
- Typical: 16 shards

## Utility Structures

### Completion (src/utils/completion.zig)

Completion entry for tab completion.

```zig
pub const Completion = struct {
    value: []const u8,
    description: ?[]const u8,
    type: CompletionType,
};

pub const CompletionType = enum {
    command,
    file,
    directory,
    variable,
    alias,
    function,
    builtin,
};
```

### GlobPattern (src/utils/glob.zig)

Compiled glob pattern for matching.

```zig
pub const GlobPattern = struct {
    pattern: []const u8,
    segments: []Segment,

    pub const Segment = union(enum) {
        literal: []const u8,
        star: void,
        double_star: void,
        question: void,
        char_class: []const u8,
    };
};
```

**Usage**:
```zig
var pattern = try GlobPattern.compile("*.txt", allocator);
defer pattern.deinit();

if (pattern.matches("file.txt")) {
    // Match!
}
```

### ExpansionResult (src/utils/expansion.zig)

Result of variable/command expansion.

```zig
pub const ExpansionResult = struct {
    values: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ExpansionResult) void {
        for (self.values) |value| {
            self.allocator.free(value);
        }
        self.allocator.free(self.values);
    }
};
```

## Memory Ownership Patterns

### 1. Shell Owns Long-Lived Data

```zig
// Shell allocates and owns
shell.environment.put("VAR", try allocator.dupe(u8, "value"));

// Shell frees in deinit
var iter = shell.environment.iterator();
while (iter.next()) |entry| {
    allocator.free(entry.value_ptr.*);
}
```

### 2. Parser Owns AST (Temporary)

```zig
// Parser allocates AST
var ast = try parser.parse();

// Execute
try executor.execute(ast);

// Parser frees AST
parser.deinit();  // Frees all AST nodes
```

### 3. Caller Owns Results

```zig
// Function allocates and returns
pub fn expand(input: []const u8, allocator: Allocator) ![][]const u8 {
    var result = std.ArrayList([]const u8).init(allocator);
    // ... expand ...
    return result.toOwnedSlice();
}

// Caller must free
const expanded = try expand("$VAR", allocator);
defer {
    for (expanded) |value| allocator.free(value);
    allocator.free(expanded);
}
```

## Size Reference

Typical memory footprint of major structures:

| Structure | Size | Notes |
|-----------|------|-------|
| Shell | ~100KB | Dominated by history/job arrays |
| Token | 40 bytes | Points into source string |
| ASTNode | 100-200 bytes | Varies by type |
| Command | 50-100 bytes | Plus args array |
| ProcessInfo | 64 bytes | Plus file descriptors |
| Plugin | 100 bytes | Plus state |
| ThreadPool | ~1KB | Plus N threads |
| AtomicCounter | 8 bytes | Single atomic value |
| SPSCQueue | capacity * sizeof(T) | Fixed-size buffer |

## Performance Characteristics

| Operation | Complexity | Notes |
|-----------|-----------|-------|
| Environment lookup | O(1) | HashMap |
| History lookup | O(n) | Linear search, cached |
| Alias lookup | O(1) | HashMap |
| Job lookup | O(n) | Small N (max 16) |
| Token generation | O(n) | Linear scan |
| AST building | O(n) | Recursive descent |
| Glob matching | O(n*m) | Pattern * filename |
| Thread pool submit | O(1) | Lock + append |
| Atomic counter | O(1) | Lock-free |
| SPSC queue push/pop | O(1) | Lock-free |

## Related Documentation

- [Architecture](ARCHITECTURE.md) - System architecture
- [Algorithms](ALGORITHMS.md) - Algorithm implementations
- [API Reference](API.md) - Public APIs
- [Memory Optimization](MEMORY_OPTIMIZATION.md) - Memory optimization techniques
