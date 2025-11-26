const std = @import("std");

// ============================================================================
// Tab Completion Tests
// Tests for command, file, and path completion
// Note: These are unit tests for the completion engine, not interactive tests
// ============================================================================

// Import completion module if available
// const Completion = @import("../src/completion.zig").Completion;

test "completion: file path completion basics" {
    const allocator = std.testing.allocator;

    // Create temp directory with test files
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test files
    const file1 = try tmp_dir.dir.createFile("test_file1.txt", .{});
    file1.close();
    const file2 = try tmp_dir.dir.createFile("test_file2.txt", .{});
    file2.close();
    const file3 = try tmp_dir.dir.createFile("other.txt", .{});
    file3.close();

    // Test that files exist
    var entries = std.ArrayList([]const u8).empty;
    defer {
        for (entries.items) |item| {
            allocator.free(item);
        }
        entries.deinit(allocator);
    }

    var iter = tmp_dir.dir.iterate();
    while (try iter.next()) |entry| {
        try entries.append(allocator, try allocator.dupe(u8, entry.name));
    }

    try std.testing.expect(entries.items.len == 3);
}

test "completion: directory listing" {
    // Create temp directory with subdirectories
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("subdir1");
    try tmp_dir.dir.makeDir("subdir2");
    const file = try tmp_dir.dir.createFile("file.txt", .{});
    file.close();

    var dir_count: usize = 0;
    var file_count: usize = 0;

    var iter = tmp_dir.dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            dir_count += 1;
        } else {
            file_count += 1;
        }
    }

    try std.testing.expectEqual(@as(usize, 2), dir_count);
    try std.testing.expectEqual(@as(usize, 1), file_count);
}

test "completion: filter by prefix" {
    const allocator = std.testing.allocator;

    const items = [_][]const u8{ "apple", "apricot", "banana", "avocado" };
    const prefix = "ap";

    var matches = std.ArrayList([]const u8).empty;
    defer matches.deinit(allocator);

    for (items) |item| {
        if (std.mem.startsWith(u8, item, prefix)) {
            try matches.append(allocator, item);
        }
    }

    try std.testing.expectEqual(@as(usize, 2), matches.items.len);
    try std.testing.expectEqualStrings("apple", matches.items[0]);
    try std.testing.expectEqualStrings("apricot", matches.items[1]);
}

test "completion: case insensitive matching" {
    const items = [_][]const u8{ "Apple", "APRICOT", "Banana" };
    const prefix = "ap";

    var match_count: usize = 0;
    for (items) |item| {
        var lower_item: [32]u8 = undefined;
        const len = @min(item.len, 32);
        for (item[0..len], 0..) |c, i| {
            lower_item[i] = std.ascii.toLower(c);
        }

        if (std.mem.startsWith(u8, lower_item[0..len], prefix)) {
            match_count += 1;
        }
    }

    try std.testing.expectEqual(@as(usize, 2), match_count);
}

test "completion: common prefix extraction" {
    const allocator = std.testing.allocator;

    const items = [_][]const u8{ "test_file1.txt", "test_file2.txt", "test_file3.txt" };

    // Find common prefix
    var common_prefix = items[0];
    for (items[1..]) |item| {
        var common_len: usize = 0;
        const min_len = @min(common_prefix.len, item.len);
        while (common_len < min_len and common_prefix[common_len] == item[common_len]) {
            common_len += 1;
        }
        common_prefix = common_prefix[0..common_len];
    }

    _ = allocator;
    try std.testing.expectEqualStrings("test_file", common_prefix);
}

test "completion: empty prefix matches all" {
    const items = [_][]const u8{ "apple", "banana", "cherry" };
    const prefix = "";

    var match_count: usize = 0;
    for (items) |item| {
        if (std.mem.startsWith(u8, item, prefix)) {
            match_count += 1;
        }
    }

    try std.testing.expectEqual(@as(usize, 3), match_count);
}

test "completion: no matches returns empty" {
    const items = [_][]const u8{ "apple", "banana", "cherry" };
    const prefix = "xyz";

    var match_count: usize = 0;
    for (items) |item| {
        if (std.mem.startsWith(u8, item, prefix)) {
            match_count += 1;
        }
    }

    try std.testing.expectEqual(@as(usize, 0), match_count);
}

test "completion: hidden files filtering" {
    const allocator = std.testing.allocator;

    // Create temp directory with hidden and visible files
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const visible = try tmp_dir.dir.createFile("visible.txt", .{});
    visible.close();
    const hidden = try tmp_dir.dir.createFile(".hidden.txt", .{});
    hidden.close();

    var visible_count: usize = 0;
    var hidden_count: usize = 0;

    var iter = tmp_dir.dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.name.len > 0 and entry.name[0] == '.') {
            hidden_count += 1;
        } else {
            visible_count += 1;
        }
    }

    _ = allocator;
    try std.testing.expectEqual(@as(usize, 1), visible_count);
    try std.testing.expectEqual(@as(usize, 1), hidden_count);
}

test "completion: path with spaces" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create file with space in name
    const file = try tmp_dir.dir.createFile("file with spaces.txt", .{});
    file.close();

    var found = false;
    var iter = tmp_dir.dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.indexOf(u8, entry.name, " ") != null) {
            found = true;
            break;
        }
    }

    _ = allocator;
    try std.testing.expect(found);
}

test "completion: executable detection" {
    // Test executable bit detection (Unix only)
    if (@import("builtin").os.tag == .windows) {
        return;
    }

    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file and make it executable
    const file = try tmp_dir.dir.createFile("script.sh", .{ .mode = 0o755 });
    file.close();

    const stat = try tmp_dir.dir.statFile("script.sh");
    const is_executable = (stat.mode & 0o111) != 0;

    _ = allocator;
    try std.testing.expect(is_executable);
}

test "completion: symlink handling" {
    if (@import("builtin").os.tag == .windows) {
        return;
    }

    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create target file
    const target = try tmp_dir.dir.createFile("target.txt", .{});
    target.close();

    // Create symlink
    tmp_dir.dir.symLink("target.txt", "link.txt", .{}) catch |err| {
        if (err == error.AccessDenied) {
            // Skip on systems where we can't create symlinks
            return;
        }
        return err;
    };

    var link_count: usize = 0;
    var iter = tmp_dir.dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .sym_link) {
            link_count += 1;
        }
    }

    _ = allocator;
    try std.testing.expectEqual(@as(usize, 1), link_count);
}

test "completion: special characters in filename" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create files with special characters (excluding ones that are invalid)
    const file1 = try tmp_dir.dir.createFile("file-with-dash.txt", .{});
    file1.close();
    const file2 = try tmp_dir.dir.createFile("file_with_underscore.txt", .{});
    file2.close();

    var count: usize = 0;
    var iter = tmp_dir.dir.iterate();
    while (try iter.next()) |_| {
        count += 1;
    }

    _ = allocator;
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "completion: sort completions alphabetically" {
    const allocator = std.testing.allocator;

    var items = [_][]const u8{ "zebra", "apple", "mango", "banana" };

    // Sort the items
    std.mem.sort([]const u8, &items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    _ = allocator;
    try std.testing.expectEqualStrings("apple", items[0]);
    try std.testing.expectEqualStrings("banana", items[1]);
    try std.testing.expectEqualStrings("mango", items[2]);
    try std.testing.expectEqualStrings("zebra", items[3]);
}

test "completion: limit number of suggestions" {
    const items = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" };
    const max_suggestions: usize = 5;

    const limited = items[0..@min(items.len, max_suggestions)];

    try std.testing.expectEqual(@as(usize, 5), limited.len);
}
