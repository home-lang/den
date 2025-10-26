const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create a module for our source with target
    const den_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Den shell executable
    const exe = b.addExecutable(.{
        .name = "den",
        .root_module = den_module,
    });
    exe.linkLibC();
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the den shell");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Plugin tests
    const plugin_test_module = b.createModule(.{
        .root_source_file = b.path("src/plugins/test_plugins.zig"),
        .target = target,
        .optimize = optimize,
    });

    const plugin_tests = b.addTest(.{
        .root_module = plugin_test_module,
    });

    const run_plugin_tests = b.addRunArtifact(plugin_tests);
    const plugin_test_step = b.step("test-plugins", "Run plugin tests");
    plugin_test_step.dependOn(&run_plugin_tests.step);

    // Plugin interface tests
    const interface_test_module = b.createModule(.{
        .root_source_file = b.path("src/plugins/test_interface.zig"),
        .target = target,
        .optimize = optimize,
    });

    const interface_tests = b.addTest(.{
        .root_module = interface_test_module,
    });

    const run_interface_tests = b.addRunArtifact(interface_tests);
    const interface_test_step = b.step("test-interface", "Run plugin interface tests");
    interface_test_step.dependOn(&run_interface_tests.step);

    // Builtin plugin tests
    const builtin_plugin_test_module = b.createModule(.{
        .root_source_file = b.path("src/plugins/test_builtin_plugins.zig"),
        .target = target,
        .optimize = optimize,
    });

    const builtin_plugin_tests = b.addTest(.{
        .root_module = builtin_plugin_test_module,
    });

    const run_builtin_plugin_tests = b.addRunArtifact(builtin_plugin_tests);
    const builtin_plugin_test_step = b.step("test-builtin-plugins", "Run builtin plugin tests");
    builtin_plugin_test_step.dependOn(&run_builtin_plugin_tests.step);

    // Integration tests
    const integration_test_module = b.createModule(.{
        .root_source_file = b.path("src/plugins/test_integration.zig"),
        .target = target,
        .optimize = optimize,
    });

    const integration_tests = b.addTest(.{
        .root_module = integration_test_module,
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step("test-plugin-integration", "Run plugin integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

    // Discovery tests
    const discovery_test_module = b.createModule(.{
        .root_source_file = b.path("src/plugins/test_discovery.zig"),
        .target = target,
        .optimize = optimize,
    });

    const discovery_tests = b.addTest(.{
        .root_module = discovery_test_module,
    });

    const run_discovery_tests = b.addRunArtifact(discovery_tests);
    const discovery_test_step = b.step("test-plugin-discovery", "Run plugin discovery tests");
    discovery_test_step.dependOn(&run_discovery_tests.step);

    // API tests
    const api_test_module = b.createModule(.{
        .root_source_file = b.path("src/plugins/test_api.zig"),
        .target = target,
        .optimize = optimize,
    });

    const api_tests = b.addTest(.{
        .root_module = api_test_module,
    });

    const run_api_tests = b.addRunArtifact(api_tests);
    const api_test_step = b.step("test-plugin-api", "Run plugin API tests");
    api_test_step.dependOn(&run_api_tests.step);

    // All plugin tests combined
    const all_plugin_test_step = b.step("test-all-plugins", "Run all plugin tests");
    all_plugin_test_step.dependOn(&run_plugin_tests.step);
    all_plugin_test_step.dependOn(&run_interface_tests.step);
    all_plugin_test_step.dependOn(&run_builtin_plugin_tests.step);
    all_plugin_test_step.dependOn(&run_integration_tests.step);
    all_plugin_test_step.dependOn(&run_discovery_tests.step);
    all_plugin_test_step.dependOn(&run_api_tests.step);
}
