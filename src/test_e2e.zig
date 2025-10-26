const std = @import("std");
const test_utils = @import("test_utils.zig");

// End-to-End Tests
// Tests that verify the complete system from user input to output

test "E2E: basic echo command" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo 'Hello, World!'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "Hello, World!");
}

test "E2E: file operations" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    // Create a file
    const file_path = try std.fs.path.join(allocator, &[_][]const u8{ fixture.temp_dir.path, "test.txt" });
    defer allocator.free(file_path);

    const cmd1 = try std.fmt.allocPrint(allocator, "echo 'test content' > {s}", .{file_path});
    defer allocator.free(cmd1);

    const result1 = try fixture.exec(cmd1);
    defer allocator.free(result1.stdout);
    defer allocator.free(result1.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result1.exit_code);

    // Read the file
    const cmd2 = try std.fmt.allocPrint(allocator, "cat {s}", .{file_path});
    defer allocator.free(cmd2);

    const result2 = try fixture.exec(cmd2);
    defer allocator.free(result2.stdout);
    defer allocator.free(result2.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result2.exit_code);
    try test_utils.TestAssert.expectContains(result2.stdout, "test content");
}

test "E2E: directory navigation" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    // Create subdirectory
    const subdir = try fixture.temp_dir.createDir("subdir");
    defer allocator.free(subdir);

    // Change to subdirectory and verify
    const cmd1 = try std.fmt.allocPrint(allocator, "cd {s} && pwd", .{subdir});
    defer allocator.free(cmd1);

    const result = try fixture.exec(cmd1);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "subdir");
}

test "E2E: complex pipeline with filtering" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    // Create a test file with multiple lines
    const test_file = try fixture.temp_dir.createFile("lines.txt", "apple\nbanana\napricot");
    defer allocator.free(test_file);

    const cmd = try std.fmt.allocPrint(allocator, "cat {s} | grep '^a'", .{test_file});
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "apple");
    try test_utils.TestAssert.expectContains(result.stdout, "apricot");
}

test "E2E: script with multiple commands" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const script_content =
        \\#!/bin/sh
        \\echo "Starting script"
        \\VAR=test_value
        \\echo "Variable: $VAR"
        \\echo "Script complete"
    ;

    const script_path = try fixture.createScript("multi.sh", script_content);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "Starting script");
    try test_utils.TestAssert.expectContains(result.stdout, "test_value");
    try test_utils.TestAssert.expectContains(result.stdout, "Script complete");
}

test "E2E: conditional logic" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const script_content =
        \\#!/bin/sh
        \\if true; then
        \\  echo "condition true"
        \\else
        \\  echo "condition false"
        \\fi
    ;

    const script_path = try fixture.createScript("conditional.sh", script_content);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "condition true");
}

test "E2E: loop execution" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const script_content =
        \\#!/bin/sh
        \\for i in 1 2 3; do
        \\  echo "Number: $i"
        \\done
    ;

    const script_path = try fixture.createScript("loop.sh", script_content);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "Number: 1");
    try test_utils.TestAssert.expectContains(result.stdout, "Number: 2");
    try test_utils.TestAssert.expectContains(result.stdout, "Number: 3");
}

test "E2E: error propagation" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("false && echo 'should not print'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Output should not contain the message
    const contains = std.mem.indexOf(u8, result.stdout, "should not print");
    try test_utils.TestAssert.expectTrue(contains == null);
}

test "E2E: multiple file operations" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const file1 = try std.fs.path.join(allocator, &[_][]const u8{ fixture.temp_dir.path, "file1.txt" });
    defer allocator.free(file1);

    const file2 = try std.fs.path.join(allocator, &[_][]const u8{ fixture.temp_dir.path, "file2.txt" });
    defer allocator.free(file2);

    // Create multiple files
    const cmd = try std.fmt.allocPrint(
        allocator,
        "echo 'content1' > {s} && echo 'content2' > {s}",
        .{ file1, file2 },
    );
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);

    // Verify both files exist
    const content1 = try fixture.temp_dir.readFile("file1.txt");
    defer allocator.free(content1);
    try test_utils.TestAssert.expectContains(content1, "content1");

    const content2 = try fixture.temp_dir.readFile("file2.txt");
    defer allocator.free(content2);
    try test_utils.TestAssert.expectContains(content2, "content2");
}

test "E2E: text processing pipeline" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    // Create a file with content
    const input_file = try fixture.temp_dir.createFile("input.txt", "line1\nline2\nline3\n");
    defer allocator.free(input_file);

    const cmd = try std.fmt.allocPrint(
        allocator,
        "cat {s} | grep line2",
        .{input_file},
    );
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "line2");
}

test "E2E: append operation" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const output_file = try std.fs.path.join(allocator, &[_][]const u8{ fixture.temp_dir.path, "append.txt" });
    defer allocator.free(output_file);

    // Write first line
    const cmd1 = try std.fmt.allocPrint(allocator, "echo 'first' > {s}", .{output_file});
    defer allocator.free(cmd1);

    const result1 = try fixture.exec(cmd1);
    defer allocator.free(result1.stdout);
    defer allocator.free(result1.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result1.exit_code);

    // Append second line
    const cmd2 = try std.fmt.allocPrint(allocator, "echo 'second' >> {s}", .{output_file});
    defer allocator.free(cmd2);

    const result2 = try fixture.exec(cmd2);
    defer allocator.free(result2.stdout);
    defer allocator.free(result2.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result2.exit_code);

    // Verify both lines are present
    const content = try fixture.temp_dir.readFile("append.txt");
    defer allocator.free(content);

    try test_utils.TestAssert.expectContains(content, "first");
    try test_utils.TestAssert.expectContains(content, "second");
}

test "E2E: command chaining with different operators" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo a ; echo b && echo c || echo d");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "a");
    try test_utils.TestAssert.expectContains(result.stdout, "b");
    try test_utils.TestAssert.expectContains(result.stdout, "c");
}

test "E2E: working directory persistence" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const subdir = try fixture.temp_dir.createDir("persistent");
    defer allocator.free(subdir);

    const cmd = try std.fmt.allocPrint(
        allocator,
        "cd {s} && echo 'file content' > test.txt && cat test.txt",
        .{subdir},
    );
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "file content");
}

test "E2E: large output handling" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    // Generate large output
    const result = try fixture.exec("seq 1 100");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "1");
    try test_utils.TestAssert.expectContains(result.stdout, "100");
}

test "E2E: special characters in filenames" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const file_name = "test-file_123.txt";
    const file_path = try std.fs.path.join(allocator, &[_][]const u8{ fixture.temp_dir.path, file_name });
    defer allocator.free(file_path);

    const cmd = try std.fmt.allocPrint(allocator, "echo 'special chars' > {s} && cat {s}", .{ file_path, file_path });
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "special chars");
}

test "E2E: exit code propagation" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("false");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // false command should return 1
    try test_utils.TestAssert.expectTrue(result.exit_code != 0);
}

test "E2E: true command success" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("true");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}
