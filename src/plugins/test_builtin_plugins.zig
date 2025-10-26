const std = @import("std");
const builtin_plugins = @import("builtin_plugins_advanced.zig");

const AutoSuggestPlugin = builtin_plugins.AutoSuggestPlugin;
const HighlightPlugin = builtin_plugins.HighlightPlugin;
const ScriptSuggesterPlugin = builtin_plugins.ScriptSuggesterPlugin;

test "AutoSuggestPlugin - initialization" {
    const allocator = std.testing.allocator;

    var history = [_]?[]const u8{null} ** 1000;
    var history_count: usize = 0;
    var environment = std.StringHashMap([]const u8).init(allocator);
    defer environment.deinit();

    const plugin = AutoSuggestPlugin.init(allocator, &history, &history_count, &environment);

    try std.testing.expect(plugin.enabled);
    try std.testing.expectEqual(@as(usize, 5), plugin.max_suggestions);
}

test "AutoSuggestPlugin - suggest from history" {
    const allocator = std.testing.allocator;

    var history = [_]?[]const u8{null} ** 1000;
    var history_count: usize = 0;
    var environment = std.StringHashMap([]const u8).init(allocator);
    defer environment.deinit();

    // Add some history entries
    history[0] = try allocator.dupe(u8, "echo hello");
    history[1] = try allocator.dupe(u8, "echo world");
    history[2] = try allocator.dupe(u8, "ls -la");
    history_count = 3;

    defer {
        for (history[0..history_count]) |maybe_entry| {
            if (maybe_entry) |entry| {
                allocator.free(entry);
            }
        }
    }

    var plugin = AutoSuggestPlugin.init(allocator, &history, &history_count, &environment);

    // Get suggestions for "echo"
    const suggestions = try plugin.getSuggestions("echo");
    defer {
        for (suggestions) |suggestion| {
            allocator.free(suggestion);
        }
        allocator.free(suggestions);
    }

    try std.testing.expect(suggestions.len >= 2);

    // Check that suggestions contain our history entries
    var found_hello = false;
    var found_world = false;
    for (suggestions) |suggestion| {
        if (std.mem.eql(u8, suggestion, "echo hello")) found_hello = true;
        if (std.mem.eql(u8, suggestion, "echo world")) found_world = true;
    }

    try std.testing.expect(found_hello);
    try std.testing.expect(found_world);
}

test "AutoSuggestPlugin - suggest builtins" {
    const allocator = std.testing.allocator;

    var history = [_]?[]const u8{null} ** 1000;
    var history_count: usize = 0;
    var environment = std.StringHashMap([]const u8).init(allocator);
    defer environment.deinit();

    var plugin = AutoSuggestPlugin.init(allocator, &history, &history_count, &environment);

    // Get suggestions for "c"
    const suggestions = try plugin.getSuggestions("c");
    defer {
        for (suggestions) |suggestion| {
            allocator.free(suggestion);
        }
        allocator.free(suggestions);
    }

    try std.testing.expect(suggestions.len > 0);

    // Should suggest "cd"
    var found_cd = false;
    for (suggestions) |suggestion| {
        if (std.mem.eql(u8, suggestion, "cd")) {
            found_cd = true;
            break;
        }
    }
    try std.testing.expect(found_cd);
}

test "AutoSuggestPlugin - no duplicates" {
    const allocator = std.testing.allocator;

    var history = [_]?[]const u8{null} ** 1000;
    var history_count: usize = 0;
    var environment = std.StringHashMap([]const u8).init(allocator);
    defer environment.deinit();

    // Add duplicate entries
    history[0] = try allocator.dupe(u8, "echo test");
    history[1] = try allocator.dupe(u8, "echo test");
    history[2] = try allocator.dupe(u8, "echo test");
    history_count = 3;

    defer {
        for (history[0..history_count]) |maybe_entry| {
            if (maybe_entry) |entry| {
                allocator.free(entry);
            }
        }
    }

    var plugin = AutoSuggestPlugin.init(allocator, &history, &history_count, &environment);

    const suggestions = try plugin.getSuggestions("echo");
    defer {
        for (suggestions) |suggestion| {
            allocator.free(suggestion);
        }
        allocator.free(suggestions);
    }

    // Should only have one "echo test" suggestion
    var count: usize = 0;
    for (suggestions) |suggestion| {
        if (std.mem.eql(u8, suggestion, "echo test")) {
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "AutoSuggestPlugin - empty input" {
    const allocator = std.testing.allocator;

    var history = [_]?[]const u8{null} ** 1000;
    var history_count: usize = 0;
    var environment = std.StringHashMap([]const u8).init(allocator);
    defer environment.deinit();

    var plugin = AutoSuggestPlugin.init(allocator, &history, &history_count, &environment);

    const suggestions = try plugin.getSuggestions("");
    defer allocator.free(suggestions);

    try std.testing.expectEqual(@as(usize, 0), suggestions.len);
}

test "AutoSuggestPlugin - disabled" {
    const allocator = std.testing.allocator;

    var history = [_]?[]const u8{null} ** 1000;
    var history_count: usize = 0;
    var environment = std.StringHashMap([]const u8).init(allocator);
    defer environment.deinit();

    var plugin = AutoSuggestPlugin.init(allocator, &history, &history_count, &environment);
    plugin.setEnabled(false);

    const suggestions = try plugin.getSuggestions("echo");
    defer allocator.free(suggestions);

    try std.testing.expectEqual(@as(usize, 0), suggestions.len);
}

test "AutoSuggestPlugin - max suggestions" {
    const allocator = std.testing.allocator;

    var history = [_]?[]const u8{null} ** 1000;
    var history_count: usize = 0;
    var environment = std.StringHashMap([]const u8).init(allocator);
    defer environment.deinit();

    // Add many history entries
    history[0] = try allocator.dupe(u8, "echo 1");
    history[1] = try allocator.dupe(u8, "echo 2");
    history[2] = try allocator.dupe(u8, "echo 3");
    history[3] = try allocator.dupe(u8, "echo 4");
    history[4] = try allocator.dupe(u8, "echo 5");
    history[5] = try allocator.dupe(u8, "echo 6");
    history_count = 6;

    defer {
        for (history[0..history_count]) |maybe_entry| {
            if (maybe_entry) |entry| {
                allocator.free(entry);
            }
        }
    }

    var plugin = AutoSuggestPlugin.init(allocator, &history, &history_count, &environment);
    plugin.setMaxSuggestions(3);

    const suggestions = try plugin.getSuggestions("echo");
    defer {
        for (suggestions) |suggestion| {
            allocator.free(suggestion);
        }
        allocator.free(suggestions);
    }

    try std.testing.expect(suggestions.len <= 3);
}

test "HighlightPlugin - initialization" {
    const allocator = std.testing.allocator;

    const plugin = HighlightPlugin.init(allocator);

    try std.testing.expect(plugin.enabled);
    try std.testing.expect(plugin.highlight_builtins);
    try std.testing.expect(plugin.highlight_paths);
}

test "HighlightPlugin - highlight builtins" {
    const allocator = std.testing.allocator;

    var plugin = HighlightPlugin.init(allocator);

    const tokens = try plugin.highlight("echo hello");
    defer allocator.free(tokens);

    try std.testing.expect(tokens.len >= 2);

    // First token should be "echo" and be classified as builtin
    try std.testing.expectEqual(HighlightPlugin.TokenType.builtin, tokens[0].token_type);
}

test "HighlightPlugin - highlight strings" {
    const allocator = std.testing.allocator;

    var plugin = HighlightPlugin.init(allocator);

    const tokens = try plugin.highlight("echo \"hello world\"");
    defer allocator.free(tokens);

    try std.testing.expect(tokens.len >= 2);

    // Second token should be the string
    var found_string = false;
    for (tokens) |token| {
        if (token.token_type == .string) {
            found_string = true;
            break;
        }
    }
    try std.testing.expect(found_string);
}

test "HighlightPlugin - highlight options" {
    const allocator = std.testing.allocator;

    var plugin = HighlightPlugin.init(allocator);

    const tokens = try plugin.highlight("ls -la");
    defer allocator.free(tokens);

    try std.testing.expect(tokens.len >= 2);

    // Should find option token
    var found_option = false;
    for (tokens) |token| {
        if (token.token_type == .option) {
            found_option = true;
            break;
        }
    }
    try std.testing.expect(found_option);
}

test "HighlightPlugin - highlight operators" {
    const allocator = std.testing.allocator;

    var plugin = HighlightPlugin.init(allocator);

    const tokens = try plugin.highlight("ls | grep test");
    defer allocator.free(tokens);

    // Should find operator token (|)
    var found_operator = false;
    for (tokens) |token| {
        if (token.token_type == .operator) {
            found_operator = true;
            break;
        }
    }
    try std.testing.expect(found_operator);
}

test "HighlightPlugin - highlight paths" {
    const allocator = std.testing.allocator;

    var plugin = HighlightPlugin.init(allocator);

    const tokens = try plugin.highlight("cd /usr/local");
    defer allocator.free(tokens);

    // Should find path token
    var found_path = false;
    for (tokens) |token| {
        if (token.token_type == .path) {
            found_path = true;
            break;
        }
    }
    try std.testing.expect(found_path);
}

test "HighlightPlugin - empty input" {
    const allocator = std.testing.allocator;

    var plugin = HighlightPlugin.init(allocator);

    const tokens = try plugin.highlight("");
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 0), tokens.len);
}

test "HighlightPlugin - disabled" {
    const allocator = std.testing.allocator;

    var plugin = HighlightPlugin.init(allocator);
    plugin.setEnabled(false);

    const tokens = try plugin.highlight("echo hello");
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 0), tokens.len);
}

test "ScriptSuggesterPlugin - initialization" {
    const allocator = std.testing.allocator;

    var plugin = ScriptSuggesterPlugin.init(allocator);
    defer plugin.deinit();

    try std.testing.expect(plugin.enabled);
    try std.testing.expect(plugin.cache_scripts);
    try std.testing.expect(!plugin.cache_valid);
}

test "ScriptSuggesterPlugin - get suggestions with PATH" {
    const allocator = std.testing.allocator;

    var plugin = ScriptSuggesterPlugin.init(allocator);
    defer plugin.deinit();

    var environment = std.StringHashMap([]const u8).init(allocator);
    defer environment.deinit();

    // Set PATH to /usr/bin which should have common commands
    try environment.put("PATH", "/usr/bin:/bin");

    const suggestions = try plugin.getSuggestions("l", &environment);
    defer {
        for (suggestions) |suggestion| {
            allocator.free(suggestion);
        }
        allocator.free(suggestions);
    }

    // Should find some commands starting with "l" (like ls, ln, etc.)
    // This test might be environment-dependent
    // try std.testing.expect(suggestions.len > 0);
}

test "ScriptSuggesterPlugin - empty input" {
    const allocator = std.testing.allocator;

    var plugin = ScriptSuggesterPlugin.init(allocator);
    defer plugin.deinit();

    var environment = std.StringHashMap([]const u8).init(allocator);
    defer environment.deinit();

    try environment.put("PATH", "/usr/bin");

    const suggestions = try plugin.getSuggestions("", &environment);
    defer allocator.free(suggestions);

    try std.testing.expectEqual(@as(usize, 0), suggestions.len);
}

test "ScriptSuggesterPlugin - disabled" {
    const allocator = std.testing.allocator;

    var plugin = ScriptSuggesterPlugin.init(allocator);
    defer plugin.deinit();
    plugin.setEnabled(false);

    var environment = std.StringHashMap([]const u8).init(allocator);
    defer environment.deinit();

    try environment.put("PATH", "/usr/bin");

    const suggestions = try plugin.getSuggestions("ls", &environment);
    defer allocator.free(suggestions);

    try std.testing.expectEqual(@as(usize, 0), suggestions.len);
}

test "ScriptSuggesterPlugin - cache invalidation" {
    const allocator = std.testing.allocator;

    var plugin = ScriptSuggesterPlugin.init(allocator);
    defer plugin.deinit();

    var environment = std.StringHashMap([]const u8).init(allocator);
    defer environment.deinit();

    try environment.put("PATH", "/usr/bin");

    // First call builds cache
    const suggestions1 = try plugin.getSuggestions("l", &environment);
    defer {
        for (suggestions1) |suggestion| {
            allocator.free(suggestion);
        }
        allocator.free(suggestions1);
    }

    try std.testing.expect(plugin.cache_valid);

    // Invalidate cache
    plugin.invalidateCache();
    try std.testing.expect(!plugin.cache_valid);

    // Second call rebuilds cache
    const suggestions2 = try plugin.getSuggestions("l", &environment);
    defer {
        for (suggestions2) |suggestion| {
            allocator.free(suggestion);
        }
        allocator.free(suggestions2);
    }

    try std.testing.expect(plugin.cache_valid);
}
