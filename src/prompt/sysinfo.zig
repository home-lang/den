const std = @import("std");

/// System information provider
pub const SystemInfo = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SystemInfo {
        return .{ .allocator = allocator };
    }

    /// Get current working directory
    pub fn getCurrentDir(self: *SystemInfo) ![]const u8 {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cwd_len = try std.process.currentPath(std.Options.debug_io, &buf);
        return try self.allocator.dupe(u8, buf[0..cwd_len]);
    }

    /// Get home directory
    pub fn getHomeDir(self: *SystemInfo) !?[]const u8 {
        if (std.process.getEnvVarOwned(self.allocator, "HOME") catch null) |home| {
            return home;
        }

        return null;
    }

    /// Get current user name
    pub fn getUsername(self: *SystemInfo) ![]const u8 {
        if (std.process.getEnvVarOwned(self.allocator, "USER") catch null) |user| {
            return user;
        }

        if (std.process.getEnvVarOwned(self.allocator, "USERNAME") catch null) |user| {
            return user;
        }

        return try self.allocator.dupe(u8, "unknown");
    }

    /// Get hostname
    pub fn getHostname(self: *SystemInfo) ![]const u8 {
        if (std.process.getEnvVarOwned(self.allocator, "HOSTNAME") catch null) |hostname| {
            return hostname;
        }

        // Try to read from /etc/hostname on Unix systems
        if (@import("builtin").os.tag != .windows) {
            var file = std.Io.Dir.openFileAbsolute(std.Options.debug_io, "/etc/hostname", .{}) catch {
                return try self.allocator.dupe(u8, "localhost");
            };
            defer file.close(std.Options.debug_io);

            var buf: [256]u8 = undefined;
            var size: usize = 0;
            while (size < buf.len) {
                const n = try file.read(buf[size..]);
                if (n == 0) break;
                size += n;
            }
            const hostname = std.mem.trim(u8, buf[0..size], &std.ascii.whitespace);

            return try self.allocator.dupe(u8, hostname);
        }

        return try self.allocator.dupe(u8, "localhost");
    }

    /// Check if current user is root
    pub fn isRoot(self: *SystemInfo) bool {
        _ = self;

        if (@import("builtin").os.tag == .windows) {
            return false;
        }

        const posix = std.posix;
        return posix.geteuid() == 0;
    }

    /// Abbreviate path with home directory (~)
    pub fn abbreviatePath(self: *SystemInfo, path: []const u8) ![]const u8 {
        const home = try self.getHomeDir() orelse return try self.allocator.dupe(u8, path);
        defer self.allocator.free(home);

        if (std.mem.startsWith(u8, path, home)) {
            const rest = path[home.len..];
            return try std.fmt.allocPrint(self.allocator, "~{s}", .{rest});
        }

        return try self.allocator.dupe(u8, path);
    }

    /// Truncate path to a maximum number of components
    pub fn truncatePath(self: *SystemInfo, path: []const u8, max_components: usize) ![]const u8 {
        if (max_components == 0) {
            return try self.allocator.dupe(u8, path);
        }

        var components: std.ArrayList([]const u8) = .{
            .items = &[_][]const u8{},
            .capacity = 0,
        };
        defer components.deinit(self.allocator);

        var iter = std.mem.splitScalar(u8, path, '/');
        while (iter.next()) |component| {
            if (component.len > 0) {
                try components.append(self.allocator, component);
            }
        }

        const total = components.items.len;
        if (total <= max_components) {
            return try self.allocator.dupe(u8, path);
        }

        // Keep first component and last (max_components - 1) components
        var result: std.ArrayList(u8) = .{
            .items = &[_]u8{},
            .capacity = 0,
        };
        defer result.deinit(self.allocator);

        const starts_with_slash = path.len > 0 and path[0] == '/';
        if (starts_with_slash) {
            try result.append(self.allocator, '/');
        }

        // Add first component
        try result.appendSlice(self.allocator, components.items[0]);

        // Add ellipsis
        try result.appendSlice(self.allocator, "/…");

        // Add remaining components
        const start_idx = total - (max_components - 1);
        for (components.items[start_idx..]) |component| {
            try result.append(self.allocator, '/');
            try result.appendSlice(self.allocator, component);
        }

        return try result.toOwnedSlice(self.allocator);
    }

    /// Get the base name (last component) of a path
    pub fn basename(self: *SystemInfo, path: []const u8) ![]const u8 {
        const base = std.fs.path.basename(path);
        return try self.allocator.dupe(u8, base);
    }

    /// Get parent directory of a path
    pub fn dirname(self: *SystemInfo, path: []const u8) !?[]const u8 {
        const dir = std.fs.path.dirname(path) orelse return null;
        return try self.allocator.dupe(u8, dir);
    }

    /// Detect runtime module versions
    pub fn detectRuntimeModules(self: *SystemInfo) !RuntimeModules {
        var modules = RuntimeModules{
            .node_version = null,
            .bun_version = null,
            .deno_version = null,
            .allocator = self.allocator,
        };

        // Detect Node.js
        modules.node_version = self.getCommandVersion("node", &[_][]const u8{ "node", "--version" }) catch null;

        // Detect Bun
        modules.bun_version = self.getCommandVersion("bun", &[_][]const u8{ "bun", "--version" }) catch null;

        // Detect Deno
        modules.deno_version = self.getCommandVersion("deno", &[_][]const u8{ "deno", "--version" }) catch null;

        return modules;
    }

    /// Get version from a command
    fn getCommandVersion(self: *SystemInfo, _: []const u8, argv: []const []const u8) ![]const u8 {
        var child = std.process.spawn(std.Options.debug_io, .{
            .argv = argv,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return error.CommandNotFound;

        var stdout_read_buf: [1024]u8 = undefined;
        var stdout_reader = child.stdout.?.readerStreaming(std.Options.debug_io, &stdout_read_buf);
        const stdout = stdout_reader.interface.allocRemaining(self.allocator, .limited(1024)) catch return error.CommandNotFound;
        defer self.allocator.free(stdout);

        _ = try child.wait(std.Options.debug_io);

        // Extract version number from output
        const trimmed = std.mem.trim(u8, stdout, &std.ascii.whitespace);

        // Remove 'v' prefix if present
        const version = if (trimmed.len > 0 and trimmed[0] == 'v')
            trimmed[1..]
        else
            trimmed;

        // Take only the first line
        var line_iter = std.mem.splitScalar(u8, version, '\n');
        const first_line = line_iter.next() orelse return error.InvalidVersion;

        return try self.allocator.dupe(u8, first_line);
    }
};

/// Runtime module versions
pub const RuntimeModules = struct {
    node_version: ?[]const u8,
    bun_version: ?[]const u8,
    deno_version: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RuntimeModules) void {
        if (self.node_version) |v| self.allocator.free(v);
        if (self.bun_version) |v| self.allocator.free(v);
        if (self.deno_version) |v| self.allocator.free(v);
    }
};
