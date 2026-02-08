const std = @import("std");
const Value = @import("../types/value.zig").Value;
const PipelineMetadata = @import("../types/metadata.zig").PipelineMetadata;

/// Structured pipeline for passing typed Value data between builtins.
///
/// Traditional shell pipelines serialize everything to text (byte streams).
/// The structured pipeline allows builtins to pass rich Value types directly,
/// preserving type information across pipeline stages. This is inspired by
/// Nushell's structured data pipelines. When a pipeline stage does not support
/// structured data, the pipeline gracefully degrades to text mode via `toText`.
pub const StructuredPipeline = struct {
    /// The ordered collection of values flowing through the pipeline.
    values: std.ArrayList(Value),
    /// Optional metadata describing provenance, content type, etc.
    metadata: ?PipelineMetadata,

    const Self = @This();

    /// Create an empty structured pipeline.
    pub fn init() Self {
        return .{
            .values = std.ArrayList(Value).empty,
            .metadata = null,
        };
    }

    /// Create a structured pipeline pre-populated with metadata.
    pub fn initWithMetadata(meta: PipelineMetadata) Self {
        return .{
            .values = std.ArrayList(Value).empty,
            .metadata = meta,
        };
    }

    /// Release all owned values and metadata.
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.values.items) |*v| {
            v.deinit(allocator);
        }
        self.values.deinit(allocator);
        if (self.metadata) |*meta| {
            meta.deinit(allocator);
        }
    }

    /// Deep-clone the pipeline and all contained values.
    pub fn clone(self: Self, allocator: std.mem.Allocator) !Self {
        var new_values = std.ArrayList(Value).empty;
        errdefer {
            for (new_values.items) |*v| v.deinit(allocator);
            new_values.deinit(allocator);
        }
        try new_values.ensureTotalCapacity(allocator, self.values.items.len);
        for (self.values.items) |v| {
            try new_values.append(allocator, try v.clone(allocator));
        }
        const new_meta = if (self.metadata) |m| try m.clone(allocator) else null;
        return .{
            .values = new_values,
            .metadata = new_meta,
        };
    }

    /// Append a single value (takes ownership).
    pub fn push(self: *Self, allocator: std.mem.Allocator, value: Value) !void {
        try self.values.append(allocator, value);
    }

    /// Return the number of values in the pipeline.
    pub fn len(self: Self) usize {
        return self.values.items.len;
    }

    /// Return true when the pipeline carries no values.
    pub fn isEmpty(self: Self) bool {
        return self.values.items.len == 0;
    }
};

/// A pipeline payload that is either traditional text or structured typed data.
///
/// This union allows pipeline stages to operate transparently on both legacy
/// text streams and the new structured data path. Callers can inspect the mode
/// and convert between representations as needed.
pub const PipelineValue = union(enum) {
    /// Traditional text data (byte slice, not owned).
    text: []const u8,
    /// Structured typed data.
    structured: StructuredPipeline,

    const Self = @This();

    // ----- Construction helpers -----

    /// Wrap a text slice as a PipelineValue. The caller retains ownership of
    /// the underlying bytes.
    pub fn fromText(text: []const u8) Self {
        return .{ .text = text };
    }

    /// Wrap a single Value in a new structured pipeline (takes ownership of
    /// the value).
    pub fn fromValue(allocator: std.mem.Allocator, value: Value) !Self {
        var sp = StructuredPipeline.init();
        try sp.push(allocator, value);
        return .{ .structured = sp };
    }

    /// Wrap a slice of Values by cloning each into a new structured pipeline.
    pub fn fromValues(allocator: std.mem.Allocator, values: []const Value) !Self {
        var sp = StructuredPipeline.init();
        errdefer sp.deinit(allocator);
        try sp.values.ensureTotalCapacity(allocator, values.len);
        for (values) |v| {
            try sp.values.append(allocator, try v.clone(allocator));
        }
        return .{ .structured = sp };
    }

    // ----- Conversion helpers -----

    /// Serialize the payload to text.
    ///
    /// * For `.text` payloads the string is duplicated so the caller always owns
    ///   the returned slice.
    /// * For `.structured` payloads each value is converted via `Value.asString`
    ///   and joined with newlines. Records and tables produce a simple
    ///   key: value / columnar representation (full JSON serialization is
    ///   intentionally deferred to the `to json` builtin).
    pub fn toText(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        switch (self) {
            .text => |t| return try allocator.dupe(u8, t),
            .structured => |sp| {
                if (sp.values.items.len == 0) {
                    return try allocator.dupe(u8, "");
                }

                // Single value -- just convert directly.
                if (sp.values.items.len == 1) {
                    return try sp.values.items[0].asString(allocator);
                }

                // Multiple values -- join with newlines.
                var buf = std.ArrayList(u8).empty;
                errdefer buf.deinit(allocator);

                for (sp.values.items, 0..) |v, idx| {
                    if (idx > 0) try buf.append(allocator, '\n');
                    const s = try v.asString(allocator);
                    defer allocator.free(s);
                    try buf.appendSlice(allocator, s);
                }

                return try buf.toOwnedSlice(allocator);
            },
        }
    }

    /// Returns `true` when the payload carries structured data.
    pub fn isStructured(self: Self) bool {
        return self == .structured;
    }

    /// If the payload is structured, return a slice over the contained values.
    /// Returns `null` for text payloads.
    pub fn asValues(self: Self) ?[]const Value {
        return switch (self) {
            .structured => |sp| sp.values.items,
            .text => null,
        };
    }

    /// Release all owned memory. After calling `deinit` the value must not be
    /// used.
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .structured => |*sp| sp.deinit(allocator),
            .text => {}, // text slice is not owned
        }
    }
};

/// A channel for incrementally building pipeline data during stage execution.
///
/// Each pipeline stage writes into a `PipelineChannel`. Depending on the mode,
/// the stage either appends raw text bytes or pushes structured `Value`s.
/// When the stage is done it calls `finish` to obtain a `PipelineValue` that
/// can be handed to the next stage.
pub const PipelineChannel = struct {
    /// Internal text buffer for text-mode writes.
    writer: std.ArrayList(u8),
    /// Internal value buffer for structured-mode pushes.
    values: std.ArrayList(Value),
    /// The current operating mode of the channel.
    mode: Mode,

    pub const Mode = enum {
        text,
        structured,
    };

    const Self = @This();

    /// Create a channel in the given mode.
    pub fn init(mode: Mode) Self {
        return .{
            .writer = std.ArrayList(u8).empty,
            .values = std.ArrayList(Value).empty,
            .mode = mode,
        };
    }

    /// Release all resources. Outstanding data that was never `finish`ed is
    /// discarded.
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.writer.deinit(allocator);
        for (self.values.items) |*v| {
            v.deinit(allocator);
        }
        self.values.deinit(allocator);
    }

    /// Append raw text bytes. If the channel is in structured mode this is a
    /// no-op -- callers should check `mode` or use `pushValue` instead.
    pub fn writeText(self: *Self, allocator: std.mem.Allocator, data: []const u8) !void {
        if (self.mode != .text) return;
        try self.writer.appendSlice(allocator, data);
    }

    /// Push a structured value (takes ownership). If the channel is in text
    /// mode this is a no-op.
    pub fn pushValue(self: *Self, allocator: std.mem.Allocator, value: Value) !void {
        if (self.mode != .structured) return;
        try self.values.append(allocator, value);
    }

    /// Finalize the channel and return the accumulated data as a
    /// `PipelineValue`. After calling `finish` the channel is reset and may
    /// be reused.
    pub fn finish(self: *Self, allocator: std.mem.Allocator) !PipelineValue {
        switch (self.mode) {
            .text => {
                const owned = try self.writer.toOwnedSlice(allocator);
                // Reset the writer for potential reuse.
                self.writer = std.ArrayList(u8).empty;
                return PipelineValue{ .text = owned };
            },
            .structured => {
                var sp = StructuredPipeline.init();
                sp.values = self.values;
                // Detach from the channel so the caller owns the data.
                self.values = std.ArrayList(Value).empty;
                return PipelineValue{ .structured = sp };
            },
        }
    }

    /// Switch the channel mode. Any buffered data for the *previous* mode is
    /// discarded.
    pub fn setMode(self: *Self, allocator: std.mem.Allocator, new_mode: Mode) void {
        if (self.mode == new_mode) return;
        // Discard buffered data from the old mode.
        switch (self.mode) {
            .text => {
                self.writer.deinit(allocator);
                self.writer = std.ArrayList(u8).empty;
            },
            .structured => {
                for (self.values.items) |*v| v.deinit(allocator);
                self.values.deinit(allocator);
                self.values = std.ArrayList(Value).empty;
            },
        }
        self.mode = new_mode;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "StructuredPipeline init and deinit" {
    const allocator = std.testing.allocator;
    var sp = StructuredPipeline.init();
    defer sp.deinit(allocator);

    try std.testing.expect(sp.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), sp.len());
    try std.testing.expect(sp.metadata == null);
}

test "StructuredPipeline push and len" {
    const allocator = std.testing.allocator;
    var sp = StructuredPipeline.init();
    defer sp.deinit(allocator);

    try sp.push(allocator, .{ .int = 42 });
    try sp.push(allocator, .{ .string = try allocator.dupe(u8, "hello") });

    try std.testing.expectEqual(@as(usize, 2), sp.len());
    try std.testing.expect(!sp.isEmpty());
    try std.testing.expect(sp.values.items[0].eql(.{ .int = 42 }));
}

test "StructuredPipeline clone" {
    const allocator = std.testing.allocator;
    var sp = StructuredPipeline.init();
    defer sp.deinit(allocator);

    try sp.push(allocator, .{ .int = 1 });
    try sp.push(allocator, .{ .float = 2.5 });

    var sp2 = try sp.clone(allocator);
    defer sp2.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), sp2.len());
    try std.testing.expect(sp2.values.items[0].eql(.{ .int = 1 }));
    try std.testing.expect(sp2.values.items[1].eql(.{ .float = 2.5 }));
}

test "PipelineValue fromText" {
    const pv = PipelineValue.fromText("hello world");

    try std.testing.expect(!pv.isStructured());
    try std.testing.expect(pv.asValues() == null);
    try std.testing.expectEqualStrings("hello world", pv.text);
}

test "PipelineValue fromValue" {
    const allocator = std.testing.allocator;
    var pv = try PipelineValue.fromValue(allocator, .{ .int = 99 });
    defer pv.deinit(allocator);

    try std.testing.expect(pv.isStructured());
    const vals = pv.asValues().?;
    try std.testing.expectEqual(@as(usize, 1), vals.len);
    try std.testing.expect(vals[0].eql(.{ .int = 99 }));
}

test "PipelineValue fromValues" {
    const allocator = std.testing.allocator;
    const source = [_]Value{
        .{ .int = 1 },
        .{ .int = 2 },
        .{ .int = 3 },
    };
    var pv = try PipelineValue.fromValues(allocator, &source);
    defer pv.deinit(allocator);

    try std.testing.expect(pv.isStructured());
    const vals = pv.asValues().?;
    try std.testing.expectEqual(@as(usize, 3), vals.len);
    try std.testing.expect(vals[0].eql(.{ .int = 1 }));
    try std.testing.expect(vals[2].eql(.{ .int = 3 }));
}

test "PipelineValue toText for text mode" {
    const allocator = std.testing.allocator;
    const pv = PipelineValue.fromText("already text");
    const result = try pv.toText(allocator);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("already text", result);
}

test "PipelineValue toText for single structured value" {
    const allocator = std.testing.allocator;
    var pv = try PipelineValue.fromValue(allocator, .{ .int = 42 });
    defer pv.deinit(allocator);

    const result = try pv.toText(allocator);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("42", result);
}

test "PipelineValue toText for multiple structured values" {
    const allocator = std.testing.allocator;
    const source = [_]Value{
        .{ .int = 10 },
        .{ .bool_val = true },
    };
    var pv = try PipelineValue.fromValues(allocator, &source);
    defer pv.deinit(allocator);

    const result = try pv.toText(allocator);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("10\ntrue", result);
}

test "PipelineValue toText for empty structured pipeline" {
    const allocator = std.testing.allocator;
    var pv = PipelineValue{ .structured = StructuredPipeline.init() };
    defer pv.deinit(allocator);

    const result = try pv.toText(allocator);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "PipelineChannel text mode" {
    const allocator = std.testing.allocator;
    var ch = PipelineChannel.init(.text);
    defer ch.deinit(allocator);

    try ch.writeText(allocator, "hello ");
    try ch.writeText(allocator, "world");

    var pv = try ch.finish(allocator);
    defer allocator.free(pv.text);

    try std.testing.expect(!pv.isStructured());
    try std.testing.expectEqualStrings("hello world", pv.text);
}

test "PipelineChannel structured mode" {
    const allocator = std.testing.allocator;
    var ch = PipelineChannel.init(.structured);
    defer ch.deinit(allocator);

    try ch.pushValue(allocator, .{ .int = 1 });
    try ch.pushValue(allocator, .{ .int = 2 });

    var pv = try ch.finish(allocator);
    defer pv.deinit(allocator);

    try std.testing.expect(pv.isStructured());
    const vals = pv.asValues().?;
    try std.testing.expectEqual(@as(usize, 2), vals.len);
}

test "PipelineChannel ignores wrong-mode writes" {
    const allocator = std.testing.allocator;

    // Text channel ignores pushValue.
    var ch_text = PipelineChannel.init(.text);
    defer ch_text.deinit(allocator);
    try ch_text.pushValue(allocator, .{ .int = 1 });
    try std.testing.expectEqual(@as(usize, 0), ch_text.values.items.len);

    // Structured channel ignores writeText.
    var ch_struct = PipelineChannel.init(.structured);
    defer ch_struct.deinit(allocator);
    try ch_struct.writeText(allocator, "ignored");
    try std.testing.expectEqual(@as(usize, 0), ch_struct.writer.items.len);
}

test "PipelineChannel setMode discards old data" {
    const allocator = std.testing.allocator;
    var ch = PipelineChannel.init(.text);
    defer ch.deinit(allocator);

    try ch.writeText(allocator, "some data");
    try std.testing.expect(ch.writer.items.len > 0);

    ch.setMode(allocator, .structured);
    try std.testing.expectEqual(@as(usize, 0), ch.writer.items.len);
    try std.testing.expectEqual(PipelineChannel.Mode.structured, ch.mode);
}
