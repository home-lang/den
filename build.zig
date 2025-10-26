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

    // Test runner executable
    const test_runner_module = b.createModule(.{
        .root_source_file = b.path("src/test_framework/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_runner_exe = b.addExecutable(.{
        .name = "den-test",
        .root_module = test_runner_module,
    });
    b.installArtifact(test_runner_exe);

    const test_runner_cmd = b.addRunArtifact(test_runner_exe);
    test_runner_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        test_runner_cmd.addArgs(args);
    }

    const test_runner_step = b.step("test-runner", "Run the test runner");
    test_runner_step.dependOn(&test_runner_cmd.step);

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

    // Hook manager tests
    const hook_manager_test_module = b.createModule(.{
        .root_source_file = b.path("src/hooks/test_manager.zig"),
        .target = target,
        .optimize = optimize,
    });

    const hook_manager_tests = b.addTest(.{
        .root_module = hook_manager_test_module,
    });

    const run_hook_manager_tests = b.addRunArtifact(hook_manager_tests);
    const hook_manager_test_step = b.step("test-hook-manager", "Run hook manager tests");
    hook_manager_test_step.dependOn(&run_hook_manager_tests.step);

    // Built-in hooks tests
    const builtin_hooks_test_module = b.createModule(.{
        .root_source_file = b.path("src/hooks/test_builtin.zig"),
        .target = target,
        .optimize = optimize,
    });

    const builtin_hooks_tests = b.addTest(.{
        .root_module = builtin_hooks_test_module,
    });

    const run_builtin_hooks_tests = b.addRunArtifact(builtin_hooks_tests);
    const builtin_hooks_test_step = b.step("test-builtin-hooks", "Run built-in hooks tests");
    builtin_hooks_test_step.dependOn(&run_builtin_hooks_tests.step);

    // All hook tests combined
    const all_hook_test_step = b.step("test-all-hooks", "Run all hook tests");
    all_hook_test_step.dependOn(&run_hook_manager_tests.step);
    all_hook_test_step.dependOn(&run_builtin_hooks_tests.step);

    // Theme tests
    const theme_test_module = b.createModule(.{
        .root_source_file = b.path("src/theme/test_theme.zig"),
        .target = target,
        .optimize = optimize,
    });

    const theme_tests = b.addTest(.{
        .root_module = theme_test_module,
    });
    theme_tests.linkLibC();

    const run_theme_tests = b.addRunArtifact(theme_tests);
    const theme_test_step = b.step("test-theme", "Run theme tests");
    theme_test_step.dependOn(&run_theme_tests.step);

    // Prompt tests
    const prompt_test_module = b.createModule(.{
        .root_source_file = b.path("src/prompt/test_prompt.zig"),
        .target = target,
        .optimize = optimize,
    });

    const prompt_tests = b.addTest(.{
        .root_module = prompt_test_module,
    });

    const run_prompt_tests = b.addRunArtifact(prompt_tests);
    const prompt_test_step = b.step("test-prompt", "Run prompt tests");
    prompt_test_step.dependOn(&run_prompt_tests.step);

    // Module tests
    const module_test_module = b.createModule(.{
        .root_source_file = b.path("src/modules/test_modules.zig"),
        .target = target,
        .optimize = optimize,
    });

    const module_tests = b.addTest(.{
        .root_module = module_test_module,
    });

    const run_module_tests = b.addRunArtifact(module_tests);
    const module_test_step = b.step("test-modules", "Run module tests");
    module_test_step.dependOn(&run_module_tests.step);

    // System module tests
    const system_module_test_module = b.createModule(.{
        .root_source_file = b.path("src/modules/test_system.zig"),
        .target = target,
        .optimize = optimize,
    });

    const system_module_tests = b.addTest(.{
        .root_module = system_module_test_module,
    });

    const run_system_module_tests = b.addRunArtifact(system_module_tests);
    const system_module_test_step = b.step("test-system-modules", "Run system module tests");
    system_module_test_step.dependOn(&run_system_module_tests.step);

    // All tests combined (main test suite)
    const all_tests_step = b.step("test-all", "Run all test suites");
    all_tests_step.dependOn(&run_unit_tests.step);
    all_tests_step.dependOn(&run_plugin_tests.step);
    all_tests_step.dependOn(&run_interface_tests.step);
    all_tests_step.dependOn(&run_builtin_plugin_tests.step);
    all_tests_step.dependOn(&run_integration_tests.step);
    all_tests_step.dependOn(&run_discovery_tests.step);
    all_tests_step.dependOn(&run_api_tests.step);
    all_tests_step.dependOn(&run_hook_manager_tests.step);
    all_tests_step.dependOn(&run_builtin_hooks_tests.step);
    all_tests_step.dependOn(&run_theme_tests.step);
}
