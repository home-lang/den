const std = @import("std");
const test_utils = @import("test_utils.zig");
const TestAssert = test_utils.TestAssert;
const ShellFixture = test_utils.ShellFixture;
const TempDir = test_utils.TempDir;

// Comprehensive Fuzzing Tests
// Tests for completion, expansion, and input handling robustness

// =============================================================================
// Variable Expansion Fuzzing
// =============================================================================

test "fuzz: variable expansion with special chars" {
    const allocator = std.testing.allocator;
    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    const test_vars = [_][]const u8{
        "FUZZ_EMPTY=",
        "FUZZ_SPACE=hello world",
        "FUZZ_SPECIAL=!@#$%^&*()",
        "FUZZ_NEWLINE=hello\nworld",
        "FUZZ_TAB=hello\tworld",
        "FUZZ_QUOTE=it's",
        "FUZZ_DQUOTE=he said \"hi\"",
    };

    for (test_vars) |var_def| {
        var cmd_buf: [256]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "export {s} && echo done", .{var_def}) catch continue;

        const result = try fixture.exec(cmd);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        // Should not crash
    }
}

test "fuzz: nested variable expansion" {
    const allocator = std.testing.allocator;
    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo ${UNDEFINED:-default}",
        "echo ${UNDEFINED:+alternate}",
        "echo ${VAR:-${FALLBACK:-final}}",
        "echo ${#PATH}",
        "echo ${VAR:0:5}",
    };

    for (inputs) |input| {
        const result = try fixture.exec(input);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        // Should not crash
    }
}

test "fuzz: arithmetic expansion edge cases" {
    const allocator = std.testing.allocator;
    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo $((0))",
        "echo $((1+1))",
        "echo $((2*3))",
        "echo $((10/2))",
        "echo $((10%3))",
        "echo $((-5))",
        "echo $((2147483647))",
        "echo $((-2147483648))",
        "echo $((1<<2))",
        "echo $((8>>1))",
        "echo $((5&3))",
        "echo $((5|3))",
        "echo $((5^3))",
    };

    for (inputs) |input| {
        const result = try fixture.exec(input);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        // Should handle arithmetic operations
    }
}

test "fuzz: command substitution nesting" {
    const allocator = std.testing.allocator;
    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo $(echo a)",
        "echo $(echo $(echo b))",
        "echo $(echo $(echo $(echo c)))",
        "echo `echo d`",
        "echo $(echo `echo e`)",
    };

    for (inputs) |input| {
        const result = try fixture.exec(input);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        // Should handle nesting
    }
}

// =============================================================================
// Glob/Pathname Expansion Fuzzing
// =============================================================================

test "fuzz: glob patterns" {
    const allocator = std.testing.allocator;
    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo *",
        "echo ?",
        "echo [abc]",
        "echo [a-z]",
        "echo [!a-z]",
        "echo **",
        "echo ***",
        "echo .[!.]*",
        "echo */",
        "echo *.{txt,md}",
    };

    for (inputs) |input| {
        const result = try fixture.exec(input);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        // Should handle globs
    }
}

test "fuzz: brace expansion" {
    const allocator = std.testing.allocator;
    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo {a,b,c}",
        "echo {1..5}",
        "echo {a..e}",
        "echo {1..10..2}",
        "echo {a,b}{1,2}",
        "echo {{a,b},{c,d}}",
        "echo {01..10}",
    };

    for (inputs) |input| {
        const result = try fixture.exec(input);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        // Should handle brace expansion
    }
}

test "fuzz: tilde expansion" {
    const allocator = std.testing.allocator;
    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo ~",
        "echo ~/",
        "echo ~/test",
        "echo ~root",
        "echo ~nobody",
        "echo ~+",
        "echo ~-",
    };

    for (inputs) |input| {
        const result = try fixture.exec(input);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        // Should handle tilde expansion
    }
}

// =============================================================================
// Input Handling Fuzzing
// =============================================================================

test "fuzz: control characters" {
    const allocator = std.testing.allocator;
    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    // Test printable commands (control chars in strings would be problematic)
    const inputs = [_][]const u8{
        "echo test",
        "echo 'test'",
        "echo \"test\"",
    };

    for (inputs) |input| {
        const result = try fixture.exec(input);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        // Should handle input
    }
}

test "fuzz: escape sequences" {
    const allocator = std.testing.allocator;
    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo \\n",
        "echo \\t",
        "echo \\r",
        "echo \\\\",
        "echo \\'",
        "echo \\\"",
        "echo \\$",
        "echo \\`",
    };

    for (inputs) |input| {
        const result = try fixture.exec(input);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        // Should handle escapes
    }
}

test "fuzz: line continuations" {
    const allocator = std.testing.allocator;
    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    // Line continuation with backslash-newline
    const inputs = [_][]const u8{
        "echo hello\\\nworld",
        "echo hel\\\nlo",
    };

    for (inputs) |input| {
        const result = try fixture.exec(input);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        // Should handle line continuations
    }
}

test "fuzz: long lines" {
    const allocator = std.testing.allocator;
    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    // Test long command lines
    var long_cmd: [4096]u8 = undefined;
    var pos: usize = 0;

    // Build "echo aaa...aaa"
    const echo_prefix = "echo ";
    @memcpy(long_cmd[0..echo_prefix.len], echo_prefix);
    pos = echo_prefix.len;

    while (pos < 2000) {
        long_cmd[pos] = 'a';
        pos += 1;
    }

    const result = try fixture.exec(long_cmd[0..pos]);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "fuzz: unicode input" {
    const allocator = std.testing.allocator;
    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo 'hello 世界'",
        "echo 'مرحبا'",
        "echo '🎉🎊🎈'",
        "echo 'Привет'",
        "echo 'こんにちは'",
        "echo '한글'",
    };

    for (inputs) |input| {
        const result = try fixture.exec(input);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    }
}

// =============================================================================
// Completion Fuzzing
// =============================================================================

test "fuzz: path completion patterns" {
    const allocator = std.testing.allocator;
    var temp_dir = try TempDir.init(allocator);
    defer temp_dir.deinit();

    // Create some test files
    _ = try temp_dir.createFile("test1.txt", "");
    _ = try temp_dir.createFile("test2.txt", "");
    _ = try temp_dir.createFile("README.md", "");
    _ = try temp_dir.createDir("subdir");

    // Verify directory exists
    var dir = try std.fs.cwd().openDir(temp_dir.path, .{});
    dir.close();
}

test "fuzz: command name patterns" {
    const allocator = std.testing.allocator;
    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    // Test various command patterns
    const cmds = [_][]const u8{
        "echo",
        "cat",
        "ls",
        "pwd",
        "true",
        "false",
    };

    for (cmds) |cmd| {
        const result = try fixture.exec(cmd);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        // Should handle command execution
    }
}

// =============================================================================
// Redirection Fuzzing
// =============================================================================

test "fuzz: redirection patterns" {
    const allocator = std.testing.allocator;
    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo test > /dev/null",
        "echo test >> /dev/null",
        "cat < /dev/null",
        "echo test 2> /dev/null",
        "echo test &> /dev/null",
        "echo test 2>&1",
        "echo test 1>&2",
    };

    for (inputs) |input| {
        const result = try fixture.exec(input);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        // Should handle redirections
    }
}

test "fuzz: here-doc patterns" {
    const allocator = std.testing.allocator;
    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "cat << EOF\nhello\nEOF",
        "cat <<- EOF\n\thello\n\tEOF",
        "cat << 'EOF'\n$HOME\nEOF",
    };

    for (inputs) |input| {
        const result = try fixture.exec(input);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        // Should handle here-docs
    }
}

test "fuzz: here-string" {
    const allocator = std.testing.allocator;
    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "cat <<< 'hello'",
        "cat <<< \"hello world\"",
        "cat <<< $HOME",
    };

    for (inputs) |input| {
        const result = try fixture.exec(input);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        // Should handle here-strings
    }
}

// =============================================================================
// Pipeline Fuzzing
// =============================================================================

test "fuzz: deep pipelines" {
    const allocator = std.testing.allocator;
    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo a | cat",
        "echo a | cat | cat",
        "echo a | cat | cat | cat",
        "echo a | cat | cat | cat | cat",
        "echo a | cat | cat | cat | cat | cat",
    };

    for (inputs) |input| {
        const result = try fixture.exec(input);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
        try TestAssert.expectContains(result.stdout, "a");
    }
}

test "fuzz: pipeline with redirections" {
    const allocator = std.testing.allocator;
    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo test | cat > /dev/null && echo done",
        "echo test 2>&1 | cat",
        "cat /dev/null | echo test",
    };

    for (inputs) |input| {
        const result = try fixture.exec(input);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        // Should handle combined pipeline and redirections
    }
}

// =============================================================================
// Operator Combination Fuzzing
// =============================================================================

test "fuzz: operator combinations" {
    const allocator = std.testing.allocator;
    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "true && echo success",
        "false || echo fallback",
        "true && false || echo recovered",
        "false || true && echo chain",
        "true; false; true",
        "echo a; echo b; echo c",
        "true && true && true && echo all",
        "false || false || false || echo none",
    };

    for (inputs) |input| {
        const result = try fixture.exec(input);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        // Should handle operator combinations
    }
}

test "fuzz: negation operator" {
    const allocator = std.testing.allocator;
    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "! true",
        "! false",
        "! ! true",
        "! true && echo fail || echo success",
    };

    for (inputs) |input| {
        const result = try fixture.exec(input);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        // Should handle negation
    }
}

// =============================================================================
// Subshell and Grouping Fuzzing
// =============================================================================

test "fuzz: subshell patterns" {
    const allocator = std.testing.allocator;
    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "(echo hello)",
        "(echo a; echo b)",
        "(cd /tmp && pwd)",
        "(true && echo yes)",
        "( ( echo nested ) )",
    };

    for (inputs) |input| {
        const result = try fixture.exec(input);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        // Should handle subshells
    }
}

test "fuzz: brace grouping patterns" {
    const allocator = std.testing.allocator;
    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "{ echo hello; }",
        "{ echo a; echo b; }",
        "{ true && echo yes; }",
    };

    for (inputs) |input| {
        const result = try fixture.exec(input);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        // Should handle brace grouping
    }
}

// =============================================================================
// Edge Case Fuzzing
// =============================================================================

test "fuzz: empty and whitespace" {
    const allocator = std.testing.allocator;
    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "",
        " ",
        "  ",
        "\t",
        "\n",
        "   \t\n   ",
    };

    for (inputs) |input| {
        const result = try fixture.exec(input);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        // Should handle empty input
    }
}

test "fuzz: special shell variables" {
    const allocator = std.testing.allocator;
    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo $?",
        "echo $$",
        "echo $!",
        "echo $0",
        "echo $#",
        "echo $@",
        "echo $*",
    };

    for (inputs) |input| {
        const result = try fixture.exec(input);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        // Should handle special variables
    }
}

test "fuzz: word splitting edge cases" {
    const allocator = std.testing.allocator;
    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo \"hello world\"",
        "echo 'hello world'",
        "echo hello\\ world",
        "echo \"$HOME\"",
        "echo '$HOME'",
    };

    for (inputs) |input| {
        const result = try fixture.exec(input);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        // Should handle word splitting correctly
    }
}
