// Performance profiling infrastructure for Den Shell
const std = @import("std");

/// Profiling zone for measuring performance
pub const ProfileZone = struct {
    name: []const u8,
    start_time: i64,
    parent: ?*ProfileZone,

    pub fn init(name: []const u8, parent: ?*ProfileZone) ProfileZone {
        return .{
            .name = name,
            .start_time = std.time.nanoTimestamp(),
            .parent = parent,
        };
    }

    pub fn end(self: *const ProfileZone) i64 {
        return std.time.nanoTimestamp() - self.start_time;
    }

    pub fn endMs(self: *const ProfileZone) f64 {
        const ns = self.end();
        return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
    }

    pub fn endUs(self: *const ProfileZone) f64 {
        const ns = self.end();
        return @as(f64, @floatFromInt(ns)) / 1_000.0;
    }
};

/// Profile event for recording in the trace
pub const ProfileEvent = struct {
    name: []const u8,
    category: Category,
    duration_ns: i64,
    timestamp: i64,
    thread_id: u64,

    pub const Category = enum {
        startup,
        command_execution,
        parsing,
        expansion,
        completion,
        history,
        prompt,
        io,
        other,

        pub fn toString(self: Category) []const u8 {
            return switch (self) {
                .startup => "Startup",
                .command_execution => "Command Execution",
                .parsing => "Parsing",
                .expansion => "Expansion",
                .completion => "Completion",
                .history => "History",
                .prompt => "Prompt",
                .io => "I/O",
                .other => "Other",
            };
        }
    };
};

/// Main profiler for collecting and analyzing performance data
pub const Profiler = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(ProfileEvent),
    enabled: bool,
    output_file: ?[]const u8,
    start_time: i64,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) !*Profiler {
        const profiler = try allocator.create(Profiler);
        profiler.* = .{
            .allocator = allocator,
            .events = std.ArrayList(ProfileEvent).init(allocator),
            .enabled = false,
            .output_file = null,
            .start_time = std.time.nanoTimestamp(),
            .mutex = .{},
        };
        return profiler;
    }

    pub fn deinit(self: *Profiler) void {
        self.events.deinit();
        self.allocator.destroy(self);
    }

    pub fn enable(self: *Profiler, output_file: ?[]const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.enabled = true;
        self.output_file = output_file;
        self.start_time = std.time.nanoTimestamp();
    }

    pub fn disable(self: *Profiler) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.enabled = false;
    }

    pub fn isEnabled(self: *const Profiler) bool {
        return self.enabled;
    }

    pub fn recordEvent(
        self: *Profiler,
        name: []const u8,
        category: ProfileEvent.Category,
        duration_ns: i64,
    ) !void {
        if (!self.enabled) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        const event = ProfileEvent{
            .name = name,
            .category = category,
            .duration_ns = duration_ns,
            .timestamp = std.time.nanoTimestamp() - self.start_time,
            .thread_id = std.Thread.getCurrentId(),
        };

        try self.events.append(event);
    }

    pub fn beginZone(self: *Profiler, name: []const u8) ProfileZone {
        _ = self;
        return ProfileZone.init(name, null);
    }

    pub fn endZone(
        self: *Profiler,
        zone: *ProfileZone,
        category: ProfileEvent.Category,
    ) !void {
        const duration = zone.end();
        try self.recordEvent(zone.name, category, duration);
    }

    /// Generate a summary report
    pub fn generateReport(self: *Profiler, writer: anytype) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.events.items.len == 0) {
            try writer.writeAll("No profiling data collected.\n");
            return;
        }

        try writer.writeAll("\n=== Den Shell Performance Profile ===\n\n");

        // Calculate statistics by category
        var category_stats = std.AutoHashMap(ProfileEvent.Category, CategoryStats).init(self.allocator);
        defer category_stats.deinit();

        for (self.events.items) |event| {
            var stats = category_stats.get(event.category) orelse CategoryStats{};
            stats.count += 1;
            stats.total_ns += event.duration_ns;
            stats.min_ns = @min(stats.min_ns, event.duration_ns);
            stats.max_ns = @max(stats.max_ns, event.duration_ns);
            try category_stats.put(event.category, stats);
        }

        // Print category summary
        try writer.writeAll("Category Summary:\n");
        try writer.writeAll("----------------\n");

        var it = category_stats.iterator();
        while (it.next()) |entry| {
            const category = entry.key_ptr.*;
            const stats = entry.value_ptr.*;

            const avg_ms = @as(f64, @floatFromInt(stats.total_ns)) / @as(f64, @floatFromInt(stats.count)) / 1_000_000.0;
            const min_ms = @as(f64, @floatFromInt(stats.min_ns)) / 1_000_000.0;
            const max_ms = @as(f64, @floatFromInt(stats.max_ns)) / 1_000_000.0;
            const total_ms = @as(f64, @floatFromInt(stats.total_ns)) / 1_000_000.0;

            try writer.print("{s}:\n", .{category.toString()});
            try writer.print("  Count: {d}\n", .{stats.count});
            try writer.print("  Total: {d:.2}ms\n", .{total_ms});
            try writer.print("  Avg:   {d:.2}ms\n", .{avg_ms});
            try writer.print("  Min:   {d:.2}ms\n", .{min_ms});
            try writer.print("  Max:   {d:.2}ms\n", .{max_ms});
            try writer.writeAll("\n");
        }

        // Print top slowest operations
        try writer.writeAll("Top 10 Slowest Operations:\n");
        try writer.writeAll("--------------------------\n");

        // Sort events by duration
        var sorted_events = try self.allocator.alloc(ProfileEvent, self.events.items.len);
        defer self.allocator.free(sorted_events);
        @memcpy(sorted_events, self.events.items);

        std.mem.sort(ProfileEvent, sorted_events, {}, compareEventsByDuration);

        const top_n = @min(10, sorted_events.len);
        for (sorted_events[0..top_n], 0..) |event, i| {
            const duration_ms = @as(f64, @floatFromInt(event.duration_ns)) / 1_000_000.0;
            try writer.print("{d}. {s} ({s}): {d:.2}ms\n", .{
                i + 1,
                event.name,
                event.category.toString(),
                duration_ms,
            });
        }

        try writer.writeAll("\n");
    }

    fn compareEventsByDuration(_: void, a: ProfileEvent, b: ProfileEvent) bool {
        return a.duration_ns > b.duration_ns;
    }

    /// Export trace in Chrome Trace Event Format (JSON)
    pub fn exportChromeTrace(self: *Profiler, file_path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        var writer = file.writer();

        try writer.writeAll("[\n");

        for (self.events.items, 0..) |event, i| {
            const ts_us = @divFloor(event.timestamp, 1000);
            const dur_us = @divFloor(event.duration_ns, 1000);

            try writer.print(
                \\  {{"name": "{s}", "cat": "{s}", "ph": "X", "ts": {d}, "dur": {d}, "pid": 1, "tid": {d}}}
            , .{
                event.name,
                event.category.toString(),
                ts_us,
                dur_us,
                event.thread_id,
            });

            if (i < self.events.items.len - 1) {
                try writer.writeAll(",\n");
            } else {
                try writer.writeAll("\n");
            }
        }

        try writer.writeAll("]\n");
    }

    /// Clear all collected events
    pub fn clear(self: *Profiler) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.events.clearRetainingCapacity();
        self.start_time = std.time.nanoTimestamp();
    }

    /// Get event count
    pub fn getEventCount(self: *const Profiler) usize {
        return self.events.items.len;
    }
};

const CategoryStats = struct {
    count: usize = 0,
    total_ns: i64 = 0,
    min_ns: i64 = std.math.maxInt(i64),
    max_ns: i64 = 0,
};

/// Scoped profiling helper - automatically ends zone when going out of scope
pub const ScopedZone = struct {
    profiler: *Profiler,
    zone: ProfileZone,
    category: ProfileEvent.Category,

    pub fn init(profiler: *Profiler, name: []const u8, category: ProfileEvent.Category) ScopedZone {
        return .{
            .profiler = profiler,
            .zone = ProfileZone.init(name, null),
            .category = category,
        };
    }

    pub fn deinit(self: *ScopedZone) void {
        self.profiler.endZone(&self.zone, self.category) catch {};
    }
};

/// Macro-like helper for easy profiling
pub fn profile(profiler: *Profiler, name: []const u8, category: ProfileEvent.Category) ScopedZone {
    return ScopedZone.init(profiler, name, category);
}

// Tests
test "ProfileZone timing" {
    var zone = ProfileZone.init("test", null);
    std.time.sleep(1_000_000); // 1ms
    const duration = zone.endMs();
    try std.testing.expect(duration >= 0.5);
}

test "Profiler basic usage" {
    const allocator = std.testing.allocator;

    var profiler = try Profiler.init(allocator);
    defer profiler.deinit();

    profiler.enable(null);
    try std.testing.expect(profiler.isEnabled());

    var zone = profiler.beginZone("test_operation");
    std.time.sleep(1_000_000);
    try profiler.endZone(&zone, .other);

    try std.testing.expectEqual(@as(usize, 1), profiler.getEventCount());
}

test "Profiler report generation" {
    const allocator = std.testing.allocator;

    var profiler = try Profiler.init(allocator);
    defer profiler.deinit();

    profiler.enable(null);

    // Record some events
    try profiler.recordEvent("startup", .startup, 1_000_000);
    try profiler.recordEvent("parse", .parsing, 500_000);
    try profiler.recordEvent("execute", .command_execution, 2_000_000);

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try profiler.generateReport(buffer.writer());

    const report = buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, report, "Den Shell Performance Profile") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "Category Summary") != null);
}
