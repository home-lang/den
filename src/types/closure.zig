const std = @import("std");

/// Represents a closure - a function value with captured environment.
/// Used for pipeline operators like `each {|x| echo $x}`, `where {|row| $row.size > 100}`,
/// and `reduce {|acc, x| $acc + $x}`.
///
/// This is the mutable builder form of a closure, used during parsing and construction.
/// Once fully built, call `toValue()` to produce the lightweight `Value.Closure` representation
/// used throughout the runtime.
pub const Closure = struct {
    /// Parameter names for the closure (built incrementally via `addParam`).
    params: std.ArrayList([]const u8),
    /// The body of the closure as raw source lines (built via `setBody`).
    body: std.ArrayList([]const u8),
    /// Captured variables from the enclosing scope (name -> value).
    captures: std.StringHashMap([]const u8),
    /// Allocator used for all internal allocations.
    allocator: std.mem.Allocator,

    /// Initialize an empty closure.
    pub fn init(allocator: std.mem.Allocator) Closure {
        return .{
            .params = std.ArrayList([]const u8).empty,
            .body = std.ArrayList([]const u8).empty,
            .captures = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    /// Release all owned memory. The closure should not be used after this call.
    pub fn deinit(self: *Closure) void {
        // Free duped param names
        for (self.params.items) |param| {
            self.allocator.free(param);
        }
        self.params.deinit(self.allocator);

        // Free duped body lines
        for (self.body.items) |line| {
            self.allocator.free(line);
        }
        self.body.deinit(self.allocator);

        // Free duped capture keys and values
        var it = self.captures.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.captures.deinit();
    }

    /// Add a parameter name to the closure signature.
    /// The name is duped and owned by the closure.
    pub fn addParam(self: *Closure, name: []const u8) !void {
        const duped = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(duped);
        try self.params.append(self.allocator, duped);
    }

    /// Register a captured variable from the enclosing scope.
    /// Both name and value are duped and owned by the closure.
    /// If a capture with the same name already exists, its value is replaced.
    pub fn addCapture(self: *Closure, name: []const u8, value: []const u8) !void {
        const duped_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(duped_value);

        // If a capture with this name already exists, replace just the value
        if (self.captures.getPtr(name)) |existing_value_ptr| {
            self.allocator.free(existing_value_ptr.*);
            existing_value_ptr.* = duped_value;
        } else {
            const duped_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(duped_name);
            try self.captures.put(duped_name, duped_value);
        }
    }

    /// Set the closure body from a slice of source lines.
    /// Each line is duped and owned by the closure.
    /// Any previously set body lines are freed first.
    pub fn setBody(self: *Closure, lines: []const []const u8) !void {
        // Free any existing body lines
        for (self.body.items) |line| {
            self.allocator.free(line);
        }
        self.body.clearRetainingCapacity();

        for (lines) |line| {
            const duped = try self.allocator.dupe(u8, line);
            errdefer self.allocator.free(duped);
            try self.body.append(self.allocator, duped);
        }
    }

    /// Add a single line to the closure body.
    /// The line is duped and owned by the closure.
    pub fn addBodyLine(self: *Closure, line: []const u8) !void {
        const duped = try self.allocator.dupe(u8, line);
        errdefer self.allocator.free(duped);
        try self.body.append(self.allocator, duped);
    }

    /// Return the number of parameters.
    pub fn paramCount(self: Closure) usize {
        return self.params.items.len;
    }

    /// Return the number of captured variables.
    pub fn captureCount(self: Closure) usize {
        return self.captures.count();
    }

    /// Return the number of body lines.
    pub fn bodyLineCount(self: Closure) usize {
        return self.body.items.len;
    }

    /// Retrieve the value of a captured variable by name, or null if not captured.
    pub fn getCapture(self: Closure, name: []const u8) ?[]const u8 {
        return self.captures.get(name);
    }

    /// Produce the full body as a single string with lines joined by newlines.
    /// Caller owns the returned slice and must free it with the same allocator.
    pub fn bodyAsString(self: Closure) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);

        for (self.body.items, 0..) |line, i| {
            if (i > 0) try buf.append(self.allocator, '\n');
            try buf.appendSlice(self.allocator, line);
        }

        return try buf.toOwnedSlice(self.allocator);
    }

    /// Convert this mutable builder closure to the lightweight `Value.Closure`
    /// representation used in the runtime value system.
    /// The returned `Value.Closure` borrows slices from this Closure, so
    /// this Closure must outlive the returned value (or callers must dupe).
    pub fn toValueClosure(self: *const Closure) @import("value.zig").Value.Closure {
        const Value = @import("value.zig").Value;

        // Build params slice
        const params = self.allocator.alloc(Value.Closure.Param, self.params.items.len) catch
            return .{ .params = &.{}, .body_source = "", .captures = &.{} };
        for (self.params.items, 0..) |name, i| {
            params[i] = .{ .name = name };
        }

        // Build captures slice
        const cap_count = self.captures.count();
        const captures = self.allocator.alloc(Value.Closure.Capture, cap_count) catch
            return .{ .params = params, .body_source = "", .captures = &.{} };
        var it = self.captures.iterator();
        var idx: usize = 0;
        while (it.next()) |entry| {
            captures[idx] = .{
                .name = entry.key_ptr.*,
                .value = .{ .string = entry.value_ptr.* },
            };
            idx += 1;
        }

        // Join body into a single source string
        const body_source = self.bodyAsString() catch "";

        return .{
            .params = params,
            .body_source = body_source,
            .captures = captures,
        };
    }

    /// Create a deep clone of this closure. The clone is fully independent and
    /// owns all of its own memory.
    pub fn clone(self: Closure) !Closure {
        var new_closure = Closure.init(self.allocator);
        errdefer new_closure.deinit();

        // Clone params
        for (self.params.items) |param| {
            try new_closure.addParam(param);
        }

        // Clone body
        for (self.body.items) |line| {
            try new_closure.addBodyLine(line);
        }

        // Clone captures
        var it = self.captures.iterator();
        while (it.next()) |entry| {
            try new_closure.addCapture(entry.key_ptr.*, entry.value_ptr.*);
        }

        return new_closure;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Closure init and deinit" {
    const allocator = std.testing.allocator;

    var c = Closure.init(allocator);
    defer c.deinit();

    try std.testing.expectEqual(@as(usize, 0), c.paramCount());
    try std.testing.expectEqual(@as(usize, 0), c.captureCount());
    try std.testing.expectEqual(@as(usize, 0), c.bodyLineCount());
}

test "Closure addParam" {
    const allocator = std.testing.allocator;

    var c = Closure.init(allocator);
    defer c.deinit();

    try c.addParam("x");
    try c.addParam("y");

    try std.testing.expectEqual(@as(usize, 2), c.paramCount());
    try std.testing.expectEqualStrings("x", c.params.items[0]);
    try std.testing.expectEqualStrings("y", c.params.items[1]);
}

test "Closure addCapture" {
    const allocator = std.testing.allocator;

    var c = Closure.init(allocator);
    defer c.deinit();

    try c.addCapture("name", "alice");
    try c.addCapture("count", "42");

    try std.testing.expectEqual(@as(usize, 2), c.captureCount());
    try std.testing.expectEqualStrings("alice", c.getCapture("name").?);
    try std.testing.expectEqualStrings("42", c.getCapture("count").?);
    try std.testing.expectEqual(@as(?[]const u8, null), c.getCapture("missing"));
}

test "Closure addCapture replaces existing" {
    const allocator = std.testing.allocator;

    var c = Closure.init(allocator);
    defer c.deinit();

    try c.addCapture("x", "old");
    try c.addCapture("x", "new");

    try std.testing.expectEqual(@as(usize, 1), c.captureCount());
    try std.testing.expectEqualStrings("new", c.getCapture("x").?);
}

test "Closure setBody" {
    const allocator = std.testing.allocator;

    var c = Closure.init(allocator);
    defer c.deinit();

    const lines = [_][]const u8{ "echo $x", "echo done" };
    try c.setBody(&lines);

    try std.testing.expectEqual(@as(usize, 2), c.bodyLineCount());
    try std.testing.expectEqualStrings("echo $x", c.body.items[0]);
    try std.testing.expectEqualStrings("echo done", c.body.items[1]);

    // setBody should replace previous body
    const new_lines = [_][]const u8{"return $y"};
    try c.setBody(&new_lines);

    try std.testing.expectEqual(@as(usize, 1), c.bodyLineCount());
    try std.testing.expectEqualStrings("return $y", c.body.items[0]);
}

test "Closure addBodyLine" {
    const allocator = std.testing.allocator;

    var c = Closure.init(allocator);
    defer c.deinit();

    try c.addBodyLine("let sum = $acc + $x");
    try c.addBodyLine("echo $sum");

    try std.testing.expectEqual(@as(usize, 2), c.bodyLineCount());
    try std.testing.expectEqualStrings("let sum = $acc + $x", c.body.items[0]);
    try std.testing.expectEqualStrings("echo $sum", c.body.items[1]);
}

test "Closure bodyAsString" {
    const allocator = std.testing.allocator;

    var c = Closure.init(allocator);
    defer c.deinit();

    try c.addBodyLine("echo hello");
    try c.addBodyLine("echo world");

    const s = try c.bodyAsString();
    defer allocator.free(s);
    try std.testing.expectEqualStrings("echo hello\necho world", s);
}

test "Closure bodyAsString empty" {
    const allocator = std.testing.allocator;

    var c = Closure.init(allocator);
    defer c.deinit();

    const s = try c.bodyAsString();
    defer allocator.free(s);
    try std.testing.expectEqualStrings("", s);
}

test "Closure clone" {
    const allocator = std.testing.allocator;

    var original = Closure.init(allocator);
    defer original.deinit();

    try original.addParam("acc");
    try original.addParam("x");
    try original.addBodyLine("$acc + $x");
    try original.addCapture("base", "100");

    var cloned = try original.clone();
    defer cloned.deinit();

    // Verify the clone has the same data
    try std.testing.expectEqual(@as(usize, 2), cloned.paramCount());
    try std.testing.expectEqualStrings("acc", cloned.params.items[0]);
    try std.testing.expectEqualStrings("x", cloned.params.items[1]);
    try std.testing.expectEqual(@as(usize, 1), cloned.bodyLineCount());
    try std.testing.expectEqualStrings("$acc + $x", cloned.body.items[0]);
    try std.testing.expectEqualStrings("100", cloned.getCapture("base").?);

    // Verify independence: mutating clone does not affect original
    try cloned.addParam("z");
    try std.testing.expectEqual(@as(usize, 3), cloned.paramCount());
    try std.testing.expectEqual(@as(usize, 2), original.paramCount());
}
