# Den Plugin System - Quick Reference Summary

## System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Shell (shell.zig)                         │
├─────────────────────────────────────────────────────────────────┤
│  PluginRegistry            PluginManager                         │
│  ├─ Hooks [6 types]        ├─ Plugin instances                  │
│  ├─ Commands               ├─ Lifecycle mgmt                    │
│  └─ Completions            └─ Configuration                     │
└─────────────────────────────────────────────────────────────────┘
         ↑                              ↑
         └──────────┬──────────────────┘
                    │
        ┌───────────┴──────────┐
        │                      │
   PluginAPI              PluginInterface
   (api.zig)              (plugin.zig)
   ├─ registerHook()      ├─ init_fn
   ├─ registerCommand()   ├─ start_fn
   ├─ registerCompletion()├─ stop_fn
   ├─ setConfig()         ├─ shutdown_fn
   ├─ logging             └─ execute_fn
   └─ utilities
```

## Plugin Lifecycle

```
┌─────────────┐
│  unloaded   │
└──────┬──────┘
       │
       ├─ registerPlugin()
       │
       ▼
┌─────────────┐
│   loaded    │
└──────┬──────┘
       │
       ├─ initialize()
       │
       ▼
┌─────────────┐
│ initialized │
└──────┬──────┘
       │
       ├─ start()
       │
       ▼
┌─────────────┐
│   started   │ ◄─ Active, executing commands
└──────┬──────┘
       │
       ├─ stop()
       │
       ▼
┌─────────────┐
│   stopped   │
└──────┬──────┘
       │
       ├─ start() again
       │
       ▼ (or shutdown)
┌──────────────┐
│   unloaded   │
└──────────────┘
       
    Error can occur at any point → error_state
```

## Hook Execution Flow

```
shell.zig triggers hook execution
        │
        ▼
HookContext created with:
  ├─ hook_type
  ├─ data (command string, etc)
  ├─ user_data
  └─ allocator
        │
        ▼
PluginRegistry.executeHooks()
        │
        ├─ Get hooks for type
        ├─ Iterate by priority order (lowest first)
        │
        ├─ For each hook:
        │  ├─ Check enabled flag
        │  ├─ Call hook function
        │  ├─ Capture result + execution time
        │  └─ Handle errors (log, continue)
        │
        ▼
Continue with shell execution
(Hooks cannot prevent/modify execution)
```

## Available Hooks

| Hook | When | Can Access | Can Modify |
|------|------|------------|------------|
| `pre_command` | Before execution | Command string | No |
| `post_command` | After execution | Command string | No |
| `shell_init` | Shell startup | Allocator | No |
| `shell_exit` | Shell shutdown | Allocator | No |
| `pre_prompt` | Before prompt | Allocator | No |
| `post_prompt` | After prompt | Allocator | No |

## API Capabilities Matrix

| Feature | Supported | Notes |
|---------|-----------|-------|
| Register hooks | ✓ | Priority-based ordering |
| Register commands | ✓ | New commands only |
| Register completions | ✓ | Prefix-based matching |
| Configuration | ✓ | Key-value storage |
| Logging | ✓ | Info/debug/warn/error |
| String utilities | ✓ | Split/join/trim/etc |
| Access environment | ✗ | No direct access |
| Access history | ✗ | No direct access |
| Modify commands | ✗ | Can't wrap/override |
| Execute commands | ✗ | Can't run shell commands |
| Access variables | ✗ | Limited to own config |

## Key Files

```
src/plugins/
├─ mod.zig                    → Public exports
├─ plugin.zig                 → Core types
│  ├─ PluginInfo
│  ├─ PluginConfig
│  ├─ PluginInterface
│  └─ PluginState
├─ interface.zig              → Registry
│  ├─ HookType (6 types)
│  ├─ HookContext
│  ├─ Hook
│  ├─ PluginCommand
│  ├─ CompletionProvider
│  └─ PluginRegistry
├─ manager.zig                → Lifecycle mgmt
│  └─ PluginManager
├─ api.zig                    → Plugin API
│  └─ PluginAPI
├─ builtin_plugins.zig        → Simple examples
├─ builtin_plugins_advanced.zig → Complex plugins
├─ example_plugins.zig        → Illustrative examples
├─ discovery.zig              → Manifest parsing (unused)
└─ test_*.zig                 → 93 comprehensive tests
```

## Critical Limitations

### BLOCKING for Production

1. **No Dynamic Loading**
   - Plugins must be compiled into binary
   - Requires full rebuild to add plugin
   - No .so/.dll support

2. **No Isolation**
   - One bad plugin crashes shell
   - No memory/process boundaries
   - No capability restrictions

3. **Silent Error Handling**
   - Hook errors caught and ignored
   - No user feedback on failures
   - Can't debug issues

4. **Limited Shell Access**
   - Can't read environment variables
   - Can't access history directly
   - Can't modify existing commands

### LIMITING for Development

5. **No Dependency Resolution**
   - Manifest exists but unused
   - No version checking
   - Manual dependency management

6. **Incomplete Async**
   - Only stubs, not implemented
   - Shell blocks on slow hooks
   - No timeout enforcement

7. **Hardcoded Limits**
   - Max 32 plugin paths
   - Max 256 commands
   - Buffer-based limits throughout

8. **No Package Management**
   - No plugin registry
   - No install/update mechanism
   - Manual distribution

## Complexity Assessment

### Easy to Implement
- Simple command plugins (30-50 lines)
- Hook-based logging
- Timer/monitoring plugins
- Static completions

### Moderate
- Stateful plugins with persistence
- Multiple hooks with coordination
- Completion providers
- Configuration-driven behavior

### Hard/Not Possible
- Plugins accessing shell internals
- Dynamic command generation
- Complex state machines
- Integration with parser
- Access to environment variables

## Testing Status

- ✓ 93 comprehensive tests
- ✓ 1400+ lines of test code
- ✓ Priority sorting verified
- ✓ Enable/disable tested
- ✓ Lifecycle transitions tested
- ✗ No concurrency tests
- ✗ No resource cleanup tests
- ✗ No timeout verification
- ✗ No error propagation tests

## What Works

```zig
// ✓ Simple command plugin
pub fn myCommand(args: []const []const u8) !i32 {
    std.debug.print("Hello from plugin\n", .{});
    return 0;
}

// ✓ Hook registration
try registry.registerHook("myplugin", .pre_command, myHook, 0);

// ✓ Configuration
try manager.setPluginConfig("myplugin", "key", "value");

// ✓ Multiple plugins, same hook
// Both plugins execute in priority order

// ✓ Hook enable/disable
registry.setHookEnabled("myplugin", .pre_command, false);
```

## What Doesn't Work

```zig
// ✗ Dynamic loading
let plugins = loadPluginsFromDirectory("/path/to/plugins");

// ✗ Command modification
registry.wrapCommand("cd", myCdWrapper);

// ✗ Access shell state
let env = shell.getEnvironment();
let history = shell.getHistory();

// ✗ Prevent command execution
if (isBadCommand()) return error.Rejected;  // No such hook exists

// ✗ Async hooks
registerHookAsync(.pre_command, asyncHook);

// ✗ Execute shell commands
shell.execute("ls -la");

// ✗ Read variables
let value = shell.getVariable("MY_VAR");
```

## Migration Path (if needed)

### Current: Compile-time Plugins
```zig
// Must edit shell.zig
try manager.registerPlugin("name", "1.0", "desc", myplugin);
// Rebuild entire shell binary
```

### Needed: Runtime Plugins
```zig
// Would be like:
try manager.loadPlugin("/path/to/plugin.so");
// No rebuild needed
```

## Recommendations Priority

| Priority | Change | Effort | Impact |
|----------|--------|--------|--------|
| P0 | Error handling | 2h | Can't debug |
| P0 | Shell state access | 1d | Limited usefulness |
| P1 | Dynamic loading | 1w | Currently unusable |
| P1 | Plugin isolation | 2w | Safety critical |
| P2 | Configuration files | 1d | Better UX |
| P2 | Dependency resolution | 3d | Reliability |
| P3 | Package management | 1w | Distribution |
| P3 | Command wrapping | 3d | More powerful |

---

Generated from comprehensive analysis of Den plugin system.
Current status: SOLID ARCHITECTURE, LIMITED IMPLEMENTATION
