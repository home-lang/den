const std = @import("std");
const Parser = @import("parser.zig").Parser;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const types = @import("../types/mod.zig");

/// Helper function to parse input string
fn parseInput(allocator: std.mem.Allocator, input: []const u8) !types.CommandChain {
    var tokenizer = Tokenizer.init(allocator, input);
    const tokens = try tokenizer.tokenize();
    // The parser dupes the strings it needs into the CommandChain, so free the
    // tokens (including their heap-allocated values) once parsing is done.
    defer tokenizer.deinitTokens(tokens);

    var parser = Parser.init(allocator, tokens);
    return try parser.parse();
}

// Variable Expansion Integration Tests
test "Parser: expand variables during parsing" {
    const allocator = std.testing.allocator;

    const input = "echo hello";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), chain.commands.len);
    try std.testing.expectEqualStrings("echo", chain.commands[0].name);
    try std.testing.expectEqual(@as(usize, 1), chain.commands[0].args.len);
    try std.testing.expectEqualStrings("hello", chain.commands[0].args[0]);
}

test "Parser: basic command parsing" {
    const allocator = std.testing.allocator;

    const input = "ls -la /tmp";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), chain.commands.len);
    try std.testing.expectEqualStrings("ls", chain.commands[0].name);
    try std.testing.expectEqual(@as(usize, 2), chain.commands[0].args.len);
    try std.testing.expectEqualStrings("-la", chain.commands[0].args[0]);
    try std.testing.expectEqualStrings("/tmp", chain.commands[0].args[1]);
}

test "Parser: command with multiple arguments" {
    const allocator = std.testing.allocator;

    const input = "echo arg1 arg2 arg3";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), chain.commands.len);
    try std.testing.expectEqualStrings("echo", chain.commands[0].name);
    try std.testing.expectEqual(@as(usize, 3), chain.commands[0].args.len);
    try std.testing.expectEqualStrings("arg1", chain.commands[0].args[0]);
    try std.testing.expectEqualStrings("arg2", chain.commands[0].args[1]);
    try std.testing.expectEqualStrings("arg3", chain.commands[0].args[2]);
}

// Redirection Parsing Tests
test "Parser: output redirection" {
    const allocator = std.testing.allocator;

    const input = "echo hello > output.txt";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), chain.commands.len);
    try std.testing.expectEqualStrings("echo", chain.commands[0].name);

    // Check for redirections
    try std.testing.expect(chain.commands[0].redirections.len > 0);

    var found_stdout = false;
    for (chain.commands[0].redirections) |redir| {
        if (redir.kind == .output_truncate) {
            try std.testing.expectEqualStrings("output.txt", redir.target);
            found_stdout = true;
        }
    }
    try std.testing.expect(found_stdout);
}

test "Parser: input redirection" {
    const allocator = std.testing.allocator;

    const input = "cat < input.txt";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), chain.commands.len);
    try std.testing.expectEqualStrings("cat", chain.commands[0].name);

    var found_stdin = false;
    for (chain.commands[0].redirections) |redir| {
        if (redir.kind == .input) {
            try std.testing.expectEqualStrings("input.txt", redir.target);
            found_stdin = true;
        }
    }
    try std.testing.expect(found_stdin);
}

test "Parser: stderr redirection" {
    const allocator = std.testing.allocator;

    const input = "command 2> error.log";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), chain.commands.len);

    var found_stderr = false;
    for (chain.commands[0].redirections) |redir| {
        // `2>` is an output-truncate redirection on fd 2 (stderr).
        if (redir.kind == .output_truncate and redir.fd == 2) {
            try std.testing.expectEqualStrings("error.log", redir.target);
            found_stderr = true;
        }
    }
    try std.testing.expect(found_stderr);
}

test "Parser: append redirection" {
    const allocator = std.testing.allocator;

    const input = "echo hello >> output.txt";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), chain.commands.len);

    var found_append = false;
    for (chain.commands[0].redirections) |redir| {
        if (redir.kind == .output_append) {
            try std.testing.expectEqualStrings("output.txt", redir.target);
            found_append = true;
        }
    }
    try std.testing.expect(found_append);
}

// Pipe Tests
test "Parser: simple pipe" {
    const allocator = std.testing.allocator;

    const input = "ls | grep test";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), chain.commands.len);
    try std.testing.expectEqualStrings("ls", chain.commands[0].name);
    try std.testing.expectEqualStrings("grep", chain.commands[1].name);

    try std.testing.expectEqual(@as(usize, 1), chain.operators.len);
    try std.testing.expectEqual(types.Operator.pipe, chain.operators[0]);
}

test "Parser: multiple pipes" {
    const allocator = std.testing.allocator;

    const input = "cat file.txt | grep pattern | sort";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), chain.commands.len);
    try std.testing.expectEqualStrings("cat", chain.commands[0].name);
    try std.testing.expectEqualStrings("grep", chain.commands[1].name);
    try std.testing.expectEqualStrings("sort", chain.commands[2].name);

    try std.testing.expectEqual(@as(usize, 2), chain.operators.len);
    try std.testing.expectEqual(types.Operator.pipe, chain.operators[0]);
    try std.testing.expectEqual(types.Operator.pipe, chain.operators[1]);
}

// Boolean Operators Tests
test "Parser: AND operator" {
    const allocator = std.testing.allocator;

    const input = "make && make install";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), chain.commands.len);
    try std.testing.expectEqualStrings("make", chain.commands[0].name);
    try std.testing.expectEqualStrings("make", chain.commands[1].name);

    try std.testing.expectEqual(@as(usize, 1), chain.operators.len);
    try std.testing.expectEqual(types.Operator.and_op, chain.operators[0]);
}

test "Parser: OR operator" {
    const allocator = std.testing.allocator;

    const input = "command1 || command2";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), chain.commands.len);
    try std.testing.expectEqual(@as(usize, 1), chain.operators.len);
    try std.testing.expectEqual(types.Operator.or_op, chain.operators[0]);
}

// Background Process Tests
test "Parser: background process" {
    const allocator = std.testing.allocator;

    const input = "long-command &";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), chain.commands.len);
    try std.testing.expectEqualStrings("long-command", chain.commands[0].name);

    try std.testing.expectEqual(@as(usize, 1), chain.operators.len);
    try std.testing.expectEqual(types.Operator.background, chain.operators[0]);
}

// Semicolon Tests
test "Parser: semicolon separator" {
    const allocator = std.testing.allocator;

    const input = "echo first; echo second";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), chain.commands.len);
    try std.testing.expectEqualStrings("echo", chain.commands[0].name);
    try std.testing.expectEqualStrings("echo", chain.commands[1].name);

    try std.testing.expectEqual(@as(usize, 1), chain.operators.len);
    try std.testing.expectEqual(types.Operator.semicolon, chain.operators[0]);
}

// Complex Command Tests
test "Parser: mixed operators" {
    const allocator = std.testing.allocator;

    const input = "cmd1 | cmd2 && cmd3";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), chain.commands.len);
    try std.testing.expectEqual(@as(usize, 2), chain.operators.len);
    try std.testing.expectEqual(types.Operator.pipe, chain.operators[0]);
    try std.testing.expectEqual(types.Operator.and_op, chain.operators[1]);
}

test "Parser: command with redirections and pipes" {
    const allocator = std.testing.allocator;

    const input = "cat < input.txt | grep pattern > output.txt";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), chain.commands.len);
    try std.testing.expectEqualStrings("cat", chain.commands[0].name);
    try std.testing.expectEqualStrings("grep", chain.commands[1].name);
}

// Edge Cases
test "Parser: empty input" {
    const allocator = std.testing.allocator;

    const input = "";
    var tokenizer = Tokenizer.init(allocator, input);
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    if (tokens.len == 0) {
        // Empty input is valid - no commands to parse
        return;
    }
}

test "Parser: whitespace only" {
    const allocator = std.testing.allocator;

    const input = "   \t  \n  ";
    var tokenizer = Tokenizer.init(allocator, input);
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    if (tokens.len == 0) {
        // Whitespace only is valid
        return;
    }
}

test "Parser: command with no arguments" {
    const allocator = std.testing.allocator;

    const input = "ls";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), chain.commands.len);
    try std.testing.expectEqualStrings("ls", chain.commands[0].name);
    try std.testing.expectEqual(@as(usize, 0), chain.commands[0].args.len);
}

test "Parser: command with quoted arguments" {
    const allocator = std.testing.allocator;

    const input = "echo \"hello world\"";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), chain.commands.len);
    try std.testing.expectEqualStrings("echo", chain.commands[0].name);
    try std.testing.expectEqual(@as(usize, 1), chain.commands[0].args.len);
}

test "Parser: command with single quotes" {
    const allocator = std.testing.allocator;

    const input = "echo 'hello world'";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), chain.commands.len);
    try std.testing.expectEqualStrings("echo", chain.commands[0].name);
}

test "Parser: command with escaped spaces" {
    const allocator = std.testing.allocator;

    const input = "ls file\\ with\\ space";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), chain.commands.len);
    try std.testing.expectEqualStrings("ls", chain.commands[0].name);
}

test "Parser: command with flags" {
    const allocator = std.testing.allocator;

    const input = "ls -la --color=auto";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), chain.commands.len);
    try std.testing.expectEqualStrings("ls", chain.commands[0].name);
    try std.testing.expectEqual(@as(usize, 2), chain.commands[0].args.len);
}

test "Parser: command with equals in arguments" {
    const allocator = std.testing.allocator;

    const input = "env KEY=value command";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), chain.commands.len);
    try std.testing.expectEqualStrings("env", chain.commands[0].name);
}

// Redirection Edge Cases
test "Parser: multiple redirections" {
    const allocator = std.testing.allocator;

    const input = "command < input.txt > output.txt 2> error.txt";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), chain.commands.len);
    try std.testing.expect(chain.commands[0].redirections.len >= 3);
}

test "Parser: redirection with no space" {
    const allocator = std.testing.allocator;

    const input = "echo hello>output.txt";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), chain.commands.len);
    try std.testing.expectEqualStrings("echo", chain.commands[0].name);
}

test "Parser: here-string redirection" {
    const allocator = std.testing.allocator;

    const input = "cat <<< \"hello world\"";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), chain.commands.len);
    try std.testing.expectEqualStrings("cat", chain.commands[0].name);
}

// Complex Scenarios
test "Parser: long command chain" {
    const allocator = std.testing.allocator;

    const input = "cmd1 | cmd2 | cmd3 | cmd4 | cmd5";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), chain.commands.len);
    try std.testing.expectEqual(@as(usize, 4), chain.operators.len);
}

test "Parser: command with many arguments" {
    const allocator = std.testing.allocator;

    const input = "echo a b c d e f g h i j";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), chain.commands.len);
    try std.testing.expectEqual(@as(usize, 10), chain.commands[0].args.len);
}

test "Parser: background with pipe" {
    const allocator = std.testing.allocator;

    const input = "cmd1 | cmd2 &";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), chain.commands.len);
    try std.testing.expectEqual(@as(usize, 2), chain.operators.len);
}

test "Parser: consecutive semicolons" {
    const allocator = std.testing.allocator;

    const input = "cmd1; cmd2; cmd3";
    var chain = try parseInput(allocator, input);
    defer chain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), chain.commands.len);
    try std.testing.expectEqual(@as(usize, 2), chain.operators.len);
}
