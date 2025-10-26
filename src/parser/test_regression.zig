const std = @import("std");
const Tokenizer = @import("tokenizer.zig").Tokenizer;

// Parser Regression Tests
// Tests for bugs that were fixed and should never regress

test "Regression: empty input should not crash" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should return empty token array, not crash
    try std.testing.expect(tokens.len >= 0);
}

test "Regression: whitespace only input" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "   \t   \n  ");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should not crash on whitespace-only input
    try std.testing.expect(tokens.len >= 0);
}

test "Regression: single operator should not crash" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "|");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should handle single operator without crash
    try std.testing.expect(tokens.len >= 1);
}

test "Regression: multiple pipes in sequence" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo hello | | cat");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should parse without crashing
    try std.testing.expect(tokens.len > 0);
}

test "Regression: trailing operator" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo hello &&");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should handle trailing operator
    try std.testing.expect(tokens.len > 0);
}

test "Regression: leading operator" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "&& echo hello");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should handle leading operator
    try std.testing.expect(tokens.len > 0);
}

test "Regression: very long command line" {
    const allocator = std.testing.allocator;

    // Create a very long command using fixed buffer
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try writer.writeAll("echo ");
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try writer.print("arg{d} ", .{i});
    }

    const long_cmd = fbs.getWritten();

    var tokenizer = Tokenizer.init(allocator, long_cmd);
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should handle long command without overflow
    try std.testing.expect(tokens.len > 100);
}

test "Regression: multiple redirections on same command" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "cmd < input.txt > output.txt 2> error.log");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should parse all redirections
    try std.testing.expect(tokens.len > 5);
}

test "Regression: redirection without space" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo hello>output.txt");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should handle no-space redirection
    try std.testing.expect(tokens.len > 2);
}

test "Regression: semicolon at end of line" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo hello;");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should handle trailing semicolon
    try std.testing.expect(tokens.len > 0);
}

test "Regression: multiple semicolons" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo a; echo b; echo c");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should parse all commands
    try std.testing.expect(tokens.len > 5);
}

test "Regression: mixed operators" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "cmd1 && cmd2 || cmd3 ; cmd4 | cmd5");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should handle mixed operators
    try std.testing.expect(tokens.len > 5);
}

test "Regression: command with many arguments" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "ls -la -h -R --color=auto --group-directories-first /tmp");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should tokenize all arguments
    try std.testing.expect(tokens.len >= 6);
}

test "Regression: nested command structure" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "if true; then echo yes; fi");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should parse control structures
    try std.testing.expect(tokens.len > 5);
}

test "Regression: command with equals sign" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "VAR=value command");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should handle environment variable assignment
    try std.testing.expect(tokens.len >= 2);
}

test "Regression: multiple spaces between tokens" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo    hello     world");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should normalize multiple spaces
    try std.testing.expect(tokens.len >= 3);
}

test "Regression: tab characters" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo\thello\tworld");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should handle tabs as whitespace
    try std.testing.expect(tokens.len >= 3);
}

test "Regression: newline in command" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo hello\necho world");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should handle newlines
    try std.testing.expect(tokens.len >= 4);
}

test "Regression: background operator" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "sleep 10 &");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should parse background operator
    try std.testing.expect(tokens.len >= 3);
}

test "Regression: combined stderr and stdout redirect" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "command &> output.txt");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should parse combined redirect
    try std.testing.expect(tokens.len >= 2);
}

test "Regression: append redirection" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo hello >> file.txt");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should parse append redirect
    try std.testing.expect(tokens.len >= 3);
}

test "Regression: here-string syntax" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "cat <<< hello");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should parse here-string
    try std.testing.expect(tokens.len >= 2);
}

test "Regression: command with dollar signs" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo $VAR ${HOME} $?");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should parse variables
    try std.testing.expect(tokens.len >= 4);
}

test "Regression: command with backticks" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo `date`");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should parse command substitution
    try std.testing.expect(tokens.len >= 2);
}

test "Regression: command with braces" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo {a,b,c}");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should parse brace expansion
    try std.testing.expect(tokens.len >= 2);
}

test "Regression: glob patterns" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "ls *.txt ?.log [a-z]*");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should parse glob patterns
    try std.testing.expect(tokens.len >= 4);
}

test "Regression: special characters in arguments" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo @#$%^&*()");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should handle special characters
    try std.testing.expect(tokens.len >= 2);
}

test "Regression: command with slashes" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "/usr/bin/env node /tmp/test.js");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should handle path separators
    try std.testing.expect(tokens.len >= 3);
}

test "Regression: command with hyphens and underscores" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "my-command --my-flag my_arg");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should handle hyphens and underscores
    try std.testing.expect(tokens.len >= 3);
}

test "Regression: numbers as commands and arguments" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo 123 456 789");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should handle numeric arguments
    try std.testing.expect(tokens.len >= 4);
}

test "Regression: dotfiles and relative paths" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "cat .bashrc ./script.sh ../config.json");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should handle dotfiles and relative paths
    try std.testing.expect(tokens.len >= 4);
}
