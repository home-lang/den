const std = @import("std");

/// Test module information
pub const TestModule = struct {
    name: []const u8,
    path: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, path: []const u8) !TestModule {
        return .{
            .name = try allocator.dupe(u8, name),
            .path = try allocator.dupe(u8, path),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *const TestModule) void {
        self.allocator.free(self.name);
        self.allocator.free(self.path);
    }
};

/// Test discovery engine
pub const TestDiscovery = struct {
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    test_dirs: []const []const u8,

    pub fn init(allocator: std.mem.Allocator, root_dir: []const u8) TestDiscovery {
        return .{
            .allocator = allocator,
            .root_dir = root_dir,
            .test_dirs = &[_][]const u8{ "src", "test" },
        };
    }

    /// Discover all test files in the project
    pub fn discoverTests(self: *TestDiscovery) !std.ArrayList(TestModule) {
        var modules = std.ArrayList(TestModule){};

        for (self.test_dirs) |dir| {
            const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.root_dir, dir });
            defer self.allocator.free(full_path);

            try self.scanDirectory(full_path, &modules);
        }

        return modules;
    }

    /// Scan a directory recursively for test files
    fn scanDirectory(self: *TestDiscovery, dir_path: []const u8, modules: *std.ArrayList(TestModule)) !void {
        var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .directory) {
                // Recursively scan subdirectories
                const sub_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, entry.name });
                defer self.allocator.free(sub_path);
                try self.scanDirectory(sub_path, modules);
            } else if (entry.kind == .file) {
                // Check if it's a test file
                if (self.isTestFile(entry.name)) {
                    const file_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, entry.name });
                    defer self.allocator.free(file_path);

                    const module_name = try self.extractModuleName(entry.name);
                    defer self.allocator.free(module_name);

                    const module = try TestModule.init(self.allocator, module_name, file_path);
                    try modules.append(self.allocator, module);
                }
            }
        }
    }

    /// Check if a file is a test file
    fn isTestFile(self: *TestDiscovery, filename: []const u8) bool {
        _ = self;

        // Test files start with "test_" or end with "_test.zig"
        if (std.mem.startsWith(u8, filename, "test_")) {
            return std.mem.endsWith(u8, filename, ".zig");
        }

        if (std.mem.endsWith(u8, filename, "_test.zig")) {
            return true;
        }

        return false;
    }

    /// Extract module name from filename
    fn extractModuleName(self: *TestDiscovery, filename: []const u8) ![]const u8 {
        // Remove .zig extension
        var name = filename;
        if (std.mem.endsWith(u8, name, ".zig")) {
            name = name[0 .. name.len - 4];
        }

        // Remove test_ prefix
        if (std.mem.startsWith(u8, name, "test_")) {
            name = name[5..];
        }

        // Remove _test suffix
        if (std.mem.endsWith(u8, name, "_test")) {
            name = name[0 .. name.len - 5];
        }

        return try self.allocator.dupe(u8, name);
    }

    /// Get list of known test modules (from build.zig)
    pub fn getKnownTestModules(self: *TestDiscovery) !std.ArrayList(TestModule) {
        var modules = std.ArrayList(TestModule){};

        // Hardcoded list of test modules we know about
        const known_tests = [_]struct { name: []const u8, path: []const u8 }{
            .{ .name = "tokenizer", .path = "src/tokenizer/test_tokenizer.zig" },
            .{ .name = "parser", .path = "src/parser/test_parser.zig" },
            .{ .name = "expander", .path = "src/expander/test_expander.zig" },
            .{ .name = "executor", .path = "src/executor/test_executor.zig" },
            .{ .name = "plugins", .path = "src/plugins/test_plugins.zig" },
            .{ .name = "plugin_interface", .path = "src/plugins/test_interface.zig" },
            .{ .name = "builtin_plugins", .path = "src/plugins/test_builtin_plugins.zig" },
            .{ .name = "plugin_integration", .path = "src/plugins/test_integration.zig" },
            .{ .name = "plugin_discovery", .path = "src/plugins/test_discovery.zig" },
            .{ .name = "plugin_api", .path = "src/plugins/test_api.zig" },
            .{ .name = "hook_manager", .path = "src/hooks/test_manager.zig" },
            .{ .name = "builtin_hooks", .path = "src/hooks/test_builtin.zig" },
            .{ .name = "theme", .path = "src/theme/test_theme.zig" },
            .{ .name = "prompt", .path = "src/prompt/test_prompt.zig" },
            .{ .name = "modules", .path = "src/modules/test_modules.zig" },
            .{ .name = "system_modules", .path = "src/modules/test_system.zig" },
        };

        for (known_tests) |test_info| {
            const module = try TestModule.init(self.allocator, test_info.name, test_info.path);
            try modules.append(self.allocator, module);
        }

        return modules;
    }
};
