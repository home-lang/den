# Den Plugin System - Concrete Code Examples

## Example 1: Simple Command Plugin

This is the simplest plugin - just adds a new command.

```zig
// my_command_plugin.zig
const std = @import("std");

pub fn helloWorld(args: []const []const u8) !i32 {
    _ = args; // unused
    std.debug.print("Hello from plugin!\n", .{});
    return 0;
}

// Register in shell.zig:
// try manager.registerPlugin("hello", "1.0.0", "Simple hello plugin", .{
//     .init_fn = null,
//     .start_fn = null,
//     .stop_fn = null,
//     .shutdown_fn = null,
//     .execute_fn = helloWorld,
// });
```

**Complexity:** 5 lines of code
**Capabilities:** Can respond to command invocation
**Limitations:** Can't access shell state, can't modify behavior

---

## Example 2: Hook-Based Monitoring Plugin

Tracks and reports command execution.

```zig
const std = @import("std");
const HookContext = @import("plugins/interface.zig").HookContext;

var command_count: usize = 0;
var total_time_ms: u64 = 0;

pub fn preCommandHook(ctx: *HookContext) !void {
    if (ctx.getCommand()) |cmd| {
        std.debug.print("[monitor] Executing: {s}\n", .{cmd});
    }
}

pub fn postCommandHook(ctx: *HookContext) !void {
    command_count += 1;
    if (ctx.getCommand()) |cmd| {
        std.debug.print("[monitor] Completed: {s} (total: {})\n", .{cmd, command_count});
    }
}

pub fn monitorCommand(args: []const []const u8) !i32 {
    if (args.len == 0) {
        std.debug.print("Commands executed: {}\n", .{command_count});
    } else if (std.mem.eql(u8, args[0], "reset")) {
        command_count = 0;
        std.debug.print("Counter reset\n", .{});
    }
    return 0;
}

// Register in shell.zig:
// try manager.registerPlugin("monitor", "1.0.0", "Command monitor", .{
//     .init_fn = null,
//     .start_fn = null,
//     .stop_fn = null,
//     .shutdown_fn = null,
//     .execute_fn = monitorCommand,
// });
// try registry.registerHook("monitor", .pre_command, preCommandHook, 10);
// try registry.registerHook("monitor", .post_command, postCommandHook, 10);
```

**Complexity:** 30 lines
**Capabilities:** Can monitor command execution, track state
**Limitations:** Can't prevent commands, can't access exit codes

---

## Example 3: Plugin with Configuration

Demonstrates configuration usage.

```zig
const std = @import("std");
const PluginConfig = @import("plugins/plugin.zig").PluginConfig;

pub fn initPlugin(config: *PluginConfig) !void {
    // Set default configuration
    try config.set("enabled", "true");
    try config.set("verbose", "false");
    try config.set("timeout_ms", "5000");
    
    std.debug.print("[plugin] Initialized with config\n", .{});
}

pub fn startPlugin(config: *PluginConfig) !void {
    const enabled = config.get("enabled") orelse "true";
    const verbose = config.get("verbose") orelse "false";
    const timeout = config.get("timeout_ms") orelse "5000";
    
    std.debug.print("[plugin] Started:\n", .{});
    std.debug.print("  enabled: {s}\n", .{enabled});
    std.debug.print("  verbose: {s}\n", .{verbose});
    std.debug.print("  timeout: {s}ms\n", .{timeout});
}

pub fn statusCommand(args: []const []const u8) !i32 {
    _ = args; // unused
    std.debug.print("Plugin is operational\n", .{});
    return 0;
}

// Register in shell.zig:
// try manager.registerPlugin("configured", "1.0.0", "Config plugin", .{
//     .init_fn = initPlugin,
//     .start_fn = startPlugin,
//     .stop_fn = null,
//     .shutdown_fn = null,
//     .execute_fn = statusCommand,
// });
// 
// // Later, modify configuration:
// try manager.setPluginConfig("configured", "verbose", "true");
```

**Complexity:** 40 lines
**Capabilities:** Configuration-driven behavior
**Limitations:** Config is in-memory only, not persistent

---

## Example 4: Multiple Hooks with Priority

Shows how hook priority affects execution order.

```zig
const std = @import("std");
const HookContext = @import("plugins/interface.zig").HookContext;

// Priority 0 = runs first
pub fn firstHook(ctx: *HookContext) !void {
    _ = ctx;
    std.debug.print("[order] 1. First hook (priority 0)\n", .{});
}

// Priority 50 = runs second
pub fn secondHook(ctx: *HookContext) !void {
    _ = ctx;
    std.debug.print("[order] 2. Second hook (priority 50)\n", .{});
}

// Priority 100 = runs third
pub fn thirdHook(ctx: *HookContext) !void {
    _ = ctx;
    std.debug.print("[order] 3. Third hook (priority 100)\n", .{});
}

// Register in shell.zig:
// try registry.registerHook("ordered", .pre_command, firstHook, 0);
// try registry.registerHook("ordered", .pre_command, secondHook, 50);
// try registry.registerHook("ordered", .pre_command, thirdHook, 100);
//
// Output when command executes:
// [order] 1. First hook (priority 0)
// [order] 2. Second hook (priority 50)
// [order] 3. Third hook (priority 100)
```

**Complexity:** 25 lines
**Capabilities:** Control execution order of multiple hooks
**Limitations:** Can only order by priority, no dependencies

---

## Example 5: Stateful Plugin with Buffer

Demonstrates maintaining state across calls.

```zig
const std = @import("std");
const HookContext = @import("plugins/interface.zig").HookContext;

// Buffer to store recent commands
var command_history: [100][]const u8 = undefined;
var history_index: usize = 0;
var allocator: std.mem.Allocator = undefined;

pub fn initHistory(config: *@import("plugins/plugin.zig").PluginConfig) !void {
    _ = config;
    // Note: Would need allocator passed in for real implementation
    history_index = 0;
    std.debug.print("[history] Initialized\n", .{});
}

pub fn recordCommand(ctx: *HookContext) !void {
    if (ctx.getCommand()) |cmd| {
        if (history_index < command_history.len) {
            // In real code, would duplicate string with allocator
            command_history[history_index] = cmd;
            history_index += 1;
            
            if (history_index > 5) {
                std.debug.print("[history] Recorded {} commands\n", .{history_index});
            }
        }
    }
}

pub fn showHistory(args: []const []const u8) !i32 {
    _ = args; // unused
    std.debug.print("Recent commands ({}): \n", .{history_index});
    var i: usize = if (history_index > 10) history_index - 10 else 0;
    while (i < history_index) {
        std.debug.print("  [{}] {s}\n", .{i + 1, command_history[i]});
        i += 1;
    }
    return 0;
}

pub fn clearHistory(args: []const []const u8) !i32 {
    _ = args; // unused
    history_index = 0;
    std.debug.print("[history] Cleared\n", .{});
    return 0;
}

// Register in shell.zig:
// try manager.registerPlugin("history", "1.0.0", "History plugin", .{
//     .init_fn = initHistory,
//     .start_fn = null,
//     .stop_fn = null,
//     .shutdown_fn = null,
//     .execute_fn = showHistory,
// });
// try registry.registerHook("history", .post_command, recordCommand, 0);
```

**Complexity:** 60 lines
**Capabilities:** Maintain state, multiple commands
**Limitations:** Buffer is fixed size, not persistent, not thread-safe

---

## Example 6: Plugin with Completion

Provides command completions.

```zig
const std = @import("std");

pub fn fileCompletion(input: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    // Simple example - return hardcoded matches
    const suggestions = [_][]const u8{
        "file:list",
        "file:view",
        "file:delete",
        "file:compress",
    };
    
    var matches: [10][]const u8 = undefined;
    var match_count: usize = 0;
    
    for (suggestions) |suggestion| {
        if (std.mem.startsWith(u8, suggestion, input)) {
            if (match_count < matches.len) {
                matches[match_count] = try allocator.dupe(u8, suggestion);
                match_count += 1;
            }
        }
    }
    
    const result = try allocator.alloc([]const u8, match_count);
    @memcpy(result, matches[0..match_count]);
    return result;
}

// Register in shell.zig:
// try registry.registerCompletion("file", "file:", fileCompletion);
//
// Usage: User types "file:" and hits TAB
// Receives: ["file:list", "file:view", "file:delete", "file:compress"]
```

**Complexity:** 35 lines
**Capabilities:** Provide custom completions
**Limitations:** Prefix-based only, static suggestions

---

## What You CAN'T Do (Yet)

```zig
// ✗ Cannot prevent command execution
pub fn gatekeeper(ctx: *HookContext) !void {
    if (isBadCommand()) {
        return error.CommandRejected;  // Fails silently, doesn't prevent execution
    }
}

// ✗ Cannot access shell environment
pub fn checkEnv(ctx: *HookContext) !void {
    const path = getenv("PATH");  // Not available through API
}

// ✗ Cannot modify existing commands
try registry.wrapCommand("cd", myCustomCd);  // No such function

// ✗ Cannot execute shell commands
const output = try shell.execute("ls -la");  // Can't call back into shell

// ✗ Cannot access history
const recent = try shell.getHistory(10);  // No API for this

// ✗ Cannot dynamically load plugins
try manager.loadPlugin("/path/to/plugin.so");  // Not implemented
```

---

## Common Patterns

### Pattern 1: Hook Pair (Before/After)

Use `pre_command` and `post_command` hooks together.

```zig
var start_time: i64 = 0;

pub fn beforeCommand(ctx: *HookContext) !void {
    _ = ctx;
    start_time = std.time.milliTimestamp();
}

pub fn afterCommand(ctx: *HookContext) !void {
    const elapsed = std.time.milliTimestamp() - start_time;
    if (ctx.getCommand()) |cmd| {
        std.debug.print("[timer] '{s}' took {}ms\n", .{cmd, elapsed});
    }
}
```

### Pattern 2: Configuration with Defaults

```zig
fn getConfigWithDefault(config: *PluginConfig, key: []const u8, default: []const u8) []const u8 {
    return config.get(key) orelse default;
}
```

### Pattern 3: Optional Callbacks

```zig
// Some plugins don't need all lifecycle callbacks
pub const minimal_plugin = PluginInterface{
    .init_fn = null,
    .start_fn = null,
    .stop_fn = null,
    .shutdown_fn = null,
    .execute_fn = myCommand,  // Only this is needed
};
```

### Pattern 4: State Machine in Plugin

```zig
const PluginState = enum { init, ready, processing, error_state };

var plugin_state: PluginState = .init;

pub fn handleStateTransition(args: []const []const u8) !i32 {
    switch (plugin_state) {
        .init => {
            plugin_state = .ready;
            std.debug.print("Initialized\n", .{});
        },
        .ready => {
            plugin_state = .processing;
            std.debug.print("Processing\n", .{});
        },
        // ... handle other states
        else => return error.InvalidState,
    }
    return 0;
}
```

---

## Integration Checklist

When creating a new plugin:

- [ ] Define PluginInterface struct with callbacks
- [ ] Implement required functions (init_fn, execute_fn, etc)
- [ ] Register plugin with PluginManager
- [ ] Register hooks if needed
- [ ] Register commands if needed
- [ ] Register completions if needed
- [ ] Add to shell.zig imports
- [ ] Test plugin lifecycle
- [ ] Test hook execution
- [ ] Test command invocation
- [ ] Test error handling
- [ ] Document expected behavior
- [ ] Rebuild shell binary

---

## Testing Your Plugin

```zig
test "my plugin - initialization" {
    const allocator = std.testing.allocator;
    var config = PluginConfig.init(allocator, "test", "1.0.0");
    defer config.deinit();
    
    try myInit(&config);
    // Verify initialization
}

test "my plugin - hook execution" {
    const allocator = std.testing.allocator;
    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();
    
    try registry.registerHook("test", .pre_command, myHook, 0);
    
    const cmd = try allocator.dupe(u8, "test command");
    defer allocator.free(cmd);
    
    var ctx = HookContext{
        .hook_type = .pre_command,
        .data = @ptrCast(&cmd),
        .user_data = null,
        .allocator = allocator,
    };
    
    try registry.executeHooks(.pre_command, &ctx);
    // Verify hook was called
}

test "my plugin - command execution" {
    const result = try myCommand(&[_][]const u8{"arg1", "arg2"});
    try std.testing.expectEqual(@as(i32, 0), result);
}
```

---

## Performance Considerations

1. **Hook Execution Time**
   - Keep hooks fast (< 1ms ideal)
   - Slow hooks block the shell
   - Pre_command/post_command run synchronously

2. **Memory Allocation**
   - Plugins are responsible for cleanup
   - Use allocator.alloc/free pairs
   - No garbage collection - manual is critical

3. **Buffer Sizes**
   - Stack-allocated buffers are limited
   - Use ArrayList for dynamic sizes
   - Watch out for stack overflow

4. **Priority System**
   - Lower priority values run first
   - Use 0-100 for ordering
   - Conflicts (same priority) are stable by registration order

---

## Debugging Tips

1. **Hook not executing?**
   - Check if plugin is enabled
   - Verify hook type is correct
   - Check priority value
   - Ensure allocator is passed correctly

2. **Plugin crashes?**
   - Check for null pointer dereferences
   - Verify memory allocation/deallocation pairs
   - Add debug print statements
   - Check hook context data types

3. **Command not working?**
   - Verify command is registered
   - Check command name doesn't conflict
   - Ensure execute_fn is implemented
   - Test with simple debug output

4. **Configuration issues?**
   - Verify config keys are set
   - Check get() returns expected values
   - Remember all values are strings

---

See PLUGIN_SYSTEM_ANALYSIS.md for complete system documentation.
