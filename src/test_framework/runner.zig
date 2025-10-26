const std = @import("std");
const types = @import("types.zig");
const discovery_mod = @import("discovery.zig");
const reporter_mod = @import("reporter.zig");

const TestResult = types.TestResult;
const TestStats = types.TestStats;
const TestFilter = types.TestFilter;
const ReporterConfig = types.ReporterConfig;
const TestDiscovery = discovery_mod.TestDiscovery;
const TestReporter = reporter_mod.TestReporter;

/// Test runner
pub const TestRunner = struct {
    allocator: std.mem.Allocator,
    filter: TestFilter,
    reporter: TestReporter,
    root_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, root_dir: []const u8, filter: TestFilter, config: ReporterConfig) TestRunner {
        return .{
            .allocator = allocator,
            .filter = filter,
            .reporter = TestReporter.init(allocator, config),
            .root_dir = root_dir,
        };
    }

    /// Run all discovered tests
    pub fn runAll(self: *TestRunner) !TestStats {
        var discovery = TestDiscovery.init(self.allocator, self.root_dir);

        // Get known test modules from build.zig
        var modules = try discovery.getKnownTestModules();
        defer {
            for (modules.items) |*module| {
                module.deinit();
            }
            modules.deinit();
        }

        var stats = TestStats.init();

        for (modules.items) |module| {
            // Apply filter
            if (!self.filter.matches(module.name)) {
                continue;
            }

            try self.reporter.reportStart(module.name);

            const result = try self.runTestModule(module.name);
            defer result.deinit();

            try self.reporter.reportResult(&result);
            stats.addResult(&result);
        }

        try self.reporter.reportSummary(&stats);

        return stats;
    }

    /// Run a specific test module
    fn runTestModule(self: *TestRunner, module_name: []const u8) !TestResult {
        var result = try TestResult.init(self.allocator, module_name);

        const start_time = std.time.nanoTimestamp();

        // Build test command
        var cmd_args = std.ArrayList([]const u8).init(self.allocator);
        defer cmd_args.deinit();

        try cmd_args.append("zig");
        try cmd_args.append("build");

        // Construct test step name
        const test_step = try self.getTestStepName(module_name);
        defer self.allocator.free(test_step);
        try cmd_args.append(test_step);

        // Execute test
        var child = std.process.Child.init(cmd_args.items, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        child.spawn() catch |err| {
            const duration = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));
            const error_msg = try std.fmt.allocPrint(self.allocator, "Failed to spawn test: {any}", .{err});
            try result.setFailed(duration, error_msg);
            self.allocator.free(error_msg);
            return result;
        };

        const stdout = child.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024) catch "";
        defer self.allocator.free(stdout);

        const stderr = child.stderr.?.readToEndAlloc(self.allocator, 1024 * 1024) catch "";
        defer self.allocator.free(stderr);

        const term = child.wait() catch |err| {
            const duration = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));
            const error_msg = try std.fmt.allocPrint(self.allocator, "Failed to wait for test: {any}", .{err});
            try result.setFailed(duration, error_msg);
            self.allocator.free(error_msg);
            return result;
        };

        const duration = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));

        switch (term) {
            .Exited => |code| {
                if (code == 0) {
                    result.setPassed(duration);
                } else {
                    const error_output = if (stderr.len > 0) stderr else stdout;
                    try result.setFailed(duration, error_output);
                }
            },
            else => {
                const error_msg = try std.fmt.allocPrint(self.allocator, "Test terminated abnormally: {any}", .{term});
                try result.setFailed(duration, error_msg);
                self.allocator.free(error_msg);
            },
        }

        return result;
    }

    /// Get test step name for build.zig
    fn getTestStepName(self: *TestRunner, module_name: []const u8) ![]const u8 {
        // Map module names to build.zig test steps
        const mapping = .{
            .{ "tokenizer", "test-tokenizer" },
            .{ "parser", "test-parser" },
            .{ "expander", "test-expander" },
            .{ "executor", "test-executor" },
            .{ "plugins", "test-plugins" },
            .{ "plugin_interface", "test-interface" },
            .{ "builtin_plugins", "test-builtin-plugins" },
            .{ "plugin_integration", "test-plugin-integration" },
            .{ "plugin_discovery", "test-plugin-discovery" },
            .{ "plugin_api", "test-plugin-api" },
            .{ "hook_manager", "test-hook-manager" },
            .{ "builtin_hooks", "test-builtin-hooks" },
            .{ "theme", "test-theme" },
            .{ "prompt", "test-prompt" },
            .{ "modules", "test-modules" },
            .{ "system_modules", "test-system-modules" },
        };

        inline for (mapping) |pair| {
            if (std.mem.eql(u8, module_name, pair[0])) {
                return try self.allocator.dupe(u8, pair[1]);
            }
        }

        // Default: test-{module_name}
        return try std.fmt.allocPrint(self.allocator, "test-{s}", .{module_name});
    }

    /// Run tests in parallel
    pub fn runParallel(self: *TestRunner, max_parallel: usize) !TestStats {
        var discovery = TestDiscovery.init(self.allocator, self.root_dir);

        var modules = try discovery.getKnownTestModules();
        defer {
            for (modules.items) |*module| {
                module.deinit();
            }
            modules.deinit();
        }

        var stats = TestStats.init();
        var current_parallel: usize = 0;
        var module_index: usize = 0;

        while (module_index < modules.items.len or current_parallel > 0) {
            // Start new tests if we have capacity
            while (current_parallel < max_parallel and module_index < modules.items.len) {
                const module = modules.items[module_index];

                if (!self.filter.matches(module.name)) {
                    module_index += 1;
                    continue;
                }

                try self.reporter.reportStart(module.name);

                // In a real implementation, we'd track processes
                // For now, just run sequentially
                const result = try self.runTestModule(module.name);
                defer result.deinit();

                try self.reporter.reportResult(&result);
                stats.addResult(&result);

                module_index += 1;
                current_parallel += 1;
            }

            current_parallel = 0;
        }

        try self.reporter.reportSummary(&stats);
        return stats;
    }
};
