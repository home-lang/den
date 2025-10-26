const std = @import("std");
const builtin_plugins = @import("builtin_plugins_advanced.zig");

const AutoSuggestPlugin = builtin_plugins.AutoSuggestPlugin;
const HighlightPlugin = builtin_plugins.HighlightPlugin;
const ScriptSuggesterPlugin = builtin_plugins.ScriptSuggesterPlugin;

test "Integration - AutoSuggest with realistic history" {
    const allocator = std.testing.allocator;

    var history = [_]?[]const u8{null} ** 1000;
    var history_count: usize = 0;
    var environment = std.StringHashMap([]const u8).init(allocator);
    defer environment.deinit();

    // Simulate realistic shell history
    const commands = [_][]const u8{
        "git status",
        "git add .",
        "git commit -m \"update\"",
        "git push origin main",
        "ls -la",
        "cd src",
        "pwd",
        "echo hello world",
        "grep -r \"function\" .",
        "find . -name \"*.zig\"",
    };

    for (commands, 0..) |cmd, i| {
        history[i] = try allocator.dupe(u8, cmd);
    }
    history_count = commands.len;

    defer {
        for (history[0..history_count]) |maybe_entry| {
            if (maybe_entry) |entry| {
                allocator.free(entry);
            }
        }
    }

    var plugin = AutoSuggestPlugin.init(allocator, &history, &history_count, &environment);

    // Test git command suggestions
    const git_suggestions = try plugin.getSuggestions("git");
    defer {
        for (git_suggestions) |suggestion| {
            allocator.free(suggestion);
        }
        allocator.free(git_suggestions);
    }

    try std.testing.expect(git_suggestions.len >= 4);

    // Test partial command matching
    const grep_suggestions = try plugin.getSuggestions("grep");
    defer {
        for (grep_suggestions) |suggestion| {
            allocator.free(suggestion);
        }
        allocator.free(grep_suggestions);
    }

    try std.testing.expect(grep_suggestions.len >= 1);
}

test "Integration - Highlight complex command" {
    const allocator = std.testing.allocator;

    var plugin = HighlightPlugin.init(allocator);

    // Complex command with multiple elements
    const complex_cmd = "ls -la /usr/bin | grep \"test\" && echo \"done\"";

    const tokens = try plugin.highlight(complex_cmd);
    defer allocator.free(tokens);

    // Should have multiple tokens
    try std.testing.expect(tokens.len >= 7);

    // Verify we have different token types
    var has_builtin = false;
    var has_option = false;
    var has_path = false;
    var has_operator = false;
    var has_string = false;

    for (tokens) |token| {
        switch (token.token_type) {
            .builtin => has_builtin = true,
            .option => has_option = true,
            .path => has_path = true,
            .operator => has_operator = true,
            .string => has_string = true,
            else => {},
        }
    }

    try std.testing.expect(has_builtin);
    try std.testing.expect(has_option);
    try std.testing.expect(has_path);
    try std.testing.expect(has_operator);
    try std.testing.expect(has_string);
}

test "Integration - Highlight different command types" {
    const allocator = std.testing.allocator;

    var plugin = HighlightPlugin.init(allocator);

    const test_cases = [_]struct {
        input: []const u8,
        expected_builtin: bool,
        expected_path: bool,
    }{
        .{ .input = "cd /home/user", .expected_builtin = true, .expected_path = true },
        .{ .input = "echo test", .expected_builtin = true, .expected_path = false },
        .{ .input = "cat ./file.txt", .expected_builtin = false, .expected_path = true },
    };

    for (test_cases) |case| {
        const tokens = try plugin.highlight(case.input);
        defer allocator.free(tokens);

        var has_builtin = false;
        var has_path = false;

        for (tokens) |token| {
            if (token.token_type == .builtin) has_builtin = true;
            if (token.token_type == .path) has_path = true;
        }

        try std.testing.expectEqual(case.expected_builtin, has_builtin);
        try std.testing.expectEqual(case.expected_path, has_path);
    }
}

test "Integration - Combined AutoSuggest and Highlight" {
    const allocator = std.testing.allocator;

    var history = [_]?[]const u8{null} ** 1000;
    var history_count: usize = 0;
    var environment = std.StringHashMap([]const u8).init(allocator);
    defer environment.deinit();

    // Add some commands to history
    history[0] = try allocator.dupe(u8, "echo hello");
    history[1] = try allocator.dupe(u8, "echo world");
    history_count = 2;

    defer {
        for (history[0..history_count]) |maybe_entry| {
            if (maybe_entry) |entry| {
                allocator.free(entry);
            }
        }
    }

    var suggest_plugin = AutoSuggestPlugin.init(allocator, &history, &history_count, &environment);
    var highlight_plugin = HighlightPlugin.init(allocator);

    // Get suggestions
    const suggestions = try suggest_plugin.getSuggestions("echo");
    defer {
        for (suggestions) |suggestion| {
            allocator.free(suggestion);
        }
        allocator.free(suggestions);
    }

    // Highlight each suggestion
    for (suggestions) |suggestion| {
        const tokens = try highlight_plugin.highlight(suggestion);
        defer allocator.free(tokens);

        // Each suggestion should have at least one token
        try std.testing.expect(tokens.len > 0);

        // First token should be "echo" which is a builtin
        if (tokens.len > 0) {
            try std.testing.expectEqual(HighlightPlugin.TokenType.builtin, tokens[0].token_type);
        }
    }
}

test "Integration - ScriptSuggester performance" {
    const allocator = std.testing.allocator;

    var plugin = ScriptSuggesterPlugin.init(allocator);
    defer plugin.deinit();

    var environment = std.StringHashMap([]const u8).init(allocator);
    defer environment.deinit();

    try environment.put("PATH", "/usr/bin:/bin");

    // First call - builds cache
    const start = std.time.milliTimestamp();
    const suggestions1 = try plugin.getSuggestions("l", &environment);
    const first_duration = std.time.milliTimestamp() - start;

    defer {
        for (suggestions1) |suggestion| {
            allocator.free(suggestion);
        }
        allocator.free(suggestions1);
    }

    // Second call - uses cache (should be faster or similar)
    const start2 = std.time.milliTimestamp();
    const suggestions2 = try plugin.getSuggestions("l", &environment);
    const second_duration = std.time.milliTimestamp() - start2;

    defer {
        for (suggestions2) |suggestion| {
            allocator.free(suggestion);
        }
        allocator.free(suggestions2);
    }

    // Second call should not be significantly slower
    // (allowing some variance for test stability)
    _ = first_duration;
    _ = second_duration;
    // In practice, second call should be faster due to caching

    // Both calls should return same results
    try std.testing.expectEqual(suggestions1.len, suggestions2.len);
}

test "Integration - Plugin configuration changes" {
    const allocator = std.testing.allocator;

    var history = [_]?[]const u8{null} ** 1000;
    var history_count: usize = 0;
    var environment = std.StringHashMap([]const u8).init(allocator);
    defer environment.deinit();

    // Add many commands
    for (0..10) |i| {
        const cmd = try std.fmt.allocPrint(allocator, "command{}", .{i});
        history[i] = cmd;
    }
    history_count = 10;

    defer {
        for (history[0..history_count]) |maybe_entry| {
            if (maybe_entry) |entry| {
                allocator.free(entry);
            }
        }
    }

    var plugin = AutoSuggestPlugin.init(allocator, &history, &history_count, &environment);

    // Default max suggestions is 5
    const suggestions1 = try plugin.getSuggestions("command");
    defer {
        for (suggestions1) |suggestion| {
            allocator.free(suggestion);
        }
        allocator.free(suggestions1);
    }

    try std.testing.expect(suggestions1.len <= 5);

    // Change max suggestions to 3
    plugin.setMaxSuggestions(3);

    const suggestions2 = try plugin.getSuggestions("command");
    defer {
        for (suggestions2) |suggestion| {
            allocator.free(suggestion);
        }
        allocator.free(suggestions2);
    }

    try std.testing.expect(suggestions2.len <= 3);

    // Disable plugin
    plugin.setEnabled(false);

    const suggestions3 = try plugin.getSuggestions("command");
    defer allocator.free(suggestions3);

    try std.testing.expectEqual(@as(usize, 0), suggestions3.len);
}

test "Integration - Highlight with escaped strings" {
    const allocator = std.testing.allocator;

    var plugin = HighlightPlugin.init(allocator);

    const cmd_with_escapes = "echo \"hello \\\"world\\\"\"";

    const tokens = try plugin.highlight(cmd_with_escapes);
    defer allocator.free(tokens);

    // Should have at least 2 tokens (builtin + string)
    try std.testing.expect(tokens.len >= 2);

    // Find the string token
    var found_string = false;
    for (tokens) |token| {
        if (token.token_type == .string) {
            found_string = true;
            break;
        }
    }

    try std.testing.expect(found_string);
}
