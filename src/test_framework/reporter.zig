const std = @import("std");
const types = @import("types.zig");

const TestResult = types.TestResult;
const TestStats = types.TestStats;
const ReporterConfig = types.ReporterConfig;
const OutputFormat = types.OutputFormat;

/// ANSI color codes
const Color = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const blue = "\x1b[34m";
    const cyan = "\x1b[36m";
};

/// Test reporter
pub const TestReporter = struct {
    allocator: std.mem.Allocator,
    config: ReporterConfig,
    writer: std.fs.File.Writer,

    pub fn init(allocator: std.mem.Allocator, config: ReporterConfig) TestReporter {
        return .{
            .allocator = allocator,
            .config = config,
            .writer = std.io.getStdOut().writer(),
        };
    }

    /// Report test start
    pub fn reportStart(self: *TestReporter, module_name: []const u8) !void {
        if (self.config.format == .human) {
            if (self.config.color) {
                try self.writer.print("{s}{s}Running{s} {s}\n", .{ Color.bold, Color.blue, Color.reset, module_name });
            } else {
                try self.writer.print("Running {s}\n", .{module_name});
            }
        }
    }

    /// Report individual test result
    pub fn reportResult(self: *TestReporter, result: *const TestResult) !void {
        switch (self.config.format) {
            .human => try self.reportHuman(result),
            .json => try self.reportJSON(result),
            .junit => try self.reportJUnit(result),
            .tap => try self.reportTAP(result),
        }
    }

    /// Report test summary
    pub fn reportSummary(self: *TestReporter, stats: *const TestStats) !void {
        switch (self.config.format) {
            .human => try self.reportSummaryHuman(stats),
            .json => try self.reportSummaryJSON(stats),
            .junit => try self.reportSummaryJUnit(stats),
            .tap => try self.reportSummaryTAP(stats),
        }
    }

    /// Human-readable format
    fn reportHuman(self: *TestReporter, result: *const TestResult) !void {
        if (!self.config.show_passed and result.status == .passed) {
            return;
        }

        const duration_ms = @as(f64, @floatFromInt(result.duration_ns)) / 1_000_000.0;

        const status_str = switch (result.status) {
            .passed => if (self.config.color) Color.green ++ "PASS" ++ Color.reset else "PASS",
            .failed => if (self.config.color) Color.red ++ "FAIL" ++ Color.reset else "FAIL",
            .skipped => if (self.config.color) Color.yellow ++ "SKIP" ++ Color.reset else "SKIP",
            .running => "RUN ",
        };

        try self.writer.print("  [{s}] {s} ({d:.2}ms)\n", .{ status_str, result.name, duration_ms });

        if (result.error_message) |msg| {
            if (self.config.verbose) {
                const indent = "    ";
                var lines = std.mem.splitScalar(u8, msg, '\n');
                while (lines.next()) |line| {
                    try self.writer.print("{s}{s}\n", .{ indent, line });
                }
            } else {
                try self.writer.print("    Error: {s}\n", .{msg});
            }
        }
    }

    /// JSON format
    fn reportJSON(self: *TestReporter, result: *const TestResult) !void {
        try self.writer.writeAll("{");
        try self.writer.print("\"name\":\"{s}\",", .{result.name});
        try self.writer.print("\"status\":\"{s}\",", .{@tagName(result.status)});
        try self.writer.print("\"duration_ns\":{d}", .{result.duration_ns});

        if (result.error_message) |msg| {
            // Escape JSON string
            try self.writer.writeAll(",\"error\":\"");
            for (msg) |c| {
                switch (c) {
                    '"' => try self.writer.writeAll("\\\""),
                    '\\' => try self.writer.writeAll("\\\\"),
                    '\n' => try self.writer.writeAll("\\n"),
                    '\r' => try self.writer.writeAll("\\r"),
                    '\t' => try self.writer.writeAll("\\t"),
                    else => try self.writer.writeByte(c),
                }
            }
            try self.writer.writeAll("\"");
        }

        try self.writer.writeAll("}\n");
    }

    /// JUnit XML format
    fn reportJUnit(self: *TestReporter, result: *const TestResult) !void {
        const duration_s = @as(f64, @floatFromInt(result.duration_ns)) / 1_000_000_000.0;

        try self.writer.print("  <testcase name=\"{s}\" time=\"{d:.3}\"", .{ result.name, duration_s });

        switch (result.status) {
            .passed => try self.writer.writeAll(" />\n"),
            .failed => {
                try self.writer.writeAll(">\n");
                try self.writer.writeAll("    <failure>");
                if (result.error_message) |msg| {
                    try self.writer.writeAll(msg);
                }
                try self.writer.writeAll("</failure>\n");
                try self.writer.writeAll("  </testcase>\n");
            },
            .skipped => {
                try self.writer.writeAll(">\n");
                try self.writer.writeAll("    <skipped />\n");
                try self.writer.writeAll("  </testcase>\n");
            },
            .running => try self.writer.writeAll(" />\n"),
        }
    }

    /// TAP (Test Anything Protocol) format
    fn reportTAP(self: *TestReporter, result: *const TestResult) !void {
        const status = if (result.status == .passed) "ok" else "not ok";
        try self.writer.print("{s} - {s}\n", .{ status, result.name });

        if (result.error_message) |msg| {
            try self.writer.print("  # {s}\n", .{msg});
        }
    }

    /// Human-readable summary
    fn reportSummaryHuman(self: *TestReporter, stats: *const TestStats) !void {
        const duration_s = @as(f64, @floatFromInt(stats.duration_ns)) / 1_000_000_000.0;

        try self.writer.writeAll("\n");
        if (self.config.color) {
            try self.writer.print("{s}═══════════════════════════════════════{s}\n", .{ Color.bold, Color.reset });
        } else {
            try self.writer.writeAll("========================================\n");
        }

        if (self.config.color) {
            try self.writer.print("{s}Test Results:{s}\n", .{ Color.bold, Color.reset });
        } else {
            try self.writer.writeAll("Test Results:\n");
        }

        const passed_color = if (self.config.color) Color.green else "";
        const failed_color = if (self.config.color) Color.red else "";
        const skipped_color = if (self.config.color) Color.yellow else "";
        const reset = if (self.config.color) Color.reset else "";

        try self.writer.print("  Total:   {d}\n", .{stats.total});
        try self.writer.print("  {s}Passed:  {d}{s}\n", .{ passed_color, stats.passed, reset });
        try self.writer.print("  {s}Failed:  {d}{s}\n", .{ failed_color, stats.failed, reset });
        try self.writer.print("  {s}Skipped: {d}{s}\n", .{ skipped_color, stats.skipped, reset });
        try self.writer.print("  Duration: {d:.2}s\n", .{duration_s});

        if (self.config.color) {
            try self.writer.print("{s}═══════════════════════════════════════{s}\n\n", .{ Color.bold, Color.reset });
        } else {
            try self.writer.writeAll("========================================\n\n");
        }

        // Exit status indicator
        if (stats.failed > 0) {
            if (self.config.color) {
                try self.writer.print("{s}{s}FAILED{s}\n", .{ Color.bold, Color.red, Color.reset });
            } else {
                try self.writer.writeAll("FAILED\n");
            }
        } else {
            if (self.config.color) {
                try self.writer.print("{s}{s}PASSED{s}\n", .{ Color.bold, Color.green, Color.reset });
            } else {
                try self.writer.writeAll("PASSED\n");
            }
        }
    }

    /// JSON summary
    fn reportSummaryJSON(self: *TestReporter, stats: *const TestStats) !void {
        try self.writer.writeAll("{");
        try self.writer.print("\"total\":{d},", .{stats.total});
        try self.writer.print("\"passed\":{d},", .{stats.passed});
        try self.writer.print("\"failed\":{d},", .{stats.failed});
        try self.writer.print("\"skipped\":{d},", .{stats.skipped});
        try self.writer.print("\"duration_ns\":{d}", .{stats.duration_ns});
        try self.writer.writeAll("}\n");
    }

    /// JUnit XML summary
    fn reportSummaryJUnit(self: *TestReporter, stats: *const TestStats) !void {
        const duration_s = @as(f64, @floatFromInt(stats.duration_ns)) / 1_000_000_000.0;

        try self.writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
        try self.writer.print("<testsuite tests=\"{d}\" failures=\"{d}\" skipped=\"{d}\" time=\"{d:.3}\">\n", .{
            stats.total,
            stats.failed,
            stats.skipped,
            duration_s,
        });
        try self.writer.writeAll("</testsuite>\n");
    }

    /// TAP summary
    fn reportSummaryTAP(self: *TestReporter, stats: *const TestStats) !void {
        try self.writer.print("1..{d}\n", .{stats.total});
        if (stats.failed > 0) {
            try self.writer.print("# Failed: {d}\n", .{stats.failed});
        }
    }
};
