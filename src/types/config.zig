const std = @import("std");

/// Main configuration for the Den shell
pub const DenConfig = struct {
    verbose: bool = false,
    stream_output: ?bool = null,

    prompt: PromptConfig = .{},
    history: HistoryConfig = .{},
    completion: CompletionConfig = .{},
    theme: ThemeConfig = .{},
    expansion: ExpansionConfig = .{},
    aliases: AliasConfig = .{},
    keybindings: KeybindingConfig = .{},
};

/// Alias configuration - predefined shell aliases
pub const AliasConfig = struct {
    /// Enable loading aliases from config
    enabled: bool = true,
    /// Custom aliases map (loaded at runtime)
    custom: ?[]const AliasEntry = null,

    pub const AliasEntry = struct {
        name: []const u8,
        command: []const u8,
    };
};

/// Keybinding configuration
pub const KeybindingConfig = struct {
    /// Editing mode: emacs or vi
    mode: EditMode = .emacs,
    /// Custom keybindings
    custom: ?[]const KeybindEntry = null,

    pub const EditMode = enum {
        emacs,
        vi,
    };

    pub const KeybindEntry = struct {
        key: []const u8,
        action: []const u8,
    };
};

pub const PromptConfig = struct {
    format: []const u8 = "{path}{git} {modules} \n{symbol} ",
    show_git: bool = true,
    show_time: bool = false,
    show_user: bool = false,
    show_host: bool = false,
    show_path: bool = true,
    show_exit_code: bool = true,
    right_prompt: ?[]const u8 = null,
    transient: bool = false,
    simple_when_not_tty: bool = true,
};

pub const HistoryConfig = struct {
    max_entries: u32 = 50000,
    file: []const u8 = "~/.den_history",
    ignore_duplicates: bool = true,
    ignore_space: bool = true,
    search_mode: SearchMode = .fuzzy,
    search_limit: ?u32 = null,

    pub const SearchMode = enum {
        fuzzy,
        exact,
        startswith,
        regex,
    };
};

pub const CompletionConfig = struct {
    enabled: bool = true,
    case_sensitive: bool = false,
    show_descriptions: bool = true,
    max_suggestions: u32 = 15,
    cache: CompletionCacheConfig = .{},
};

pub const CompletionCacheConfig = struct {
    enabled: bool = true,
    ttl: u32 = 3600000, // 1 hour in milliseconds
    max_entries: u32 = 1000,
};

pub const ThemeConfig = struct {
    name: []const u8 = "default",
    auto_detect_color_scheme: bool = true,
    enable_right_prompt: bool = true,
    colors: ColorConfig = .{},
    symbols: SymbolConfig = .{},
};

pub const ColorConfig = struct {
    primary: []const u8 = "#00D9FF",
    secondary: []const u8 = "#FF6B9D",
    success: []const u8 = "#00FF88",
    warning: []const u8 = "#FFD700",
    err: []const u8 = "#FF4757",
    info: []const u8 = "#74B9FF",
};

pub const SymbolConfig = struct {
    prompt: []const u8 = "❯",
    continuation: []const u8 = "…",
};

pub const ExpansionConfig = struct {
    cache_limits: CacheLimits = .{},

    pub const CacheLimits = struct {
        arg: u32 = 200,
        exec: u32 = 500,
        arithmetic: u32 = 500,
    };
};

test "DenConfig default values" {
    const config = DenConfig{};
    try std.testing.expect(config.verbose == false);
    try std.testing.expect(config.history.max_entries == 50000);
    try std.testing.expectEqualStrings("~/.den_history", config.history.file);
}
