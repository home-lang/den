# Plugin Development Guide

This guide explains how to develop plugins for Den Shell. Plugins can extend the shell with custom commands, hooks, and completion providers.

## Table of Contents

- [Overview](#overview)
- [Plugin Architecture](#plugin-architecture)
- [Creating a Plugin](#creating-a-plugin)
- [Plugin Lifecycle](#plugin-lifecycle)
- [Hooks](#hooks)
- [Commands](#commands)
- [Completion Providers](#completion-providers)
- [Plugin API](#plugin-api)
- [Configuration](#configuration)
- [Error Handling](#error-handling)
- [Examples](#examples)
- [Best Practices](#best-practices)

---

## Overview

Den Shell's plugin system allows you to:

- **Register hooks** that run at specific points in the shell lifecycle
- **Add custom commands** that users can invoke
- **Provide completions** for tab completion
- **Access shell state** including environment variables, aliases, and history
- **Log messages** with different severity levels

Plugins are written in Zig and are compiled into the shell.

---

## Plugin Architecture

### Core Components

```
┌─────────────────────────────────────────────────────────────┐
│                        Den Shell                            │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │   Plugin    │  │   Plugin    │  │  Plugin Registry    │  │
│  │  Manager    │──│     API     │──│  - Hooks            │  │
│  │             │  │             │  │  - Commands         │  │
│  └─────────────┘  └─────────────┘  │  - Completions      │  │
│                                     └─────────────────────┘  │
├─────────────────────────────────────────────────────────────┤
│                      Your Plugin                            │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │    Hook     │  │   Command   │  │   Completion        │  │
│  │  Functions  │  │  Functions  │  │   Provider          │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### Key Types

| Type | Description |
|------|-------------|
| `PluginAPI` | Main interface for plugin functionality |
| `PluginRegistry` | Manages registered hooks, commands, and completions |
| `PluginContext` | Simplified wrapper around PluginAPI |
| `HookContext` | Context passed to hook functions |
| `HookType` | Enum of available hook points |

---

## Creating a Plugin

### Basic Structure

```zig
const std = @import("std");
const interface_mod = @import("interface.zig");
const api_mod = @import("api.zig");

const HookContext = interface_mod.HookContext;
const HookType = interface_mod.HookType;
const PluginAPI = api_mod.PluginAPI;

// Plugin state (module-level variables)
var my_state: usize = 0;

// Hook function
pub fn myPreCommand(ctx: *HookContext) !void {
    if (ctx.getCommand()) |cmd| {
        std.debug.print("About to run: {s}\n", .{cmd});
    }
}

// Command function
pub fn myCommand(args: []const []const u8) !i32 {
    if (args.len > 0) {
        std.debug.print("Hello, {s}!\n", .{args[0]});
    } else {
        std.debug.print("Hello, world!\n", .{});
    }
    return 0;  // Exit code
}

// Completion function
pub fn myCompletion(input: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    const suggestions = [_][]const u8{ "option1", "option2", "option3" };

    var matches = std.ArrayList([]const u8).init(allocator);
    for (suggestions) |suggestion| {
        if (std.mem.startsWith(u8, suggestion, input)) {
            try matches.append(try allocator.dupe(u8, suggestion));
        }
    }
    return matches.toOwnedSlice();
}
```

### Registration

Register your plugin components using the PluginAPI:

```zig
pub fn registerPlugin(api: *PluginAPI) !void {
    // Register hooks
    try api.registerHook(.pre_command, myPreCommand, 10);

    // Register commands
    try api.registerCommand("mycommand", "Description of my command", myCommand);

    // Register completions
    try api.registerCompletion("myprefix", myCompletion);

    try api.logInfo("My plugin initialized!", .{});
}
```

---

## Plugin Lifecycle

### States

| State | Description |
|-------|-------------|
| `unloaded` | Plugin not loaded |
| `loaded` | Plugin code loaded |
| `initialized` | `init_fn` called successfully |
| `started` | `start_fn` called, plugin active |
| `stopped` | `stop_fn` called, plugin inactive |
| `error_state` | Plugin encountered an error |

### Lifecycle Functions

```zig
pub const PluginInterface = struct {
    /// Called once after loading
    init_fn: ?*const fn (config: *PluginConfig) anyerror!void,

    /// Called when plugin is activated
    start_fn: ?*const fn (config: *PluginConfig) anyerror!void,

    /// Called when plugin is deactivated
    stop_fn: ?*const fn () anyerror!void,

    /// Called before unloading
    shutdown_fn: ?*const fn () anyerror!void,

    /// Execute plugin command
    execute_fn: ?*const fn (args: []const []const u8) anyerror!i32,
};
```

### Lifecycle Flow

```
load → initialize → start → (active) → stop → shutdown → unload
                      ↑                   │
                      └───────────────────┘
                         (can restart)
```

---

## Hooks

Hooks allow your plugin to run code at specific points in the shell's execution.

### Available Hook Types

| Hook Type | When It Runs |
|-----------|--------------|
| `pre_command` | Before a command is executed |
| `post_command` | After a command completes |
| `pre_prompt` | Before the prompt is displayed |
| `post_prompt` | After user enters input at prompt |
| `shell_init` | When shell initializes |
| `shell_exit` | When shell is exiting |

### Hook Function Signature

```zig
pub const HookFn = *const fn (context: *HookContext) anyerror!void;
```

### Hook Context

```zig
pub const HookContext = struct {
    hook_type: HookType,
    data: ?*anyopaque,        // Hook-specific data
    user_data: ?*anyopaque,   // Your plugin's data
    allocator: std.mem.Allocator,

    /// Get command string (for pre/post_command hooks)
    pub fn getCommand(self: *HookContext) ?[]const u8;

    /// Set user data
    pub fn setUserData(self: *HookContext, data: *anyopaque) void;

    /// Get user data
    pub fn getUserData(self: *HookContext) ?*anyopaque;
};
```

### Hook Priority

Hooks are executed in priority order (lower numbers first):

```zig
// Priority 1 runs before priority 10
try api.registerHook(.pre_command, myHook, 1);    // Runs first
try api.registerHook(.pre_command, otherHook, 10); // Runs second
```

### Example: Command Timer

```zig
var timer_start: i64 = 0;

pub fn timerPreCommand(ctx: *HookContext) !void {
    _ = ctx;
    timer_start = std.time.milliTimestamp();
}

pub fn timerPostCommand(ctx: *HookContext) !void {
    const elapsed = std.time.milliTimestamp() - timer_start;
    if (ctx.getCommand()) |cmd| {
        std.debug.print("[timer] '{s}' took {}ms\n", .{ cmd, elapsed });
    }
}
```

---

## Commands

Plugins can register custom commands that users can invoke.

### Command Function Signature

```zig
pub const CommandFn = *const fn (args: []const []const u8) anyerror!i32;
```

The function receives command arguments and returns an exit code (0 for success).

### Registration

```zig
try api.registerCommand(
    "greet",                    // Command name
    "Greet someone by name",    // Description
    greetCommand,               // Function
);
```

### Example: Greeting Command

```zig
pub fn greetCommand(args: []const []const u8) !i32 {
    if (args.len > 0) {
        std.debug.print("Hello, {s}!\n", .{args[0]});
    } else {
        std.debug.print("Hello, stranger!\n", .{});
    }
    return 0;
}
```

### Example: Calculator Commands

```zig
pub fn addCommand(args: []const []const u8) !i32 {
    if (args.len < 2) {
        std.debug.print("Usage: add <num1> <num2>\n", .{});
        return 1;
    }

    const a = try std.fmt.parseInt(i32, args[0], 10);
    const b = try std.fmt.parseInt(i32, args[1], 10);
    std.debug.print("Result: {}\n", .{a + b});
    return 0;
}
```

---

## Completion Providers

Plugins can provide custom tab completion suggestions.

### Completion Function Signature

```zig
pub const CompletionFn = *const fn (
    input: []const u8,
    allocator: std.mem.Allocator
) anyerror![][]const u8;
```

### Registration

```zig
// Register for commands starting with "myprefix"
try api.registerCompletion("myprefix", myCompletionFn);
```

### Example: Plugin Commands Completion

```zig
pub fn pluginCompletion(input: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    const suggestions = [_][]const u8{
        "plugin:list",
        "plugin:info",
        "plugin:enable",
        "plugin:disable",
    };

    var matches = std.ArrayList([]const u8).init(allocator);
    defer matches.deinit();

    for (suggestions) |suggestion| {
        if (std.mem.startsWith(u8, suggestion, input)) {
            try matches.append(try allocator.dupe(u8, suggestion));
        }
    }

    return try matches.toOwnedSlice();
}
```

---

## Plugin API

The PluginAPI provides access to shell functionality.

### Initialization

```zig
pub fn init(
    allocator: std.mem.Allocator,
    plugin_name: []const u8,
    registry: *PluginRegistry
) !PluginAPI;
```

### Hook Registration

```zig
/// Register a hook
pub fn registerHook(
    self: *PluginAPI,
    hook_type: HookType,
    function: HookFn,
    priority: i32,
) !void;

/// Unregister all hooks for this plugin
pub fn unregisterHooks(self: *PluginAPI) void;
```

### Command Registration

```zig
/// Register a command
pub fn registerCommand(
    self: *PluginAPI,
    name: []const u8,
    description: []const u8,
    function: CommandFn,
) !void;

/// Unregister all commands for this plugin
pub fn unregisterCommands(self: *PluginAPI) void;
```

### Completion Registration

```zig
/// Register a completion provider
pub fn registerCompletion(
    self: *PluginAPI,
    prefix: []const u8,
    function: CompletionFn,
) !void;

/// Unregister all completions for this plugin
pub fn unregisterCompletions(self: *PluginAPI) void;
```

### Shell State Access

```zig
/// Get an environment variable
pub fn getEnvironmentVar(self: *PluginAPI, name: []const u8) ?[]const u8;

/// Get all environment variables
pub fn getAllEnvironmentVars(self: *PluginAPI) ![][2][]const u8;

/// Get current working directory
pub fn getCurrentDirectory(self: *PluginAPI) ?[]const u8;

/// Get command history
pub fn getHistory(self: *PluginAPI) ![][]const u8;

/// Get last exit code
pub fn getLastExitCode(self: *PluginAPI) i32;

/// Get a shell alias
pub fn getAlias(self: *PluginAPI, name: []const u8) ?[]const u8;

/// Get all aliases
pub fn getAllAliases(self: *PluginAPI) ![][2][]const u8;

/// Check if shell access is available
pub fn hasShellAccess(self: *PluginAPI) bool;
```

### Logging

```zig
/// Log levels
pub const LogLevel = enum { debug, info, warn, err };

/// Log at different levels
pub fn logDebug(self: *PluginAPI, comptime format: []const u8, args: anytype) !void;
pub fn logInfo(self: *PluginAPI, comptime format: []const u8, args: anytype) !void;
pub fn logWarn(self: *PluginAPI, comptime format: []const u8, args: anytype) !void;
pub fn logError(self: *PluginAPI, comptime format: []const u8, args: anytype) !void;
```

### Utility Functions

```zig
/// Split a string by delimiter
pub fn splitString(self: *PluginAPI, string: []const u8, delimiter: u8) ![][]const u8;

/// Join strings with delimiter
pub fn joinStrings(self: *PluginAPI, strings: []const []const u8, delimiter: []const u8) ![]const u8;

/// Trim whitespace from string
pub fn trimString(self: *PluginAPI, string: []const u8) ![]const u8;

/// Check if string starts with prefix
pub fn startsWith(self: *PluginAPI, string: []const u8, prefix: []const u8) bool;

/// Check if string ends with suffix
pub fn endsWith(self: *PluginAPI, string: []const u8, suffix: []const u8) bool;

/// Get current timestamp in milliseconds
pub fn timestamp(self: *PluginAPI) i64;
```

---

## Configuration

### Plugin Configuration

```zig
pub const PluginConfig = struct {
    name: []const u8,
    version: []const u8,
    enabled: bool,
    auto_start: bool,
    config_data: std.StringHashMap([]const u8),

    /// Set configuration value
    pub fn set(self: *PluginConfig, key: []const u8, value: []const u8) !void;

    /// Get configuration value
    pub fn get(self: *PluginConfig, key: []const u8) ?[]const u8;
};
```

### API Configuration Methods

```zig
/// Set a configuration value
pub fn setConfig(self: *PluginAPI, key: []const u8, value: []const u8) !void;

/// Get a configuration value
pub fn getConfig(self: *PluginAPI, key: []const u8) ?[]const u8;

/// Get with default
pub fn getConfigOr(self: *PluginAPI, key: []const u8, default: []const u8) []const u8;

/// Check if key exists
pub fn hasConfig(self: *PluginAPI, key: []const u8) bool;
```

---

## Error Handling

### Error Statistics

The plugin registry tracks errors per plugin:

```zig
pub const PluginErrorStats = struct {
    plugin_name: []const u8,
    hook_errors: u64,
    command_errors: u64,
    last_error: ?[]const u8,
    last_error_time: i64,
};
```

### Retrieving Errors

```zig
/// Get error stats for a plugin
pub fn getPluginErrors(self: *PluginRegistry, plugin_name: []const u8) ?PluginErrorStats;

/// Get all plugin errors
pub fn getAllErrors(self: *PluginRegistry) ![]PluginErrorStats;

/// Clear errors for a plugin
pub fn clearPluginErrors(self: *PluginRegistry, plugin_name: []const u8) void;
```

### Error Verbosity

```zig
/// Enable/disable verbose error printing
pub fn setVerboseErrors(self: *PluginRegistry, verbose: bool) void;
```

---

## Examples

### Complete Plugin: Command Counter

```zig
const std = @import("std");
const interface_mod = @import("interface.zig");
const api_mod = @import("api.zig");

const HookContext = interface_mod.HookContext;
const PluginAPI = api_mod.PluginAPI;

// State
var command_count: usize = 0;

// Hooks
pub fn preCommand(ctx: *HookContext) !void {
    _ = ctx;
    command_count += 1;
}

pub fn postCommand(ctx: *HookContext) !void {
    if (ctx.getCommand()) |cmd| {
        std.debug.print("[counter] Command #{}: {s}\n", .{ command_count, cmd });
    }
}

// Commands
pub fn getCount(args: []const []const u8) !i32 {
    _ = args;
    std.debug.print("Total commands: {}\n", .{command_count});
    return 0;
}

pub fn resetCount(args: []const []const u8) !i32 {
    _ = args;
    command_count = 0;
    std.debug.print("Counter reset\n", .{});
    return 0;
}

// Registration
pub fn register(api: *PluginAPI) !void {
    try api.registerHook(.pre_command, preCommand, 10);
    try api.registerHook(.post_command, postCommand, 10);
    try api.registerCommand("cmdcount", "Show command count", getCount);
    try api.registerCommand("cmdreset", "Reset command count", resetCount);
}
```

### Complete Plugin: Command Logger

```zig
const std = @import("std");
const interface_mod = @import("interface.zig");
const api_mod = @import("api.zig");

const HookContext = interface_mod.HookContext;
const PluginAPI = api_mod.PluginAPI;

// State
var log_buffer: [100][]const u8 = undefined;
var log_count: usize = 0;
var log_allocator: std.mem.Allocator = undefined;
var initialized = false;

// Initialize
pub fn init(allocator: std.mem.Allocator) void {
    log_allocator = allocator;
    log_count = 0;
    initialized = true;
}

// Hook
pub fn preCommand(ctx: *HookContext) !void {
    if (!initialized) return;
    if (ctx.getCommand()) |cmd| {
        if (log_count < log_buffer.len) {
            log_buffer[log_count] = try log_allocator.dupe(u8, cmd);
            log_count += 1;
        }
    }
}

// Commands
pub fn showLog(args: []const []const u8) !i32 {
    _ = args;
    std.debug.print("Command log ({} entries):\n", .{log_count});
    for (log_buffer[0..log_count], 0..) |cmd, i| {
        std.debug.print("  [{}] {s}\n", .{ i + 1, cmd });
    }
    return 0;
}

pub fn clearLog(args: []const []const u8) !i32 {
    _ = args;
    for (log_buffer[0..log_count]) |cmd| {
        log_allocator.free(cmd);
    }
    log_count = 0;
    std.debug.print("Log cleared\n", .{});
    return 0;
}

// Cleanup
pub fn shutdown() void {
    if (initialized) {
        for (log_buffer[0..log_count]) |cmd| {
            log_allocator.free(cmd);
        }
        log_count = 0;
        initialized = false;
    }
}
```

---

## Best Practices

### Memory Management

1. **Use the provided allocator** - Don't create your own allocators
2. **Free what you allocate** - Clean up in shutdown/stop functions
3. **Use arena allocators** for temporary allocations within a function

```zig
pub fn myFunction(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Use arena.allocator() for temporary allocations
    const temp = try arena.allocator().alloc(u8, 1024);
    _ = temp;
    // No need to free - arena handles cleanup
}
```

### Error Handling

1. **Return errors rather than panic** - Use `!` return types
2. **Log errors** for debugging
3. **Provide meaningful error messages**

```zig
pub fn myCommand(args: []const []const u8) !i32 {
    if (args.len < 1) {
        std.debug.print("Error: missing required argument\n", .{});
        return 1;
    }

    const value = std.fmt.parseInt(i32, args[0], 10) catch |err| {
        std.debug.print("Error: invalid number: {}\n", .{err});
        return 1;
    };

    std.debug.print("Value: {}\n", .{value});
    return 0;
}
```

### Hook Best Practices

1. **Keep hooks fast** - They run for every command
2. **Use appropriate priorities** - Don't block other plugins
3. **Handle missing data** - Context may not have all fields

```zig
pub fn myHook(ctx: *HookContext) !void {
    // Always check if data is available
    if (ctx.getCommand()) |cmd| {
        // Process command
        _ = cmd;
    }
    // Don't assume data exists
}
```

### State Management

1. **Use module-level variables** for plugin state
2. **Initialize state properly** in init functions
3. **Clean up state** in shutdown functions

```zig
var my_state: ?MyState = null;

pub fn init(allocator: std.mem.Allocator) !void {
    my_state = MyState.init(allocator);
}

pub fn shutdown() void {
    if (my_state) |*state| {
        state.deinit();
        my_state = null;
    }
}
```

### Testing

1. **Write unit tests** for command functions
2. **Test edge cases** (empty args, invalid input)
3. **Test cleanup** to avoid memory leaks

---

## See Also

- [Architecture Overview](./ARCHITECTURE.md)
- [Scripting Guide](./SCRIPTING.md)
- [Builtin Commands](./BUILTINS.md)
- [Configuration Guide](./config.md)
