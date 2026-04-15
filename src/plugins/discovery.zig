const std = @import("std");

/// Plugin manifest structure
/// Defines plugin metadata, dependencies, and configuration
pub const PluginManifest = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    author: []const u8,
    license: ?[]const u8,
    dependencies: []Dependency,
    min_shell_version: ?[]const u8,
    allocator: std.mem.Allocator,

    pub const Dependency = struct {
        name: []const u8,
        version_requirement: []const u8, // e.g., ">=1.0.0", "^2.0.0"
        optional: bool,
    };

    pub fn init(allocator: std.mem.Allocator, name: []const u8, version: []const u8, description: []const u8, author: []const u8) !PluginManifest {
        return .{
            .name = try allocator.dupe(u8, name),
            .version = try allocator.dupe(u8, version),
            .description = try allocator.dupe(u8, description),
            .author = try allocator.dupe(u8, author),
            .license = null,
            .dependencies = &[_]Dependency{},
            .min_shell_version = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PluginManifest) void {
        self.allocator.free(self.name);
        self.allocator.free(self.version);
        self.allocator.free(self.description);
        self.allocator.free(self.author);

        if (self.license) |license| {
            self.allocator.free(license);
        }

        for (self.dependencies) |dep| {
            self.allocator.free(dep.name);
            self.allocator.free(dep.version_requirement);
        }
        if (self.dependencies.len > 0) {
            self.allocator.free(self.dependencies);
        }

        if (self.min_shell_version) |version| {
            self.allocator.free(version);
        }
    }

    /// Parse manifest from text content
    pub fn parse(allocator: std.mem.Allocator, content: []const u8) !PluginManifest {
        var name: ?[]const u8 = null;
        var version: ?[]const u8 = null;
        var description: ?[]const u8 = null;
        var author: ?[]const u8 = null;
        var license: ?[]const u8 = null;
        var min_shell_version: ?[]const u8 = null;

        // Use dynamic allocation to avoid silent truncation at 32 dependencies.
        var dependencies: std.ArrayListUnmanaged(Dependency) = .empty;
        errdefer {
            for (dependencies.items) |dep| {
                allocator.free(dep.name);
                allocator.free(dep.version_requirement);
            }
            dependencies.deinit(allocator);
        }

        var line_iter = std.mem.splitScalar(u8, content, '\n');
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], &std.ascii.whitespace);
                const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], &std.ascii.whitespace);

                if (std.mem.eql(u8, key, "name")) {
                    name = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "version")) {
                    version = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "description")) {
                    description = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "author")) {
                    author = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "license")) {
                    license = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "min_shell_version")) {
                    min_shell_version = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "dependency")) {
                    // Format: "name:version[:optional]"
                    const dep = try parseDependency(allocator, value);
                    errdefer {
                        allocator.free(dep.name);
                        allocator.free(dep.version_requirement);
                    }
                    try dependencies.append(allocator, dep);
                }
            }
        }

        // Validate required fields
        if (name == null or version == null or description == null or author == null) {
            // Clean up any allocated fields before returning error.
            // (dependencies cleanup is handled by the errdefer above.)
            if (name) |n| allocator.free(n);
            if (version) |v| allocator.free(v);
            if (description) |d| allocator.free(d);
            if (author) |a| allocator.free(a);
            if (license) |l| allocator.free(l);
            if (min_shell_version) |v| allocator.free(v);
            return error.InvalidManifest;
        }

        const deps = try dependencies.toOwnedSlice(allocator);

        return .{
            .name = name.?,
            .version = version.?,
            .description = description.?,
            .author = author.?,
            .license = license,
            .dependencies = deps,
            .min_shell_version = min_shell_version,
            .allocator = allocator,
        };
    }

    fn parseDependency(allocator: std.mem.Allocator, spec: []const u8) !Dependency {
        var parts_iter = std.mem.splitScalar(u8, spec, ':');

        const name = parts_iter.next() orelse return error.InvalidDependency;
        const version_req = parts_iter.next() orelse ">=0.0.0";
        const optional_str = parts_iter.next();

        const optional = if (optional_str) |opt|
            std.mem.eql(u8, opt, "optional")
        else
            false;

        return .{
            .name = try allocator.dupe(u8, name),
            .version_requirement = try allocator.dupe(u8, version_req),
            .optional = optional,
        };
    }
};

/// Version comparison result
pub const VersionOrder = enum {
    less,
    equal,
    greater,
};

/// Semantic version parsing and comparison
pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn parse(version_str: []const u8) !Version {
        var parts_iter = std.mem.splitScalar(u8, version_str, '.');

        const major_str = parts_iter.next() orelse return error.InvalidVersion;
        const minor_str = parts_iter.next() orelse "0";
        const patch_str = parts_iter.next() orelse "0";

        return .{
            .major = try std.fmt.parseInt(u32, major_str, 10),
            .minor = try std.fmt.parseInt(u32, minor_str, 10),
            .patch = try std.fmt.parseInt(u32, patch_str, 10),
        };
    }

    pub fn compare(self: Version, other: Version) VersionOrder {
        if (self.major != other.major) {
            return if (self.major < other.major) .less else .greater;
        }
        if (self.minor != other.minor) {
            return if (self.minor < other.minor) .less else .greater;
        }
        if (self.patch != other.patch) {
            return if (self.patch < other.patch) .less else .greater;
        }
        return .equal;
    }

    pub fn satisfies(self: Version, requirement: []const u8) !bool {
        // Parse requirement: ">=1.0.0", "^2.0.0", "~1.2.3"
        if (requirement.len < 2) return false;

        if (std.mem.startsWith(u8, requirement, ">=")) {
            const req_version = try parse(requirement[2..]);
            return self.compare(req_version) != .less;
        } else if (std.mem.startsWith(u8, requirement, "<=")) {
            const req_version = try parse(requirement[2..]);
            return self.compare(req_version) != .greater;
        } else if (std.mem.startsWith(u8, requirement, ">")) {
            const req_version = try parse(requirement[1..]);
            return self.compare(req_version) == .greater;
        } else if (std.mem.startsWith(u8, requirement, "<")) {
            const req_version = try parse(requirement[1..]);
            return self.compare(req_version) == .less;
        } else if (std.mem.startsWith(u8, requirement, "^")) {
            // Caret: compatible with version (same major version)
            const req_version = try parse(requirement[1..]);
            return self.major == req_version.major and self.compare(req_version) != .less;
        } else if (std.mem.startsWith(u8, requirement, "~")) {
            // Tilde: compatible with patch version
            const req_version = try parse(requirement[1..]);
            return self.major == req_version.major and
                self.minor == req_version.minor and
                self.compare(req_version) != .less;
        } else {
            // Exact version
            const req_version = try parse(requirement);
            return self.compare(req_version) == .equal;
        }
    }
};

/// Plugin discovery system
pub const PluginDiscovery = struct {
    allocator: std.mem.Allocator,
    search_paths: [16]?[]const u8,
    search_paths_count: usize,

    pub fn init(allocator: std.mem.Allocator) PluginDiscovery {
        return .{
            .allocator = allocator,
            .search_paths = [_]?[]const u8{null} ** 16,
            .search_paths_count = 0,
        };
    }

    pub fn deinit(self: *PluginDiscovery) void {
        for (self.search_paths) |maybe_path| {
            if (maybe_path) |path| {
                self.allocator.free(path);
            }
        }
    }

    /// Add a search path for plugin discovery
    pub fn addSearchPath(self: *PluginDiscovery, path: []const u8) !void {
        if (self.search_paths_count >= self.search_paths.len) {
            return error.TooManySearchPaths;
        }

        const path_copy = try self.allocator.dupe(u8, path);
        self.search_paths[self.search_paths_count] = path_copy;
        self.search_paths_count += 1;
    }

    /// Discover plugins in search paths
    pub fn discoverPlugins(self: *PluginDiscovery) ![]PluginManifest {
        var manifests_buffer: [100]PluginManifest = undefined;
        var manifests_count: usize = 0;

        for (self.search_paths[0..self.search_paths_count]) |maybe_path| {
            if (maybe_path) |path| {
                // Try to open directory
                var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, path, .{ .iterate = true }) catch continue;
                defer dir.close(std.Options.debug_io);

                // Look for plugin manifests
                var iter = dir.iterate();
                while (iter.next(std.Options.debug_io) catch null) |entry| {
                    if (entry.kind == .directory) {
                        // Look for manifest file in plugin directory
                        const manifest_path = try std.fmt.allocPrint(
                            self.allocator,
                            "{s}/{s}/plugin.manifest",
                            .{ path, entry.name },
                        );
                        defer self.allocator.free(manifest_path);

                        if (self.loadManifest(manifest_path)) |manifest| {
                            if (manifests_count < manifests_buffer.len) {
                                manifests_buffer[manifests_count] = manifest;
                                manifests_count += 1;
                            }
                        } else |_| {
                            // Manifest not found or invalid, skip
                            continue;
                        }
                    }
                }
            }
        }

        const result = try self.allocator.alloc(PluginManifest, manifests_count);
        @memcpy(result, manifests_buffer[0..manifests_count]);
        return result;
    }

    /// Load manifest from file
    fn loadManifest(self: *PluginDiscovery, path: []const u8) !PluginManifest {
        const file = try std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{});
        defer file.close(std.Options.debug_io);

        var read_file_buf: [4096]u8 = undefined;
        var file_reader = file.readerStreaming(std.Options.debug_io, &read_file_buf);
        const content = try file_reader.interface.allocRemaining(self.allocator, .limited(1024 * 1024));
        defer self.allocator.free(content);

        return try PluginManifest.parse(self.allocator, content);
    }

    /// Check if dependencies are satisfied
    pub fn checkDependencies(
        self: *PluginDiscovery,
        manifest: *const PluginManifest,
        available_plugins: []const PluginManifest,
    ) !bool {
        _ = self;

        for (manifest.dependencies) |dep| {
            var found = false;

            for (available_plugins) |available| {
                if (std.mem.eql(u8, available.name, dep.name)) {
                    // Check version compatibility
                    const version = try Version.parse(available.version);
                    if (try version.satisfies(dep.version_requirement)) {
                        found = true;
                        break;
                    }
                }
            }

            if (!found and !dep.optional) {
                return false;
            }
        }

        return true;
    }

    /// Check shell version compatibility
    pub fn checkShellVersion(manifest: *const PluginManifest, shell_version: []const u8) !bool {
        if (manifest.min_shell_version) |min_version| {
            const current = try Version.parse(shell_version);
            const required = try Version.parse(min_version);
            return current.compare(required) != .less;
        }
        return true;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "PluginManifest.parse basic manifest" {
    const content =
        \\name = testplugin
        \\version = 1.0.0
        \\description = A test plugin
        \\author = Test Author
    ;

    var manifest = try PluginManifest.parse(std.testing.allocator, content);
    defer manifest.deinit();

    try std.testing.expectEqualStrings("testplugin", manifest.name);
    try std.testing.expectEqualStrings("1.0.0", manifest.version);
    try std.testing.expectEqualStrings("A test plugin", manifest.description);
    try std.testing.expectEqualStrings("Test Author", manifest.author);
    try std.testing.expect(manifest.dependencies.len == 0);
}

test "PluginManifest.parse missing required fields" {
    const content = "name = onlyname\n";
    try std.testing.expectError(error.InvalidManifest, PluginManifest.parse(std.testing.allocator, content));
}

test "PluginManifest.parse with many dependencies (more than old 32 cap)" {
    // Build a manifest with 50 dependencies (more than the previous 32-cap)
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(std.testing.allocator);

    try content.appendSlice(std.testing.allocator,
        \\name = testplugin
        \\version = 1.0.0
        \\description = Many deps
        \\author = Test
        \\
    );
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var buf: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "dependency = dep{d}:1.0.0\n", .{i});
        try content.appendSlice(std.testing.allocator, line);
    }

    var manifest = try PluginManifest.parse(std.testing.allocator, content.items);
    defer manifest.deinit();

    // All 50 dependencies should be present (no silent truncation)
    try std.testing.expectEqual(@as(usize, 50), manifest.dependencies.len);
}

test "PluginManifest.parse optional fields" {
    const content =
        \\name = p
        \\version = 1
        \\description = d
        \\author = a
        \\license = MIT
        \\min_shell_version = 0.5
    ;

    var manifest = try PluginManifest.parse(std.testing.allocator, content);
    defer manifest.deinit();

    try std.testing.expect(manifest.license != null);
    try std.testing.expectEqualStrings("MIT", manifest.license.?);
    try std.testing.expect(manifest.min_shell_version != null);
    try std.testing.expectEqualStrings("0.5", manifest.min_shell_version.?);
}
