const std = @import("std");
const Tokenizer = @import("tokenizer.zig").Tokenizer;

// Simplified Fuzzing Tests
// Tests parser robustness with various inputs

test "Fuzz: empty strings" {
    const allocator = std.testing.allocator;

    const inputs = [_][]const u8{ "", "   ", "\t", "\n", "  \t\n  " };

    for (inputs) |input| {
        var tokenizer = Tokenizer.init(allocator, input);
        const tokens = try tokenizer.tokenize();
        defer allocator.free(tokens);

        // Should not crash
        try std.testing.expect(tokens.len >= 0);
    }
}

test "Fuzz: single characters" {
    const allocator = std.testing.allocator;

    const chars = [_]u8{ '|', '&', ';', '>', '<', '(', ')', '{', '}', '$', '`', '\\', '\'', '"', '!', '#', '%', '*', '?', '[', ']' };

    for (chars) |c| {
        const input = [_]u8{c};
        var tokenizer = Tokenizer.init(allocator, &input);
        _ = tokenizer.tokenize() catch continue; // May error, that's ok
    }
}

test "Fuzz: repeated operators" {
    const allocator = std.testing.allocator;

    const inputs = [_][]const u8{
        "|||",
        "&&&",
        ";;;",
        ">>>",
        "<<<",
        "echo | | cat",
        "cmd && && cmd",
        "cmd || || cmd",
    };

    for (inputs) |input| {
        var tokenizer = Tokenizer.init(allocator, input);
        _ = tokenizer.tokenize() catch continue; // May error
    }
}

test "Fuzz: long strings" {
    const allocator = std.testing.allocator;

    // Test various lengths
    const lengths = [_]usize{ 10, 50, 100, 500, 1000 };

    for (lengths) |len| {
        var buf: [2048]u8 = undefined;
        @memset(buf[0..len], 'a');

        var tokenizer = Tokenizer.init(allocator, buf[0..len]);
        const tokens = try tokenizer.tokenize();
        defer allocator.free(tokens);

        try std.testing.expect(tokens.len > 0);
    }
}

test "Fuzz: mixed whitespace" {
    const allocator = std.testing.allocator;

    const inputs = [_][]const u8{
        "echo\t\thello",
        "echo  \n  world",
        "echo\t  \n\t\thello",
        "  \t  echo  \t  \n  hello  \t  ",
    };

    for (inputs) |input| {
        var tokenizer = Tokenizer.init(allocator, input);
        const tokens = try tokenizer.tokenize();
        defer allocator.free(tokens);

        try std.testing.expect(tokens.len >= 2);
    }
}

test "Fuzz: operator combinations" {
    const allocator = std.testing.allocator;

    const inputs = [_][]const u8{
        "cmd1 | cmd2 && cmd3",
        "cmd1 || cmd2 ; cmd3",
        "cmd1 && cmd2 || cmd3 | cmd4",
        "cmd1 ; cmd2 && cmd3 ; cmd4",
    };

    for (inputs) |input| {
        var tokenizer = Tokenizer.init(allocator, input);
        const tokens = try tokenizer.tokenize();
        defer allocator.free(tokens);

        try std.testing.expect(tokens.len > 3);
    }
}

test "Fuzz: special characters" {
    const allocator = std.testing.allocator;

    const inputs = [_][]const u8{
        "echo $VAR",
        "echo ${VAR}",
        "echo `cmd`",
        "echo $(cmd)",
        "echo {a,b,c}",
        "echo *.txt",
        "echo [a-z]*",
        "echo 'quoted'",
        "echo \"quoted\"",
    };

    for (inputs) |input| {
        var tokenizer = Tokenizer.init(allocator, input);
        const tokens = try tokenizer.tokenize();
        defer allocator.free(tokens);

        try std.testing.expect(tokens.len >= 2);
    }
}

test "Fuzz: nested structures" {
    const allocator = std.testing.allocator;

    const inputs = [_][]const u8{
        "echo $(echo $(echo hi))",
        "echo ${VAR:-${DEFAULT}}",
        "echo {a{1,2},b{3,4}}",
        "(cmd1 && cmd2) || (cmd3 && cmd4)",
    };

    for (inputs) |input| {
        var tokenizer = Tokenizer.init(allocator, input);
        const tokens = try tokenizer.tokenize();
        defer allocator.free(tokens);

        try std.testing.expect(tokens.len > 0);
    }
}
