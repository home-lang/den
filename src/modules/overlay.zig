const std = @import("std");
const IO = @import("../utils/io.zig").IO;

/// A single overlay layer that can store environment variable overrides and
/// command overrides (function-like definitions). Overlays are stacked so
/// that inner scopes can shadow outer scopes without mutating them.
///
/// When a `use <module>` statement is executed, a new overlay is pushed
/// containing the imported commands and variables. When the scope ends
/// (e.g. leaving a block or calling `overlay pop`), the overlay is removed
/// and the previous environment is restored.
pub const OverlayLayer = struct {
    /// Human-readable name for this layer (e.g. "math", "global", "block-3").
    name: []const u8,

    /// Environment variable overrides in this layer.
    /// Key: variable name, Value: variable value.
    env_vars: std.StringHashMap([]const u8),

    /// Command overrides in this layer.
    /// Key: command name, Value: list of body lines.
    commands: std.StringHashMap(std.ArrayList([]const u8)),

    /// Whether this overlay is currently active.
    active: bool,

    /// Create a new overlay layer with the given name.
    /// The name is duped.
    pub fn init(allocator: std.mem.Allocator, name: []const u8) !OverlayLayer {
        return .{
            .name = try allocator.dupe(u8, name),
            .env_vars = std.StringHashMap([]const u8).empty,
            .commands = std.StringHashMap(std.ArrayList([]const u8)).empty,
            .active = true,
        };
    }

    /// Free all memory owned by this layer.
    pub fn deinit(self: *OverlayLayer, allocator: std.mem.Allocator) void {
        // Free env vars
        var env_iter = self.env_vars.iterator();
        while (env_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.env_vars.deinit(allocator);

        // Free commands
        var cmd_iter = self.commands.iterator();
        while (cmd_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |line| {
                allocator.free(line);
            }
            entry.value_ptr.deinit(allocator);
        }
        self.commands.deinit(allocator);

        allocator.free(self.name);
    }

    /// Set an environment variable in this overlay layer.
    /// Both key and value are duped.
    pub fn setEnvVar(self: *OverlayLayer, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        if (self.env_vars.fetchRemove(key)) |removed| {
            allocator.free(removed.key);
            allocator.free(removed.value);
        }
        const k = try allocator.dupe(u8, key);
        const v = try allocator.dupe(u8, value);
        try self.env_vars.put(allocator, k, v);
    }

    /// Set a command override in this overlay layer.
    /// The name and each body line are duped.
    pub fn setCommand(self: *OverlayLayer, allocator: std.mem.Allocator, name: []const u8, body_lines: []const []const u8) !void {
        if (self.commands.fetchRemove(name)) |removed| {
            allocator.free(removed.key);
            var old_lines = removed.value;
            for (old_lines.items) |line| {
                allocator.free(line);
            }
            old_lines.deinit(allocator);
        }

        var lines: std.ArrayList([]const u8) = .{
            .items = &[_][]const u8{},
            .capacity = 0,
        };
        for (body_lines) |line| {
            try lines.append(allocator, try allocator.dupe(u8, line));
        }

        const k = try allocator.dupe(u8, name);
        try self.commands.put(allocator, k, lines);
    }

    /// Look up an env var in this layer. Returns null if not set here.
    pub fn getEnvVar(self: *const OverlayLayer, key: []const u8) ?[]const u8 {
        return self.env_vars.get(key);
    }

    /// Look up a command in this layer. Returns null if not set here.
    pub fn getCommand(self: *const OverlayLayer, name: []const u8) ?[]const []const u8 {
        if (self.commands.get(name)) |lines| {
            return lines.items;
        }
        return null;
    }
};

/// Overlay stack manager. Maintains an ordered stack of OverlayLayers.
/// Lookups walk the stack from top (most recent) to bottom (base) so
/// that inner scopes shadow outer scopes.
pub const OverlayStack = struct {
    /// The layer stack. Index 0 is the bottom (base) layer.
    layers: std.ArrayList(OverlayLayer),

    /// Create a new overlay stack. A base layer named "global" is pushed
    /// automatically.
    pub fn init(allocator: std.mem.Allocator) !OverlayStack {
        var stack = OverlayStack{
            .layers = .{
                .items = &[_]OverlayLayer{},
                .capacity = 0,
            },
        };
        // Push the implicit base layer.
        const base = try OverlayLayer.init(allocator, "global");
        try stack.layers.append(allocator, base);
        return stack;
    }

    /// Free all layers and the stack itself.
    pub fn deinit(self: *OverlayStack, allocator: std.mem.Allocator) void {
        for (self.layers.items) |*layer| {
            layer.deinit(allocator);
        }
        self.layers.deinit(allocator);
    }

    /// Push a new named overlay onto the stack.
    pub fn push(self: *OverlayStack, allocator: std.mem.Allocator, name: []const u8) !void {
        const layer = try OverlayLayer.init(allocator, name);
        try self.layers.append(allocator, layer);
    }

    /// Pop the topmost overlay. The base "global" layer cannot be popped.
    /// Returns the name of the popped layer (caller does NOT own it; the
    /// memory is freed as part of the pop).
    /// Returns null if only the base layer remains.
    pub fn pop(self: *OverlayStack, allocator: std.mem.Allocator) ?[]const u8 {
        if (self.layers.items.len <= 1) {
            // Cannot pop the base layer.
            return null;
        }
        var layer = self.layers.pop();
        const name_copy = layer.name; // valid until deinit
        _ = name_copy;
        layer.deinit(allocator);
        return "popped"; // layer name was freed
    }

    /// Pop the topmost overlay and return its name (duped so the caller
    /// owns it). Returns null if only the base layer remains.
    pub fn popNamed(self: *OverlayStack, allocator: std.mem.Allocator) !?[]const u8 {
        if (self.layers.items.len <= 1) {
            return null;
        }
        var layer = self.layers.pop();
        const name = try allocator.dupe(u8, layer.name);
        layer.deinit(allocator);
        return name;
    }

    /// Look up an environment variable by walking the stack top-down.
    /// The first active layer that defines the variable wins.
    pub fn getEnvVar(self: *const OverlayStack, key: []const u8) ?[]const u8 {
        // Walk from top to bottom.
        var i: usize = self.layers.items.len;
        while (i > 0) {
            i -= 1;
            const layer = &self.layers.items[i];
            if (!layer.active) continue;
            if (layer.getEnvVar(key)) |val| {
                return val;
            }
        }
        return null;
    }

    /// Look up a command by walking the stack top-down.
    pub fn getCommand(self: *const OverlayStack, name: []const u8) ?[]const []const u8 {
        var i: usize = self.layers.items.len;
        while (i > 0) {
            i -= 1;
            const layer = &self.layers.items[i];
            if (!layer.active) continue;
            if (layer.getCommand(name)) |body| {
                return body;
            }
        }
        return null;
    }

    /// Set an env var on the topmost active layer.
    pub fn setEnvVar(self: *OverlayStack, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        if (self.layers.items.len == 0) return;
        const top = &self.layers.items[self.layers.items.len - 1];
        try top.setEnvVar(allocator, key, value);
    }

    /// Set a command on the topmost active layer.
    pub fn setCommand(self: *OverlayStack, allocator: std.mem.Allocator, name: []const u8, body_lines: []const []const u8) !void {
        if (self.layers.items.len == 0) return;
        const top = &self.layers.items[self.layers.items.len - 1];
        try top.setCommand(allocator, name, body_lines);
    }

    /// Return the number of layers (including the base).
    pub fn depth(self: *const OverlayStack) usize {
        return self.layers.items.len;
    }

    /// Return a list of layer names, bottom to top.
    /// Caller owns the returned slice but NOT the strings.
    pub fn listLayers(self: *const OverlayStack, allocator: std.mem.Allocator) ![]const []const u8 {
        var names: std.ArrayList([]const u8) = .{
            .items = &[_][]const u8{},
            .capacity = 0,
        };
        for (self.layers.items) |*layer| {
            try names.append(allocator, layer.name);
        }
        return try names.toOwnedSlice(allocator);
    }

    /// Activate or deactivate a layer by name. Returns true if found.
    pub fn setLayerActive(self: *OverlayStack, name: []const u8, active: bool) bool {
        for (self.layers.items) |*layer| {
            if (std.mem.eql(u8, layer.name, name)) {
                layer.active = active;
                return true;
            }
        }
        return false;
    }

    /// Get a reference to the topmost layer. Returns null if the stack is
    /// empty (should not happen in practice since the base layer is always
    /// present).
    pub fn top(self: *OverlayStack) ?*OverlayLayer {
        if (self.layers.items.len == 0) return null;
        return &self.layers.items[self.layers.items.len - 1];
    }

    /// Collect all env vars visible from the top of the stack, merging
    /// all active layers (top wins). Caller owns both the map and the
    /// duped strings inside it.
    pub fn collectEnvVars(self: *const OverlayStack, allocator: std.mem.Allocator) !std.StringHashMap([]const u8) {
        var merged: std.StringHashMap([]const u8) = std.StringHashMap([]const u8).empty;

        // Walk bottom to top so upper layers overwrite.
        for (self.layers.items) |*layer| {
            if (!layer.active) continue;
            var iter = layer.env_vars.iterator();
            while (iter.next()) |entry| {
                // If already present, free the old duped value.
                if (merged.fetchRemove(entry.key_ptr.*)) |removed| {
                    allocator.free(removed.key);
                    allocator.free(removed.value);
                }
                const k = try allocator.dupe(u8, entry.key_ptr.*);
                const v = try allocator.dupe(u8, entry.value_ptr.*);
                try merged.put(allocator, k, v);
            }
        }
        return merged;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "OverlayStack basic push/pop" {
    const allocator = std.testing.allocator;

    var stack = try OverlayStack.init(allocator);
    defer stack.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), stack.depth()); // base layer

    try stack.push(allocator, "math");
    try std.testing.expectEqual(@as(usize, 2), stack.depth());

    _ = stack.pop(allocator);
    try std.testing.expectEqual(@as(usize, 1), stack.depth());

    // Cannot pop the base layer.
    try std.testing.expect(stack.pop(allocator) == null);
    try std.testing.expectEqual(@as(usize, 1), stack.depth());
}

test "OverlayStack env var shadowing" {
    const allocator = std.testing.allocator;

    var stack = try OverlayStack.init(allocator);
    defer stack.deinit(allocator);

    try stack.setEnvVar(allocator, "FOO", "base_value");
    try std.testing.expectEqualStrings("base_value", stack.getEnvVar("FOO").?);

    try stack.push(allocator, "inner");
    try stack.setEnvVar(allocator, "FOO", "inner_value");
    try std.testing.expectEqualStrings("inner_value", stack.getEnvVar("FOO").?);

    _ = stack.pop(allocator);
    try std.testing.expectEqualStrings("base_value", stack.getEnvVar("FOO").?);
}

test "OverlayStack command override" {
    const allocator = std.testing.allocator;

    var stack = try OverlayStack.init(allocator);
    defer stack.deinit(allocator);

    const body = &[_][]const u8{"echo hello"};
    try stack.setCommand(allocator, "greet", body);

    const found = stack.getCommand("greet");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("echo hello", found.?[0]);
}

test "OverlayStack listLayers" {
    const allocator = std.testing.allocator;

    var stack = try OverlayStack.init(allocator);
    defer stack.deinit(allocator);

    try stack.push(allocator, "layer1");
    try stack.push(allocator, "layer2");

    const names = try stack.listLayers(allocator);
    defer allocator.free(names);

    try std.testing.expectEqual(@as(usize, 3), names.len);
    try std.testing.expectEqualStrings("global", names[0]);
    try std.testing.expectEqualStrings("layer1", names[1]);
    try std.testing.expectEqualStrings("layer2", names[2]);
}

test "OverlayStack setLayerActive" {
    const allocator = std.testing.allocator;

    var stack = try OverlayStack.init(allocator);
    defer stack.deinit(allocator);

    try stack.push(allocator, "temp");
    try stack.setEnvVar(allocator, "X", "from_temp");

    // Deactivate the "temp" layer -- lookup should skip it.
    try std.testing.expect(stack.setLayerActive("temp", false));
    try std.testing.expect(stack.getEnvVar("X") == null);

    // Re-activate.
    try std.testing.expect(stack.setLayerActive("temp", true));
    try std.testing.expectEqualStrings("from_temp", stack.getEnvVar("X").?);
}

test "OverlayStack collectEnvVars" {
    const allocator = std.testing.allocator;

    var stack = try OverlayStack.init(allocator);
    defer stack.deinit(allocator);

    try stack.setEnvVar(allocator, "A", "1");
    try stack.push(allocator, "upper");
    try stack.setEnvVar(allocator, "A", "2");
    try stack.setEnvVar(allocator, "B", "3");

    var merged = try stack.collectEnvVars(allocator);
    defer {
        var iter = merged.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        merged.deinit(allocator);
    }

    try std.testing.expectEqualStrings("2", merged.get("A").?);
    try std.testing.expectEqualStrings("3", merged.get("B").?);
}
