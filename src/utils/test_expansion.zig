const std = @import("std");
const Expansion = @import("expansion.zig").Expansion;

// Test Variable Expansion

test "Expansion: simple variable" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("USER", "testuser");

    var expansion = Expansion.init(allocator, &env, 0);

    const result = try expansion.expand("Hello $USER");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello testuser", result);
}

test "Expansion: variable with braces" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("HOME", "/home/testuser");

    var expansion = Expansion.init(allocator, &env, 0);

    const result = try expansion.expand("Path: ${HOME}/bin");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Path: /home/testuser/bin", result);
}

test "Expansion: undefined variable returns empty" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    var expansion = Expansion.init(allocator, &env, 0);

    const result = try expansion.expand("Value: $UNDEFINED");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Value: ", result);
}

test "Expansion: multiple variables" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("USER", "testuser");
    try env.put("HOME", "/home/testuser");

    var expansion = Expansion.init(allocator, &env, 0);

    const result = try expansion.expand("$USER at $HOME");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("testuser at /home/testuser", result);
}

test "Expansion: variable at end of string" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("PATH", "/usr/bin");

    var expansion = Expansion.init(allocator, &env, 0);

    const result = try expansion.expand("Current PATH: $PATH");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Current PATH: /usr/bin", result);
}

test "Expansion: variable with special chars boundary" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("VAR", "value");

    var expansion = Expansion.init(allocator, &env, 0);

    const result = try expansion.expand("$VAR/path");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("value/path", result);
}

test "Expansion: special variable $?" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    var expansion = Expansion.init(allocator, &env, 42);

    const result = try expansion.expand("Exit code: $?");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Exit code: 42", result);
}

test "Expansion: special variable $$" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    var expansion = Expansion.init(allocator, &env, 0);

    const result = try expansion.expand("PID: $$");
    defer allocator.free(result);

    // Should contain "PID: " followed by a number
    try std.testing.expect(std.mem.startsWith(u8, result, "PID: "));
}

test "Expansion: special variable $0" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    const params = &[_][]const u8{};
    var expansion = Expansion.initWithParams(allocator, &env, 0, params, "den", 0, "");

    const result = try expansion.expand("Shell: $0");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Shell: den", result);
}

test "Expansion: positional parameter $1" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    const params = &[_][]const u8{ "first", "second", "third" };
    var expansion = Expansion.initWithParams(allocator, &env, 0, params, "den", 0, "");

    const result = try expansion.expand("First: $1");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("First: first", result);
}

test "Expansion: positional parameter $2" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    const params = &[_][]const u8{ "first", "second", "third" };
    var expansion = Expansion.initWithParams(allocator, &env, 0, params, "den", 0, "");

    const result = try expansion.expand("Second: $2");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Second: second", result);
}

test "Expansion: special variable $#" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    const params = &[_][]const u8{ "first", "second", "third" };
    var expansion = Expansion.initWithParams(allocator, &env, 0, params, "den", 0, "");

    const result = try expansion.expand("Count: $#");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Count: 3", result);
}

test "Expansion: special variable $!" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    const params = &[_][]const u8{};
    var expansion = Expansion.initWithParams(allocator, &env, 0, params, "den", 12345, "");

    const result = try expansion.expand("Background PID: $!");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Background PID: 12345", result);
}

test "Expansion: tilde expansion" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("HOME", "/home/testuser");

    var expansion = Expansion.init(allocator, &env, 0);

    const result = try expansion.expand("~/documents");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("/home/testuser/documents", result);
}

test "Expansion: tilde alone" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("HOME", "/home/testuser");

    var expansion = Expansion.init(allocator, &env, 0);

    const result = try expansion.expand("~");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("/home/testuser", result);
}

test "Expansion: no expansion for escaped dollar" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("VAR", "value");

    var expansion = Expansion.init(allocator, &env, 0);

    const result = try expansion.expand("Cost: \\$5");
    defer allocator.free(result);

    // Backslash should be preserved
    try std.testing.expectEqualStrings("Cost: \\$5", result);
}

test "Expansion: empty string" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    var expansion = Expansion.init(allocator, &env, 0);

    const result = try expansion.expand("");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "Expansion: no variables" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    var expansion = Expansion.init(allocator, &env, 0);

    const result = try expansion.expand("plain text");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("plain text", result);
}

test "Expansion: dollar at end" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    var expansion = Expansion.init(allocator, &env, 0);

    const result = try expansion.expand("price is 5$");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("price is 5$", result);
}

test "Expansion: consecutive variables" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("A", "foo");
    try env.put("B", "bar");

    var expansion = Expansion.init(allocator, &env, 0);

    const result = try expansion.expand("$A$B");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("foobar", result);
}

test "Expansion: variable with numbers" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("VAR123", "value");

    var expansion = Expansion.init(allocator, &env, 0);

    const result = try expansion.expand("$VAR123");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("value", result);
}

test "Expansion: variable with underscore" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("MY_VAR", "value");

    var expansion = Expansion.init(allocator, &env, 0);

    const result = try expansion.expand("$MY_VAR");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("value", result);
}

test "Expansion: braces with special chars" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("VAR", "value");

    var expansion = Expansion.init(allocator, &env, 0);

    const result = try expansion.expand("${VAR}-suffix");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("value-suffix", result);
}

test "Expansion: empty variable" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("EMPTY", "");

    var expansion = Expansion.init(allocator, &env, 0);

    const result = try expansion.expand("Value: $EMPTY end");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Value:  end", result);
}

test "Expansion: complex expression" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("USER", "testuser");
    try env.put("HOME", "/home/testuser");
    try env.put("SHELL", "/bin/den");

    var expansion = Expansion.init(allocator, &env, 0);

    const result = try expansion.expand("$USER:$HOME:$SHELL");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("testuser:/home/testuser:/bin/den", result);
}

test "Expansion: dollar in middle of word without var" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    var expansion = Expansion.init(allocator, &env, 0);

    const result = try expansion.expand("test$");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("test$", result);
}

test "Expansion: multiple tildes" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("HOME", "/home/testuser");

    var expansion = Expansion.init(allocator, &env, 0);

    const result = try expansion.expand("~/path ~/other");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("/home/testuser/path /home/testuser/other", result);
}

test "Expansion: tilde not at start" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("HOME", "/home/testuser");

    var expansion = Expansion.init(allocator, &env, 0);

    const result = try expansion.expand("path~test");
    defer allocator.free(result);

    // Tilde not expanded when not at word start
    try std.testing.expectEqualStrings("path~test", result);
}

test "Expansion: PATH with tilde after colon" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("HOME", "/home/testuser");

    var expansion = Expansion.init(allocator, &env, 0);

    const result = try expansion.expand("/usr/bin:~/bin");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("/usr/bin:/home/testuser/bin", result);
}
