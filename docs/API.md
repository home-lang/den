# Den Shell API Reference

Complete API documentation for Den Shell's public interfaces.

## Table of Contents

1. [Shell API](#shell-api)
2. [Parser API](#parser-api)
3. [Executor API](#executor-api)
4. [Plugin API](#plugin-api)
5. [Utility APIs](#utility-apis)
6. [Concurrency API](#concurrency-api)

## Shell API

### Shell.init

Initialize a new shell instance.

```zig
pub fn init(allocator: std.mem.Allocator) !Shell
```

**Parameters**:
- `allocator`: Memory allocator for shell lifetime

**Returns**: Initialized `Shell` instance

**Errors**: `OutOfMemory` if allocation fails

**Example**:
```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

var shell = try Shell.init(allocator);
defer shell.deinit();
```

### Shell.deinit

Clean up shell resources.

```zig
pub fn deinit(self: *Shell) void
```

**Cleanup**:
- Frees environment variables
- Frees command history
- Frees background jobs
- Cleanup plugins
- Shutdown thread pool

### Shell.run

Start interactive shell loop.

```zig
pub fn run(self: *Shell) !void
```

**Errors**: I/O errors, allocation errors

**Behavior**:
- Displays prompt
- Reads user input
- Parses and executes commands
- Updates history
- Continues until exit command

### Shell.executeCommand

Execute a single command string.

```zig
pub fn executeCommand(self: *Shell, command: []const u8) !i32
```

**Parameters**:
- `command`: Command string to execute

**Returns**: Exit code (0 for success)

**Example**:
```zig
const exit_code = try shell.executeCommand("ls -la");
```

### Shell.setVariable

Set environment variable.

```zig
pub fn setVariable(self: *Shell, name: []const u8, value: []const u8) !void
```

**Parameters**:
- `name`: Variable name
- `value`: Variable value

**Example**:
```zig
try shell.setVariable("MY_VAR", "my_value");
```

### Shell.getVariable

Get environment variable value.

```zig
pub fn getVariable(self: *Shell, name: []const u8) ?[]const u8
```

**Parameters**:
- `name`: Variable name

**Returns**: Variable value or null if not found

**Example**:
```zig
if (shell.getVariable("HOME")) |home| {
    std.debug.print("Home: {s}\n", .{home});
}
```

## Parser API

### Tokenizer.init

Create tokenizer for input string.

```zig
pub fn init(input: []const u8) Tokenizer
```

**Parameters**:
- `input`: Input string to tokenize

**Example**:
```zig
var tokenizer = Tokenizer.init("echo hello");
```

### Tokenizer.next

Get next token from input.

```zig
pub fn next(self: *Tokenizer) !?Token
```

**Returns**: Next token or null at EOF

**Errors**: `SyntaxError` for invalid syntax

**Example**:
```zig
while (try tokenizer.next()) |token| {
    std.debug.print("Token: {s}\n", .{token.value});
}
```

### Parser.init

Create parser from token stream.

```zig
pub fn init(allocator: std.mem.Allocator, tokens: []Token) Parser
```

**Parameters**:
- `allocator`: Allocator for AST nodes
- `tokens`: Token array from tokenizer

### Parser.parse

Parse tokens into AST.

```zig
pub fn parse(self: *Parser) !*ASTNode
```

**Returns**: Root AST node

**Errors**:
- `SyntaxError`: Invalid syntax
- `OutOfMemory`: Allocation failure

**Example**:
```zig
var tokenizer = Tokenizer.init(input);
const tokens = try tokenizer.tokenize(allocator);

var parser = Parser.init(allocator, tokens);
const ast = try parser.parse();
defer parser.deinit();
```

### Parser.deinit

Free all AST nodes.

```zig
pub fn deinit(self: *Parser) void
```

## Executor API

### Executor.init

Create executor instance.

```zig
pub fn init(allocator: std.mem.Allocator, shell: *Shell) Executor
```

**Parameters**:
- `allocator`: Memory allocator
- `shell`: Shell instance for state access

### Executor.execute

Execute an AST node.

```zig
pub fn execute(self: *Executor, node: *ASTNode) !i32
```

**Parameters**:
- `node`: AST node to execute

**Returns**: Exit code

**Errors**: Execution errors, I/O errors

**Example**:
```zig
var executor = Executor.init(allocator, &shell);
const exit_code = try executor.execute(ast);
```

### Executor.executePipeline

Execute a command pipeline.

```zig
pub fn executePipeline(self: *Executor, commands: []Command) !i32
```

**Parameters**:
- `commands`: Array of commands to pipe

**Returns**: Exit code of last command

**Example**:
```zig
const commands = [_]Command{
    Command{ .name = "cat", .args = &[_][]const u8{"file.txt"} },
    Command{ .name = "grep", .args = &[_][]const u8{"pattern"} },
};
const exit_code = try executor.executePipeline(&commands);
```

### Executor.executeBuiltin

Execute builtin command.

```zig
pub fn executeBuiltin(
    self: *Executor,
    name: []const u8,
    args: []const []const u8,
) !i32
```

**Parameters**:
- `name`: Builtin name (cd, echo, export, etc.)
- `args`: Command arguments

**Returns**: Exit code

## Plugin API

### Plugin Structure

Define a plugin.

```zig
pub const Plugin = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,

    init: *const fn (*PluginContext) anyerror!void,
    deinit: *const fn (*PluginContext) void,

    hooks: []const HookRegistration,
};
```

**Example**:
```zig
pub const MyPlugin = Plugin{
    .name = "my-plugin",
    .version = "1.0.0",
    .description = "My custom plugin",

    .init = init,
    .deinit = deinit,

    .hooks = &[_]HookRegistration{
        .{ .hook_type = .pre_command, .handler = preCommand },
        .{ .hook_type = .post_command, .handler = postCommand },
    },
};

fn init(ctx: *PluginContext) !void {
    // Initialize plugin
}

fn deinit(ctx: *PluginContext) void {
    // Cleanup plugin
}

fn preCommand(ctx: *HookContext) !void {
    const command = @as(*Command, @ptrCast(@alignCast(ctx.data)));
    // Modify or inspect command
}

fn postCommand(ctx: *HookContext) !void {
    const result = @as(*CommandResult, @ptrCast(@alignCast(ctx.data)));
    // Handle result
}
```

### PluginRegistry.register

Register a plugin.

```zig
pub fn register(self: *PluginRegistry, plugin: Plugin) !void
```

**Parameters**:
- `plugin`: Plugin to register

**Errors**: `OutOfMemory`, `PluginExists`

### PluginRegistry.executeHooks

Execute hooks for an event.

```zig
pub fn executeHooks(
    self: *PluginRegistry,
    hook_type: HookType,
    context: *HookContext,
) !void
```

**Parameters**:
- `hook_type`: Type of hook to execute
- `context`: Hook context with event data

**Example**:
```zig
var context = HookContext{
    .hook_type = .pre_command,
    .data = &command,
    .allocator = allocator,
};
try registry.executeHooks(.pre_command, &context);
```

### Hook Types

Available hook types:

```zig
pub const HookType = enum {
    shell_init,      // After shell initialization
    shell_exit,      // Before shell cleanup
    pre_command,     // Before command execution
    post_command,    // After command execution
    pre_prompt,      // Before displaying prompt
    post_prompt,     // After displaying prompt
    completion,      // Custom completions
    highlight,       // Syntax highlighting
};
```

## Utility APIs

### Expansion.expandVariables

Expand variables in string.

```zig
pub fn expandVariables(
    input: []const u8,
    allocator: std.mem.Allocator,
    env: *std.StringHashMap([]const u8),
) ![]const u8
```

**Parameters**:
- `input`: String with variables ($VAR, ${VAR})
- `allocator`: Memory allocator
- `env`: Environment variable map

**Returns**: Expanded string (caller owns)

**Example**:
```zig
const expanded = try Expansion.expandVariables(
    "Hello $USER",
    allocator,
    &shell.environment,
);
defer allocator.free(expanded);
```

### Glob.match

Test if string matches glob pattern.

```zig
pub fn match(pattern: []const u8, text: []const u8) bool
```

**Parameters**:
- `pattern`: Glob pattern (*, ?, [abc])
- `text`: String to test

**Returns**: true if matches

**Example**:
```zig
if (Glob.match("*.txt", "file.txt")) {
    // Matches!
}
```

### Glob.expand

Expand glob pattern to matching files.

```zig
pub fn expand(
    pattern: []const u8,
    allocator: std.mem.Allocator,
) ![][]const u8
```

**Parameters**:
- `pattern`: Glob pattern
- `allocator`: Memory allocator

**Returns**: Array of matching file paths (caller owns)

**Example**:
```zig
const files = try Glob.expand("src/*.zig", allocator);
defer {
    for (files) |file| allocator.free(file);
    allocator.free(files);
}
```

### Completion.complete

Get completions for prefix.

```zig
pub fn complete(
    prefix: []const u8,
    type: CompletionType,
    allocator: std.mem.Allocator,
    shell: *Shell,
) ![]Completion
```

**Parameters**:
- `prefix`: Prefix to complete
- `type`: Completion type (command, file, etc.)
- `allocator`: Memory allocator
- `shell`: Shell instance

**Returns**: Array of completions (caller owns)

**Example**:
```zig
const completions = try Completion.complete(
    "ec",
    .command,
    allocator,
    &shell,
);
defer allocator.free(completions);
```

### BraceExpander.expand

Expand brace expressions.

```zig
pub fn expand(
    input: []const u8,
    allocator: std.mem.Allocator,
) ![][]const u8
```

**Parameters**:
- `input`: String with braces ({a,b,c}, {1..10})
- `allocator`: Memory allocator

**Returns**: Array of expanded strings (caller owns)

**Example**:
```zig
const expanded = try BraceExpander.expand(
    "file{1..3}.txt",
    allocator,
);
defer {
    for (expanded) |s| allocator.free(s);
    allocator.free(expanded);
}
// Result: ["file1.txt", "file2.txt", "file3.txt"]
```

## Concurrency API

### ThreadPool.init

Create thread pool.

```zig
pub fn init(allocator: std.mem.Allocator, thread_count: usize) !ThreadPool
```

**Parameters**:
- `allocator`: Memory allocator
- `thread_count`: Number of threads (0 = auto-detect CPUs)

**Returns**: Initialized thread pool

**Example**:
```zig
var pool = try ThreadPool.init(allocator, 0); // Auto CPU count
defer pool.deinit();
```

### ThreadPool.submit

Submit work to thread pool.

```zig
pub fn submit(
    self: *ThreadPool,
    comptime func: anytype,
    args: anytype,
) !void
```

**Parameters**:
- `func`: Function to execute
- `args`: Function arguments (struct)

**Example**:
```zig
const Args = struct { x: i32, y: i32 };

try pool.submit(struct {
    fn work(args: Args) void {
        std.debug.print("Sum: {}\n", .{args.x + args.y});
    }
}.work, Args{ .x = 1, .y = 2 });
```

### ThreadPool.waitIdle

Wait for all work to complete.

```zig
pub fn waitIdle(self: *ThreadPool) void
```

**Example**:
```zig
try pool.submit(work1, .{});
try pool.submit(work2, .{});
pool.waitIdle(); // Wait for both to finish
```

### AtomicCounter

Lock-free counter.

```zig
pub const AtomicCounter = struct {
    pub fn init() AtomicCounter;
    pub fn increment(self: *AtomicCounter) usize;
    pub fn decrement(self: *AtomicCounter) usize;
    pub fn get(self: *const AtomicCounter) usize;
    pub fn set(self: *AtomicCounter, val: usize) void;
};
```

**Example**:
```zig
var counter = AtomicCounter.init();
_ = counter.increment(); // Returns 1
_ = counter.increment(); // Returns 2
const value = counter.get(); // Returns 2
```

### SPSCQueue

Lock-free queue for single producer/consumer.

```zig
pub fn SPSCQueue(comptime T: type, comptime capacity: usize) type
```

**Example**:
```zig
var queue = SPSCQueue(i32, 1024).init();

// Producer
_ = queue.push(42);

// Consumer
if (queue.pop()) |value| {
    std.debug.print("Got: {}\n", .{value});
}
```

### ParallelScanner

Parallel directory scanning.

```zig
pub const ParallelScanner = struct {
    pub fn init(allocator: std.mem.Allocator, pool: *ThreadPool) ParallelScanner;
    pub fn deinit(self: *ParallelScanner) void;

    pub fn scanDirectories(
        self: *ParallelScanner,
        directories: []const []const u8,
        extension: []const u8,
    ) ![]const []const u8;
};
```

**Example**:
```zig
var scanner = ParallelScanner.init(allocator, &pool);
defer scanner.deinit();

const dirs = [_][]const u8{ "src", "test", "bench" };
const files = try scanner.scanDirectories(&dirs, ".zig");
```

## Error Handling

### Common Errors

```zig
pub const ShellError = error{
    SyntaxError,
    CommandNotFound,
    PermissionDenied,
    FileNotFound,
    InvalidArgument,
    ExecutionFailed,
    OutOfMemory,
};
```

### Error Context

Many functions return error unions:

```zig
const result = functionThatMightFail() catch |err| {
    switch (err) {
        error.CommandNotFound => {
            std.debug.print("Command not found\n", .{});
            return 127;
        },
        error.PermissionDenied => {
            std.debug.print("Permission denied\n", .{});
            return 126;
        },
        else => return err,
    }
};
```

## Best Practices

### 1. Always defer cleanup

```zig
var shell = try Shell.init(allocator);
defer shell.deinit();
```

### 2. Use arena allocators for temporary data

```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();

const temp_data = try arena.allocator().alloc(u8, 1024);
// No need to free individually
```

### 3. Check error returns

```zig
// BAD: Ignoring errors
_ = shell.executeCommand("ls");

// GOOD: Handle errors
const exit_code = shell.executeCommand("ls") catch |err| {
    std.debug.print("Error: {}\n", .{err});
    return err;
};
```

### 4. Use thread pool for I/O

```zig
// Instead of sequential:
for (files) |file| {
    try processFile(file);
}

// Parallel:
for (files) |file| {
    try pool.submit(processFile, .{ .path = file });
}
pool.waitIdle();
```

## Version Compatibility

This API documentation is for Den Shell v0.1.0 using Zig 0.16-dev.

Breaking changes will be noted in:
- Major version increments
- CHANGELOG.md
- Migration guides

## Related Documentation

- [Architecture](ARCHITECTURE.md) - System design
- [Data Structures](DATA_STRUCTURES.md) - Internal structures
- [Algorithms](ALGORITHMS.md) - Implementation details
- [Examples](../examples/) - Code examples
