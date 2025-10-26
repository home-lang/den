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

        var dependencies_buffer: [32]Dependency = undefined;
        var dependencies_count: usize = 0;

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
                    if (dependencies_count < dependencies_buffer.len) {
                        const dep = try parseDependency(allocator, value);
                        dependencies_buffer[dependencies_count] = dep;
                        dependencies_count += 1;
                    }
                }
            }
        }

        // Validate required fields
        if (name == null or version == null or description == null or author == null) {
            // Clean up any allocated fields before returning error
            if (name) |n| allocator.free(n);
            if (version) |v| allocator.free(v);
            if (description) |d| allocator.free(d);
            if (author) |a| allocator.free(a);
            if (license) |l| allocator.free(l);
            if (min_shell_version) |v| allocator.free(v);
            for (dependencies_buffer[0..dependencies_count]) |dep| {
                allocator.free(dep.name);
                allocator.free(dep.version_requirement);
            }
            return error.InvalidManifest;
        }

        // Copy dependencies to owned slice
        var deps: []Dependency = &[_]Dependency{};
        if (dependencies_count > 0) {
            deps = try allocator.alloc(Dependency, dependencies_count);
            @memcpy(deps, dependencies_buffer[0..dependencies_count]);
        }

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
                var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch continue;
                defer dir.close();

                // Look for plugin manifests
                var iter = dir.iterate();
                while (iter.next() catch null) |entry| {
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
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
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
