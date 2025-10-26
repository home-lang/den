# Den Shell Plugin Examples

This directory contains example plugins demonstrating how to extend Den Shell functionality.

## Available Examples

### 1. notify.zig
**Language:** Zig
**Description:** Sends desktop notifications for commands that exceed a time threshold.

**Features:**
- Configurable time threshold
- Cross-platform notifications (Linux/macOS)
- Hooks into post-command execution

**Installation:**
```bash
# Copy to plugins directory
cp notify.zig ~/.config/den/plugins/

# Enable in config
# Add "notify" to plugins.autoload in ~/.config/den/config.jsonc
```

**Configuration:**
```jsonc
{
  "plugins": {
    "notify": {
      "threshold": 10,     // seconds
      "enabled": true
    }
  }
}
```

### 2. weather.sh
**Language:** Shell Script
**Description:** Displays current weather in the prompt using wttr.in API.

**Features:**
- Caching to reduce API calls
- Customizable location and format
- Async updates

**Installation:**
```bash
# Copy and make executable
cp weather.sh ~/.config/den/plugins/
chmod +x ~/.config/den/plugins/weather.sh

# Enable in config
```

**Configuration:**
```bash
export WEATHER_LOCATION="London"
export WEATHER_FORMAT="%c%t"  # icon + temperature
```

## Creating Your Own Plugins

### Plugin Structure

Plugins can be written in:
- **Zig** - Full integration with Den Shell internals
- **Shell Scripts** - Simple, portable plugins
- **Any language** - Via executable interface

### Plugin Interface

All plugins must implement:

```zig
pub const Plugin = struct {
    impl: *anyopaque,
    getName: *const fn (*anyopaque) []const u8,
    getVersion: *const fn (*anyopaque) []const u8,
    getDescription: *const fn (*anyopaque) []const u8,
    onHook: *const fn (*anyopaque, HookType, *HookContext) anyerror!void,
    deinit: *const fn (*anyopaque) void,
};
```

### Hook Types

Available hooks:
- `pre_command` - Before command execution
- `post_command` - After command execution
- `directory_change` - When directory changes
- `pre_prompt` - Before prompt rendering
- `post_prompt` - After prompt rendering
- `shell_start` - When shell starts
- `shell_exit` - Before shell exits

### Example: Minimal Plugin

```zig
const std = @import("std");
const Plugin = @import("../../src/plugins/interface.zig").Plugin;

pub const MyPlugin = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*MyPlugin {
        var plugin = try allocator.create(MyPlugin);
        plugin.* = MyPlugin{ .allocator = allocator };
        return plugin;
    }

    pub fn getName(self: *MyPlugin) []const u8 {
        _ = self;
        return "my-plugin";
    }

    pub fn getVersion(self: *MyPlugin) []const u8 {
        _ = self;
        return "1.0.0";
    }

    pub fn getDescription(self: *MyPlugin) []const u8 {
        _ = self;
        return "My awesome plugin";
    }

    pub fn onHook(
        self: *MyPlugin,
        hook_type: HookType,
        context: *HookContext
    ) !void {
        // Handle hook events
        if (hook_type == .pre_command) {
            std.debug.print("Command about to execute!\n", .{});
        }
    }

    pub fn deinit(self: *MyPlugin) void {
        self.allocator.destroy(self);
    }
};
```

## Plugin Best Practices

1. **Performance**
   - Cache expensive operations
   - Use async operations when possible
   - Minimize startup time

2. **Error Handling**
   - Always handle errors gracefully
   - Don't crash the shell on plugin errors
   - Provide helpful error messages

3. **Configuration**
   - Provide sensible defaults
   - Make behavior configurable
   - Document all options

4. **Testing**
   - Test with different shell configurations
   - Handle edge cases
   - Test performance impact

## Resources

- [Plugin API Documentation](../../docs/plugins.md)
- [Hook System Guide](../../docs/hooks.md)
- [Den Shell Architecture](../../docs/architecture.md)
