const std = @import("std");
const discovery = @import("discovery.zig");

const PluginManifest = discovery.PluginManifest;
const Version = discovery.Version;
const PluginDiscovery = discovery.PluginDiscovery;

test "PluginManifest - initialization" {
    const allocator = std.testing.allocator;

    var manifest = try PluginManifest.init(allocator, "test-plugin", "1.0.0", "A test plugin", "Test Author");
    defer manifest.deinit();

    try std.testing.expectEqualStrings("test-plugin", manifest.name);
    try std.testing.expectEqualStrings("1.0.0", manifest.version);
    try std.testing.expectEqualStrings("A test plugin", manifest.description);
    try std.testing.expectEqualStrings("Test Author", manifest.author);
    try std.testing.expect(manifest.license == null);
    try std.testing.expectEqual(@as(usize, 0), manifest.dependencies.len);
}

test "PluginManifest - parse simple manifest" {
    const allocator = std.testing.allocator;

    const manifest_content =
        \\name = my-plugin
        \\version = 1.2.3
        \\description = My awesome plugin
        \\author = John Doe
    ;

    var manifest = try PluginManifest.parse(allocator, manifest_content);
    defer manifest.deinit();

    try std.testing.expectEqualStrings("my-plugin", manifest.name);
    try std.testing.expectEqualStrings("1.2.3", manifest.version);
    try std.testing.expectEqualStrings("My awesome plugin", manifest.description);
    try std.testing.expectEqualStrings("John Doe", manifest.author);
}

test "PluginManifest - parse with optional fields" {
    const allocator = std.testing.allocator;

    const manifest_content =
        \\name = my-plugin
        \\version = 1.0.0
        \\description = My plugin
        \\author = Jane Doe
        \\license = MIT
        \\min_shell_version = 0.5.0
    ;

    var manifest = try PluginManifest.parse(allocator, manifest_content);
    defer manifest.deinit();

    try std.testing.expect(manifest.license != null);
    try std.testing.expectEqualStrings("MIT", manifest.license.?);
    try std.testing.expect(manifest.min_shell_version != null);
    try std.testing.expectEqualStrings("0.5.0", manifest.min_shell_version.?);
}

test "PluginManifest - parse with dependencies" {
    const allocator = std.testing.allocator;

    const manifest_content =
        \\name = my-plugin
        \\version = 1.0.0
        \\description = My plugin
        \\author = Test
        \\dependency = core:>=1.0.0
        \\dependency = utils:^2.0.0:optional
    ;

    var manifest = try PluginManifest.parse(allocator, manifest_content);
    defer manifest.deinit();

    try std.testing.expectEqual(@as(usize, 2), manifest.dependencies.len);

    try std.testing.expectEqualStrings("core", manifest.dependencies[0].name);
    try std.testing.expectEqualStrings(">=1.0.0", manifest.dependencies[0].version_requirement);
    try std.testing.expect(!manifest.dependencies[0].optional);

    try std.testing.expectEqualStrings("utils", manifest.dependencies[1].name);
    try std.testing.expectEqualStrings("^2.0.0", manifest.dependencies[1].version_requirement);
    try std.testing.expect(manifest.dependencies[1].optional);
}

test "PluginManifest - parse with comments" {
    const allocator = std.testing.allocator;

    const manifest_content =
        \\# This is a comment
        \\name = test-plugin
        \\# Another comment
        \\version = 1.0.0
        \\description = Test
        \\author = Tester
        \\
        \\# Empty line above
    ;

    var manifest = try PluginManifest.parse(allocator, manifest_content);
    defer manifest.deinit();

    try std.testing.expectEqualStrings("test-plugin", manifest.name);
}

test "PluginManifest - parse missing required field" {
    const allocator = std.testing.allocator;

    const manifest_content =
        \\name = test-plugin
        \\version = 1.0.0
        \\# Missing description and author
    ;

    const result = PluginManifest.parse(allocator, manifest_content);
    try std.testing.expectError(error.InvalidManifest, result);
}

test "Version - parse simple version" {
    const version = try Version.parse("1.2.3");

    try std.testing.expectEqual(@as(u32, 1), version.major);
    try std.testing.expectEqual(@as(u32, 2), version.minor);
    try std.testing.expectEqual(@as(u32, 3), version.patch);
}

test "Version - parse version with missing parts" {
    const version1 = try Version.parse("1");
    try std.testing.expectEqual(@as(u32, 1), version1.major);
    try std.testing.expectEqual(@as(u32, 0), version1.minor);
    try std.testing.expectEqual(@as(u32, 0), version1.patch);

    const version2 = try Version.parse("2.5");
    try std.testing.expectEqual(@as(u32, 2), version2.major);
    try std.testing.expectEqual(@as(u32, 5), version2.minor);
    try std.testing.expectEqual(@as(u32, 0), version2.patch);
}

test "Version - compare versions" {
    const v1 = try Version.parse("1.0.0");
    const v2 = try Version.parse("2.0.0");
    const v3 = try Version.parse("1.5.0");
    const v4 = try Version.parse("1.0.0");

    try std.testing.expectEqual(discovery.VersionOrder.less, v1.compare(v2));
    try std.testing.expectEqual(discovery.VersionOrder.greater, v2.compare(v1));
    try std.testing.expectEqual(discovery.VersionOrder.equal, v1.compare(v4));
    try std.testing.expectEqual(discovery.VersionOrder.less, v1.compare(v3));
}

test "Version - satisfies requirement with >=" {
    const v = try Version.parse("2.0.0");

    try std.testing.expect(try v.satisfies(">=1.0.0"));
    try std.testing.expect(try v.satisfies(">=2.0.0"));
    try std.testing.expect(!try v.satisfies(">=3.0.0"));
}

test "Version - satisfies requirement with ^" {
    const v = try Version.parse("2.5.3");

    try std.testing.expect(try v.satisfies("^2.0.0"));
    try std.testing.expect(try v.satisfies("^2.5.0"));
    try std.testing.expect(!try v.satisfies("^1.0.0"));
    try std.testing.expect(!try v.satisfies("^3.0.0"));
}

test "Version - satisfies requirement with ~" {
    const v = try Version.parse("1.2.5");

    try std.testing.expect(try v.satisfies("~1.2.3"));
    try std.testing.expect(try v.satisfies("~1.2.0"));
    try std.testing.expect(!try v.satisfies("~1.3.0"));
    try std.testing.expect(!try v.satisfies("~2.0.0"));
}

test "Version - satisfies exact version" {
    const v = try Version.parse("1.2.3");

    try std.testing.expect(try v.satisfies("1.2.3"));
    try std.testing.expect(!try v.satisfies("1.2.4"));
    try std.testing.expect(!try v.satisfies("1.3.0"));
}

test "PluginDiscovery - initialization" {
    const allocator = std.testing.allocator;

    var disc = PluginDiscovery.init(allocator);
    defer disc.deinit();

    try std.testing.expectEqual(@as(usize, 0), disc.search_paths_count);
}

test "PluginDiscovery - add search paths" {
    const allocator = std.testing.allocator;

    var disc = PluginDiscovery.init(allocator);
    defer disc.deinit();

    try disc.addSearchPath("/usr/local/share/den/plugins");
    try disc.addSearchPath("/home/user/.den/plugins");

    try std.testing.expectEqual(@as(usize, 2), disc.search_paths_count);
    try std.testing.expectEqualStrings("/usr/local/share/den/plugins", disc.search_paths[0].?);
    try std.testing.expectEqualStrings("/home/user/.den/plugins", disc.search_paths[1].?);
}

test "PluginDiscovery - check dependencies satisfied" {
    const allocator = std.testing.allocator;

    var disc = PluginDiscovery.init(allocator);
    defer disc.deinit();

    // Create plugin with dependency
    var plugin = try PluginManifest.init(allocator, "my-plugin", "1.0.0", "Test", "Author");
    defer plugin.deinit();

    var deps = [_]PluginManifest.Dependency{
        .{
            .name = try allocator.dupe(u8, "core"),
            .version_requirement = try allocator.dupe(u8, ">=1.0.0"),
            .optional = false,
        },
    };
    defer {
        for (deps) |dep| {
            allocator.free(dep.name);
            allocator.free(dep.version_requirement);
        }
    }

    const deps_slice = try allocator.alloc(PluginManifest.Dependency, deps.len);
    defer allocator.free(deps_slice);
    @memcpy(deps_slice, &deps);

    // Temporarily replace dependencies
    const old_deps = plugin.dependencies;
    plugin.dependencies = deps_slice;
    defer plugin.dependencies = old_deps;

    // Create available plugin
    var available = try PluginManifest.init(allocator, "core", "1.5.0", "Core plugin", "Author");
    defer available.deinit();

    const available_plugins = [_]PluginManifest{available};

    const satisfied = try disc.checkDependencies(&plugin, &available_plugins);
    try std.testing.expect(satisfied);
}

test "PluginDiscovery - check dependencies not satisfied" {
    const allocator = std.testing.allocator;

    var disc = PluginDiscovery.init(allocator);
    defer disc.deinit();

    // Create plugin with dependency
    var plugin = try PluginManifest.init(allocator, "my-plugin", "1.0.0", "Test", "Author");
    defer plugin.deinit();

    var deps = [_]PluginManifest.Dependency{
        .{
            .name = try allocator.dupe(u8, "missing"),
            .version_requirement = try allocator.dupe(u8, ">=1.0.0"),
            .optional = false,
        },
    };
    defer {
        for (deps) |dep| {
            allocator.free(dep.name);
            allocator.free(dep.version_requirement);
        }
    }

    const deps_slice = try allocator.alloc(PluginManifest.Dependency, deps.len);
    defer allocator.free(deps_slice);
    @memcpy(deps_slice, &deps);

    const old_deps = plugin.dependencies;
    plugin.dependencies = deps_slice;
    defer plugin.dependencies = old_deps;

    const available_plugins = [_]PluginManifest{};

    const satisfied = try disc.checkDependencies(&plugin, &available_plugins);
    try std.testing.expect(!satisfied);
}

test "PluginDiscovery - check shell version" {
    const allocator = std.testing.allocator;

    var plugin = try PluginManifest.init(allocator, "test", "1.0.0", "Test", "Author");
    defer plugin.deinit();

    plugin.min_shell_version = try allocator.dupe(u8, "0.5.0");

    try std.testing.expect(try PluginDiscovery.checkShellVersion(&plugin, "1.0.0"));
    try std.testing.expect(try PluginDiscovery.checkShellVersion(&plugin, "0.5.0"));
    try std.testing.expect(!try PluginDiscovery.checkShellVersion(&plugin, "0.4.0"));
}
