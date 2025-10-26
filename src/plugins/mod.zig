// Plugin system module exports

pub const Plugin = @import("plugin.zig").Plugin;
pub const PluginInfo = @import("plugin.zig").PluginInfo;
pub const PluginConfig = @import("plugin.zig").PluginConfig;
pub const PluginInterface = @import("plugin.zig").PluginInterface;
pub const PluginState = @import("plugin.zig").PluginState;

pub const PluginManager = @import("manager.zig").PluginManager;

pub const HookType = @import("interface.zig").HookType;
pub const HookContext = @import("interface.zig").HookContext;
pub const HookFn = @import("interface.zig").HookFn;
pub const Hook = @import("interface.zig").Hook;
pub const PluginCommand = @import("interface.zig").PluginCommand;
pub const CommandFn = @import("interface.zig").CommandFn;
pub const CompletionProvider = @import("interface.zig").CompletionProvider;
pub const CompletionFn = @import("interface.zig").CompletionFn;
pub const PluginRegistry = @import("interface.zig").PluginRegistry;

// Example plugins
pub const example_plugins = @import("example_plugins.zig");

// Builtin plugins
pub const AutoSuggestPlugin = @import("builtin_plugins_advanced.zig").AutoSuggestPlugin;
pub const HighlightPlugin = @import("builtin_plugins_advanced.zig").HighlightPlugin;
pub const ScriptSuggesterPlugin = @import("builtin_plugins_advanced.zig").ScriptSuggesterPlugin;
