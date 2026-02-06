const std = @import("std");
const interface_mod = @import("interface.zig");
const HookContext = interface_mod.HookContext;
const CompletionFn = interface_mod.CompletionFn;

/// Auto-suggest Plugin
/// Suggests commands based on history and available commands
pub const AutoSuggestPlugin = struct {
    allocator: std.mem.Allocator,
    history: *[1000]?[]const u8,
    history_count: *usize,
    environment: *std.StringHashMap([]const u8),
    enabled: bool,
    max_suggestions: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        history: *[1000]?[]const u8,
        history_count: *usize,
        environment: *std.StringHashMap([]const u8),
    ) AutoSuggestPlugin {
        return .{
            .allocator = allocator,
            .history = history,
            .history_count = history_count,
            .environment = environment,
            .enabled = true,
            .max_suggestions = 5,
        };
    }

    /// Get command suggestions based on partial input
    pub fn getSuggestions(self: *AutoSuggestPlugin, input: []const u8) ![][]const u8 {
        if (!self.enabled or input.len == 0) {
            return try self.allocator.alloc([]const u8, 0);
        }

        var suggestions_buffer: [100][]const u8 = undefined;
        var suggestions_count: usize = 0;
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        // Search history for matching commands (most recent first)
        var i: usize = self.history_count.*;
        while (i > 0 and suggestions_count < self.max_suggestions) {
            i -= 1;
            if (self.history.*[i]) |cmd| {
                if (std.mem.startsWith(u8, cmd, input)) {
                    // Avoid duplicates
                    const contains = seen.contains(cmd);
                    if (!contains) {
                        try seen.put(cmd, {});
                        if (suggestions_count < suggestions_buffer.len) {
                            suggestions_buffer[suggestions_count] = try self.allocator.dupe(u8, cmd);
                            suggestions_count += 1;
                        }
                    }
                }
            }
        }

        // Add common builtin commands if they match
        const builtins = [_][]const u8{
            "cd", "echo", "pwd", "export", "exit", "source",
            "alias", "unalias", "history", "jobs", "fg", "bg",
            "test", "read", "printf", "true", "false", "sleep",
        };

        for (builtins) |builtin| {
            if (suggestions_count >= self.max_suggestions) break;
            if (std.mem.startsWith(u8, builtin, input)) {
                const contains = seen.contains(builtin);
                if (!contains) {
                    try seen.put(builtin, {});
                    if (suggestions_count < suggestions_buffer.len) {
                        suggestions_buffer[suggestions_count] = try self.allocator.dupe(u8, builtin);
                        suggestions_count += 1;
                    }
                }
            }
        }

        const result = try self.allocator.alloc([]const u8, suggestions_count);
        @memcpy(result, suggestions_buffer[0..suggestions_count]);
        return result;
    }

    /// Completion function for plugin registry
    pub fn complete(input: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
        // This is a simplified version for static registration
        // In practice, would need access to plugin instance
        _ = input;
        return try allocator.alloc([]const u8, 0);
    }

    pub fn setEnabled(self: *AutoSuggestPlugin, enabled: bool) void {
        self.enabled = enabled;
    }

    pub fn setMaxSuggestions(self: *AutoSuggestPlugin, max: usize) void {
        self.max_suggestions = max;
    }
};

/// Highlight Plugin
/// Provides syntax highlighting information for commands
pub const HighlightPlugin = struct {
    allocator: std.mem.Allocator,
    enabled: bool,
    highlight_builtins: bool,
    highlight_paths: bool,
    highlight_errors: bool,

    pub const TokenType = enum {
        command,
        builtin,
        option,
        path,
        string,
        number,
        operator,
        error_token,
        normal,
    };

    pub const HighlightToken = struct {
        start: usize,
        end: usize,
        token_type: TokenType,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *HighlightToken) void {
            _ = self;
        }
    };

    pub fn init(allocator: std.mem.Allocator) HighlightPlugin {
        return .{
            .allocator = allocator,
            .enabled = true,
            .highlight_builtins = true,
            .highlight_paths = true,
            .highlight_errors = true,
        };
    }

    /// Analyze input and return highlighting tokens
    pub fn highlight(self: *HighlightPlugin, input: []const u8) ![]HighlightToken {
        if (!self.enabled or input.len == 0) {
            return try self.allocator.alloc(HighlightToken, 0);
        }

        var tokens_buffer: [100]HighlightToken = undefined;
        var tokens_count: usize = 0;

        // Simple tokenizer for highlighting
        var i: usize = 0;
        var in_string = false;
        var string_char: u8 = 0;

        while (i < input.len) {
            // Skip whitespace
            while (i < input.len and std.ascii.isWhitespace(input[i])) {
                i += 1;
            }
            if (i >= input.len) break;

            const start = i;

            // Check for strings
            if (input[i] == '"' or input[i] == '\'') {
                string_char = input[i];
                in_string = true;
                i += 1;
                while (i < input.len and (in_string and input[i] != string_char)) {
                    if (input[i] == '\\' and i + 1 < input.len) {
                        i += 2; // Skip escape sequence
                    } else {
                        i += 1;
                    }
                }
                if (i < input.len) i += 1; // Skip closing quote

                if (tokens_count < tokens_buffer.len) {
                    tokens_buffer[tokens_count] = .{
                        .start = start,
                        .end = i,
                        .token_type = .string,
                        .allocator = self.allocator,
                    };
                    tokens_count += 1;
                }
                in_string = false;
                continue;
            }

            // Check for options (starting with -)
            if (input[i] == '-') {
                while (i < input.len and !std.ascii.isWhitespace(input[i])) {
                    i += 1;
                }
                if (tokens_count < tokens_buffer.len) {
                    tokens_buffer[tokens_count] = .{
                        .start = start,
                        .end = i,
                        .token_type = .option,
                        .allocator = self.allocator,
                    };
                    tokens_count += 1;
                }
                continue;
            }

            // Check for operators
            if (input[i] == '|' or input[i] == '&' or input[i] == '>' or input[i] == '<' or input[i] == ';') {
                while (i < input.len and (input[i] == '|' or input[i] == '&' or input[i] == '>' or input[i] == '<' or input[i] == ';')) {
                    i += 1;
                }
                if (tokens_count < tokens_buffer.len) {
                    tokens_buffer[tokens_count] = .{
                        .start = start,
                        .end = i,
                        .token_type = .operator,
                        .allocator = self.allocator,
                    };
                    tokens_count += 1;
                }
                continue;
            }

            // Regular word
            while (i < input.len and !std.ascii.isWhitespace(input[i])) {
                i += 1;
            }

            const word = input[start..i];
            const token_type = self.classifyWord(word);

            if (tokens_count < tokens_buffer.len) {
                tokens_buffer[tokens_count] = .{
                    .start = start,
                    .end = i,
                    .token_type = token_type,
                    .allocator = self.allocator,
                };
                tokens_count += 1;
            }
        }

        const result = try self.allocator.alloc(HighlightToken, tokens_count);
        @memcpy(result, tokens_buffer[0..tokens_count]);
        return result;
    }

    fn classifyWord(self: *HighlightPlugin, word: []const u8) TokenType {
        // Check if it's a builtin
        if (self.highlight_builtins and self.isBuiltin(word)) {
            return .builtin;
        }

        // Check if it's a number
        if (self.isNumber(word)) {
            return .number;
        }

        // Check if it looks like a path
        if (self.highlight_paths and self.isPath(word)) {
            return .path;
        }

        return .command;
    }

    fn isBuiltin(self: *HighlightPlugin, word: []const u8) bool {
        _ = self;
        const builtins = [_][]const u8{
            "cd", "echo", "pwd", "export", "exit", "source",
            "alias", "unalias", "history", "jobs", "fg", "bg",
            "test", "read", "printf", "true", "false", "sleep",
            "if", "then", "else", "elif", "fi", "while", "do",
            "done", "for", "case", "esac", "function",
        };

        for (builtins) |builtin| {
            if (std.mem.eql(u8, word, builtin)) {
                return true;
            }
        }
        return false;
    }

    fn isNumber(self: *HighlightPlugin, word: []const u8) bool {
        _ = self;
        if (word.len == 0) return false;
        for (word) |c| {
            if (!std.ascii.isDigit(c) and c != '.' and c != '-') {
                return false;
            }
        }
        return true;
    }

    fn isPath(self: *HighlightPlugin, word: []const u8) bool {
        _ = self;
        if (word.len == 0) return false;
        // Simple heuristic: contains / or starts with . or ~
        return std.mem.indexOf(u8, word, "/") != null or
            word[0] == '.' or
            word[0] == '~';
    }

    pub fn setEnabled(self: *HighlightPlugin, enabled: bool) void {
        self.enabled = enabled;
    }
};

/// Script Suggester Plugin
/// Suggests executable scripts from PATH and common locations
pub const ScriptSuggesterPlugin = struct {
    allocator: std.mem.Allocator,
    enabled: bool,
    cache_scripts: bool,
    cached_scripts: ?[][]const u8,
    cache_valid: bool,

    pub fn init(allocator: std.mem.Allocator) ScriptSuggesterPlugin {
        return .{
            .allocator = allocator,
            .enabled = true,
            .cache_scripts = true,
            .cached_scripts = null,
            .cache_valid = false,
        };
    }

    pub fn deinit(self: *ScriptSuggesterPlugin) void {
        if (self.cached_scripts) |scripts| {
            for (scripts) |script| {
                self.allocator.free(script);
            }
            self.allocator.free(scripts);
        }
    }

    /// Get script suggestions based on input
    pub fn getSuggestions(self: *ScriptSuggesterPlugin, input: []const u8, environment: *std.StringHashMap([]const u8)) ![][]const u8 {
        if (!self.enabled or input.len == 0) {
            return try self.allocator.alloc([]const u8, 0);
        }

        // Get or refresh cache
        if (self.cache_scripts and !self.cache_valid) {
            try self.refreshCache(environment);
        }

        var suggestions_buffer: [50][]const u8 = undefined;
        var suggestions_count: usize = 0;

        // Search cached scripts
        if (self.cached_scripts) |scripts| {
            for (scripts) |script| {
                if (suggestions_count >= suggestions_buffer.len) break;
                if (std.mem.startsWith(u8, script, input)) {
                    suggestions_buffer[suggestions_count] = try self.allocator.dupe(u8, script);
                    suggestions_count += 1;
                }
            }
        }

        const result = try self.allocator.alloc([]const u8, suggestions_count);
        @memcpy(result, suggestions_buffer[0..suggestions_count]);
        return result;
    }

    /// Refresh the cache of available scripts
    fn refreshCache(self: *ScriptSuggesterPlugin, environment: *std.StringHashMap([]const u8)) !void {
        // Clear existing cache
        if (self.cached_scripts) |scripts| {
            for (scripts) |script| {
                self.allocator.free(script);
            }
            self.allocator.free(scripts);
            self.cached_scripts = null;
        }

        var scripts_buffer: [500][]const u8 = undefined;
        var scripts_count: usize = 0;

        // Get PATH environment variable
        const path = environment.get("PATH") orelse return;

        // Split PATH and scan each directory
        var path_iter = std.mem.splitScalar(u8, path, ':');
        while (path_iter.next()) |dir_path| {
            if (dir_path.len == 0) continue;

            // Try to open directory
            var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, dir_path, .{ .iterate = true }) catch continue;
            defer dir.close(std.Options.debug_io);

            // Iterate files
            var iter = dir.iterate();
            while (iter.next() catch null) |entry| {
                if (entry.kind == .file) {
                    // Check if executable (simplified - would need stat in real impl)
                    if (scripts_count < scripts_buffer.len) {
                        scripts_buffer[scripts_count] = try self.allocator.dupe(u8, entry.name);
                        scripts_count += 1;
                    }
                }
            }
        }

        // Sort scripts alphabetically
        if (scripts_count > 0) {
            const scripts_slice = scripts_buffer[0..scripts_count];
            std.mem.sort([]const u8, scripts_slice, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.lessThan);
        }

        // Store in cache
        const result = try self.allocator.alloc([]const u8, scripts_count);
        @memcpy(result, scripts_buffer[0..scripts_count]);
        self.cached_scripts = result;
        self.cache_valid = true;
    }

    /// Invalidate cache (call when PATH changes)
    pub fn invalidateCache(self: *ScriptSuggesterPlugin) void {
        self.cache_valid = false;
    }

    pub fn setEnabled(self: *ScriptSuggesterPlugin, enabled: bool) void {
        self.enabled = enabled;
    }

    /// Completion function for plugin registry
    pub fn complete(input: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
        // Simplified static version
        _ = input;
        return try allocator.alloc([]const u8, 0);
    }
};
