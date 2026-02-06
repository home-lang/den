const std = @import("std");
const types = @import("types.zig");

const ModuleInfo = types.ModuleInfo;
const LanguageModule = types.LanguageModule;

/// Execute a command and get version string
fn getCommandVersion(allocator: std.mem.Allocator, argv: []const []const u8) !?[]const u8 {
    var child = std.process.spawn(std.Options.debug_io, .{
        .argv = argv,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return null;

    // Read both stdout and stderr (some commands output to stderr)
    var stdout_read_buf: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.readerStreaming(std.Options.debug_io, &stdout_read_buf);
    const stdout = stdout_reader.interface.allocRemaining(allocator, .limited(4096)) catch "";
    defer allocator.free(stdout);

    var stderr_read_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.readerStreaming(std.Options.debug_io, &stderr_read_buf);
    const stderr = stderr_reader.interface.allocRemaining(allocator, .limited(4096)) catch "";
    defer allocator.free(stderr);

    const status = child.wait(std.Options.debug_io) catch return null;

    // Check if command succeeded
    if (status != .exited or status.exited != 0) {
        // Some commands (like java) output version to stderr even on success
        if (stderr.len > 0) {
            const trimmed = std.mem.trim(u8, stderr, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                return try parseVersion(allocator, trimmed);
            }
        }
        return null;
    }

    // Prefer stdout, but fall back to stderr
    const output = if (stdout.len > 0) stdout else stderr;
    const trimmed = std.mem.trim(u8, output, &std.ascii.whitespace);

    if (trimmed.len == 0) {
        return null;
    }

    return try parseVersion(allocator, trimmed);
}

/// Parse version from command output
pub fn parseVersion(allocator: std.mem.Allocator, output: []const u8) ![]const u8 {
    // Take first line
    var line_iter = std.mem.splitScalar(u8, output, '\n');
    const first_line = line_iter.next() orelse return error.InvalidVersion;

    // Common patterns:
    // - "v1.2.3"
    // - "node v1.2.3"
    // - "go version go1.2.3 darwin/arm64"
    // - "rustc 1.2.3 (hash date)"
    // - "java version "1.2.3""

    var version_start: ?usize = null;
    var version_end: ?usize = null;

    // Look for version pattern: digit followed by dot
    var i: usize = 0;
    while (i < first_line.len) : (i += 1) {
        const c = first_line[i];
        if (std.ascii.isDigit(c)) {
            // Found a digit, check if there's a dot after some digits
            var j = i;
            while (j < first_line.len and std.ascii.isDigit(first_line[j])) : (j += 1) {}

            if (j < first_line.len and first_line[j] == '.') {
                // This looks like a version number
                version_start = i;
                break;
            }
        }
    }

    if (version_start) |start| {
        // Find end of version (space, quote, or end of string)
        version_end = start;
        while (version_end.? < first_line.len) : (version_end = version_end.? + 1) {
            const c = first_line[version_end.?];
            if (c == ' ' or c == '"' or c == ')' or c == '\t') {
                break;
            }
        }

        const version = first_line[start..version_end.?];
        return try allocator.dupe(u8, version);
    }

    // If no version pattern found, just return first word
    var word_iter = std.mem.tokenizeAny(u8, first_line, " \t\"");
    if (word_iter.next()) |word| {
        // Skip "v" prefix
        const clean = if (word.len > 0 and word[0] == 'v') word[1..] else word;
        return try allocator.dupe(u8, clean);
    }

    return error.InvalidVersion;
}

/// Check if any file pattern exists in directory
fn hasFilePattern(allocator: std.mem.Allocator, cwd: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pattern| {
        const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, pattern }) catch continue;
        defer allocator.free(path);

        std.Io.Dir.accessAbsolute(std.Options.debug_io, path, .{}) catch continue;
        return true;
    }
    return false;
}

/// Detect Bun
pub fn detectBun(allocator: std.mem.Allocator, cwd: []const u8) !?ModuleInfo {
    if (!hasFilePattern(allocator, cwd, LanguageModule.Bun.file_patterns)) {
        return null;
    }

    const version = try getCommandVersion(allocator, &[_][]const u8{ "bun", "--version" }) orelse return null;

    var info = ModuleInfo.init(LanguageModule.Bun.name);
    info.version = version;
    info.icon = LanguageModule.Bun.icon;
    info.color = LanguageModule.Bun.color;

    return info;
}

/// Detect Node.js
pub fn detectNode(allocator: std.mem.Allocator, cwd: []const u8) !?ModuleInfo {
    if (!hasFilePattern(allocator, cwd, LanguageModule.Node.file_patterns)) {
        return null;
    }

    const version = try getCommandVersion(allocator, &[_][]const u8{ "node", "--version" }) orelse return null;

    var info = ModuleInfo.init(LanguageModule.Node.name);
    info.version = version;
    info.icon = LanguageModule.Node.icon;
    info.color = LanguageModule.Node.color;

    return info;
}

/// Detect Python
pub fn detectPython(allocator: std.mem.Allocator, cwd: []const u8) !?ModuleInfo {
    if (!hasFilePattern(allocator, cwd, LanguageModule.Python.file_patterns)) {
        return null;
    }

    const version = try getCommandVersion(allocator, &[_][]const u8{ "python", "--version" }) orelse
        try getCommandVersion(allocator, &[_][]const u8{ "python3", "--version" }) orelse
        return null;

    var info = ModuleInfo.init(LanguageModule.Python.name);
    info.version = version;
    info.icon = LanguageModule.Python.icon;
    info.color = LanguageModule.Python.color;

    return info;
}

/// Detect Go
pub fn detectGo(allocator: std.mem.Allocator, cwd: []const u8) !?ModuleInfo {
    if (!hasFilePattern(allocator, cwd, LanguageModule.Go.file_patterns)) {
        return null;
    }

    const version = try getCommandVersion(allocator, &[_][]const u8{ "go", "version" }) orelse return null;

    var info = ModuleInfo.init(LanguageModule.Go.name);
    info.version = version;
    info.icon = LanguageModule.Go.icon;
    info.color = LanguageModule.Go.color;

    return info;
}

/// Detect Zig
pub fn detectZig(allocator: std.mem.Allocator, cwd: []const u8) !?ModuleInfo {
    if (!hasFilePattern(allocator, cwd, LanguageModule.Zig.file_patterns)) {
        return null;
    }

    const version = try getCommandVersion(allocator, &[_][]const u8{ "zig", "version" }) orelse return null;

    var info = ModuleInfo.init(LanguageModule.Zig.name);
    info.version = version;
    info.icon = LanguageModule.Zig.icon;
    info.color = LanguageModule.Zig.color;

    return info;
}

/// Detect Rust
pub fn detectRust(allocator: std.mem.Allocator, cwd: []const u8) !?ModuleInfo {
    if (!hasFilePattern(allocator, cwd, LanguageModule.Rust.file_patterns)) {
        return null;
    }

    const version = try getCommandVersion(allocator, &[_][]const u8{ "rustc", "--version" }) orelse return null;

    var info = ModuleInfo.init(LanguageModule.Rust.name);
    info.version = version;
    info.icon = LanguageModule.Rust.icon;
    info.color = LanguageModule.Rust.color;

    return info;
}

/// Detect Java
pub fn detectJava(allocator: std.mem.Allocator, cwd: []const u8) !?ModuleInfo {
    if (!hasFilePattern(allocator, cwd, LanguageModule.Java.file_patterns)) {
        return null;
    }

    const version = try getCommandVersion(allocator, &[_][]const u8{ "java", "-version" }) orelse return null;

    var info = ModuleInfo.init(LanguageModule.Java.name);
    info.version = version;
    info.icon = LanguageModule.Java.icon;
    info.color = LanguageModule.Java.color;

    return info;
}

/// Detect Ruby
pub fn detectRuby(allocator: std.mem.Allocator, cwd: []const u8) !?ModuleInfo {
    if (!hasFilePattern(allocator, cwd, LanguageModule.Ruby.file_patterns)) {
        return null;
    }

    const version = try getCommandVersion(allocator, &[_][]const u8{ "ruby", "--version" }) orelse return null;

    var info = ModuleInfo.init(LanguageModule.Ruby.name);
    info.version = version;
    info.icon = LanguageModule.Ruby.icon;
    info.color = LanguageModule.Ruby.color;

    return info;
}

/// Detect PHP
pub fn detectPHP(allocator: std.mem.Allocator, cwd: []const u8) !?ModuleInfo {
    if (!hasFilePattern(allocator, cwd, LanguageModule.PHP.file_patterns)) {
        return null;
    }

    const version = try getCommandVersion(allocator, &[_][]const u8{ "php", "--version" }) orelse return null;

    var info = ModuleInfo.init(LanguageModule.PHP.name);
    info.version = version;
    info.icon = LanguageModule.PHP.icon;
    info.color = LanguageModule.PHP.color;

    return info;
}
