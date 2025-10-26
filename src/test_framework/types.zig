const std = @import("std");

/// Test status
pub const TestStatus = enum {
    passed,
    failed,
    skipped,
    running,
};

/// Test result
pub const TestResult = struct {
    name: []const u8,
    status: TestStatus,
    duration_ns: u64,
    error_message: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !TestResult {
        return .{
            .name = try allocator.dupe(u8, name),
            .status = .running,
            .duration_ns = 0,
            .error_message = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *const TestResult) void {
        self.allocator.free(self.name);
        if (self.error_message) |msg| {
            self.allocator.free(msg);
        }
    }

    pub fn setPassed(self: *TestResult, duration_ns: u64) void {
        self.status = .passed;
        self.duration_ns = duration_ns;
    }

    pub fn setFailed(self: *TestResult, duration_ns: u64, message: []const u8) !void {
        self.status = .failed;
        self.duration_ns = duration_ns;
        self.error_message = try self.allocator.dupe(u8, message);
    }

    pub fn setSkipped(self: *TestResult) void {
        self.status = .skipped;
    }
};

/// Test suite statistics
pub const TestStats = struct {
    total: usize,
    passed: usize,
    failed: usize,
    skipped: usize,
    duration_ns: u64,

    pub fn init() TestStats {
        return .{
            .total = 0,
            .passed = 0,
            .failed = 0,
            .skipped = 0,
            .duration_ns = 0,
        };
    }

    pub fn addResult(self: *TestStats, result: *const TestResult) void {
        self.total += 1;
        self.duration_ns += result.duration_ns;

        switch (result.status) {
            .passed => self.passed += 1,
            .failed => self.failed += 1,
            .skipped => self.skipped += 1,
            .running => {},
        }
    }

    pub fn hasFailed(self: *const TestStats) bool {
        return self.failed > 0;
    }
};

/// Test filter options
pub const TestFilter = struct {
    pattern: ?[]const u8,
    include_tags: []const []const u8,
    exclude_tags: []const []const u8,
    only_failed: bool,

    pub fn initDefault() TestFilter {
        return .{
            .pattern = null,
            .include_tags = &[_][]const u8{},
            .exclude_tags = &[_][]const u8{},
            .only_failed = false,
        };
    }

    pub fn matches(self: *const TestFilter, name: []const u8) bool {
        // Pattern matching
        if (self.pattern) |pattern| {
            if (std.mem.indexOf(u8, name, pattern) == null) {
                return false;
            }
        }

        return true;
    }
};

/// Test output format
pub const OutputFormat = enum {
    human,
    json,
    junit,
    tap,
};

/// Test reporter configuration
pub const ReporterConfig = struct {
    format: OutputFormat,
    verbose: bool,
    show_passed: bool,
    color: bool,

    pub fn initDefault() ReporterConfig {
        return .{
            .format = .human,
            .verbose = false,
            .show_passed = true,
            .color = true,
        };
    }
};
