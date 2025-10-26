const std = @import("std");

/// Test utilities for Den shell tests
/// Provides helpers for temporary files, process mocking, and test assertions

/// Temporary directory manager for tests
pub const TempDir = struct {
    path: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !TempDir {
        const tmp_dir_template = "den_test_XXXXXX";
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;

        // Create unique temp directory
        const tmp_path = try std.fmt.bufPrint(&path_buf, "/tmp/{s}", .{tmp_dir_template});

        // Generate unique name
        var random = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        const rand_num = random.random().int(u32);
        const unique_name = try std.fmt.allocPrint(allocator, "den_test_{d}", .{rand_num});
        defer allocator.free(unique_name);

        const full_path = try std.fmt.allocPrint(allocator, "/tmp/{s}", .{unique_name});

        // Create directory
        try std.fs.cwd().makePath(full_path);

        return TempDir{
            .path = full_path,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TempDir) void {
        // Clean up temp directory
        std.fs.cwd().deleteTree(self.path) catch {};
        self.allocator.free(self.path);
    }

    /// Create a file in the temp directory
    pub fn createFile(self: *TempDir, name: []const u8, content: []const u8) ![]const u8 {
        const file_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.path, name });

        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        try file.writeAll(content);

        return file_path;
    }

    /// Create a directory in the temp directory
    pub fn createDir(self: *TempDir, name: []const u8) ![]const u8 {
        const dir_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.path, name });
        try std.fs.cwd().makePath(dir_path);
        return dir_path;
    }

    /// Read a file from the temp directory
    pub fn readFile(self: *TempDir, name: []const u8) ![]const u8 {
        const file_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.path, name });
        defer self.allocator.free(file_path);

        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        return try file.readToEndAlloc(self.allocator, 1024 * 1024);
    }
};

/// Process mock for testing command execution
pub const ProcessMock = struct {
    command: []const u8,
    args: []const []const u8,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, command: []const u8) ProcessMock {
        return ProcessMock{
            .command = command,
            .args = &[_][]const u8{},
            .stdout = "",
            .stderr = "",
            .exit_code = 0,
            .allocator = allocator,
        };
    }

    pub fn withArgs(self: *ProcessMock, args: []const []const u8) *ProcessMock {
        self.args = args;
        return self;
    }

    pub fn withStdout(self: *ProcessMock, stdout: []const u8) *ProcessMock {
        self.stdout = stdout;
        return self;
    }

    pub fn withStderr(self: *ProcessMock, stderr: []const u8) *ProcessMock {
        self.stderr = stderr;
        return self;
    }

    pub fn withExitCode(self: *ProcessMock, code: u8) *ProcessMock {
        self.exit_code = code;
        return self;
    }

    pub fn execute(self: *ProcessMock) !struct { stdout: []const u8, stderr: []const u8, exit_code: u8 } {
        return .{
            .stdout = self.stdout,
            .stderr = self.stderr,
            .exit_code = self.exit_code,
        };
    }
};

/// Test assertions
pub const TestAssert = struct {
    /// Assert two strings are equal
    pub fn expectEqualStrings(expected: []const u8, actual: []const u8) !void {
        try std.testing.expectEqualStrings(expected, actual);
    }

    /// Assert two values are equal
    pub fn expectEqual(expected: anytype, actual: anytype) !void {
        try std.testing.expectEqual(expected, actual);
    }

    /// Assert condition is true
    pub fn expectTrue(condition: bool) !void {
        try std.testing.expect(condition);
    }

    /// Assert condition is false
    pub fn expectFalse(condition: bool) !void {
        try std.testing.expect(!condition);
    }

    /// Assert string contains substring
    pub fn expectContains(haystack: []const u8, needle: []const u8) !void {
        if (std.mem.indexOf(u8, haystack, needle) == null) {
            std.debug.print("Expected '{s}' to contain '{s}'\n", .{ haystack, needle });
            return error.TestExpectedContains;
        }
    }

    /// Assert string starts with prefix
    pub fn expectStartsWith(str: []const u8, prefix: []const u8) !void {
        if (!std.mem.startsWith(u8, str, prefix)) {
            std.debug.print("Expected '{s}' to start with '{s}'\n", .{ str, prefix });
            return error.TestExpectedStartsWith;
        }
    }

    /// Assert string ends with suffix
    pub fn expectEndsWith(str: []const u8, suffix: []const u8) !void {
        if (!std.mem.endsWith(u8, str, suffix)) {
            std.debug.print("Expected '{s}' to end with '{s}'\n", .{ str, suffix });
            return error.TestExpectedEndsWith;
        }
    }

    /// Assert error is expected
    pub fn expectError(expected_error: anyerror, result: anytype) !void {
        try std.testing.expectError(expected_error, result);
    }
};

/// Shell fixture for testing shell operations
pub const ShellFixture = struct {
    temp_dir: TempDir,
    allocator: std.mem.Allocator,
    env_vars: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) !ShellFixture {
        const temp_dir = try TempDir.init(allocator);

        return ShellFixture{
            .temp_dir = temp_dir,
            .allocator = allocator,
            .env_vars = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ShellFixture) void {
        var it = self.env_vars.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.env_vars.deinit();
        self.temp_dir.deinit();
    }

    /// Set environment variable for test
    pub fn setEnv(self: *ShellFixture, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.env_vars.put(key_copy, value_copy);
    }

    /// Get environment variable
    pub fn getEnv(self: *ShellFixture, key: []const u8) ?[]const u8 {
        return self.env_vars.get(key);
    }

    /// Create a test script file
    pub fn createScript(self: *ShellFixture, name: []const u8, content: []const u8) ![]const u8 {
        const script_path = try self.temp_dir.createFile(name, content);

        // Make executable
        const file = try std.fs.cwd().openFile(script_path, .{});
        defer file.close();

        // Set executable permissions (0755)
        if (@import("builtin").os.tag != .windows) {
            try file.chmod(0o755);
        }

        return script_path;
    }

    /// Execute a command and capture output
    pub fn exec(self: *ShellFixture, command: []const u8) !struct { stdout: []const u8, stderr: []const u8, exit_code: u8 } {
        _ = self;

        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        try args.append("sh");
        try args.append("-c");
        try args.append(command);

        var child = std.process.Child.init(args.items, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        // Set environment variables
        var env_list = std.ArrayList([]const u8).init(self.allocator);
        defer env_list.deinit();

        var it = self.env_vars.iterator();
        while (it.next()) |entry| {
            const env_str = try std.fmt.allocPrint(self.allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
            try env_list.append(env_str);
        }

        if (env_list.items.len > 0) {
            child.env_map = &std.process.EnvMap.init(self.allocator);
            for (env_list.items) |env_str| {
                const eq_pos = std.mem.indexOf(u8, env_str, "=") orelse continue;
                const key = env_str[0..eq_pos];
                const value = env_str[eq_pos + 1 ..];
                try child.env_map.?.put(key, value);
            }
        }

        try child.spawn();

        var stdout_buf = std.ArrayList(u8).init(self.allocator);
        defer stdout_buf.deinit();
        var stderr_buf = std.ArrayList(u8).init(self.allocator);
        defer stderr_buf.deinit();

        if (child.stdout) |stdout| {
            try stdout.reader().readAllArrayList(&stdout_buf, 1024 * 1024);
        }

        if (child.stderr) |stderr| {
            try stderr.reader().readAllArrayList(&stderr_buf, 1024 * 1024);
        }

        const term = try child.wait();
        const exit_code: u8 = switch (term) {
            .Exited => |code| @intCast(code),
            else => 1,
        };

        const stdout_owned = try self.allocator.dupe(u8, stdout_buf.items);
        const stderr_owned = try self.allocator.dupe(u8, stderr_buf.items);

        return .{
            .stdout = stdout_owned,
            .stderr = stderr_owned,
            .exit_code = exit_code,
        };
    }
};

/// Helper to create temporary test files
pub fn createTempFile(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var temp_dir = try TempDir.init(allocator);
    defer temp_dir.deinit();

    return try temp_dir.createFile("test_file.txt", content);
}

/// Helper to run a command and get output
pub fn runCommand(allocator: std.mem.Allocator, cmd: []const u8) ![]const u8 {
    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    try args.append("sh");
    try args.append("-c");
    try args.append(cmd);

    var child = std.process.Child.init(args.items, allocator);
    child.stdout_behavior = .Pipe;

    try child.spawn();

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    if (child.stdout) |stdout| {
        try stdout.reader().readAllArrayList(&stdout_buf, 1024 * 1024);
    }

    _ = try child.wait();

    return try allocator.dupe(u8, stdout_buf.items);
}

// Tests for test utilities
test "TempDir creates and cleans up" {
    const allocator = std.testing.allocator;

    var temp_dir = try TempDir.init(allocator);
    defer temp_dir.deinit();

    // Verify directory exists
    var dir = try std.fs.cwd().openDir(temp_dir.path, .{});
    dir.close();
}

test "TempDir.createFile creates file" {
    const allocator = std.testing.allocator;

    var temp_dir = try TempDir.init(allocator);
    defer temp_dir.deinit();

    const file_path = try temp_dir.createFile("test.txt", "hello world");
    defer allocator.free(file_path);

    const content = try temp_dir.readFile("test.txt");
    defer allocator.free(content);

    try TestAssert.expectEqualStrings("hello world", content);
}

test "TestAssert.expectContains works" {
    try TestAssert.expectContains("hello world", "world");
    try TestAssert.expectContains("hello world", "hello");
}

test "TestAssert.expectStartsWith works" {
    try TestAssert.expectStartsWith("hello world", "hello");
}

test "TestAssert.expectEndsWith works" {
    try TestAssert.expectEndsWith("hello world", "world");
}

test "ShellFixture environment variables" {
    const allocator = std.testing.allocator;

    var fixture = try ShellFixture.init(allocator);
    defer fixture.deinit();

    try fixture.setEnv("TEST_VAR", "test_value");

    const value = fixture.getEnv("TEST_VAR");
    try TestAssert.expectEqualStrings("test_value", value.?);
}
