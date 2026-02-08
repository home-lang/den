const std = @import("std");

/// Content type of pipeline data, used for format detection and conversion.
pub const ContentType = enum {
    json,
    csv,
    toml,
    yaml,
    text,
    binary,
    table,

    /// Return the canonical string name for this content type.
    pub fn name(self: ContentType) []const u8 {
        return switch (self) {
            .json => "application/json",
            .csv => "text/csv",
            .toml => "application/toml",
            .yaml => "application/yaml",
            .text => "text/plain",
            .binary => "application/octet-stream",
            .table => "application/x-table",
        };
    }

    /// Return the short label for display purposes.
    pub fn label(self: ContentType) []const u8 {
        return @tagName(self);
    }

    /// Attempt to detect content type from a file extension.
    pub fn fromExtension(ext: []const u8) ?ContentType {
        if (std.mem.eql(u8, ext, ".json")) return .json;
        if (std.mem.eql(u8, ext, ".csv")) return .csv;
        if (std.mem.eql(u8, ext, ".toml")) return .toml;
        if (std.mem.eql(u8, ext, ".yaml") or std.mem.eql(u8, ext, ".yml")) return .yaml;
        if (std.mem.eql(u8, ext, ".txt") or std.mem.eql(u8, ext, ".log")) return .text;
        if (std.mem.eql(u8, ext, ".bin")) return .binary;
        return null;
    }
};

/// Tracks data provenance through pipelines.
///
/// Records which command produced the data, the source file (if any),
/// the content type, creation timestamp, and arbitrary metadata tags.
/// Builder methods return a modified copy so calls can be chained.
pub const PipelineMetadata = struct {
    /// The command that produced this data (e.g. "open", "from json").
    source_command: ?[]const u8,
    /// The file the data was read from, if applicable.
    source_file: ?[]const u8,
    /// The content/format type of the pipeline data.
    content_type: ContentType,
    /// Unix epoch timestamp (seconds) when this metadata was created.
    created_at: i64,
    /// Arbitrary key-value metadata tags for extensibility.
    tags: std.StringHashMap([]const u8),

    const Self = @This();

    /// Obtain the current wall-clock time as seconds since the Unix epoch.
    fn currentTimestamp() i64 {
        const ts = std.posix.clock_gettime(.REALTIME) catch return 0;
        return ts.sec;
    }

    /// Create a new PipelineMetadata with sensible defaults.
    /// `content_type` defaults to `.text`, `created_at` is set to the current time.
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .source_command = null,
            .source_file = null,
            .content_type = .text,
            .created_at = currentTimestamp(),
            .tags = std.StringHashMap([]const u8).init(allocator),
        };
    }

    /// Release all owned memory. After calling deinit the struct must not be used.
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.source_command) |cmd| allocator.free(cmd);
        if (self.source_file) |file| allocator.free(file);

        var it = self.tags.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.tags.deinit();

        self.* = undefined;
    }

    /// Deep-clone this metadata, duplicating all owned strings.
    pub fn clone(self: Self, allocator: std.mem.Allocator) !Self {
        const cmd = if (self.source_command) |c| try allocator.dupe(u8, c) else null;
        errdefer if (cmd) |c| allocator.free(c);

        const file = if (self.source_file) |f| try allocator.dupe(u8, f) else null;
        errdefer if (file) |f| allocator.free(f);

        var new_tags = std.StringHashMap([]const u8).init(allocator);
        errdefer {
            var tag_it = new_tags.iterator();
            while (tag_it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            new_tags.deinit();
        }

        var it = self.tags.iterator();
        while (it.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);
            const value = try allocator.dupe(u8, entry.value_ptr.*);
            try new_tags.put(key, value);
        }

        return .{
            .source_command = cmd,
            .source_file = file,
            .content_type = self.content_type,
            .created_at = self.created_at,
            .tags = new_tags,
        };
    }

    // ----- Builder methods -----
    // Each builder duplicates the supplied string into the metadata's allocator
    // and returns the modified struct value for chaining.

    /// Set the source command. Frees any previously set value.
    pub fn withSource(self: *Self, allocator: std.mem.Allocator, command: []const u8) !*Self {
        if (self.source_command) |old| allocator.free(old);
        self.source_command = try allocator.dupe(u8, command);
        return self;
    }

    /// Set the source file path. Frees any previously set value.
    pub fn withFile(self: *Self, allocator: std.mem.Allocator, file: []const u8) !*Self {
        if (self.source_file) |old| allocator.free(old);
        self.source_file = try allocator.dupe(u8, file);

        // Auto-detect content type from the file extension when possible.
        if (std.fs.path.extension(file).len > 0) {
            if (ContentType.fromExtension(std.fs.path.extension(file))) |ct| {
                self.content_type = ct;
            }
        }

        return self;
    }

    /// Set the content type explicitly.
    pub fn withContentType(self: *Self, ct: ContentType) *Self {
        self.content_type = ct;
        return self;
    }

    /// Add or update an arbitrary metadata tag. Both key and value are duplicated.
    pub fn setTag(self: *Self, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        // If the key already exists, free the old value.
        if (self.tags.fetchRemove(key)) |removed| {
            allocator.free(removed.key);
            allocator.free(removed.value);
        }
        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        const owned_value = try allocator.dupe(u8, value);
        try self.tags.put(owned_key, owned_value);
    }

    /// Retrieve a tag value by key.
    pub fn getTag(self: Self, key: []const u8) ?[]const u8 {
        return self.tags.get(key);
    }

    /// Remove a tag by key, freeing its memory. Returns true if the tag existed.
    pub fn removeTag(self: *Self, allocator: std.mem.Allocator, key: []const u8) bool {
        if (self.tags.fetchRemove(key)) |removed| {
            allocator.free(removed.key);
            allocator.free(removed.value);
            return true;
        }
        return false;
    }

    /// Format a human-readable summary of this metadata.
    pub fn describe(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);

        try buf.appendSlice(allocator, "PipelineMetadata{");

        if (self.source_command) |cmd| {
            try buf.appendSlice(allocator, " cmd=\"");
            try buf.appendSlice(allocator, cmd);
            try buf.append(allocator, '"');
        }

        if (self.source_file) |file| {
            try buf.appendSlice(allocator, " file=\"");
            try buf.appendSlice(allocator, file);
            try buf.append(allocator, '"');
        }

        try buf.appendSlice(allocator, " type=");
        try buf.appendSlice(allocator, self.content_type.label());

        const ts = try std.fmt.allocPrint(allocator, " ts={d}", .{self.created_at});
        defer allocator.free(ts);
        try buf.appendSlice(allocator, ts);

        if (self.tags.count() > 0) {
            const tag_count = try std.fmt.allocPrint(allocator, " tags={d}", .{self.tags.count()});
            defer allocator.free(tag_count);
            try buf.appendSlice(allocator, tag_count);
        }

        try buf.appendSlice(allocator, " }");

        return try buf.toOwnedSlice(allocator);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "PipelineMetadata init and deinit" {
    const allocator = std.testing.allocator;
    var meta = PipelineMetadata.init(allocator);
    defer meta.deinit(allocator);

    try std.testing.expect(meta.source_command == null);
    try std.testing.expect(meta.source_file == null);
    try std.testing.expectEqual(ContentType.text, meta.content_type);
    try std.testing.expect(meta.created_at > 0);
}

test "PipelineMetadata builder methods" {
    const allocator = std.testing.allocator;
    var meta = PipelineMetadata.init(allocator);
    defer meta.deinit(allocator);

    _ = try meta.withSource(allocator, "open");
    _ = try meta.withFile(allocator, "data.json");

    try std.testing.expectEqualStrings("open", meta.source_command.?);
    try std.testing.expectEqualStrings("data.json", meta.source_file.?);
    try std.testing.expectEqual(ContentType.json, meta.content_type);
}

test "PipelineMetadata withContentType override" {
    const allocator = std.testing.allocator;
    var meta = PipelineMetadata.init(allocator);
    defer meta.deinit(allocator);

    _ = try meta.withFile(allocator, "data.json");
    try std.testing.expectEqual(ContentType.json, meta.content_type);

    _ = meta.withContentType(.csv);
    try std.testing.expectEqual(ContentType.csv, meta.content_type);
}

test "PipelineMetadata tags" {
    const allocator = std.testing.allocator;
    var meta = PipelineMetadata.init(allocator);
    defer meta.deinit(allocator);

    try meta.setTag(allocator, "encoding", "utf-8");
    try meta.setTag(allocator, "separator", ",");

    try std.testing.expectEqualStrings("utf-8", meta.getTag("encoding").?);
    try std.testing.expectEqualStrings(",", meta.getTag("separator").?);
    try std.testing.expect(meta.getTag("nonexistent") == null);

    // Overwrite existing tag.
    try meta.setTag(allocator, "encoding", "ascii");
    try std.testing.expectEqualStrings("ascii", meta.getTag("encoding").?);

    // Remove a tag.
    try std.testing.expect(meta.removeTag(allocator, "separator"));
    try std.testing.expect(meta.getTag("separator") == null);
    try std.testing.expect(!meta.removeTag(allocator, "separator"));
}

test "PipelineMetadata clone" {
    const allocator = std.testing.allocator;
    var meta = PipelineMetadata.init(allocator);
    defer meta.deinit(allocator);

    _ = try meta.withSource(allocator, "ls");
    _ = try meta.withFile(allocator, "items.csv");
    try meta.setTag(allocator, "rows", "100");

    var cloned = try meta.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expectEqualStrings("ls", cloned.source_command.?);
    try std.testing.expectEqualStrings("items.csv", cloned.source_file.?);
    try std.testing.expectEqual(ContentType.csv, cloned.content_type);
    try std.testing.expectEqualStrings("100", cloned.getTag("rows").?);

    // Mutating the clone must not affect the original.
    _ = try cloned.withSource(allocator, "ps");
    try std.testing.expectEqualStrings("ls", meta.source_command.?);
    try std.testing.expectEqualStrings("ps", cloned.source_command.?);
}

test "PipelineMetadata describe" {
    const allocator = std.testing.allocator;
    var meta = PipelineMetadata.init(allocator);
    defer meta.deinit(allocator);

    _ = try meta.withSource(allocator, "from json");
    _ = try meta.withFile(allocator, "config.json");

    const desc = try meta.describe(allocator);
    defer allocator.free(desc);

    // The description should contain the key pieces of information.
    try std.testing.expect(std.mem.indexOf(u8, desc, "from json") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "config.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "json") != null);
}

test "ContentType fromExtension" {
    try std.testing.expectEqual(ContentType.json, ContentType.fromExtension(".json").?);
    try std.testing.expectEqual(ContentType.csv, ContentType.fromExtension(".csv").?);
    try std.testing.expectEqual(ContentType.toml, ContentType.fromExtension(".toml").?);
    try std.testing.expectEqual(ContentType.yaml, ContentType.fromExtension(".yaml").?);
    try std.testing.expectEqual(ContentType.yaml, ContentType.fromExtension(".yml").?);
    try std.testing.expectEqual(ContentType.text, ContentType.fromExtension(".txt").?);
    try std.testing.expectEqual(ContentType.text, ContentType.fromExtension(".log").?);
    try std.testing.expectEqual(ContentType.binary, ContentType.fromExtension(".bin").?);
    try std.testing.expect(ContentType.fromExtension(".xyz") == null);
}

test "ContentType name and label" {
    try std.testing.expectEqualStrings("application/json", ContentType.json.name());
    try std.testing.expectEqualStrings("json", ContentType.json.label());
    try std.testing.expectEqualStrings("text/plain", ContentType.text.name());
    try std.testing.expectEqualStrings("text", ContentType.text.label());
}
