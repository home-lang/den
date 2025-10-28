const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options
    const static_build = b.option(bool, "static", "Build statically linked binary") orelse false;
    const strip = b.option(bool, "strip", "Strip debug symbols") orelse false;
    const link_libc = b.option(bool, "link-libc", "Link against libc") orelse true;

    // Add zig-config as a module
    const zig_config = b.addModule("zig-config", .{
        .root_source_file = b.path("lib/zig-config/src/zig-config.zig"),
        .target = target,
    });

    // Create a module for our source with target
    const den_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    den_module.addImport("zig-config", zig_config);

    // Den shell executable
    const exe = b.addExecutable(.{
        .name = "den",
        .root_module = den_module,
    });

    // Static linking requires not linking libc (or using musl on Linux)
    if (static_build) {
        exe.linkage = .static;
        // Only link libc if we're not doing static build, or if target supports it
        if (target.result.os.tag == .linux) {
            exe.linkLibC(); // musl on Linux supports static
        }
    } else {
        exe.linkage = .dynamic;
        if (link_libc) exe.linkLibC();
    }
    b.installArtifact(exe);

    // Cross-compilation targets for release builds
    const release_step = b.step("release", "Build release binaries for all platforms");

    const targets = [_]std.Target.Query{
        // Linux x64
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        // Linux ARM64
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
        // macOS x64 (Intel)
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        // macOS ARM64 (Apple Silicon)
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        // Windows x64
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
    };

    const target_names = [_][]const u8{
        "linux-x64",
        "linux-arm64",
        "darwin-x64",
        "darwin-arm64",
        "windows-x64",
    };

    inline for (targets, target_names) |t, name| {
        const release_target = b.resolveTargetQuery(t);

        const release_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = release_target,
            .optimize = .ReleaseSafe,
            .strip = strip,
        });
        release_module.addImport("zig-config", zig_config);

        const release_exe = b.addExecutable(.{
            .name = "den",
            .root_module = release_module,
        });

        // Static linking requires not linking libc (or using musl on Linux)
        if (static_build) {
            release_exe.linkage = .static;
            if (release_target.result.os.tag == .linux) {
                release_exe.linkLibC(); // musl on Linux supports static
            }
        } else {
            release_exe.linkage = .dynamic;
            release_exe.linkLibC();
        }

        const install_exe = b.addInstallArtifact(release_exe, .{
            .dest_dir = .{
                .override = .{
                    .custom = std.fmt.allocPrint(
                        b.allocator,
                        "release/{s}",
                        .{name},
                    ) catch @panic("OOM"),
                },
            },
        });

        release_step.dependOn(&install_exe.step);
    }

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

    // Parser tests
    const parser_test_module = b.createModule(.{
        .root_source_file = b.path("src/parser/test_parser.zig"),
        .target = target,
        .optimize = optimize,
    });

    const parser_tests = b.addTest(.{
        .root_module = parser_test_module,
    });

    const run_parser_tests = b.addRunArtifact(parser_tests);
    const parser_test_step = b.step("test-parser", "Run parser tests");
    parser_test_step.dependOn(&run_parser_tests.step);

    // Tokenizer tests
    const tokenizer_test_module = b.createModule(.{
        .root_source_file = b.path("src/parser/test_tokenizer.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tokenizer_tests = b.addTest(.{
        .root_module = tokenizer_test_module,
    });

    const run_tokenizer_tests = b.addRunArtifact(tokenizer_tests);
    const tokenizer_test_step = b.step("test-tokenizer", "Run tokenizer tests");
    tokenizer_test_step.dependOn(&run_tokenizer_tests.step);

    // Test utilities tests
    const test_utils_test_module = b.createModule(.{
        .root_source_file = b.path("src/test_utils.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_utils_tests = b.addTest(.{
        .root_module = test_utils_test_module,
    });

    const run_test_utils_tests = b.addRunArtifact(test_utils_tests);
    const test_utils_test_step = b.step("test-utils", "Run test utilities tests");
    test_utils_test_step.dependOn(&run_test_utils_tests.step);

    // Expansion tests
    const expansion_test_module = b.createModule(.{
        .root_source_file = b.path("src/utils/test_expansion.zig"),
        .target = target,
        .optimize = optimize,
    });

    const expansion_tests = b.addTest(.{
        .root_module = expansion_test_module,
    });

    const run_expansion_tests = b.addRunArtifact(expansion_tests);
    const expansion_test_step = b.step("test-expansion", "Run expansion tests");
    expansion_test_step.dependOn(&run_expansion_tests.step);

    // Regression tests
    const regression_test_module = b.createModule(.{
        .root_source_file = b.path("src/parser/test_regression.zig"),
        .target = target,
        .optimize = optimize,
    });

    const regression_tests = b.addTest(.{
        .root_module = regression_test_module,
    });

    const run_regression_tests = b.addRunArtifact(regression_tests);
    const regression_test_step = b.step("test-regression", "Run regression tests");
    regression_test_step.dependOn(&run_regression_tests.step);

    // Fuzzing tests
    const fuzz_test_module = b.createModule(.{
        .root_source_file = b.path("src/parser/test_fuzz_simple.zig"),
        .target = target,
        .optimize = optimize,
    });

    const fuzz_tests = b.addTest(.{
        .root_module = fuzz_test_module,
    });

    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    const fuzz_test_step = b.step("test-fuzz", "Run fuzzing tests");
    fuzz_test_step.dependOn(&run_fuzz_tests.step);

    // Integration tests
    const integration_e2e_test_module = b.createModule(.{
        .root_source_file = b.path("src/test_integration.zig"),
        .target = target,
        .optimize = optimize,
    });

    const integration_e2e_tests = b.addTest(.{
        .root_module = integration_e2e_test_module,
    });

    const run_integration_e2e_tests = b.addRunArtifact(integration_e2e_tests);
    const integration_e2e_test_step = b.step("test-integration-e2e", "Run integration tests");
    integration_e2e_test_step.dependOn(&run_integration_e2e_tests.step);

    // E2E tests
    const e2e_test_module = b.createModule(.{
        .root_source_file = b.path("src/test_e2e.zig"),
        .target = target,
        .optimize = optimize,
    });

    const e2e_tests = b.addTest(.{
        .root_module = e2e_test_module,
    });

    const run_e2e_tests = b.addRunArtifact(e2e_tests);
    const e2e_test_step = b.step("test-e2e", "Run end-to-end tests");
    e2e_test_step.dependOn(&run_e2e_tests.step);

    // CLI tests
    const cli_test_module = b.createModule(.{
        .root_source_file = b.path("src/test_cli.zig"),
        .target = target,
        .optimize = optimize,
    });

    const cli_tests = b.addTest(.{
        .root_module = cli_test_module,
    });

    const run_cli_tests = b.addRunArtifact(cli_tests);
    const cli_test_step = b.step("test-cli", "Run CLI tests");
    cli_test_step.dependOn(&run_cli_tests.step);

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
    all_tests_step.dependOn(&run_parser_tests.step);
    all_tests_step.dependOn(&run_tokenizer_tests.step);
    all_tests_step.dependOn(&run_test_utils_tests.step);
    all_tests_step.dependOn(&run_system_module_tests.step);
    all_tests_step.dependOn(&run_expansion_tests.step);
    all_tests_step.dependOn(&run_regression_tests.step);
    all_tests_step.dependOn(&run_fuzz_tests.step);
    all_tests_step.dependOn(&run_integration_e2e_tests.step);
    all_tests_step.dependOn(&run_e2e_tests.step);
    all_tests_step.dependOn(&run_cli_tests.step);

    // ========================================
    // Profiling and Benchmarks
    // ========================================

    // Profiling CLI tool
    const profiling_cli_module = b.createModule(.{
        .root_source_file = b.path("src/profiling/cli.zig"),
        .target = target,
        .optimize = optimize,
    });

    const profiling_cli = b.addExecutable(.{
        .name = "den-profile",
        .root_module = profiling_cli_module,
    });
    b.installArtifact(profiling_cli);

    // Benchmark executables
    const bench_step = b.step("bench", "Build all benchmarks");

    // Profiling module for benchmarks
    const profiling_module = b.createModule(.{
        .root_source_file = b.path("src/profiling.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    // Startup benchmark
    const startup_bench_module = b.createModule(.{
        .root_source_file = b.path("bench/startup_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    startup_bench_module.addImport("profiling", profiling_module);

    const startup_bench = b.addExecutable(.{
        .name = "startup_bench",
        .root_module = startup_bench_module,
    });
    b.installArtifact(startup_bench);
    bench_step.dependOn(&startup_bench.step);

    // Command execution benchmark
    const command_bench_module = b.createModule(.{
        .root_source_file = b.path("bench/command_exec_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    command_bench_module.addImport("profiling", profiling_module);

    const command_bench = b.addExecutable(.{
        .name = "command_exec_bench",
        .root_module = command_bench_module,
    });
    b.installArtifact(command_bench);
    bench_step.dependOn(&command_bench.step);

    // Completion benchmark
    const completion_bench_module = b.createModule(.{
        .root_source_file = b.path("bench/completion_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    completion_bench_module.addImport("profiling", profiling_module);

    const completion_bench = b.addExecutable(.{
        .name = "completion_bench",
        .root_module = completion_bench_module,
    });
    b.installArtifact(completion_bench);
    bench_step.dependOn(&completion_bench.step);

    // History benchmark
    const history_bench_module = b.createModule(.{
        .root_source_file = b.path("bench/history_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    history_bench_module.addImport("profiling", profiling_module);

    const history_bench = b.addExecutable(.{
        .name = "history_bench",
        .root_module = history_bench_module,
    });
    b.installArtifact(history_bench);
    bench_step.dependOn(&history_bench.step);

    // Prompt rendering benchmark
    const prompt_bench_module = b.createModule(.{
        .root_source_file = b.path("bench/prompt_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    prompt_bench_module.addImport("profiling", profiling_module);

    const prompt_bench = b.addExecutable(.{
        .name = "prompt_bench",
        .root_module = prompt_bench_module,
    });
    b.installArtifact(prompt_bench);
    bench_step.dependOn(&prompt_bench.step);

    // Memory optimization benchmark
    const memory_module = b.createModule(.{
        .root_source_file = b.path("src/utils/memory.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const memory_bench_module = b.createModule(.{
        .root_source_file = b.path("bench/memory_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    memory_bench_module.addImport("profiling", profiling_module);
    memory_bench_module.addImport("memory", memory_module);

    const memory_bench = b.addExecutable(.{
        .name = "memory_bench",
        .root_module = memory_bench_module,
    });
    b.installArtifact(memory_bench);
    bench_step.dependOn(&memory_bench.step);

    // CPU optimization benchmark
    const cpu_opt_module = b.createModule(.{
        .root_source_file = b.path("src/utils/cpu_opt.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const optimized_parser_module = b.createModule(.{
        .root_source_file = b.path("src/parser/optimized_parser.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const cpu_bench_module = b.createModule(.{
        .root_source_file = b.path("bench/cpu_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    cpu_bench_module.addImport("profiling", profiling_module);
    cpu_bench_module.addImport("cpu_opt", cpu_opt_module);
    cpu_bench_module.addImport("optimized_parser", optimized_parser_module);

    const cpu_bench = b.addExecutable(.{
        .name = "cpu_bench",
        .root_module = cpu_bench_module,
    });
    b.installArtifact(cpu_bench);
    bench_step.dependOn(&cpu_bench.step);

    // Concurrency benchmark
    const concurrency_module = b.createModule(.{
        .root_source_file = b.path("src/utils/concurrency.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const parallel_discovery_module = b.createModule(.{
        .root_source_file = b.path("src/utils/parallel_discovery.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    parallel_discovery_module.addImport("concurrency", concurrency_module);

    const concurrency_bench_module = b.createModule(.{
        .root_source_file = b.path("bench/concurrency_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    concurrency_bench_module.addImport("profiling", profiling_module);
    concurrency_bench_module.addImport("concurrency", concurrency_module);
    concurrency_bench_module.addImport("parallel_discovery", parallel_discovery_module);

    const concurrency_bench = b.addExecutable(.{
        .name = "concurrency_bench",
        .root_module = concurrency_bench_module,
    });
    b.installArtifact(concurrency_bench);
    bench_step.dependOn(&concurrency_bench.step);

    // Profiler tests
    const profiler_test_module = b.createModule(.{
        .root_source_file = b.path("src/profiling/profiler.zig"),
        .target = target,
        .optimize = optimize,
    });

    const profiler_tests = b.addTest(.{
        .root_module = profiler_test_module,
    });

    const run_profiler_tests = b.addRunArtifact(profiler_tests);
    const profiler_test_step = b.step("test-profiler", "Run profiler tests");
    profiler_test_step.dependOn(&run_profiler_tests.step);

    // Benchmark tests
    const benchmark_test_module = b.createModule(.{
        .root_source_file = b.path("src/profiling/benchmarks.zig"),
        .target = target,
        .optimize = optimize,
    });

    const benchmark_tests = b.addTest(.{
        .root_module = benchmark_test_module,
    });

    const run_benchmark_tests = b.addRunArtifact(benchmark_tests);
    const benchmark_test_step = b.step("test-benchmarks", "Run benchmark framework tests");
    benchmark_test_step.dependOn(&run_benchmark_tests.step);

    // Add profiler tests to all_tests
    all_tests_step.dependOn(&run_profiler_tests.step);
    all_tests_step.dependOn(&run_benchmark_tests.step);

    // Concurrency tests
    const concurrency_test_module = b.createModule(.{
        .root_source_file = b.path("src/utils/test_concurrency.zig"),
        .target = target,
        .optimize = optimize,
    });
    const concurrency_import_module = b.createModule(.{
        .root_source_file = b.path("src/utils/concurrency.zig"),
        .target = target,
        .optimize = optimize,
    });

    const parallel_discovery_import_module = b.createModule(.{
        .root_source_file = b.path("src/utils/parallel_discovery.zig"),
        .target = target,
        .optimize = optimize,
    });
    parallel_discovery_import_module.addImport("concurrency", concurrency_import_module);

    concurrency_test_module.addImport("concurrency", concurrency_import_module);
    concurrency_test_module.addImport("parallel_discovery", parallel_discovery_import_module);

    const concurrency_tests = b.addTest(.{
        .root_module = concurrency_test_module,
    });

    const run_concurrency_tests = b.addRunArtifact(concurrency_tests);
    const concurrency_test_step = b.step("test-concurrency", "Run concurrency tests");
    concurrency_test_step.dependOn(&run_concurrency_tests.step);

    // Add to all tests
    all_tests_step.dependOn(&run_concurrency_tests.step);

    // ==================== Examples ====================

    // Create utils module for examples
    const utils_module = b.createModule(.{
        .root_source_file = b.path("src/utils.zig"),
        .target = target,
    });

    // Logging example
    const logging_example_module = b.createModule(.{
        .root_source_file = b.path("examples/logging_example.zig"),
        .target = target,
        .optimize = optimize,
    });
    logging_example_module.addImport("utils", utils_module);

    const logging_example = b.addExecutable(.{
        .name = "logging_example",
        .root_module = logging_example_module,
    });
    b.installArtifact(logging_example);

    const run_logging_example = b.addRunArtifact(logging_example);
    const logging_example_step = b.step("example-logging", "Run logging example");
    logging_example_step.dependOn(&run_logging_example.step);

    // ANSI/Terminal example
    const ansi_example_module = b.createModule(.{
        .root_source_file = b.path("examples/ansi_example.zig"),
        .target = target,
        .optimize = optimize,
    });
    ansi_example_module.addImport("utils", utils_module);

    const ansi_example = b.addExecutable(.{
        .name = "ansi_example",
        .root_module = ansi_example_module,
    });
    b.installArtifact(ansi_example);

    const run_ansi_example = b.addRunArtifact(ansi_example);
    const ansi_example_step = b.step("example-ansi", "Run ANSI/Terminal example");
    ansi_example_step.dependOn(&run_ansi_example.step);
}
