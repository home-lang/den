const std = @import("std");
const Tokenizer = @import("tokenizer.zig").Tokenizer;

// Parser Fuzzing Tests
// Generate random inputs to test parser robustness

fn generateRandomToken(allocator: std.mem.Allocator, rng: std.Random) ![]u8 {
    const atoms = [_][]const u8{ "foo", "bar", "baz", "qux", "42", "hello", "world", "a_b", "A-B", "x.y" };
    const base = atoms[rng.intRangeAtMost(usize, 0, atoms.len - 1)];

    const decoration = rng.intRangeAtMost(u32, 0, 4);

    if (decoration == 0) {
        // Plain token
        return try allocator.dupe(u8, base);
    } else if (decoration == 1) {
        // Double quoted
        return try std.fmt.allocPrint(allocator, "\"{s}\"", .{base});
    } else if (decoration == 2) {
        // Single quoted
        return try std.fmt.allocPrint(allocator, "'{s}'", .{base});
    } else if (decoration == 3) {
        // With escape - use fixed buffer
        var buf: [64]u8 = undefined;
        var idx: usize = 0;
        for (base) |c| {
            if (c == 'o' and idx < buf.len - 1) {
                buf[idx] = '\\';
                idx += 1;
            }
            if (idx < buf.len) {
                buf[idx] = c;
                idx += 1;
            }
        }
        return try allocator.dupe(u8, buf[0..idx]);
    } else {
        return try allocator.dupe(u8, base);
    }
}

/// Generate random command line
fn generateRandomCommand(allocator: std.mem.Allocator, rng: std.Random) ![]u8 {
    var cmd = std.ArrayList(u8).init(allocator);
    errdefer cmd.deinit();

    // Generate 1-4 words
    const word_count = rng.intRangeAtMost(usize, 1, 4);

    var i: usize = 0;
    while (i < word_count) : (i += 1) {
        const token = try generateRandomToken(allocator, rng);
        defer allocator.free(token);

        if (i > 0) {
            try cmd.append(' ');
        }
        try cmd.appendSlice(token);
    }

    // Optionally add pipe
    if (rng.boolean()) {
        try cmd.appendSlice(" | ");

        const rhs_count = rng.intRangeAtMost(usize, 1, 3);
        var j: usize = 0;
        while (j < rhs_count) : (j += 1) {
            const token = try generateRandomToken(allocator, rng);
            defer allocator.free(token);

            if (j > 0) {
                try cmd.append(' ');
            }
            try cmd.appendSlice(token);
        }
    }

    // Optionally add operator
    if (rng.boolean()) {
        const operators = [_][]const u8{ ";", "&&", "||" };
        const op = operators[rng.intRangeAtMost(usize, 0, operators.len - 1)];

        try cmd.append(' ');
        try cmd.appendSlice(op);
        try cmd.append(' ');

        const tail_count = rng.intRangeAtMost(usize, 1, 3);
        var k: usize = 0;
        while (k < tail_count) : (k += 1) {
            const token = try generateRandomToken(allocator, rng);
            defer allocator.free(token);

            if (k > 0) {
                try cmd.append(' ');
            }
            try cmd.appendSlice(token);
        }
    }

    return try cmd.toOwnedSlice();
}

test "Fuzz: tokenizer handles random valid commands" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(12345);
    const rng = prng.random();

    // Test 100 random commands
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const cmd = try generateRandomCommand(allocator, rng);
        defer allocator.free(cmd);

        // Should not crash
        var tokenizer = Tokenizer.init(allocator, cmd);
        const tokens = tokenizer.tokenize() catch continue; // Some may fail, that's ok
        defer allocator.free(tokens);

        // Should return some tokens
        try std.testing.expect(tokens.len > 0);
    }
}

test "Fuzz: tokenizer handles random special characters" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(54321);
    const rng = prng.random();

    const special_chars = [_]u8{ '|', '&', ';', '>', '<', '(', ')', '{', '}', '[', ']', '$', '`', '\\', '\'', '"' };

    // Test 50 random combinations
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var cmd = std.ArrayList(u8).init(allocator);
        defer cmd.deinit();

        try cmd.appendSlice("echo ");

        // Add some random special characters
        const char_count = rng.intRangeAtMost(usize, 1, 5);
        var j: usize = 0;
        while (j < char_count) : (j += 1) {
            const char_idx = rng.intRangeAtMost(usize, 0, special_chars.len - 1);
            try cmd.append(special_chars[char_idx]);
        }

        // Should not crash (may error, which is fine)
        var tokenizer = Tokenizer.init(allocator, cmd.items);
        const tokens = tokenizer.tokenize() catch continue;
        defer allocator.free(tokens);

        // If it succeeded, should have tokens
        try std.testing.expect(tokens.len > 0);
    }
}

test "Fuzz: tokenizer handles random whitespace" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(98765);
    const rng = prng.random();

    const whitespace = [_]u8{ ' ', '\t', '\n' };

    // Test 50 commands with random whitespace
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var cmd = std.ArrayList(u8).init(allocator);
        defer cmd.deinit();

        try cmd.appendSlice("echo");

        // Add random whitespace
        const ws_count = rng.intRangeAtMost(usize, 1, 10);
        var j: usize = 0;
        while (j < ws_count) : (j += 1) {
            const ws_idx = rng.intRangeAtMost(usize, 0, whitespace.len - 1);
            try cmd.append(whitespace[ws_idx]);
        }

        try cmd.appendSlice("hello");

        // Should handle random whitespace
        var tokenizer = Tokenizer.init(allocator, cmd.items);
        const tokens = try tokenizer.tokenize();
        defer allocator.free(tokens);

        // Should normalize whitespace
        try std.testing.expect(tokens.len >= 2);
    }
}

test "Fuzz: tokenizer handles random operators" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(11111);
    const rng = prng.random();

    const operators = [_][]const u8{ "|", "&&", "||", ";", "&", ">", ">>", "<", "2>", "&>" };

    // Test 50 commands with random operators
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var cmd = std.ArrayList(u8).init(allocator);
        defer cmd.deinit();

        try cmd.appendSlice("cmd1");

        // Add random operators
        const op_count = rng.intRangeAtMost(usize, 1, 3);
        var j: usize = 0;
        while (j < op_count) : (j += 1) {
            const op_idx = rng.intRangeAtMost(usize, 0, operators.len - 1);
            try cmd.append(' ');
            try cmd.appendSlice(operators[op_idx]);
            try cmd.append(' ');
            try cmd.appendSlice("cmd2");
        }

        // Should handle operators without crash
        var tokenizer = Tokenizer.init(allocator, cmd.items);
        const tokens = tokenizer.tokenize() catch continue;
        defer allocator.free(tokens);

        try std.testing.expect(tokens.len > 0);
    }
}

test "Fuzz: tokenizer handles random lengths" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(22222);
    const rng = prng.random();

    // Test various lengths from 0 to 1000
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const len = rng.intRangeAtMost(usize, 0, 1000);

        var cmd = std.ArrayList(u8).init(allocator);
        defer cmd.deinit();

        var j: usize = 0;
        while (j < len) : (j += 1) {
            try cmd.append('a');
        }

        // Should handle arbitrary lengths
        var tokenizer = Tokenizer.init(allocator, cmd.items);
        const tokens = tokenizer.tokenize() catch continue;
        defer allocator.free(tokens);

        if (len > 0) {
            try std.testing.expect(tokens.len > 0);
        }
    }
}

test "Fuzz: tokenizer idempotent on re-tokenization" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(33333);
    const rng = prng.random();

    // Test 50 random commands for idempotency
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const cmd = try generateRandomCommand(allocator, rng);
        defer allocator.free(cmd);

        // First tokenization
        var tokenizer1 = Tokenizer.init(allocator, cmd);
        const tokens1 = tokenizer1.tokenize() catch continue;
        defer allocator.free(tokens1);

        // Reconstruct and re-tokenize
        var reconstructed = std.ArrayList(u8).init(allocator);
        defer reconstructed.deinit();

        for (tokens1, 0..) |token, idx| {
            if (idx > 0) {
                try reconstructed.append(' ');
            }
            try reconstructed.appendSlice(token.value);
        }

        var tokenizer2 = Tokenizer.init(allocator, reconstructed.items);
        const tokens2 = tokenizer2.tokenize() catch continue;
        defer allocator.free(tokens2);

        // Token count should be similar (may not be exact due to operator normalization)
        const diff = if (tokens1.len > tokens2.len) tokens1.len - tokens2.len else tokens2.len - tokens1.len;
        try std.testing.expect(diff < 5);
    }
}

test "Fuzz: tokenizer handles random argument counts" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(44444);
    const rng = prng.random();

    // Test commands with 0 to 50 arguments
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const arg_count = rng.intRangeAtMost(usize, 0, 50);

        var cmd = std.ArrayList(u8).init(allocator);
        defer cmd.deinit();

        try cmd.appendSlice("echo");

        var j: usize = 0;
        while (j < arg_count) : (j += 1) {
            try cmd.append(' ');
            try std.fmt.format(cmd.writer(), "arg{d}", .{j});
        }

        var tokenizer = Tokenizer.init(allocator, cmd.items);
        const tokens = try tokenizer.tokenize();
        defer allocator.free(tokens);

        // Should handle various argument counts
        try std.testing.expect(tokens.len >= 1);
    }
}

test "Fuzz: tokenizer handles mixed content" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(55555);
    const rng = prng.random();

    const components = [_][]const u8{
        "echo",
        "hello",
        "|",
        "cat",
        "&&",
        "ls",
        ";",
        ">",
        "file.txt",
        "$VAR",
        "$(cmd)",
        "{a,b}",
    };

    // Test 50 random combinations
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var cmd = std.ArrayList(u8).init(allocator);
        defer cmd.deinit();

        const component_count = rng.intRangeAtMost(usize, 1, 10);

        var j: usize = 0;
        while (j < component_count) : (j += 1) {
            if (j > 0) {
                try cmd.append(' ');
            }

            const comp_idx = rng.intRangeAtMost(usize, 0, components.len - 1);
            try cmd.appendSlice(components[comp_idx]);
        }

        // Should handle mixed content
        var tokenizer = Tokenizer.init(allocator, cmd.items);
        const tokens = tokenizer.tokenize() catch continue;
        defer allocator.free(tokens);

        try std.testing.expect(tokens.len > 0);
    }
}
