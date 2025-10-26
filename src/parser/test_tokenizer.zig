const std = @import("std");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const TokenType = @import("tokenizer.zig").TokenType;

// Basic Tokenization Tests
test "Tokenizer: simple command" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo hello");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 3), tokens.len); // echo, hello, EOF
    try std.testing.expectEqual(TokenType.word, tokens[0].type);
    try std.testing.expectEqualStrings("echo", tokens[0].value);
    try std.testing.expectEqual(TokenType.word, tokens[1].type);
    try std.testing.expectEqualStrings("hello", tokens[1].value);
}

test "Tokenizer: command with arguments" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "ls -la /tmp");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 4), tokens.len);
    try std.testing.expectEqualStrings("ls", tokens[0].value);
    try std.testing.expectEqualStrings("-la", tokens[1].value);
    try std.testing.expectEqualStrings("/tmp", tokens[2].value);
}

// Operator Tokenization Tests
test "Tokenizer: pipe operator" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "ls | grep test");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(TokenType.word, tokens[0].type);
    try std.testing.expectEqual(TokenType.pipe, tokens[1].type);
    try std.testing.expectEqual(TokenType.word, tokens[2].type);
}

test "Tokenizer: AND operator" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "make && make install");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(TokenType.word, tokens[0].type);
    try std.testing.expectEqual(TokenType.and_op, tokens[1].type);
    try std.testing.expectEqualStrings("&&", tokens[1].value);
}

test "Tokenizer: OR operator" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "cmd1 || cmd2");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(TokenType.or_op, tokens[1].type);
    try std.testing.expectEqualStrings("||", tokens[1].value);
}

test "Tokenizer: semicolon operator" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "cmd1; cmd2");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(TokenType.semicolon, tokens[1].type);
    try std.testing.expectEqualStrings(";", tokens[1].value);
}

test "Tokenizer: background operator" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "long-command &");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(TokenType.background, tokens[1].type);
    try std.testing.expectEqualStrings("&", tokens[1].value);
}

// Redirection Tests
test "Tokenizer: output redirection" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo hello > output.txt");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(TokenType.redirect_out, tokens[2].type);
    try std.testing.expectEqualStrings(">", tokens[2].value);
}

test "Tokenizer: append redirection" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo hello >> output.txt");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(TokenType.redirect_append, tokens[2].type);
    try std.testing.expectEqualStrings(">>", tokens[2].value);
}

test "Tokenizer: input redirection" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "cat < input.txt");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(TokenType.redirect_in, tokens[1].type);
    try std.testing.expectEqualStrings("<", tokens[1].value);
}

test "Tokenizer: stderr redirection" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "command 2> error.log");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(TokenType.redirect_err, tokens[1].type);
}

test "Tokenizer: combined redirection" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "command &> output.txt");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(TokenType.redirect_both, tokens[1].type);
}

test "Tokenizer: heredoc" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "cat << EOF");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(TokenType.heredoc, tokens[1].type);
    try std.testing.expectEqualStrings("<<", tokens[1].value);
}

test "Tokenizer: here-string" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "cat <<< \"hello\"");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(TokenType.herestring, tokens[1].type);
    try std.testing.expectEqualStrings("<<<", tokens[1].value);
}

// Quote Handling Tests
test "Tokenizer: double quoted string" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo \"hello world\"");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expect(std.mem.indexOf(u8, tokens[1].value, "hello world") != null);
}

test "Tokenizer: single quoted string" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo 'hello world'");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expect(std.mem.indexOf(u8, tokens[1].value, "hello world") != null);
}

test "Tokenizer: mixed quotes" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo \"outer 'inner' outer\"");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 3), tokens.len);
}

test "Tokenizer: escaped quotes" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo \\\"escaped\\\"");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 3), tokens.len);
}

// Whitespace Handling Tests
test "Tokenizer: multiple spaces" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo    hello    world");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 4), tokens.len);
    try std.testing.expectEqualStrings("echo", tokens[0].value);
    try std.testing.expectEqualStrings("hello", tokens[1].value);
    try std.testing.expectEqualStrings("world", tokens[2].value);
}

test "Tokenizer: tabs and spaces" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo\thello\t  world");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 4), tokens.len);
}

test "Tokenizer: leading and trailing whitespace" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "  echo hello  ");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqualStrings("echo", tokens[0].value);
}

// Special Character Tests
test "Tokenizer: parentheses" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "(echo hello)");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(TokenType.lparen, tokens[0].type);
    try std.testing.expectEqual(TokenType.rparen, tokens[2].type);
}

test "Tokenizer: escaped characters" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "file\\ with\\ spaces");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 2), tokens.len);
}

// Keyword Recognition Tests
test "Tokenizer: if keyword" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "if test");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(TokenType.kw_if, tokens[0].type);
}

test "Tokenizer: for loop keyword" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "for i in 1 2 3");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(TokenType.kw_for, tokens[0].type);
    try std.testing.expectEqual(TokenType.kw_in, tokens[2].type);
}

test "Tokenizer: while loop keyword" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "while true");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(TokenType.kw_while, tokens[0].type);
}

// Edge Cases
test "Tokenizer: empty input" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try std.testing.expectEqual(TokenType.eof, tokens[0].type);
}

test "Tokenizer: only whitespace" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "   \t  \n  ");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(TokenType.eof, tokens[tokens.len - 1].type);
}

test "Tokenizer: complex command chain" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "cmd1 | cmd2 && cmd3 || cmd4");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(TokenType.word, tokens[0].type);
    try std.testing.expectEqual(TokenType.pipe, tokens[1].type);
    try std.testing.expectEqual(TokenType.word, tokens[2].type);
    try std.testing.expectEqual(TokenType.and_op, tokens[3].type);
    try std.testing.expectEqual(TokenType.word, tokens[4].type);
    try std.testing.expectEqual(TokenType.or_op, tokens[5].type);
    try std.testing.expectEqual(TokenType.word, tokens[6].type);
}

test "Tokenizer: operators without spaces" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo>output.txt");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(TokenType.word, tokens[0].type);
    try std.testing.expectEqual(TokenType.redirect_out, tokens[1].type);
}

test "Tokenizer: multiple redirections" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "command < in.txt > out.txt 2> err.txt");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    var redir_count: usize = 0;
    for (tokens) |token| {
        if (token.type == .redirect_in or token.type == .redirect_out or token.type == .redirect_err) {
            redir_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), redir_count);
}

test "Tokenizer: newline handling" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo hello\necho world");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    // Should have tokens for both lines
    try std.testing.expect(tokens.len >= 4);
}

test "Tokenizer: line and column tracking" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo hello");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens[0].line);
    try std.testing.expectEqual(@as(usize, 1), tokens[0].column);
}

test "Tokenizer: special characters in words" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "file.txt file-name file_name");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 4), tokens.len);
    try std.testing.expectEqualStrings("file.txt", tokens[0].value);
}

test "Tokenizer: numbers as arguments" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "sleep 10");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqualStrings("10", tokens[1].value);
}

test "Tokenizer: environment variable syntax" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo $HOME");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqualStrings("$HOME", tokens[1].value);
}

test "Tokenizer: brace expansion syntax" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "touch file.{txt,log,conf}");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expect(tokens.len >= 2);
    try std.testing.expect(std.mem.indexOf(u8, tokens[1].value, "{") != null);
}

test "Tokenizer: command substitution syntax" {
    const allocator = std.testing.allocator;

    var tokenizer = Tokenizer.init(allocator, "echo $(date)");
    const tokens = try tokenizer.tokenize();
    defer allocator.free(tokens);

    try std.testing.expect(tokens.len >= 2);
}
